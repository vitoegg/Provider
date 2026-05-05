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


UPSTREAM_OWNER = os.environ.get("UPSTREAM_OWNER", "immortalwrt")
UPSTREAM_REPO = os.environ.get("UPSTREAM_REPO", "immortalwrt")
UPSTREAM_BRANCH = os.environ.get("UPSTREAM_BRANCH", "openwrt-25.12")
VAR_VERSION = os.environ.get("KERNEL_VERSION_VAR", "IMMORTALWRT_KERNEL_VERSION")
VAR_COMMIT = os.environ.get("KERNEL_COMMIT_VAR", "IMMORTALWRT_KERNEL_COMMIT")
STATE_FILE = os.environ.get("KERNEL_STATE_FILE", "")
DRY_RUN = os.environ.get("DRY_RUN", "").lower() in {"1", "true", "yes"}
TIMEZONE = ZoneInfo("Asia/Shanghai")


class MonitorError(Exception):
    pass


def log(event, **fields):
    payload = {"event": event, **fields}
    print(json.dumps(payload, ensure_ascii=False, sort_keys=True))


def request(method, url, token="", data=None):
    headers = {
        "Accept": "application/vnd.github+json",
        "User-Agent": "ProviderKernelMonitor/1.0",
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


def set_output(name, value):
    output_path = os.environ.get("GITHUB_OUTPUT", "")
    if not output_path:
        return
    with open(output_path, "a", encoding="utf-8") as output:
        output.write(f"{name}={value}\n")


def request_text(url):
    req = urllib.request.Request(url, headers={"User-Agent": "ProviderKernelMonitor/1.0"})
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return resp.read().decode("utf-8")
    except urllib.error.URLError as err:
        raise MonitorError(f"GET {url} failed: {err}") from err


def github_api_url(path, query=None):
    url = f"https://api.github.com{path}"
    if query:
        url += "?" + urllib.parse.urlencode(query)
    return url


def raw_url(path):
    return (
        f"https://raw.githubusercontent.com/{UPSTREAM_OWNER}/{UPSTREAM_REPO}/"
        f"{UPSTREAM_BRANCH}/{path}"
    )


def find_kernel_file(token):
    preferred = os.environ.get("KERNEL_PATCHVER", "").strip()
    if preferred:
        return f"target/linux/generic/kernel-{preferred}"

    path = f"/repos/{UPSTREAM_OWNER}/{UPSTREAM_REPO}/contents/target/linux/generic"
    _, entries = request(
        "GET",
        github_api_url(path, {"ref": UPSTREAM_BRANCH}),
        token=token,
    )
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


def parse_kernel_version(kernel_path):
    base_version = kernel_path.rsplit("-", 1)[-1]
    text = request_text(raw_url(kernel_path))
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


def latest_kernel_commit(token, kernel_path):
    path = f"/repos/{UPSTREAM_OWNER}/{UPSTREAM_REPO}/commits"
    _, commits = request(
        "GET",
        github_api_url(
            path,
            {"sha": UPSTREAM_BRANCH, "path": kernel_path, "per_page": "1"},
        ),
        token=token,
    )
    if not commits:
        raise MonitorError(f"未找到 {kernel_path} 的 commit 记录")

    commit = commits[0]
    committed_at = datetime.fromisoformat(
        commit["commit"]["committer"]["date"].replace("Z", "+00:00")
    ).astimezone(TIMEZONE)
    return {
        "sha": commit["sha"],
        "short_sha": commit["sha"][:12],
        "message": commit["commit"]["message"].splitlines()[0],
        "html_url": commit["html_url"],
        "committed_at": committed_at.strftime("%Y-%m-%d %H:%M:%S %Z"),
    }


def read_state():
    if STATE_FILE and os.path.exists(STATE_FILE):
        with open(STATE_FILE, "r", encoding="utf-8") as state:
            return json.load(state)

    if DRY_RUN:
        return {
            "version": os.environ.get("PREVIOUS_" + VAR_VERSION),
            "commit": os.environ.get("PREVIOUS_" + VAR_COMMIT),
        }

    return {}


def write_state(version, commit):
    set_output("cache_save", "true")
    set_output("state_version", version)
    set_output("state_commit", commit[:12])

    if DRY_RUN:
        log("state_dry_run", version=version, commit=commit[:12])
        return

    if not STATE_FILE:
        raise MonitorError("缺少 KERNEL_STATE_FILE")

    os.makedirs(os.path.dirname(STATE_FILE), exist_ok=True)
    with open(STATE_FILE, "w", encoding="utf-8") as state:
        json.dump({"version": version, "commit": commit}, state, ensure_ascii=False, indent=2)
        state.write("\n")
    log("state_written", path=STATE_FILE, version=version, commit=commit[:12])


def build_message(previous_version, current_version, commit):
    commit_url = html.escape(commit["html_url"], quote=True)
    return "\n".join(
        [
            "🚀 <b>ImmortalWrt Kernel 更新</b>",
            "",
            f"🧩 <b>分支</b>：<code>{html.escape(UPSTREAM_BRANCH)}</code>",
            (
                f"🔁 <b>版本</b>：<code>{html.escape(previous_version)}</code>"
                f" → <code>{html.escape(current_version)}</code>"
            ),
            f"🕒 <b>时间</b>：<code>{html.escape(commit['committed_at'])}</code>",
            f"🔗 <b>Commit</b>：<code>{html.escape(commit['short_sha'])}</code>",
            f"🌐 <b>GitHub</b>：<a href=\"{commit_url}\">查看提交</a>",
        ]
    )


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

    upstream_token = token
    set_output("cache_save", "false")
    kernel_path = find_kernel_file(upstream_token)
    current_version = parse_kernel_version(kernel_path)
    commit = latest_kernel_commit(upstream_token, kernel_path)
    log(
        "kernel_detected",
        branch=UPSTREAM_BRANCH,
        kernel_path=kernel_path,
        version=current_version,
        commit=commit["short_sha"],
    )

    state = read_state()
    previous_version = state.get("version")
    previous_commit = state.get("commit")

    if not previous_version:
        write_state(current_version, commit["sha"])
        log("state_initialized", version=current_version, commit=commit["short_sha"])
        return

    if previous_version == current_version:
        set_output("state_version", current_version)
        set_output("state_commit", commit["short_sha"])
        log("kernel_unchanged", version=current_version, commit=commit["short_sha"])
        return

    message = build_message(previous_version, current_version, commit)
    log(
        "kernel_changed",
        previous_version=previous_version,
        previous_commit=(previous_commit or "")[:12],
        current_version=current_version,
        current_commit=commit["short_sha"],
    )
    send_telegram(message)
    write_state(current_version, commit["sha"])


if __name__ == "__main__":
    try:
        main()
    except MonitorError as err:
        log("error", message=str(err))
        sys.exit(1)
