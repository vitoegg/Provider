#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
代理规则处理脚本
功能:
1. 按配置聚合本地与远程的 Surge domain-set 规则来源
2. 规范化并校验域名规则，剔除非法条目
3. 泛域名互相覆盖去重，并裁剪被泛域名覆盖的精确域名
4. 集合差分判定变更后原子写入产物
"""

import json
import os
import re
import sys
import tempfile
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime
from pathlib import Path
from typing import Dict, Iterable, List, Set, Tuple

DOMAIN_PATTERN = re.compile(r'^[a-zA-Z0-9.-]+$')
GITHUB_RAW_PATTERN = re.compile(r'^https?://raw\.githubusercontent\.com/([^/]+/[^/]+)/')
INLINE_COMMENT_PATTERN = re.compile(r'\s+[#!;].*$')
REPO_HOMEPAGE = "https://github.com/vitoegg/Provider"
CONFIG_RELATIVE_PATH = "Script/Workflow/proxy_config.json"
DOWNLOAD_ATTEMPTS = 3
DOWNLOAD_TIMEOUT = 30
MAX_WORKERS = 8

WILDCARD_KIND = "wildcard"
EXACT_KIND = "exact"


def is_valid_domain(domain: str) -> bool:
    """校验域名是否合法（不含前导点）。"""
    if not domain or len(domain) > 253:
        return False
    if not DOMAIN_PATTERN.match(domain):
        return False
    if domain.startswith('.') or domain.endswith('.') or '..' in domain:
        return False
    for part in domain.split('.'):
        if not part or len(part) > 63:
            return False
        if part.startswith('-') or part.endswith('-'):
            return False
    return True


def convert_domain_set_rule(line: str) -> Tuple[str, str]:
    """
    解析 Surge domain-set 规则
    .example.com -> 泛域名, example.com -> 精确域名
    返回: (规则, 类型) 类型为 wildcard / exact / invalid
    """
    rule = line.strip().lower()

    if rule.startswith('.'):
        if is_valid_domain(rule[1:]):
            return rule, WILDCARD_KIND
        return "", "invalid"

    if is_valid_domain(rule):
        return rule, EXACT_KIND
    return "", "invalid"


def clean_rule_lines(content: str) -> Iterable[str]:
    """剔除注释、空行与非规则行，并去掉行尾行内注释。"""
    for raw_line in content.splitlines():
        line = raw_line.strip()
        if (
            not line or
            line.startswith(('#', ';', '!', '//', '/*')) or
            line.startswith('payload:') or
            '*/' in line
        ):
            continue
        line = INLINE_COMMENT_PATTERN.sub('', line).strip()
        if line:
            yield line


def convert_source(content: str, label: str) -> Tuple[List[str], int]:
    """将单个来源转换为规则列表，返回 (规则列表, 无效条数)。"""
    rules = []
    invalid_count = 0

    for line in clean_rule_lines(content):
        rule, kind = convert_domain_set_rule(line)
        if kind == "invalid":
            invalid_count += 1
            continue
        rules.append(rule)

    if not rules:
        raise ValueError(f"来源未产生有效规则: {label}")
    return rules, invalid_count


def optimize_domains(rules: List[str]) -> Tuple[List[str], Dict[str, int]]:
    """
    去重并裁剪被覆盖的规则:
    1. 完全相同的规则去重
    2. 泛域名被更短的泛域名覆盖则丢弃
    3. 精确域名被泛域名的父域覆盖则丢弃
    """
    stats = {
        "total": len(rules),
        "duplicates": 0,
        "wildcard_covered": 0,
        "exact_covered": 0,
        "kept": 0,
    }

    seen: Set[str] = set()
    wildcards: List[str] = []
    exacts: List[str] = []

    for rule in rules:
        if rule in seen:
            stats["duplicates"] += 1
            continue
        seen.add(rule)
        if rule.startswith('.'):
            wildcards.append(rule[1:])
        else:
            exacts.append(rule)

    kept_wildcard_domains: Set[str] = set()
    kept_wildcards: List[str] = []
    for domain in sorted(wildcards, key=lambda item: (item.count('.'), item)):
        parts = domain.split('.')
        if any(
            '.'.join(parts[index:]) in kept_wildcard_domains
            for index in range(1, len(parts))
        ):
            stats["wildcard_covered"] += 1
            continue
        kept_wildcard_domains.add(domain)
        kept_wildcards.append(f".{domain}")

    kept_exacts: List[str] = []
    for domain in exacts:
        parts = domain.split('.')
        if any(
            '.'.join(parts[index:]) in kept_wildcard_domains
            for index in range(1, len(parts))
        ):
            stats["exact_covered"] += 1
            continue
        kept_exacts.append(domain)

    final_rules = sorted(kept_wildcards + kept_exacts)
    stats["kept"] = len(final_rules)
    return final_rules, stats


def is_remote(location: str) -> bool:
    return location.startswith(("https://", "http://"))


def source_display(location: str) -> str:
    """生成规则来源注释使用的展示地址。"""
    if not is_remote(location):
        return REPO_HOMEPAGE
    matched = GITHUB_RAW_PATTERN.match(location)
    if matched:
        return f"https://github.com/{matched.group(1)}"
    return location


def workspace_path(workspace: Path, relative_path: str) -> Path:
    path = (workspace / relative_path).resolve()
    if path != workspace and workspace not in path.parents:
        raise ValueError(f"路径超出工作区: {relative_path}")
    return path


def download(location: str) -> str:
    """带重试的远程下载。"""
    last_error = None
    for attempt in range(1, DOWNLOAD_ATTEMPTS + 1):
        try:
            request = urllib.request.Request(
                location,
                headers={"User-Agent": "Provider-Proxy-Workflow"}
            )
            with urllib.request.urlopen(request, timeout=DOWNLOAD_TIMEOUT) as response:
                data = response.read()
            if not data:
                raise ValueError("下载内容为空")
            return data.decode("utf-8")
        except (urllib.error.URLError, OSError, ValueError) as error:
            last_error = error
            if attempt < DOWNLOAD_ATTEMPTS:
                time.sleep(attempt * 2)
    raise RuntimeError(f"下载失败({DOWNLOAD_ATTEMPTS} 次): {location} -> {last_error}")


def read_location(workspace: Path, location: str) -> str:
    if is_remote(location):
        return download(location)

    path = workspace_path(workspace, location)
    if not path.is_file():
        raise FileNotFoundError(f"本地来源不存在: {location}")
    content = path.read_text(encoding="utf-8")
    if not content:
        raise ValueError(f"本地来源为空: {location}")
    return content


def load_config(workspace: Path) -> List[Dict]:
    config_path = workspace / CONFIG_RELATIVE_PATH
    if not config_path.is_file():
        raise FileNotFoundError(f"配置文件不存在: {CONFIG_RELATIVE_PATH}")

    config = json.loads(config_path.read_text(encoding="utf-8"))
    rules = config.get("rules")
    if not isinstance(rules, list) or not rules:
        raise ValueError("rules 必须是非空数组")

    seen_names: Set[str] = set()
    seen_paths: Set[str] = set()
    for rule in rules:
        name = rule.get("name")
        output_path = rule.get("path")
        sources = rule.get("sources")
        if not isinstance(name, str) or not name or name in seen_names:
            raise ValueError(f"规则 name 无效或重复: {name}")
        if not isinstance(output_path, str) or not output_path or output_path in seen_paths:
            raise ValueError(f"规则 path 无效或重复: {output_path}")
        if not isinstance(sources, list) or not sources or not all(
            isinstance(source, str) and source for source in sources
        ):
            raise ValueError(f"规则 {name} 的 sources 无效")
        seen_names.add(name)
        seen_paths.add(output_path)
    return rules


def load_locations(workspace: Path, rules: List[Dict]) -> Dict[str, str]:
    """并发读取所有非产物来源，任一失败即整体失败。"""
    output_paths = {rule["path"] for rule in rules}
    locations = sorted({
        source
        for rule in rules
        for source in rule["sources"]
        if source not in output_paths
    })
    with ThreadPoolExecutor(max_workers=min(MAX_WORKERS, len(locations))) as executor:
        contents = executor.map(
            lambda location: read_location(workspace, location),
            locations
        )
        return dict(zip(locations, contents))


def build_rulesets(rules: List[Dict], contents: Dict[str, str]) -> Dict[str, List[str]]:
    """按配置顺序生成规则集，后续规则可直接引用先前生成的产物。"""
    output_paths = {rule["path"] for rule in rules}
    generated: Dict[str, List[str]] = {}

    for rule in rules:
        name = rule["name"]
        collected: List[str] = []
        invalid_total = 0

        for source in rule["sources"]:
            if source in output_paths:
                if source not in generated:
                    raise ValueError(f"规则 {name} 的依赖尚未生成: {source}")
                collected.extend(generated[source])
                continue
            source_rules, invalid_count = convert_source(
                contents[source],
                f"{name}:{source}"
            )
            collected.extend(source_rules)
            invalid_total += invalid_count

        final_rules, stats = optimize_domains(collected)
        if not final_rules:
            raise ValueError(f"规则 {name} 的最终产物为空")

        generated[rule["path"]] = final_rules
        print(
            f"{name}: {stats['total']} -> {stats['kept']} 条 "
            f"(重复 {stats['duplicates']}, 泛域名覆盖 {stats['wildcard_covered']}, "
            f"精确域名覆盖 {stats['exact_covered']}, 无效 {invalid_total})"
        )

    return generated


def render_ruleset(rule: Dict, final_rules: List[str]) -> str:
    """生成含头部注释的产物内容。"""
    lines = [
        f"# 更新时间: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}",
        f"# 规则条数: {len(final_rules)}",
        "# 规则来源:",
    ]
    lines.extend(f"# - {source_display(source)}" for source in rule["sources"])
    lines.append("")
    lines.extend(final_rules)
    return "\n".join(lines) + "\n"


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


def read_existing_rules(path: Path) -> Set[str]:
    if not path.is_file():
        return set()
    return {
        line.strip()
        for line in path.read_text(encoding="utf-8").splitlines()
        if line.strip() and not line.startswith('#')
    }


def publish_rulesets(
    workspace: Path,
    rules: List[Dict],
    generated: Dict[str, List[str]]
) -> List[str]:
    """仅在规则内容变化时落盘，返回变更摘要。"""
    summaries = []
    pending_writes = []

    for rule in rules:
        relative_path = rule["path"]
        output_path = workspace_path(workspace, relative_path)
        final_rules = generated[relative_path]
        old_rules = read_existing_rules(output_path)
        new_rules = set(final_rules)

        if old_rules == new_rules:
            print(f"{rule['name']}: 无变化")
            continue

        added = len(new_rules - old_rules)
        removed = len(old_rules - new_rules)
        label = Path(relative_path).stem
        summaries.append(f"{label}(+{added}/-{removed})")
        pending_writes.append((output_path, render_ruleset(rule, final_rules)))
        print(f"{rule['name']}: 新增 {added} 条, 移除 {removed} 条")

    for output_path, content in pending_writes:
        atomic_write(output_path, content)
    return summaries


def write_github_output(summaries: List[str]) -> None:
    output_path = os.environ.get("GITHUB_OUTPUT")
    if not output_path:
        return
    with open(output_path, "a", encoding="utf-8") as file_handle:
        file_handle.write(f"has_changes={'true' if summaries else 'false'}\n")
        if summaries:
            file_handle.write(f"change_summary={' '.join(summaries)}\n")


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
