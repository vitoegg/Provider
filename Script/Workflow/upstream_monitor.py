#!/usr/bin/env python3

import argparse
import hashlib
import html
import json
import os
import re
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError


GITHUB_API_BASE = "https://api.github.com"
USER_AGENT = "ProviderUpstreamMonitor/2.0"
MAX_ATTEMPTS = 4
MAX_RETRY_DELAY = 60
TELEGRAM_TEXT_LIMIT = 4096
TELEGRAM_CAPTION_LIMIT = 1024
HTML_TAG = re.compile(r"<[^>]+>")


class MonitorError(Exception):
    pass


class ConfigError(MonitorError):
    pass


class SendRejected(MonitorError):
    pass


def telegram_length(text):
    plain = html.unescape(HTML_TAG.sub("", text))
    return len(plain.encode("utf-16-le")) // 2


def log(event, **fields):
    print(json.dumps({"event": event, **fields}, ensure_ascii=False, sort_keys=True))


def require_object(value, path):
    if not isinstance(value, dict):
        raise ConfigError(f"{path} 必须是对象")
    return value


def require_list(value, path):
    if not isinstance(value, list) or not value:
        raise ConfigError(f"{path} 必须是非空数组")
    return value


def require_string(value, path):
    if not isinstance(value, str) or not value.strip():
        raise ConfigError(f"{path} 必须是非空字符串")
    return value.strip()


def split_repo(value, path):
    repo = require_string(value, path)
    parts = repo.split("/")
    if len(parts) != 2 or not all(parts):
        raise ConfigError(f"{path} 必须使用 owner/repo 格式")
    return parts[0], parts[1]


def validate_config(config):
    require_object(config, "config")
    require_string(config.get("timezone"), "timezone")

    require_string(config.get("photo"), "photo")

    sources = require_list(config.get("sources"), "sources")
    source_ids = set()
    for index, item in enumerate(sources):
        source = require_object(item, f"sources[{index}]")
        source_id = require_string(source.get("id"), f"sources[{index}].id")
        if source_id in source_ids:
            raise ConfigError(f"重复的版本源 id: {source_id}")
        source_ids.add(source_id)
        require_string(source.get("name"), f"sources[{index}].name")
        source_type = require_string(source.get("type"), f"sources[{index}].type")
        if source_type not in {"openwrt_kernel", "github_latest_release"}:
            raise ConfigError(f"不支持的版本检测类型: {source_type}")
        split_repo(source.get("repo"), f"sources[{index}].repo")
        if source_type == "openwrt_kernel":
            require_string(source.get("branch"), f"sources[{index}].branch")
            patchver = source.get("patchver", "")
            if not isinstance(patchver, str):
                raise ConfigError(f"sources[{index}].patchver 必须是字符串")


def load_config(path):
    try:
        with open(path, "r", encoding="utf-8") as stream:
            config = json.load(stream)
    except FileNotFoundError as err:
        raise ConfigError(f"配置文件不存在: {path}") from err
    except json.JSONDecodeError as err:
        raise ConfigError(f"配置文件 JSON 无效: {err}") from err
    validate_config(config)
    return config


