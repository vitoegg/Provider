#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import ipaddress
import json
import os
import re
import sys
import tempfile
import time
import urllib.request
from collections import Counter
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from typing import Dict, Iterable, List, Set, Tuple

DOMAIN = "domain"
FULL = "full"
DomainRule = Tuple[str, str]

LABEL_PATTERN = r'(?!-)[a-z0-9-]{1,63}(?<!-)'
TLD_PATTERN = r'(?!-)[a-z][a-z0-9-]{0,62}(?<!-)'
DOMAIN_PATTERN = re.compile(
    rf'^(?=.{{1,253}}$)({LABEL_PATTERN}\.)*{TLD_PATTERN}$'
)
IPV4_PATTERN = re.compile(r'^\d{1,3}(\.\d{1,3}){3}$')
INLINE_COMMENT_PATTERN = re.compile(r'\s+#')
TRAILING_COMMENT_PATTERN = re.compile(r'\s+[#!;].*$')

COSMETIC_MARKERS = (
    '#@$?#', '#@$#', '#$?#', '#@?#', '#@%#',
    '#$#', '#?#', '#%#', '#@#', '##', '$@$', '$$'
)
ADBLOCK_MARKERS = ('||', '@@', '##', '#%#', '#$#', '#?#')
DNS_MODIFIERS = frozenset({
    'badfilter', 'client', 'ctag', 'denyallow',
    'dnsrewrite', 'dnstype', 'important', 'respgeo'
})
UNCONDITIONAL_MODIFIERS = frozenset({'important'})
REMOTE_PREFIXES = ("https://", "http://")

DOMAIN_FAMILY = "domain"
IP_FAMILY = "ip"
FORMAT_FAMILIES = {
    "domain_adguard": DOMAIN_FAMILY,
    "domain_surge": DOMAIN_FAMILY,
    "domain_mosdns": DOMAIN_FAMILY,
    "ip_cidr": IP_FAMILY,
    "ip_nft": IP_FAMILY,
}


def is_valid_domain(domain: str) -> bool:
    return bool(DOMAIN_PATTERN.match(domain))


def covered_by(domain: str, suffixes: Set[str], strict: bool = False) -> bool:
    labels = domain.split('.')
    start = 1 if strict else 0
    return any(
        '.'.join(labels[index:]) in suffixes
        for index in range(start, len(labels))
    )


def optimize_domains(rules: Iterable[DomainRule]) -> List[DomainRule]:
    rules = list(rules)
    suffixes = {domain for kind, domain in rules if kind == DOMAIN}
    exacts = {domain for kind, domain in rules if kind == FULL}

    kept_suffixes: Set[str] = set()
    for domain in sorted(suffixes, key=lambda item: (item.count('.'), item)):
        if not covered_by(domain, kept_suffixes, strict=True):
            kept_suffixes.add(domain)

    return sorted(
        [(DOMAIN, domain) for domain in kept_suffixes] +
        [(FULL, domain) for domain in exacts if not covered_by(domain, kept_suffixes)]
    )


def exclude_domains(
    rules: Iterable[DomainRule],
    excludes: Iterable[DomainRule]
) -> List[DomainRule]:
    excludes = list(excludes)
    exclude_suffixes = {domain for kind, domain in excludes if kind == DOMAIN}
    exclude_exacts = {domain for kind, domain in excludes if kind == FULL}

    return [
        (kind, domain)
        for kind, domain in rules
        if not covered_by(domain, exclude_suffixes)
        and not (kind == FULL and domain in exclude_exacts)
    ]


def optimize_networks(networks: Iterable) -> List:
    kept = []
    max_end = {4: -1, 6: -1}

    for network in sorted(
        set(networks),
        key=lambda item: (item.version, int(item.network_address), item.prefixlen)
    ):
        end = int(network.broadcast_address)
        if end <= max_end[network.version]:
            continue
        kept.append(network)
        max_end[network.version] = end

    return kept


def clean_rule_lines(content: str) -> Iterable[str]:
    for raw_line in content.splitlines():
        line = raw_line.strip()
        if (
            not line or
            line.startswith(('#', ';', '!', '//', '/*')) or
            line.startswith('payload:') or
            '*/' in line
        ):
            continue
        line = TRAILING_COMMENT_PATTERN.sub('', line).strip()
        if line:
            yield line


def is_adblock_source(content: str) -> bool:
    for raw_line in content.splitlines():
        line = raw_line.strip().lower()
        if line.startswith('[adblock'):
            return True
        if line and not line.startswith(('!', '#')):
            if any(marker in line for marker in ADBLOCK_MARKERS):
                return True
    return False


