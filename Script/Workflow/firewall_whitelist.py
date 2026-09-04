#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import ipaddress
import os
import random
import re
import sys
import tempfile
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Set, Tuple
from zoneinfo import ZoneInfo

CODE_PATTERN = re.compile(r"^\d{6}$")
TRAILING_COMMENT_PATTERN = re.compile(r"\s+[#!;].*$")
ELEMENT_PATTERN = re.compile(r"^\s*(\d{1,3}(?:\.\d{1,3}){3}/\d{1,2}),?\s*$")
MIRRORS = (
    "https://raw.githubusercontent.com/metowolf/iplist/refs/heads/master",
    "https://metowolf.github.io/iplist",
)
CNCITY_PATH = "/data/cncity/{code}.txt"
ISP_PATH = "/data/isp/{name}.txt"
CLOUD_PROVIDERS = (
    "aliyun",
    "baidu",
    "bytedance",
    "huawei",
    "ksyun",
    "microsoft",
    "tencent",
    "ucloud",
    "volcengine",
)
BASESET_RELATIVE = "RuleSet/Extra/BaseSet/Firewall/whitelist.txt"
OUTPUT_RELATIVE = "RuleSet/Extra/Firewall/whitelist.nft"
USER_AGENT = "Provider-Firewall-Workflow"
DOWNLOAD_ROUNDS = 3
DOWNLOAD_TIMEOUT = 30
RETRY_BACKOFF = 2
RETRY_JITTER = 0.3
RETRIABLE_ERRORS = (urllib.error.URLError, OSError, ValueError, UnicodeDecodeError)
PERMANENT_EXCEPTIONS = (408, 429)
OUTPUT_DELIMITER = "FIREWALL_WHITELIST_EOF"
TIMEZONE = ZoneInfo("Asia/Shanghai")


def workspace_path(workspace: Path, relative_path: str) -> Path:
    path = (workspace / relative_path).resolve()
    if path != workspace and workspace not in path.parents:
        raise ValueError(f"路径超出工作区: {relative_path}")
    return path


def parse_city_codes(raw: str) -> List[str]:
    parts = [item for item in re.split(r"[,\s]+", raw.strip()) if item]
    if not parts:
        raise ValueError("WHITELIST_CITY_CODES 为空")
    codes: List[str] = []
    seen = set()
    for part in parts:
        if not CODE_PATTERN.fullmatch(part):
            raise ValueError(f"无效的区域 code: {part}")
        if part not in seen:
            codes.append(part)
            seen.add(part)
    return codes


def clean_rule_lines(content: str) -> Iterable[str]:
    for raw_line in content.splitlines():
        line = raw_line.strip()
        if not line or line.startswith(("#", ";", "!", "//")):
            continue
        line = TRAILING_COMMENT_PATTERN.sub("", line).strip()
        if line:
            yield line


def parse_networks(content: str, label: str, allow_empty: bool = False) -> List[ipaddress.IPv4Network]:
    networks: List[ipaddress.IPv4Network] = []
    for line_number, line in enumerate(clean_rule_lines(content), start=1):
        try:
            network = ipaddress.ip_network(line, strict=False)
            if not isinstance(network, ipaddress.IPv4Network):
                raise ValueError("仅支持 IPv4")
            networks.append(network)
        except ValueError as error:
            raise ValueError(f"{label} 第 {line_number} 行无效: {line}") from error
    if not networks and not allow_empty:
        raise ValueError(f"上游为空: {label}")
    return networks


def http_get(url: str) -> str:
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(request, timeout=DOWNLOAD_TIMEOUT) as response:
        data = response.read()
    if not data:
        raise ValueError("下载内容为空")
    return data.decode("utf-8")


def is_permanent(error: BaseException) -> bool:
    return (
        isinstance(error, urllib.error.HTTPError)
        and 400 <= error.code < 500
        and error.code not in PERMANENT_EXCEPTIONS
    )


def fetch_source(label: str, path: str) -> List[ipaddress.IPv4Network]:
    last_error: Optional[BaseException] = None
    dead: Set[str] = set()
    for round_index in range(DOWNLOAD_ROUNDS):
        for mirror in MIRRORS:
            if mirror in dead:
                continue
            try:
                return parse_networks(http_get(mirror + path), label)
            except RETRIABLE_ERRORS as error:
                last_error = error
                if is_permanent(error):
                    dead.add(mirror)
                print(f"{label}: {mirror} 失败 -> {error}", file=sys.stderr)
        if len(dead) == len(MIRRORS):
            break
        if round_index < DOWNLOAD_ROUNDS - 1:
            backoff = RETRY_BACKOFF * (round_index + 1)
            time.sleep(backoff * random.uniform(1 - RETRY_JITTER, 1 + RETRY_JITTER))
    raise RuntimeError(f"{last_error}")


def fetch_networks(
    sources: List[Tuple[str, str]],
) -> Dict[str, List[ipaddress.IPv4Network]]:
    results: Dict[str, List[ipaddress.IPv4Network]] = {}
    errors: List[str] = []
    with ThreadPoolExecutor(max_workers=min(8, len(sources))) as executor:
        futures = [executor.submit(fetch_source, label, path) for label, path in sources]
        for (label, _), future in zip(sources, futures):
            try:
                networks = future.result()
            except Exception as error:
                errors.append(f"{label}: {error}")
                continue
            print(f"{label}: {len(networks)} 条")
            results[label] = networks
    if errors:
        raise RuntimeError("上游获取失败:\n" + "\n".join(errors))
    return results


