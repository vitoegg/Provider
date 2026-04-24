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
"""

import argparse
import ipaddress
import sys
import time
import os
import re
from typing import List, Tuple, Dict

# 编译正则模式以提升性能
REGEX_PATTERN = re.compile(r'[\*\[\]\(\)\\+\?\^\$\|]')
DOMAIN_PATTERN = re.compile(r'^[a-zA-Z0-9._-]+$')
SUPPORTED_FORMATS = ("adguard", "surge_domain_set", "ip_cidr")

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

def check_ip_cidr_rules(input_file: str) -> int:
    """校验文件中是否仍存在重复或被父网段覆盖的CIDR规则"""
    parsed_rules = []

    with open(input_file, 'r', encoding='utf-8') as file_handle:
        for line_number, line in enumerate(file_handle, start=1):
            converted_rule, rule_type = convert_ip_cidr_rule(line)
            if rule_type == "comment":
                continue
            if rule_type != "converted":
                print(
                    f"CIDR校验失败: 第 {line_number} 行不是有效的IP/CIDR规则: {line.strip()}",
                    file=sys.stderr
                )
                return 1
            parsed_rules.append(converted_rule)

    unique_rules = set(parsed_rules)
    duplicate_count = len(parsed_rules) - len(unique_rules)
    kept_networks, coverage_stats, covered_samples = remove_covered_ip_networks(
        [ipaddress.ip_network(rule, strict=False) for rule in unique_rules]
    )

    if duplicate_count > 0:
        print(f"CIDR校验失败: 发现 {duplicate_count} 条完全重复规则", file=sys.stderr)
    if coverage_stats["covered_subnets"] > 0:
        if covered_samples:
            parent_rule, child_rule = covered_samples[0]
            print(
                f"CIDR校验失败: 发现被父网段覆盖的子网段: {child_rule} <- {parent_rule}",
                file=sys.stderr
            )
        else:
            print(
                f"CIDR校验失败: 发现 {coverage_stats['covered_subnets']} 条被父网段覆盖的子网段",
                file=sys.stderr
            )

    if duplicate_count > 0 or coverage_stats["covered_subnets"] > 0:
        return 1

    print(
        f"CIDR校验通过: 共 {len(kept_networks)} 条规则，无重复且无覆盖子网段",
        file=sys.stderr
    )
    return 0

def parse_args():
    parser = argparse.ArgumentParser(description="MosDNS规则处理脚本")
    parser.add_argument("input_file", help="输入文件路径")
    parser.add_argument(
        "--format",
        choices=SUPPORTED_FORMATS,
        default="adguard",
        help="输入规则格式，默认 adguard"
    )
    parser.add_argument(
        "--check-redundant-ip-cidr",
        action="store_true",
        help="仅校验输入文件中是否还存在重复或被父网段覆盖的CIDR规则"
    )
    return parser.parse_args()

def main():
    args = parse_args()
    input_file = args.input_file

    converter = convert_adguard_to_mosdns
    optimizer = optimize_domains
    if args.format == "surge_domain_set":
        converter = convert_surge_domain_set_to_mosdns
    elif args.format == "ip_cidr":
        converter = convert_ip_cidr_rule
        optimizer = optimize_ip_networks

    if not os.path.exists(input_file):
        print("错误: 输入文件 '{}' 不存在".format(input_file), file=sys.stderr)
        sys.exit(1)

    if args.check_redundant_ip_cidr:
        sys.exit(check_ip_cidr_rules(input_file))

    start_time = time.time()

    # 初始化统计信息
    conversion_stats = {
        "total_lines": 0,
        "comments": 0,
        "allow_rules": 0,
        "keyword_or_regexp_rules": 0,
        "regex_rules": 0,
        "converted": 0,
        "mosdns_format": 0,
        "invalid": 0,
        "unknown": 0
    }

    print(f"[1/5] 读取和转换规则文件，输入格式: {args.format}...", file=sys.stderr)

    converted_rules = []

    try:
        with open(input_file, 'r', encoding='utf-8') as f:
            for line in f:
                line = line.strip()
                conversion_stats["total_lines"] += 1

                if not line:
                    continue

                converted_rule, rule_type = converter(line)

                # 统计转换结果
                if rule_type == "comment":
                    conversion_stats["comments"] += 1
                elif rule_type == "allow":
                    conversion_stats["allow_rules"] += 1
                elif rule_type == "keyword_or_regexp":
                    conversion_stats["keyword_or_regexp_rules"] += 1
                elif rule_type == "regex":
                    conversion_stats["regex_rules"] += 1
                elif rule_type == "converted":
                    conversion_stats["converted"] += 1
                    converted_rules.append(converted_rule)
                elif rule_type == "mosdns":
                    conversion_stats["mosdns_format"] += 1
                    converted_rules.append(converted_rule)
                elif rule_type == "invalid":
                    conversion_stats["invalid"] += 1
                else:
                    conversion_stats["unknown"] += 1

        filtered_rules = converted_rules
        if args.format == "ip_cidr":
            optimization_step_label = "优化IP规则"
        else:
            print(f"[2/5] 过滤正则表达式规则 ({len(converted_rules)} 条)...", file=sys.stderr)
            filtered_rules, regex_count = filter_regex_rules(converted_rules)
            conversion_stats["regex_rules"] = regex_count
            optimization_step_label = "优化域名规则"

        print(f"[3/5] {optimization_step_label} ({len(filtered_rules)} 条)...", file=sys.stderr)

        final_rules, optimization_stats = optimizer(filtered_rules)

        print(f"[4/5] 生成最终规则 ({len(final_rules)} 条)...", file=sys.stderr)

        # 输出最终规则
        for rule in final_rules:
            print(rule)

        print("[5/5] 输出统计信息...", file=sys.stderr)

        # 输出统计信息
        end_time = time.time()
        print(f"处理时间: {end_time - start_time:.2f} 秒", file=sys.stderr)
        print(f"总行数: {conversion_stats['total_lines']}", file=sys.stderr)
        print(f"注释行: {conversion_stats['comments']}", file=sys.stderr)
        print(f"允许规则: {conversion_stats['allow_rules']}", file=sys.stderr)
        print(f"Keyword/Regexp规则: {conversion_stats['keyword_or_regexp_rules']}", file=sys.stderr)
        print(f"正则规则: {conversion_stats['regex_rules']}", file=sys.stderr)
        print(f"转换规则: {conversion_stats['converted']}", file=sys.stderr)
        print(f"MosDNS格式: {conversion_stats['mosdns_format']}", file=sys.stderr)
        print(f"无效规则: {conversion_stats['invalid']}", file=sys.stderr)
        print(f"未知格式: {conversion_stats['unknown']}", file=sys.stderr)
        print(f"重复规则: {optimization_stats['duplicates']}", file=sys.stderr)
        if args.format != "ip_cidr":
            print(f"被父域名覆盖: {optimization_stats['wildcard_covered']}", file=sys.stderr)
            print(f"被domain规则覆盖的full规则: {optimization_stats['domain_covered_full']}", file=sys.stderr)
        else:
            print(f"被父网段覆盖的子网段: {optimization_stats['covered_subnets']}", file=sys.stderr)
        print(f"最终保留: {optimization_stats['kept']}", file=sys.stderr)

    except Exception as e:
        print(f"处理出错: {str(e)}", file=sys.stderr)
        sys.exit(1)

if __name__ == "__main__":
    main()