def parse_adguard_line(
    line: str,
    adblock_source: bool
) -> Tuple[List[DomainRule], str]:
    if not line:
        return [], "empty"
    if line.startswith('!'):
        return [], "directive" if line.startswith('!#') else "comment"
    if line.startswith('['):
        return [], "header"
    if any(marker in line for marker in COSMETIC_MARKERS):
        return [], "cosmetic"
    if line.startswith('#'):
        return [], "comment"

    line = INLINE_COMMENT_PATTERN.split(line, 1)[0].strip()
    if not line:
        return [], "comment"
    if line.startswith('@@'):
        return [], "exception"
    if len(line) > 2 and line.startswith('/') and line.endswith('/'):
        return [], "regex"

    fields = line.split()
    if len(fields) > 1:
        if not IPV4_PATTERN.match(fields[0]) and ':' not in fields[0]:
            return [], "url_pattern"
        hosts = [field.lower() for field in fields[1:]]
        if not all(is_valid_domain(host) for host in hosts):
            return [], "invalid"
        return [(FULL, host) for host in hosts], "hosts"

    if line.startswith('||'):
        body = line[2:]
        separator = body.find('^')
        if separator == -1:
            domain = body
        else:
            domain = body[:separator]
            trailer = body[separator + 1:]
            if trailer:
                if not trailer.startswith('$'):
                    return [], "url_pattern"
                names = {
                    modifier.split('=', 1)[0].lstrip('~').strip()
                    for modifier in trailer[1:].split(',')
                }
                if not names <= DNS_MODIFIERS:
                    return [], "unsupported_modifier"
                if not names <= UNCONDITIONAL_MODIFIERS:
                    return [], "conditional"
    elif adblock_source or line.startswith('|') or any(
        character in line for character in '/$*^'
    ):
        return [], "url_pattern"
    else:
        domain = line

    domain = domain.lower()
    if not is_valid_domain(domain):
        return [], "invalid"
    return [(DOMAIN, domain)], "converted"


def parse_adguard(content: str) -> Tuple[List[DomainRule], Counter]:
    adblock_source = is_adblock_source(content)
    rules: List[DomainRule] = []
    stats: Counter = Counter()

    for raw_line in content.splitlines():
        parsed, reason = parse_adguard_line(raw_line.strip(), adblock_source)
        stats[reason] += 1
        rules.extend(parsed)

    return rules, stats


def parse_surge_line(line: str) -> Tuple[List[DomainRule], str]:
    if ',' in line:
        parts = [part.strip() for part in line.split(',', 2)]
        if len(parts) < 2:
            return [], "invalid"
        surge_type = parts[0].upper()
        domain = parts[1]
        if surge_type == "DOMAIN-SUFFIX":
            kind = DOMAIN
        elif surge_type == "DOMAIN":
            kind = FULL
        else:
            return [], "unsupported"
    elif line.startswith('.'):
        domain = line[1:]
        kind = DOMAIN
    else:
        domain = line
        kind = FULL

    domain = domain.strip().lower()
    if not is_valid_domain(domain):
        return [], "invalid"
    return [(kind, domain)], "converted"


def parse_mosdns_line(line: str) -> Tuple[List[DomainRule], str]:
    kind, separator, domain = line.partition(':')
    if not separator or kind not in (DOMAIN, FULL):
        return [], "unsupported"

    domain = domain.strip().lower()
    if not is_valid_domain(domain):
        return [], "invalid"
    return [(kind, domain)], "converted"


def parse_ip_cidr_line(line: str) -> Tuple[List, str]:
    if ',' in line:
        parts = [part.strip() for part in line.split(',')]
        if len(parts) >= 2 and parts[0].upper() in ("IP-CIDR", "IP-CIDR6"):
            line = parts[1]

    try:
        if '/' in line:
            return [ipaddress.ip_network(line, strict=False)], "converted"
        address = ipaddress.ip_address(line)
        prefix_length = 32 if address.version == 4 else 128
        return [ipaddress.ip_network(f"{address}/{prefix_length}")], "converted"
    except ValueError:
        return [], "invalid"


def parse_nft(content: str, label: str) -> Tuple[List, Counter]:
    networks = []
    in_elements = False

    for line_number, raw_line in enumerate(content.splitlines(), start=1):
        text = raw_line.split('#', 1)[0].strip()
        if not text:
            continue

        if not in_elements:
            if 'elements' not in text or '{' not in text:
                continue
            in_elements = True
            text = text.split('{', 1)[1]

        if '}' in text:
            text = text.split('}', 1)[0]
            in_elements = False

        for token in text.split(','):
            token = token.strip()
            if not token:
                continue
            parsed, reason = parse_ip_cidr_line(token)
            if reason != "converted":
                raise ValueError(f"nft IP集合 {label} 第 {line_number} 行无效: {token}")
            networks.extend(parsed)

    if in_elements:
        raise ValueError(f"nft IP集合未正确闭合: {label}")
    return networks, Counter()


