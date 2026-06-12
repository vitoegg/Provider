#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import html
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime
from zoneinfo import ZoneInfo


TIMEZONE = ZoneInfo(os.environ.get("MONITOR_TIMEZONE", "Asia/Shanghai"))
STATE_FILE = os.environ.get("MONITOR_STATE_FILE", os.environ.get("KERNEL_STATE_FILE", ""))
DRY_RUN = os.environ.get("DRY_RUN", "").lower() in {"1", "true", "yes"}
USER_AGENT = "ProviderUpstreamMonitor/1.0"

KERNEL_SOURCE = "immortalwrt_kernel"
MIHOMO_SOURCE = "mihomo_core"
OPENWRT_RELEASE_SOURCE = "openwrt_release"
SOURCE_ORDER = (KERNEL_SOURCE, MIHOMO_SOURCE, OPENWRT_RELEASE_SOURCE)
SOURCE_NAMES = {
    KERNEL_SOURCE: "ImmortalWrt Kernel",
    MIHOMO_SOURCE: "Mihomo Core",
    OPENWRT_RELEASE_SOURCE: "OpenWrt Release",
}


class MonitorError(Exception):
    pass


def log(event, **fields):
    payload = {"event": event, **fields}
    print(json.dumps(payload, ensure_ascii=False, sort_keys=True))