def summarize_range(start: int, end: int) -> Iterable[ipaddress.IPv4Network]:
    return ipaddress.summarize_address_range(
        ipaddress.IPv4Address(start), ipaddress.IPv4Address(end)
    )


def exclude_networks(
    base: List[ipaddress.IPv4Network],
    excluded: List[ipaddress.IPv4Network],
) -> List[ipaddress.IPv4Network]:
    bounds = [
        (int(network.network_address), int(network.broadcast_address))
        for network in ipaddress.collapse_addresses(excluded)
    ]
    kept: List[ipaddress.IPv4Network] = []
    index = 0
    for network in ipaddress.collapse_addresses(base):
        start = int(network.network_address)
        end = int(network.broadcast_address)
        while index < len(bounds) and bounds[index][1] < start:
            index += 1
        cursor = start
        probe = index
        while probe < len(bounds) and bounds[probe][0] <= end:
            hole_start, hole_end = bounds[probe]
            if hole_start > cursor:
                kept.extend(summarize_range(cursor, hole_start - 1))
            cursor = max(cursor, hole_end + 1)
            if cursor > end:
                break
            probe += 1
        if cursor <= end:
            kept.extend(summarize_range(cursor, end))
    return kept


def load_baseset(path: Path) -> List[ipaddress.IPv4Network]:
    if not path.is_file():
        raise FileNotFoundError(f"本地来源不存在: {path}")
    networks = parse_networks(path.read_text(encoding="utf-8"), "baseset", allow_empty=True)
    print(f"baseset: {len(networks)} 条")
    return networks


def render_nft(networks: List[ipaddress.IPv4Network]) -> str:
    if not networks:
        raise ValueError("最终产物为空")
    elements = ",\n".join(f"        {network}" for network in networks)
    return (
        "set whitelist4 {\n"
        "    type ipv4_addr\n"
        "    flags interval\n"
        "    auto-merge\n"
        "    elements = {\n"
        f"{elements}\n"
        "    }\n"
        "}\n"
    )


def extract_elements(content: str) -> Set[str]:
    matches = (ELEMENT_PATTERN.match(line) for line in content.splitlines())
    return {match.group(1) for match in matches if match}


def atomic_write(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(
        dir=path.parent,
        prefix=f".{path.name}.",
        text=True,
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


def build_caption(old_count: int, new_count: int, added: int, removed: int) -> str:
    now = datetime.now(TIMEZONE).strftime("%Y-%m-%d %H:%M")
    return (
        "🛡️ <b>防火墙白名单已同步</b>\n"
        "\n"
        f"📊 总条目变更  {old_count} ➜  {new_count}\n"
        f"➕ 新增  {added} 条\n"
        f"➖ 删除  {removed} 条\n"
        "\n"
        f"🕐 {now}"
    )


def write_github_output(has_changes: bool, added: int, removed: int, caption: str) -> None:
    output_path = os.environ.get("GITHUB_OUTPUT")
    if not output_path:
        return
    summary = f"whitelist (+{added} -{removed})" if has_changes else "no changes"
    with open(output_path, "a", encoding="utf-8") as file_handle:
        file_handle.write(f"has_changes={'true' if has_changes else 'false'}\n")
        file_handle.write(f"change_summary={summary}\n")
        if caption:
            file_handle.write(f"caption<<{OUTPUT_DELIMITER}\n{caption}\n{OUTPUT_DELIMITER}\n")


def main() -> int:
    start_time = time.time()
    workspace = Path(os.environ.get("GITHUB_WORKSPACE", Path.cwd())).resolve()
    try:
        codes = parse_city_codes(os.environ.get("WHITELIST_CITY_CODES", ""))
        output_path = workspace_path(workspace, OUTPUT_RELATIVE)
        baseset_path = workspace_path(workspace, BASESET_RELATIVE)

        baseset = load_baseset(baseset_path)
        sources = [(code, CNCITY_PATH.format(code=code)) for code in codes]
        sources.extend((name, ISP_PATH.format(name=name)) for name in CLOUD_PROVIDERS)
        fetched = fetch_networks(sources)

        city = [network for code in codes for network in fetched[code]]
        cloud = [network for name in CLOUD_PROVIDERS for network in fetched[name]]
        kept = exclude_networks(city, cloud)
        print(f"云段剔除：{len(cloud)} 条云段，{len(city)} -> {len(kept)} 条")

        collapsed = list(ipaddress.collapse_addresses(kept + baseset))
        nft_text = render_nft(collapsed)

        existing_text = output_path.read_text(encoding="utf-8") if output_path.is_file() else ""
        has_changes = nft_text != existing_text
        old_elements = extract_elements(existing_text)
        new_elements = {str(network) for network in collapsed}
        added = len(new_elements - old_elements)
        removed = len(old_elements - new_elements)

        caption = ""
        if has_changes:
            atomic_write(output_path, nft_text)
            caption = build_caption(len(old_elements), len(new_elements), added, removed)
            print(f"已写入 {output_path}：{len(city) + len(baseset)} -> {len(collapsed)} 条（+{added} -{removed}）")
        else:
            print(f"无变化：{len(collapsed)} 条")

        write_github_output(has_changes, added, removed, caption)
    except Exception as error:
        print(f"错误: {error}", file=sys.stderr)
        return 1

    print(f"完成，用时 {time.time() - start_time:.2f} 秒")
    return 0


if __name__ == "__main__":
    sys.exit(main())