class HttpClient:
    def __init__(self, github_token=""):
        self.github_token = github_token

    @staticmethod
    def _retryable_http_error(error):
        if error.code in {408, 429, 500, 502, 503, 504}:
            return True
        return error.code == 403 and error.headers.get("X-RateLimit-Remaining") == "0"

    @staticmethod
    def _retry_delay(error, attempt):
        headers = getattr(error, "headers", {}) or {}
        retry_after = headers.get("Retry-After")
        if retry_after:
            try:
                return min(max(float(retry_after), 1), MAX_RETRY_DELAY)
            except ValueError:
                pass
        reset = headers.get("X-RateLimit-Reset")
        if reset:
            try:
                return min(max(float(reset) - time.time() + 1, 1), MAX_RETRY_DELAY)
            except ValueError:
                pass
        return min(2 ** attempt, MAX_RETRY_DELAY)

    def request(self, method, url, *, headers=None, data=None):
        request_headers = {"User-Agent": USER_AGENT, **(headers or {})}
        safe_url = re.sub(r"(api\.telegram\.org/bot)[^/]+", r"\1<redacted>", url)
        idempotent = method == "GET"
        for attempt in range(MAX_ATTEMPTS):
            request = urllib.request.Request(
                url,
                data=data,
                headers=request_headers,
                method=method,
            )
            try:
                with urllib.request.urlopen(request, timeout=30) as response:
                    return response.read().decode("utf-8")
            except urllib.error.HTTPError as err:
                detail = err.read().decode("utf-8", errors="replace")
                retryable = (
                    self._retryable_http_error(err) if idempotent else err.code == 429
                )
                if attempt + 1 < MAX_ATTEMPTS and retryable:
                    delay = self._retry_delay(err, attempt)
                    log(
                        "request_retry",
                        attempt=attempt + 1,
                        delay=delay,
                        status=err.code,
                        url=safe_url,
                    )
                    time.sleep(delay)
                    continue
                error_class = (
                    SendRejected
                    if not idempotent and 400 <= err.code < 500
                    else MonitorError
                )
                raise error_class(
                    f"{method} {safe_url} 失败: HTTP {err.code} {detail}"
                ) from err
            except (urllib.error.URLError, TimeoutError) as err:
                if idempotent and attempt + 1 < MAX_ATTEMPTS:
                    delay = min(2 ** attempt, MAX_RETRY_DELAY)
                    log("request_retry", attempt=attempt + 1, delay=delay, url=safe_url)
                    time.sleep(delay)
                    continue
                raise MonitorError(f"{method} {safe_url} 失败: {err}") from err
        raise MonitorError(f"{method} {safe_url} 失败")

    def github(self, path, query=None):
        url = f"{GITHUB_API_BASE}{path}"
        if query:
            url += "?" + urllib.parse.urlencode(query)
        headers = {
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
        }
        if self.github_token:
            headers["Authorization"] = f"Bearer {self.github_token}"
        text = self.request("GET", url, headers=headers)
        try:
            return json.loads(text) if text else None
        except json.JSONDecodeError as err:
            raise MonitorError(f"GitHub API 返回无效 JSON: {url}") from err

    def text(self, url):
        return self.request("GET", url)

    def post_form(self, url, fields):
        data = urllib.parse.urlencode(fields).encode("utf-8")
        text = self.request(
            "POST",
            url,
            headers={"Content-Type": "application/x-www-form-urlencoded"},
            data=data,
        )
        try:
            return json.loads(text) if text else None
        except json.JSONDecodeError as err:
            raise MonitorError(f"接口返回无效 JSON: {url}") from err


def set_output(name, value):
    output_path = os.environ.get("GITHUB_OUTPUT", "")
    if not output_path:
        return
    with open(output_path, "a", encoding="utf-8") as output:
        output.write(f"{name}={value}\n")


