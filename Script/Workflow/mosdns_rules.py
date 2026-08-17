#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
MosDNS规则处理脚本
功能:
1. 将AdGuard Home规则转换为MosDNS规则
2. 将Surge domain-set规则转换为MosDNS规则
3. 将IP/CIDR规则规范化为纯CIDR格式
4. 去掉正则匹配类型的规则
5. 按规则类型执行去重和优化
6. 支持用MosDNS域名规则排除被覆盖的域名
"""

import json
import ipaddress
import os
import re
import sys
import tempfile
import time
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from typing import Dict, Iterable, List, Tuple

# 编译正则模式以提升性能
REGEX_PATTERN = re.compile(r'[\*\[\]\(\)\\+\?\^\$\|]')
DOMAIN_PATTERN = re.compile(r'^[a-zA-Z0-9._-]+$')
DOMAIN_FAMILY = "domain"
IP_FAMILY = "ip"
FORMAT_FAMILIES = {
    "domain_adguard": DOMAIN_FAMILY,
    "domain_surge": DOMAIN_FAMILY,
    "domain_mosdns": DOMAIN_FAMILY,
    "ip_cidr": IP_FAMILY,
    "ip_nft": IP_FAMILY,
}

def is_regex_rule(rule: str) -> bool:
    """检查MosDNS规则是否为正则表达式规则"""
    if rule.startswith('domain:') or rule.startswith('full:'):
        domain_part = rule.split(':', 1)[1]
        return bool(REGEX_PATTERN.search(domain_part))
    return False

def convert_adguard_to_mosdns(rule: str) -> Tuple[str, str]:
    """
    将AdGuard Home规则转换为MosDNS规则
    返回: (转换后的规则, 规则类型)
    """
    original_rule = rule.strip()

    # 跳过注释和空行
    if not original_rule or original_rule.startswith('#') or original_rule.startswith('!'):
        return "", "comment"

    # 跳过允许规则（@@开头）
    if original_rule.startswith('@@'):
        return "", "allow"

    # 跳过 keyword: 和 regexp: 类型规则
    if original_rule.startswith('keyword:') or original_rule.startswith('regexp:'):
        return "", "keyword_or_regexp"

    # 格式7: 已经是MosDNS格式 (domain:example.com 或 full:example.com)
    if original_rule.startswith('domain:') or original_rule.startswith('full:'):
        return original_rule, "mosdns"

    # 处理不同格式的AdGuard规则
    domain = ""
    rule_type = "unknown"

    # 格式1: ||example.com^
    if original_rule.startswith('||') and original_rule.endswith('^'):
        domain = original_rule[2:-1]
        rule_type = "domain"

    # 格式2: ||example.com^$third-party
    elif original_rule.startswith('||') and '^' in original_rule:
        domain = original_rule[2:original_rule.index('^')]
        rule_type = "domain"

    # 格式3: |http://example.com
    elif original_rule.startswith('|http://'):
        domain = original_rule[8:]
        if '/' in domain:
            domain = domain[:domain.index('/')]
        rule_type = "domain"

    # 格式4: |https://example.com
    elif original_rule.startswith('|https://'):
        domain = original_rule[9:]
        if '/' in domain:
            domain = domain[:domain.index('/')]
        rule_type = "domain"

    # 格式6: .example.com (泛域名)
    elif original_rule.startswith('.'):
        domain = original_rule
        rule_type = "wildcard"

    # 格式5: example.com (简单域名格式)
    elif '.' in original_rule and not original_rule.startswith('.'):
        domain = original_rule
        rule_type = "domain"

    # 清理域名
    if domain:
        # 移除端口号
        if ':' in domain and not domain.startswith('domain:') and not domain.startswith('full:'):
            domain = domain[:domain.index(':')]

        # 移除路径
        if '/' in domain:
            domain = domain[:domain.index('/')]

        # 移除查询参数
        if '?' in domain:
            domain = domain[:domain.index('?')]

        # 基本验证域名格式（允许一些特殊字符，后续再过滤）
        if not re.match(r'^[a-zA-Z0-9._*+?^$|()\[\]\\-]+$', domain):
            return "", "invalid"

        # 转换为MosDNS格式
        if rule_type == "wildcard":
            return f"domain:{domain[1:]}", "converted"
        else:
            return f"domain:{domain}", "converted"

    return "", "unknown"

def convert_surge_domain_set_to_mosdns(rule: str) -> Tuple[str, str]:
    """
    将Surge domain-set规则转换为MosDNS规则
    .example.com -> domain:example.com
    example.com -> full:example.com
    """
    original_rule = rule.strip()

    # 跳过注释和空行
    if not original_rule or original_rule.startswith('#') or original_rule.startswith(';') or original_rule.startswith('//'):
        return "", "comment"

    rule_type = ""
    domain = ""

    # 兼容Surge逗号规则，当前上游主要是domain-set纯域名格式
    if ',' in original_rule:
        parts = [part.strip() for part in original_rule.split(',', 2)]
        if len(parts) < 2:
            return "", "invalid"

        surge_type = parts[0].upper()
        domain = parts[1]

        if surge_type == "DOMAIN-SUFFIX":
            rule_type = "domain"
        elif surge_type == "DOMAIN":
            rule_type = "full"
        else:
            return "", "unknown"
    elif original_rule.startswith('.'):
        domain = original_rule[1:]
        rule_type = "domain"
    else:
        domain = original_rule
        rule_type = "full"

    domain = domain.strip().lower()

    if not domain or domain.startswith('.') or domain.endswith('.') or '..' in domain:
        return "", "invalid"

    if not DOMAIN_PATTERN.match(domain):
        return "", "invalid"

    if rule_type == "domain":
        return f"domain:{domain}", "converted"

    return f"full:{domain}", "converted"

def convert_ip_cidr_rule(rule: str) -> Tuple[str, str]:
    """
    将IP规则统一转换为标准CIDR格式
    支持以下输入:
    1. 1.2.3.0/24
    2. 240e::/20
    3. 1.2.3.4 -> 1.2.3.4/32
    4. IP-CIDR,1.2.3.0/24,no-resolve
    """
    original_rule = rule.strip()

    if (
        not original_rule or
        original_rule.startswith('#') or
        original_rule.startswith(';') or
        original_rule.startswith('!') or
        original_rule.startswith('//')
    ):
        return "", "comment"

    if ',' in original_rule:
        parts = [part.strip() for part in original_rule.split(',')]
        if len(parts) >= 2 and parts[0].upper() in ("IP-CIDR", "IP-CIDR6"):
            original_rule = parts[1]

    try:
        if '/' in original_rule:
            network = ipaddress.ip_network(original_rule, strict=False)
        else:
            address = ipaddress.ip_address(original_rule)
            prefix_length = 32 if address.version == 4 else 128
            network = ipaddress.ip_network(f"{address}/{prefix_length}", strict=False)
    except ValueError:
        return "", "invalid"

    return network.with_prefixlen, "converted"

def filter_regex_rules(rules: List[str]) -> Tuple[List[str], int]:
    """
    过滤掉正则表达式规则
    返回: (过滤后的规则列表, 被过滤的数量)
    """
    filtered_rules = []
    regex_count = 0

    for rule in rules:
        if is_regex_rule(rule):
            regex_count += 1
        else:
            filtered_rules.append(rule)

    return filtered_rules, regex_count

def convert_mosdns_domain_rule(rule: str) -> Tuple[str, str]:
    """严格解析MosDNS域名规则，仅接受 domain: 和 full:。"""
    original_rule = rule.strip()

    if (
        not original_rule or
        original_rule.startswith('#') or
        original_rule.startswith(';') or
        original_rule.startswith('!') or
        original_rule.startswith('//')
    ):
        return "", "comment"

    if original_rule.startswith('domain:'):
        prefix = "domain"
        domain = original_rule[7:]
    elif original_rule.startswith('full:'):
        prefix = "full"
        domain = original_rule[5:]
    else:
        return "", "invalid"

    domain = domain.strip().lower()

    if not domain or domain.startswith('.') or domain.endswith('.') or '..' in domain:
        return "", "invalid"

    if not DOMAIN_PATTERN.match(domain):
        return "", "invalid"

    return f"{prefix}:{domain}", "converted"

def sort_ip_network_key(network) -> Tuple[int, int, int]:
    """为IP网络生成稳定排序键"""
    return (network.version, int(network.network_address), network.prefixlen)

def remove_covered_ip_networks(networks) -> Tuple[List, Dict[str, int], List[Tuple[str, str]]]:
    """
    严格去重IP规则:
    1. 保留更大父网段
    2. 删除被父网段完整覆盖的子网段
    3. 不主动聚合相邻网段
    """
    kept_networks = []
    coverage_stats = {"covered_subnets": 0}
    max_end_by_version = {4: -1, 6: -1}
    max_end_network_by_version = {4: None, 6: None}
    covered_samples = []

    for network in sorted(networks, key=sort_ip_network_key):
        version = network.version
        network_end = int(network.broadcast_address)
        if network_end <= max_end_by_version[version]:
            coverage_stats["covered_subnets"] += 1
            parent_network = max_end_network_by_version[version]
            if parent_network is not None and len(covered_samples) < 5:
                covered_samples.append((parent_network.with_prefixlen, network.with_prefixlen))
            continue

        kept_networks.append(network)
        max_end_by_version[version] = network_end
        max_end_network_by_version[version] = network

    return kept_networks, coverage_stats, covered_samples

def optimize_domains(rules: List[str]) -> Tuple[List[str], Dict[str, int]]:
    """
    优化域名规则，合并重复和包含关系的域名
    返回: (优化后的规则列表, 统计信息)
    """
    stats = {
        "total": len(rules),
        "duplicates": 0,
        "wildcard_covered": 0,
        "domain_covered_full": 0,
        "kept": 0
    }

    # 分离不同类型的规则
    domain_rules = []  # domain:example.com
    full_rules = []    # full:example.com
    other_rules = []   # 其他格式

    for rule in rules:
        if rule.startswith('domain:'):
            domain_rules.append(rule[7:])  # 去掉 domain: 前缀
        elif rule.startswith('full:'):
            full_rules.append(rule[5:])  # 去掉 full: 前缀
        else:
            other_rules.append(rule)

    # 去重
    original_count = len(domain_rules) + len(full_rules) + len(other_rules)
    domain_rules = list(set(domain_rules))
    full_rules = list(set(full_rules))
    other_rules = list(set(other_rules))

    stats["duplicates"] = original_count - len(domain_rules) - len(full_rules) - len(other_rules)

    # 优化domain规则 - 按域名长度排序，短的在前
    sorted_domains = sorted(domain_rules, key=lambda x: (len(x.split('.')), x))

    # 使用集合进行高效查找
    kept_domains = set()
    for domain in sorted_domains:
        is_covered = False
        domain_parts = domain.split('.')

        # 检查是否被已保留的更短域名覆盖
        for i in range(1, len(domain_parts)):
            parent_domain = '.'.join(domain_parts[i:])
            if parent_domain in kept_domains:
                # 确保父域名确实能覆盖当前域名
                if domain.endswith('.' + parent_domain):
                    is_covered = True
                    stats["wildcard_covered"] += 1
                    break

        if not is_covered:
            kept_domains.add(domain)

    # 处理 full 规则 - 检查是否被 domain 规则覆盖
    kept_full_rules = []
    for full_domain in full_rules:
        is_covered = False

        # 检查 full 域名本身是否在 domain 集合中
        if full_domain in kept_domains:
            is_covered = True
            stats["domain_covered_full"] += 1
        else:
            # 检查 full 域名的任何父域名是否在 domain 集合中
            domain_parts = full_domain.split('.')
            for i in range(1, len(domain_parts)):
                parent_domain = '.'.join(domain_parts[i:])
                if parent_domain in kept_domains:
                    is_covered = True
                    stats["domain_covered_full"] += 1
                    break

        if not is_covered:
            kept_full_rules.append(f"full:{full_domain}")

    # 组装最终规则
    optimized_domains = [f"domain:{d}" for d in kept_domains]
    final_rules = optimized_domains + kept_full_rules + other_rules
    stats["kept"] = len(final_rules)

    return sorted(final_rules), stats

def is_covered_by_domain_rule(domain: str, domain_rules: set) -> bool:
    """判断域名是否被 domain: 规则覆盖。"""
    domain_parts = domain.split('.')
    for index in range(len(domain_parts)):
        parent_domain = '.'.join(domain_parts[index:])
        if parent_domain in domain_rules:
            return True
    return False

def parse_exclude_rules(lines: Iterable[str], label: str) -> List[str]:
    """加载MosDNS排除规则，非MosDNS域名规则直接失败。"""
    exclude_rules = []

    for line_number, line in enumerate(lines, start=1):
        converted_rule, rule_type = convert_mosdns_domain_rule(line)
        if rule_type == "comment":
            continue
        if rule_type != "converted":
            raise ValueError(
                f"排除规则 {label} 第 {line_number} 行无效: {line.strip()}"
            )
        exclude_rules.append(converted_rule)

    optimized_rules, _ = optimize_domains(exclude_rules)
    return optimized_rules

def apply_domain_exclusions(rules: List[str], exclude_rules: List[str]) -> Tuple[List[str], Dict[str, int]]:
    """按MosDNS domain/full语义移除被排除规则覆盖的域名。"""
    stats = {
        "exclude_rules": len(exclude_rules),
        "excluded_by_domain": 0,
        "excluded_by_full": 0,
        "kept": 0
    }

    exclude_domains = set()
    exclude_fulls = set()

    for rule in exclude_rules:
        if rule.startswith('domain:'):
            exclude_domains.add(rule[7:])
        elif rule.startswith('full:'):
            exclude_fulls.add(rule[5:])

    filtered_rules = []
    for rule in rules:
        if rule.startswith('domain:'):
            domain = rule[7:].lower()
            if is_covered_by_domain_rule(domain, exclude_domains):
                stats["excluded_by_domain"] += 1
                continue
        elif rule.startswith('full:'):
            domain = rule[5:].lower()
            if is_covered_by_domain_rule(domain, exclude_domains):
                stats["excluded_by_domain"] += 1
                continue
            if domain in exclude_fulls:
                stats["excluded_by_full"] += 1
                continue

        filtered_rules.append(rule)

    stats["kept"] = len(filtered_rules)
    return filtered_rules, stats

def optimize_ip_networks(rules: List[str]) -> Tuple[List[str], Dict[str, int]]:
    """
    规范化IP规则，执行完全重复去重和父网段覆盖子网段裁剪
    """
    unique_rules = set(rules)
    unique_networks = [
        ipaddress.ip_network(rule, strict=False)
        for rule in unique_rules
    ]
    kept_networks, coverage_stats, _ = remove_covered_ip_networks(unique_networks)
    stats = {
        "total": len(rules),
        "duplicates": len(rules) - len(unique_rules),
        "covered_subnets": coverage_stats["covered_subnets"],
        "kept": len(kept_networks)
    }

    return [network.with_prefixlen for network in kept_networks], stats

def parse_nft_ip_cidr_rules(lines: Iterable[str], label: str) -> List[str]:
    """从nftables set elements中提取IP/CIDR规则。"""
    nft_rules = []
    in_elements = False

    for line_number, line in enumerate(lines, start=1):
        content = line.split('#', 1)[0].strip()
        if not content:
            continue

        if not in_elements:
            if 'elements' not in content or '{' not in content:
                continue
            in_elements = True
            content = content.split('{', 1)[1]

        if '}' in content:
            content = content.split('}', 1)[0]
            in_elements = False

        for token in content.split(','):
            token = token.strip()
            if not token:
                continue
            converted_rule, rule_type = convert_ip_cidr_rule(token)
            if rule_type != "converted":
                raise ValueError(
                    f"nft IP集合 {label} 第 {line_number} 行无效: {token}"
                )
            nft_rules.append(converted_rule)

    if in_elements:
        raise ValueError(f"nft IP集合未正确闭合: {label}")
    if not nft_rules:
        raise ValueError(f"未从nft IP集合提取到有效IP/CIDR规则: {label}")

    return nft_rules

def clean_rule_lines(content: str) -> Iterable[str]:
    """执行各文本格式共用的轻量清理。"""
    for raw_line in content.splitlines():
        line = raw_line.strip()
        if (
            not line or
            line.startswith(('#', ';', '!', '//', '/*')) or
            line.startswith('payload:') or
            '*/' in line
        ):
            continue
        line = re.sub(r'\s+[#!;].*$', '', line).strip()
        if line:
            yield line


def convert_lines(lines: Iterable[str], converter) -> List[str]:
    converted_rules = []
    for line in lines:
        converted_rule, rule_type = converter(line)
        if rule_type in ("converted", "mosdns"):
            converted_rules.append(converted_rule)
    return converted_rules


def convert_source(rule_format: str, content: str, label: str) -> List[str]:
    converters = {
        "domain_adguard": convert_adguard_to_mosdns,
        "domain_surge": convert_surge_domain_set_to_mosdns,
        "domain_mosdns": convert_mosdns_domain_rule,
        "ip_cidr": convert_ip_cidr_rule,
    }

    if rule_format == "ip_nft":
        rules = parse_nft_ip_cidr_rules(content.splitlines(), label)
    else:
        converter = converters.get(rule_format)
        if converter is None:
            raise ValueError(f"不支持的规则格式: {rule_format}")
        rules = convert_lines(clean_rule_lines(content), converter)

    if not rules:
        raise ValueError(f"来源未产生有效规则: {label}")
    return rules


def workspace_path(workspace: Path, relative_path: str) -> Path:
    path = (workspace / relative_path).resolve()
    if path != workspace and workspace not in path.parents:
        raise ValueError(f"路径超出工作区: {relative_path}")
    return path


def read_location(workspace: Path, location: str) -> str:
    if location.startswith(("https://", "http://")):
        request = urllib.request.Request(
            location,
            headers={"User-Agent": "Provider-MosDNS-Workflow"}
        )
        with urllib.request.urlopen(request, timeout=30) as response:
            data = response.read()
        if not data:
            raise ValueError(f"下载内容为空: {location}")
        return data.decode("utf-8")

    path = workspace_path(workspace, location)
    if not path.is_file():
        raise FileNotFoundError(f"本地来源不存在: {location}")
    content = path.read_text(encoding="utf-8")
    if not content:
        raise ValueError(f"本地来源为空: {location}")
    return content


def load_config(workspace: Path) -> List[Dict]:
    config_path = workspace / "Script/Workflow/mosdns_config.json"
    config = json.loads(config_path.read_text(encoding="utf-8"))
    rules = config.get("mosdns_rules")
    if not isinstance(rules, list) or not rules:
        raise ValueError("mosdns_rules 必须是非空数组")

    seen_ids = set()
    seen_paths = set()
    for rule in rules:
        rule_id = rule.get("id")
        output_path = rule.get("path")
        sources = rule.get("sources")
        if not isinstance(rule_id, str) or not rule_id or rule_id in seen_ids:
            raise ValueError(f"规则 id 无效或重复: {rule_id}")
        if not isinstance(output_path, str) or not output_path or output_path in seen_paths:
            raise ValueError(f"规则 path 无效或重复: {output_path}")
        if not isinstance(sources, dict) or not sources:
            raise ValueError(f"规则 {rule_id} 的 sources 必须是非空对象")
        for rule_format, locations in sources.items():
            if rule_format not in FORMAT_FAMILIES:
                raise ValueError(f"规则 {rule_id} 使用了未知格式: {rule_format}")
            if not isinstance(locations, list) or not locations or not all(
                isinstance(location, str) and location for location in locations
            ):
                raise ValueError(f"规则 {rule_id} 的 {rule_format} 来源无效")
        excludes = rule.get("exclude", [])
        if not isinstance(excludes, list) or not all(
            isinstance(path, str) and path for path in excludes
        ):
            raise ValueError(f"规则 {rule_id} 的 exclude 无效")
        seen_ids.add(rule_id)
        seen_paths.add(output_path)
    return rules


def load_locations(workspace: Path, rules: List[Dict]) -> Dict[str, str]:
    output_paths = {rule["path"] for rule in rules}
    locations = {
        location
        for rule in rules
        for source_locations in rule["sources"].values()
        for location in source_locations
    }
    locations.update(
        exclude_path
        for rule in rules
        for exclude_path in rule.get("exclude", [])
        if exclude_path not in output_paths
    )
    ordered_locations = sorted(locations)
    with ThreadPoolExecutor(max_workers=min(8, len(ordered_locations))) as executor:
        contents = executor.map(
            lambda location: read_location(workspace, location),
            ordered_locations
        )
        return dict(zip(ordered_locations, contents))


def build_rulesets(
    rules: List[Dict],
    contents: Dict[str, str]
) -> Dict[str, List[str]]:
    output_paths = {rule["path"] for rule in rules}
    generated = {}

    for rule in rules:
        rule_id = rule["id"]
        families = {FORMAT_FAMILIES[rule_format] for rule_format in rule["sources"]}
        if len(families) != 1:
            raise ValueError(f"规则 {rule_id} 不能混合域名与 IP 来源")
        family = next(iter(families))

        converted_rules = []
        for rule_format, locations in rule["sources"].items():
            for location in locations:
                converted_rules.extend(convert_source(
                    rule_format,
                    contents[location],
                    f"{rule_id}:{location}"
                ))

        filtered_rules = converted_rules
        exclude_paths = rule.get("exclude", [])
        if exclude_paths:
            if family != DOMAIN_FAMILY:
                raise ValueError(f"IP 规则 {rule_id} 不支持 exclude")
            exclude_rules = []
            for exclude_path in exclude_paths:
                if exclude_path in output_paths:
                    if exclude_path not in generated:
                        raise ValueError(
                            f"规则 {rule_id} 的依赖尚未生成: {exclude_path}"
                        )
                    exclude_rules.extend(generated[exclude_path])
                else:
                    exclude_rules.extend(parse_exclude_rules(
                        clean_rule_lines(contents[exclude_path]),
                        exclude_path
                    ))
            exclude_rules, _ = optimize_domains(exclude_rules)
            filtered_rules, _ = apply_domain_exclusions(
                filtered_rules,
                exclude_rules
            )

        if family == DOMAIN_FAMILY:
            filtered_rules, _ = filter_regex_rules(filtered_rules)
            final_rules, _ = optimize_domains(filtered_rules)
        else:
            final_rules, _ = optimize_ip_networks(filtered_rules)

        if not final_rules:
            raise ValueError(f"规则 {rule_id} 的最终产物为空")
        generated[rule["path"]] = final_rules
        print(f"{rule_id}: {len(converted_rules)} -> {len(final_rules)} 条")

    return generated


def atomic_write(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(
        dir=path.parent,
        prefix=f".{path.name}.",
        text=True
    )
    temporary_path = Path(temporary_name)
    try:
        mode = path.stat().st_mode & 0o777 if path.exists() else 0o644
        os.fchmod(descriptor, mode)
        with os.fdopen(descriptor, "w", encoding="utf-8") as file_handle:
            file_handle.write(content)
        os.replace(temporary_path, path)
    finally:
        temporary_path.unlink(missing_ok=True)


def publish_rulesets(
    workspace: Path,
    rules: List[Dict],
    generated: Dict[str, List[str]]
) -> List[str]:
    summaries = []
    pending_writes = []

    for rule in rules:
        relative_path = rule["path"]
        output_path = workspace_path(workspace, relative_path)
        new_rules = generated[relative_path]
        old_rules = set()
        if output_path.is_file():
            old_rules = {
                line.strip()
                for line in output_path.read_text(encoding="utf-8").splitlines()
                if line.strip()
            }
        new_rule_set = set(new_rules)
        if old_rules == new_rule_set:
            continue
        added = len(new_rule_set - old_rules)
        removed = len(old_rules - new_rule_set)
        summaries.append(f"{rule['id']} (+{added} -{removed})")
        pending_writes.append((output_path, "\n".join(new_rules) + "\n"))

    for output_path, content in pending_writes:
        atomic_write(output_path, content)
    return summaries


def write_github_output(summaries: List[str]) -> None:
    output_path = os.environ.get("GITHUB_OUTPUT")
    if not output_path:
        return
    with open(output_path, "a", encoding="utf-8") as file_handle:
        file_handle.write(f"has_changes={'true' if summaries else 'false'}\n")
        file_handle.write(
            f"change_summary={', '.join(summaries) if summaries else 'no changes'}\n"
        )


def main() -> int:
    start_time = time.time()
    workspace = Path(os.environ.get("GITHUB_WORKSPACE", Path.cwd())).resolve()
    try:
        rules = load_config(workspace)
        contents = load_locations(workspace, rules)
        generated = build_rulesets(rules, contents)
        summaries = publish_rulesets(workspace, rules, generated)
        write_github_output(summaries)
    except Exception as error:
        print(f"错误: {error}", file=sys.stderr)
        return 1

    print(f"完成: {len(rules)} 个规则集，用时 {time.time() - start_time:.2f} 秒")
    return 0


if __name__ == "__main__":
    sys.exit(main())