def request(method, url, token="", data=None):
    headers = {
        "Accept": "application/vnd.github+json",
        "User-Agent": USER_AGENT,
        "X-GitHub-Api-Version": "2022-11-28",
    }
    if token:
        headers["Authorization"] = f"Bearer {token}"

    body = None
    if data is not None:
        body = json.dumps(data).encode("utf-8")
        headers["Content-Type"] = "application/json"

    req = urllib.request.Request(url, data=body, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            text = resp.read().decode("utf-8")
            return resp.status, json.loads(text) if text else None
    except urllib.error.HTTPError as err:
        if err.code == 404:
            return 404, None
        detail = err.read().decode("utf-8", errors="replace")
        raise MonitorError(f"{method} {url} failed: HTTP {err.code} {detail}") from err
    except urllib.error.URLError as err:
        raise MonitorError(f"{method} {url} failed: {err}") from err


def request_text(url):
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return resp.read().decode("utf-8")
    except urllib.error.URLError as err:
        raise MonitorError(f"GET {url} failed: {err}") from err


def set_output(name, value):
    output_path = os.environ.get("GITHUB_OUTPUT", "")
    if not output_path:
        return
    with open(output_path, "a", encoding="utf-8") as output:
        output.write(f"{name}={value}\n")


def github_api_url(path, query=None):
    url = f"https://api.github.com{path}"
    if query:
        url += "?" + urllib.parse.urlencode(query)
    return url


def raw_url(owner, repo, ref, path):
    return f"https://raw.githubusercontent.com/{owner}/{repo}/{ref}/{path}"


def repo_parts(value, default_owner, default_repo):
    repo = value.strip()
    if not repo:
        return default_owner, default_repo
    parts = repo.split("/", 1)
    if len(parts) != 2 or not parts[0] or not parts[1]:
        raise MonitorError(f"仓库格式错误: {repo}")
    return parts[0], parts[1]


def format_time(value):
    if not value:
        return ""
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as err:
        raise MonitorError(f"时间格式错误: {value}") from err
    return parsed.astimezone(TIMEZONE).strftime("%Y-%m-%d %H:%M:%S %Z")


def normalize_item(item):
    if not isinstance(item, dict):
        return None
    version = str(item.get("version") or "").strip()
    if not version:
        return None
    return {
        "version": version,
        "updated_at": str(item.get("updated_at") or "").strip(),
        "url": str(item.get("url") or item.get("html_url") or "").strip(),
    }


def normalize_state(state):
    if not isinstance(state, dict):
        return {}

    if state.get("version"):
        legacy_item = normalize_item(
            {
                "version": state.get("version"),
                "updated_at": state.get("updated_at"),
                "url": state.get("url") or state.get("html_url"),
            }
        )
        return {KERNEL_SOURCE: legacy_item} if legacy_item else {}

    normalized = {}
    for source_id in SOURCE_ORDER:
        item = normalize_item(state.get(source_id))
        if item:
            normalized[source_id] = item
    return normalized


def read_state():
    if STATE_FILE and os.path.exists(STATE_FILE):
        with open(STATE_FILE, "r", encoding="utf-8") as state:
            return json.load(state)

    if not DRY_RUN:
        return {}

    state_json = os.environ.get("PREVIOUS_STATE_JSON", "")
    if state_json:
        return json.loads(state_json)

    kernel_var = os.environ.get("KERNEL_VERSION_VAR", "IMMORTALWRT_KERNEL_VERSION")
    kernel_version = os.environ.get("PREVIOUS_" + kernel_var, "")
    mihomo_version = os.environ.get("PREVIOUS_MIHOMO_CORE_VERSION", "")
    state = {}
    if kernel_version:
        state[KERNEL_SOURCE] = {"version": kernel_version}
    if mihomo_version:
        state[MIHOMO_SOURCE] = {
            "version": mihomo_version,
            "updated_at": os.environ.get("PREVIOUS_MIHOMO_CORE_UPDATED_AT", ""),
            "url": os.environ.get("PREVIOUS_MIHOMO_CORE_URL", ""),
        }
    openwrt_release_version = os.environ.get("PREVIOUS_OPENWRT_RELEASE_VERSION", "")
    if openwrt_release_version:
        state[OPENWRT_RELEASE_SOURCE] = {
            "version": openwrt_release_version,
            "updated_at": os.environ.get("PREVIOUS_OPENWRT_RELEASE_UPDATED_AT", ""),
            "url": os.environ.get("PREVIOUS_OPENWRT_RELEASE_URL", ""),
        }
    return state


def sanitize_key_part(value):
    cleaned = re.sub(r"[^A-Za-z0-9_.-]+", "-", value.strip())
    return cleaned.strip("-") or "unknown"


def state_key(snapshots):
    return "-".join(
        sanitize_key_part(snapshots.get(source_id, {}).get("version", "missing"))
        for source_id in SOURCE_ORDER
    )


def set_state_outputs(snapshots):
    set_output("state_key", state_key(snapshots))
    set_output("kernel_version", snapshots.get(KERNEL_SOURCE, {}).get("version", ""))
    set_output("mihomo_version", snapshots.get(MIHOMO_SOURCE, {}).get("version", ""))
    set_output(
        "openwrt_release_version",
        snapshots.get(OPENWRT_RELEASE_SOURCE, {}).get("version", ""),
    )


def write_state(snapshots):
    set_output("cache_save", "true")
    set_state_outputs(snapshots)

    if DRY_RUN:
        log("state_dry_run", state=snapshots)
        return

    if not STATE_FILE:
        raise MonitorError("缺少 MONITOR_STATE_FILE 或 KERNEL_STATE_FILE")

    state_dir = os.path.dirname(STATE_FILE)
    if state_dir:
        os.makedirs(state_dir, exist_ok=True)
    with open(STATE_FILE, "w", encoding="utf-8") as state:
        json.dump(snapshots, state, ensure_ascii=False, indent=2)
        state.write("\n")
    log("state_written", path=STATE_FILE, state_key=state_key(snapshots))


def find_kernel_file(token, owner, repo, branch):
    preferred = os.environ.get("KERNEL_PATCHVER", "").strip()
    if preferred:
        return f"target/linux/generic/kernel-{preferred}"

    path = f"/repos/{owner}/{repo}/contents/target/linux/generic"
    _, entries = request("GET", github_api_url(path, {"ref": branch}), token=token)
    files = sorted(
        entry["name"]
        for entry in entries or []
        if entry.get("type") == "file" and re.fullmatch(r"kernel-\d+\.\d+", entry["name"])
    )
    if not files:
        raise MonitorError("未找到 target/linux/generic/kernel-* 文件")
    if len(files) != 1:
        raise MonitorError(f"发现多个 kernel 文件，需设置 KERNEL_PATCHVER: {', '.join(files)}")
    return f"target/linux/generic/{files[0]}"


def parse_kernel_version(owner, repo, branch, kernel_path):
    base_version = kernel_path.rsplit("-", 1)[-1]
    text = request_text(raw_url(owner, repo, branch, kernel_path))
    version_match = re.search(
        rf"^LINUX_VERSION-{re.escape(base_version)}\s*=\s*(\S+)",
        text,
        re.MULTILINE,
    )
    suffix = version_match.group(1) if version_match else ""
    version = f"{base_version}{suffix}"

    hash_match = re.search(
        rf"^LINUX_KERNEL_HASH-{re.escape(version)}\s*=\s*(\S+)",
        text,
        re.MULTILINE,
    )
    if not hash_match:
        raise MonitorError(f"未找到 {version} 对应的 LINUX_KERNEL_HASH")
    return version


def latest_path_update(token, owner, repo, branch, path):
    _, commits = request(
        "GET",
        github_api_url(
            f"/repos/{owner}/{repo}/commits",
            {"sha": branch, "path": path, "per_page": "1"},
        ),
        token=token,
    )
    if not commits:
        raise MonitorError(f"未找到 {path} 的 commit 记录")

    commit = commits[0]
    return {
        "updated_at": format_time(commit["commit"]["committer"]["date"]),
        "url": commit["html_url"],
    }


def detect_kernel(token):
    owner = os.environ.get("KERNEL_UPSTREAM_OWNER", os.environ.get("UPSTREAM_OWNER", "immortalwrt"))
    repo = os.environ.get("KERNEL_UPSTREAM_REPO", os.environ.get("UPSTREAM_REPO", "immortalwrt"))
    branch = os.environ.get(
        "KERNEL_UPSTREAM_BRANCH",
        os.environ.get("UPSTREAM_BRANCH", "openwrt-25.12"),
    )
    kernel_path = find_kernel_file(token, owner, repo, branch)
    version = parse_kernel_version(owner, repo, branch, kernel_path)
    update = latest_path_update(token, owner, repo, branch, kernel_path)

    log(
        "source_detected",
        source=KERNEL_SOURCE,
        branch=branch,
        path=kernel_path,
        version=version,
    )
    return {
        "version": version,
        "updated_at": update["updated_at"],
        "url": update["url"],
    }


def detect_github_latest_release(token, source_id, repo_env, default_owner, default_repo):
    owner, repo = repo_parts(
        os.environ.get(repo_env, f"{default_owner}/{default_repo}"),
        default_owner,
        default_repo,
    )
    _, release = request(
        "GET",
        github_api_url(f"/repos/{owner}/{repo}/releases/latest"),
        token=token,
    )
    if not release:
        raise MonitorError(f"未找到 {owner}/{repo} 的 latest release")

    version = str(release.get("tag_name") or "").strip()
    published_at = str(release.get("published_at") or "").strip()
    if not version or not published_at:
        raise MonitorError(f"{owner}/{repo} latest release 缺少 tag_name 或 published_at")

    url = str(release.get("html_url") or "").strip()
    if not url:
        url = f"https://github.com/{owner}/{repo}/releases/tag/{version}"

    log(
        "source_detected",
        source=source_id,
        repo=f"{owner}/{repo}",
        version=version,
        published_at=published_at,
    )
    return {
        "version": version,
        "updated_at": format_time(published_at),
        "url": url,
    }


def detect_mihomo(token):
    return detect_github_latest_release(
        token,
        MIHOMO_SOURCE,
        "MIHOMO_REPO",
        "MetaCubeX",
        "mihomo",
    )


def detect_openwrt_release(token):
    return detect_github_latest_release(
        token,
        OPENWRT_RELEASE_SOURCE,
        "OPENWRT_RELEASE_REPO",
        "openwrt",
        "openwrt",
    )


def dry_run_current_state():
    state_json = os.environ.get("CURRENT_STATE_JSON", "")
    if not state_json:
        return None

    snapshots = normalize_state(json.loads(state_json))
    missing = [source_id for source_id in SOURCE_ORDER if source_id not in snapshots]
    if missing:
        raise MonitorError(f"CURRENT_STATE_JSON 缺少上游状态: {', '.join(missing)}")
    log("source_detected_dry_run", sources=list(snapshots))
    return snapshots


def detect_snapshots(token):
    dry_state = dry_run_current_state()
    if dry_state is not None:
        return dry_state

    return {
        KERNEL_SOURCE: detect_kernel(token),
        MIHOMO_SOURCE: detect_mihomo(token),
        OPENWRT_RELEASE_SOURCE: detect_openwrt_release(token),
    }


def changed_sources(previous, current):
    changes = []
    for source_id in SOURCE_ORDER:
        previous_item = previous.get(source_id)
        current_item = current.get(source_id)
        if not previous_item or not current_item:
            continue
        if previous_item["version"] == current_item["version"]:
            continue
        changes.append(
            {
                "source": source_id,
                "previous_version": previous_item["version"],
                "current": current_item,
            }
        )
    return changes


def build_message(changes):
    lines = ["🚀 <b>上游版本更新</b>", ""]
    for change in changes:
        current = change["current"]
        url = html.escape(current["url"], quote=True)
        lines.extend(
            [
                f"<b>{html.escape(SOURCE_NAMES[change['source']])}</b>",
                (
                    f"版本：<code>{html.escape(change['previous_version'])}</code>"
                    f" → <code>{html.escape(current['version'])}</code>"
                ),
                f"更新时间：<code>{html.escape(current['updated_at'])}</code>",
                f"链接：<a href=\"{url}\">查看更新</a>",
                "",
            ]
        )
    return "\n".join(lines).rstrip()


def send_telegram(message):
    token = os.environ.get("TELEGRAM_BOT_TOKEN", "")
    chat_id = os.environ.get("TELEGRAM_CHAT_ID", "")
    if not token or not chat_id:
        raise MonitorError("缺少 TELEGRAM_BOT_TOKEN 或 TELEGRAM_CHAT_ID")

    if DRY_RUN:
        log("telegram_dry_run", message=message)
        return

    url = f"https://api.telegram.org/bot{token}/sendMessage"
    data = urllib.parse.urlencode(
        {
            "chat_id": chat_id,
            "text": message,
            "parse_mode": "HTML",
            "disable_web_page_preview": "true",
        }
    ).encode("utf-8")
    req = urllib.request.Request(url, data=data, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            result = json.loads(resp.read().decode("utf-8"))
    except urllib.error.URLError as err:
        raise MonitorError(f"Telegram 通知发送失败: {err}") from err

    if not result.get("ok"):
        raise MonitorError(f"Telegram 通知发送失败: {result}")
    log("telegram_sent")


def main():
    token = os.environ.get("GITHUB_TOKEN", "")
    if not token and not DRY_RUN:
        raise MonitorError("缺少 GITHUB_TOKEN")

    set_output("cache_save", "false")
    raw_state = read_state()
    previous = normalize_state(raw_state)
    current = detect_snapshots(token)
    set_state_outputs(current)

    if not previous:
        write_state(current)
        log("state_initialized", sources=list(current))
        return

    changes = changed_sources(previous, current)
    if changes:
        log(
            "upstream_changed",
            sources=[change["source"] for change in changes],
            state_key=state_key(current),
        )
        send_telegram(build_message(changes))
        write_state(current)
        return

    if previous != current:
        write_state(current)
        log("state_refreshed", state_key=state_key(current))
        return

    log("upstream_unchanged", state_key=state_key(current))


if __name__ == "__main__":
    try:
        main()
    except MonitorError as err:
        log("error", message=str(err))
        sys.exit(1)