def state_digest(state):
    payload = json.dumps(state, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()[:20]


def read_state(path):
    if not path or not os.path.exists(path):
        return {}
    try:
        with open(path, "r", encoding="utf-8") as state_file:
            state = json.load(state_file)
    except (OSError, json.JSONDecodeError) as err:
        raise MonitorError(f"状态文件无效: {path}: {err}") from err
    if not isinstance(state, dict):
        raise MonitorError(f"状态文件顶层必须是对象: {path}")
    return state


def write_state(path, state, dry_run):
    digest = state_digest(state)
    set_output("state_key", digest)
    if dry_run:
        log("state_dry_run", state=state, state_key=digest)
        return
    if not path:
        raise MonitorError("缺少 --state-file 或 MONITOR_STATE_FILE")

    state_dir = os.path.dirname(path)
    if state_dir:
        os.makedirs(state_dir, exist_ok=True)
    temporary_path = ""
    try:
        with tempfile.NamedTemporaryFile(
            "w",
            encoding="utf-8",
            dir=state_dir or ".",
            prefix=".upstream-state-",
            delete=False,
        ) as temporary:
            json.dump(state, temporary, ensure_ascii=False, indent=2)
            temporary.write("\n")
            temporary.flush()
            os.fsync(temporary.fileno())
            temporary_path = temporary.name
        os.replace(temporary_path, path)
    except OSError as err:
        if temporary_path:
            try:
                os.unlink(temporary_path)
            except OSError:
                pass
        raise MonitorError(f"写入状态文件失败: {path}: {err}") from err

    set_output("cache_save", "true")
    log("state_written", path=path, state_key=digest)


class TelegramClient:
    def __init__(self, http, dry_run):
        self.http = http
        self.dry_run = dry_run
        self.token = os.environ.get("TELEGRAM_BOT_TOKEN", "")
        self.chat_id = os.environ.get("TELEGRAM_CHAT_ID", "")

    def _post(self, method, limit, fields):
        body = fields.get("text") or fields.get("caption", "")
        if telegram_length(body) > limit:
            raise SendRejected(f"Telegram {method} 内容超过 {limit} 字符")
        if self.dry_run:
            log("telegram_dry_run", method=method, **fields)
            return
        if not self.token or not self.chat_id:
            raise MonitorError("缺少 TELEGRAM_BOT_TOKEN 或 TELEGRAM_CHAT_ID")
        result = self.http.post_form(
            f"https://api.telegram.org/bot{self.token}/{method}",
            {"chat_id": self.chat_id, **fields},
        )
        if not isinstance(result, dict) or not result.get("ok"):
            raise MonitorError(f"Telegram 通知发送失败: {result}")
        log("telegram_sent", method=method)

    def send(self, message):
        self._post(
            "sendMessage",
            TELEGRAM_TEXT_LIMIT,
            {
                "text": message,
                "parse_mode": "HTML",
                "disable_web_page_preview": "true",
            },
        )

    def send_photo(self, caption, photo):
        try:
            self._post(
                "sendPhoto",
                TELEGRAM_CAPTION_LIMIT,
                {
                    "photo": photo,
                    "caption": caption,
                    "parse_mode": "HTML",
                },
            )
        except SendRejected as err:
            log("telegram_photo_fallback", error=str(err))
            self.send(caption)


def quote_path_part(value):
    return urllib.parse.quote(value, safe="")


def raw_url(owner, repo, ref, path):
    return (
        "https://raw.githubusercontent.com/"
        f"{quote_path_part(owner)}/{quote_path_part(repo)}/"
        f"{quote_path_part(ref)}/{urllib.parse.quote(path)}"
    )


def github_repo_path(owner, repo):
    return f"/repos/{quote_path_part(owner)}/{quote_path_part(repo)}"


def normalize_version_item(item, source_id):
    if not isinstance(item, dict):
        raise MonitorError(f"版本状态 {source_id} 无效")
    version = str(item.get("version") or "").strip()
    if not version:
        raise MonitorError(f"版本状态 {source_id} 缺少 version")
    return {
        "version": version,
        "updated_at": str(item.get("updated_at") or "").strip(),
        "url": str(item.get("url") or "").strip(),
    }


def normalize_version_state(state, source_ids):
    if not state:
        return {}
    normalized = {}
    for source_id in source_ids:
        if source_id in state:
            normalized[source_id] = normalize_version_item(state[source_id], source_id)
    return normalized


def format_time(value, zone):
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as err:
        raise MonitorError(f"时间格式错误: {value}") from err
    return parsed.astimezone(zone).strftime("%Y-%m-%d %H:%M:%S %Z")


def latest_path_update(http, owner, repo, branch, path, zone):
    commits = http.github(
        f"{github_repo_path(owner, repo)}/commits",
        {"sha": branch, "path": path, "per_page": 1},
    )
    if not isinstance(commits, list) or not commits:
        raise MonitorError(f"未找到 {owner}/{repo}:{path} 的 commit 记录")
    commit = commits[0]
    try:
        committed_at = commit["commit"]["committer"]["date"]
        url = commit["html_url"]
    except (KeyError, TypeError) as err:
        raise MonitorError(f"{owner}/{repo}:{path} commit 响应不完整") from err
    return {"updated_at": format_time(committed_at, zone), "url": url}


def detect_openwrt_kernel(http, source, zone):
    owner, repo = split_repo(source["repo"], f"sources.{source['id']}.repo")
    branch = source["branch"]
    patchver = source.get("patchver", "").strip()
    if patchver:
        kernel_path = f"target/linux/generic/kernel-{patchver}"
    else:
        entries = http.github(
            f"{github_repo_path(owner, repo)}/contents/target/linux/generic",
            {"ref": branch},
        )
        if not isinstance(entries, list):
            raise MonitorError(f"{source['id']} kernel 目录响应格式错误")
        files = sorted(
            entry.get("name", "")
            for entry in entries
            if entry.get("type") == "file"
            and re.fullmatch(r"kernel-\d+\.\d+", entry.get("name", ""))
        )
        if len(files) != 1:
            raise MonitorError(
                f"{source['id']} 需要唯一 kernel-* 文件，实际为: {', '.join(files) or '无'}"
            )
        kernel_path = f"target/linux/generic/{files[0]}"

    base_version = kernel_path.rsplit("-", 1)[-1]
    text = http.text(raw_url(owner, repo, branch, kernel_path))
    version_match = re.search(
        rf"^LINUX_VERSION-{re.escape(base_version)}\s*=\s*(\S+)",
        text,
        re.MULTILINE,
    )
    suffix = version_match.group(1) if version_match else ""
    version = f"{base_version}{suffix}"
    if not re.search(
        rf"^LINUX_KERNEL_HASH-{re.escape(version)}\s*=\s*(\S+)",
        text,
        re.MULTILINE,
    ):
        raise MonitorError(f"未找到 {version} 对应的 LINUX_KERNEL_HASH")
    update = latest_path_update(http, owner, repo, branch, kernel_path, zone)
    log("source_detected", source=source["id"], version=version, path=kernel_path)
    return {"version": version, **update}


def detect_github_latest_release(http, source, zone):
    owner, repo = split_repo(source["repo"], f"sources.{source['id']}.repo")
    release = http.github(f"{github_repo_path(owner, repo)}/releases/latest")
    if not isinstance(release, dict):
        raise MonitorError(f"未找到 {owner}/{repo} 的 latest release")
    version = str(release.get("tag_name") or "").strip()
    published_at = str(release.get("published_at") or "").strip()
    if not version or not published_at:
        raise MonitorError(f"{owner}/{repo} latest release 缺少版本或发布时间")
    url = str(release.get("html_url") or "").strip()
    if not url:
        url = f"https://github.com/{owner}/{repo}/releases/tag/{quote_path_part(version)}"
    log("source_detected", source=source["id"], version=version)
    return {
        "version": version,
        "updated_at": format_time(published_at, zone),
        "url": url,
    }


def detect_versions(http, sources, zone):
    snapshots = {}
    for source in sources:
        if source["type"] == "openwrt_kernel":
            snapshots[source["id"]] = detect_openwrt_kernel(http, source, zone)
        else:
            snapshots[source["id"]] = detect_github_latest_release(http, source, zone)
    return snapshots


def changed_versions(previous, current, sources):
    changes = []
    for source in sources:
        source_id = source["id"]
        previous_item = previous.get(source_id)
        current_item = current[source_id]
        if previous_item and previous_item["version"] != current_item["version"]:
            changes.append(
                {
                    **current_item,
                    "id": source_id,
                    "name": source["name"],
                    "icon": source.get("icon", "📦"),
                    "previous": previous_item["version"],
                }
            )
    return changes


def build_version_message(changes):
    parts = ["🚀 <b>上游版本更新</b>"]
    for item in changes:
        url = html.escape(item["url"], quote=True)
        parts.append(
            "\n".join(
                [
                    f'{item["icon"]} <a href="{url}"><b>{html.escape(item["name"])}</b></a>',
                    f"<code>{html.escape(item['previous'])}</code> ➜ "
                    f"<code>{html.escape(item['version'])}</code>",
                    f"🕐 {html.escape(item['updated_at'])}",
                ]
            )
        )
    return "\n\n".join(parts)


def run_versions(config, http, telegram, state_path, dry_run, zone):
    if not state_path and not dry_run:
        raise MonitorError("缺少 --state-file 或 MONITOR_STATE_FILE")
    sources = config["sources"]
    source_ids = [source["id"] for source in sources]
    raw_state = read_state(state_path)
    previous = normalize_version_state(raw_state, source_ids)
    current = detect_versions(http, sources, zone)

    if not previous:
        write_state(state_path, current, dry_run)
        log("state_initialized", sources=source_ids)
        return

    changes = changed_versions(previous, current, sources)
    if changes:
        log("upstream_changed", sources=[change["id"] for change in changes])
        telegram.send_photo(
            build_version_message(changes),
            config["photo"],
        )
        write_state(state_path, current, dry_run)
        return

    if previous != current:
        write_state(state_path, current, dry_run)
        log("state_refreshed", state_key=state_digest(current))
        return

    log("upstream_unchanged", state_key=state_digest(current))


def parse_args():
    parser = argparse.ArgumentParser(description="上游版本监控")
    parser.add_argument(
        "--config",
        default=str(Path(__file__).with_name("upstream_config.json")),
        help="配置文件路径",
    )
    parser.add_argument("--state-file", default="", help="版本状态文件")
    parser.add_argument("--dry-run", action="store_true")
    return parser.parse_args()


def main():
    args = parse_args()
    config = load_config(args.config)
    try:
        zone = ZoneInfo(config["timezone"])
    except ZoneInfoNotFoundError as err:
        raise ConfigError(f"未知时区: {config['timezone']}") from err

    dry_run = args.dry_run or os.environ.get("DRY_RUN", "").lower() in {
        "1",
        "true",
        "yes",
    }
    token = os.environ.get("GITHUB_TOKEN", "")
    if not token and not dry_run:
        raise MonitorError("缺少 GITHUB_TOKEN")
    state_path = args.state_file or os.environ.get("MONITOR_STATE_FILE", "")
    set_output("cache_save", "false")

    http = HttpClient(token)
    telegram = TelegramClient(http, dry_run)
    run_versions(config, http, telegram, state_path, dry_run, zone)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        log("error", message="用户中断执行")
        sys.exit(130)
    except MonitorError as err:
        log("error", message=str(err))
        sys.exit(1)