LINE_PARSERS = {
    "domain_surge": parse_surge_line,
    "domain_mosdns": parse_mosdns_line,
}


def parse_source(
    rule_format: str,
    content: str,
    label: str,
    strict: bool = False
) -> Tuple[List, Counter]:
    if rule_format == "ip_nft":
        rules, stats = parse_nft(content, label)
    elif rule_format == "domain_adguard":
        rules, stats = parse_adguard(content)
    else:
        rules = []
        stats = Counter()
        for line_number, line in enumerate(clean_rule_lines(content), start=1):
            if rule_format == "ip_cidr":
                parsed, reason = parse_ip_cidr_line(line)
            else:
                parsed, reason = LINE_PARSERS[rule_format](line)
            stats[reason] += 1
            if reason != "converted" and strict:
                raise ValueError(f"来源 {label} 第 {line_number} 行无效: {line}")
            rules.extend(parsed)

    if not rules:
        raise ValueError(f"来源未产生有效规则: {label}")
    return rules, stats


def format_ignored(stats: Counter) -> str:
    ignored = {
        reason: count
        for reason, count in stats.items()
        if reason not in ("converted", "hosts", "comment", "empty", "header")
    }
    if not ignored:
        return ""
    return " 忽略: " + ", ".join(
        f"{reason}={count}" for reason, count in sorted(ignored.items())
    )


def workspace_path(workspace: Path, relative_path: str) -> Path:
    path = (workspace / relative_path).resolve()
    if path != workspace and workspace not in path.parents:
        raise ValueError(f"路径超出工作区: {relative_path}")
    return path


def read_location(workspace: Path, location: str) -> str:
    if location.startswith(REMOTE_PREFIXES):
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


def collect_excludes(
    rule: Dict,
    contents: Dict[str, str],
    generated: Dict[str, List],
    output_paths: Set[str]
) -> List[DomainRule]:
    excludes: List[DomainRule] = []

    for exclude_path in rule.get("exclude", []):
        if exclude_path in output_paths:
            if exclude_path not in generated:
                raise ValueError(f"规则 {rule['id']} 的依赖尚未生成: {exclude_path}")
            excludes.extend(generated[exclude_path])
        else:
            parsed, _ = parse_source(
                "domain_mosdns", contents[exclude_path], exclude_path, strict=True
            )
            excludes.extend(parsed)

    return optimize_domains(excludes)


def build_rulesets(rules: List[Dict], contents: Dict[str, str]) -> Dict[str, List]:
    output_paths = {rule["path"] for rule in rules}
    generated: Dict[str, List] = {}

    for rule in rules:
        rule_id = rule["id"]
        families = {FORMAT_FAMILIES[rule_format] for rule_format in rule["sources"]}
        if len(families) != 1:
            raise ValueError(f"规则 {rule_id} 不能混合域名与 IP 来源")
        family = next(iter(families))

        parsed_rules = []
        for rule_format, locations in rule["sources"].items():
            for location in locations:
                source_rules, stats = parse_source(
                    rule_format,
                    contents[location],
                    f"{rule_id}:{location}"
                )
                parsed_rules.extend(source_rules)
                ignored = format_ignored(stats)
                if ignored:
                    print(f"  {rule_id} <- {location.rsplit('/', 1)[-1]}:{ignored}")

        source_count = len(parsed_rules)
        if family == DOMAIN_FAMILY:
            excludes = collect_excludes(rule, contents, generated, output_paths)
            if excludes:
                parsed_rules = exclude_domains(parsed_rules, excludes)
            final_rules = optimize_domains(parsed_rules)
        else:
            if rule.get("exclude"):
                raise ValueError(f"IP 规则 {rule_id} 不支持 exclude")
            final_rules = optimize_networks(parsed_rules)

        if not final_rules:
            raise ValueError(f"规则 {rule_id} 的最终产物为空")
        generated[rule["path"]] = final_rules
        print(f"{rule_id}: {source_count} -> {len(final_rules)} 条")

    return generated


def render(family: str, rules: List) -> List[str]:
    if family == DOMAIN_FAMILY:
        return [f"{kind}:{domain}" for kind, domain in rules]
    return [network.with_prefixlen for network in rules]


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
    generated: Dict[str, List]
) -> List[str]:
    summaries = []
    pending_writes = []

    for rule in rules:
        relative_path = rule["path"]
        family = next(
            FORMAT_FAMILIES[rule_format] for rule_format in rule["sources"]
        )
        output_path = workspace_path(workspace, relative_path)
        new_rules = render(family, generated[relative_path])

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

        summaries.append(
            f"{rule['id']} (+{len(new_rule_set - old_rules)} -{len(old_rules - new_rule_set)})"
        )
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
