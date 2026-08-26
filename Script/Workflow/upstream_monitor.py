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
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from pathlib import Path
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError


GITHUB_API_BASE = "https://api.github.com"
USER_AGENT = "ProviderUpstreamMonitor/2.0"
MAX_ATTEMPTS = 4
MAX_RETRY_DELAY = 60
MAX_COMMIT_PAGES = 20
COMPARE_FILE_LIMIT = 300
TELEGRAM_TEXT_LIMIT = 4096
TELEGRAM_CAPTION_LIMIT = 1024


class MonitorError(Exception):
    pass


class ConfigError(MonitorError):
    pass


class NotFoundError(MonitorError):
    pass


class CursorError(MonitorError):
    pass


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

    telegram = require_object(config.get("telegram"), "telegram")
    if telegram.get("parse_mode") != "HTML":
        raise ConfigError("telegram.parse_mode 目前只支持 HTML")
    if not isinstance(telegram.get("disable_web_page_preview"), bool):
        raise ConfigError("telegram.disable_web_page_preview 必须是布尔值")

    tasks = require_object(config.get("tasks"), "tasks")
    lookback = tasks.get("default_lookback_hours")
    if type(lookback) is not int or lookback <= 0:
        raise ConfigError("tasks.default_lookback_hours 必须是正整数")

    repositories = require_list(tasks.get("repositories"), "tasks.repositories")
    repo_ids = set()
    for index, item in enumerate(repositories):
        repo_config = require_object(item, f"tasks.repositories[{index}]")
        repo_id = require_string(repo_config.get("id"), f"tasks.repositories[{index}].id")
        if repo_id in repo_ids:
            raise ConfigError(f"重复的任务仓库 id: {repo_id}")
        repo_ids.add(repo_id)
        require_string(repo_config.get("name"), f"tasks.repositories[{index}].name")
        split_repo(repo_config.get("repo"), f"tasks.repositories[{index}].repo")
        require_string(repo_config.get("branch"), f"tasks.repositories[{index}].branch")

    files = require_object(tasks.get("files"), "tasks.files")
    require_string(files.get("prefix"), "tasks.files.prefix")
    extensions = require_list(files.get("extensions"), "tasks.files.extensions")
    if any(not isinstance(ext, str) or not ext.startswith(".") for ext in extensions):
        raise ConfigError("tasks.files.extensions 必须是以点开头的字符串数组")
    versions = require_object(config.get("versions"), "versions")
    require_string(versions.get("photo"), "versions.photo")
    sources = require_list(versions.get("sources"), "versions.sources")
    source_ids = set()
    for index, item in enumerate(sources):
        source = require_object(item, f"versions.sources[{index}]")
        source_id = require_string(source.get("id"), f"versions.sources[{index}].id")
        if source_id in source_ids:
            raise ConfigError(f"重复的版本源 id: {source_id}")
        source_ids.add(source_id)
        require_string(source.get("name"), f"versions.sources[{index}].name")
        source_type = require_string(source.get("type"), f"versions.sources[{index}].type")
        if source_type not in {"openwrt_kernel", "github_latest_release"}:
            raise ConfigError(f"不支持的版本检测类型: {source_type}")
        split_repo(source.get("repo"), f"versions.sources[{index}].repo")
        if source_type == "openwrt_kernel":
            require_string(source.get("branch"), f"versions.sources[{index}].branch")
            patchver = source.get("patchver", "")
            if not isinstance(patchver, str):
                raise ConfigError(f"versions.sources[{index}].patchver 必须是字符串")


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
                if attempt + 1 < MAX_ATTEMPTS and self._retryable_http_error(err):
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
                if err.code == 404:
                    raise NotFoundError(f"{method} {safe_url} 失败: HTTP 404") from err
                raise MonitorError(
                    f"{method} {safe_url} 失败: HTTP {err.code} {detail}"
                ) from err
            except (urllib.error.URLError, TimeoutError) as err:
                if attempt + 1 < MAX_ATTEMPTS:
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
    def __init__(self, http, config, dry_run):
        self.http = http
        self.config = config
        self.dry_run = dry_run
        self.token = os.environ.get("TELEGRAM_BOT_TOKEN", "")
        self.chat_id = os.environ.get("TELEGRAM_CHAT_ID", "")

    def _post(self, method, limit, fields):
        body = fields.get("text") or fields.get("caption", "")
        if len(body) > limit:
            raise MonitorError(f"Telegram {method} 内容超过 {limit} 字符")
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
                "parse_mode": self.config["parse_mode"],
                "disable_web_page_preview": str(
                    self.config["disable_web_page_preview"]
                ).lower(),
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
                    "parse_mode": self.config["parse_mode"],
                },
            )
        except MonitorError as err:
            log("telegram_photo_fallback", error=str(err))
            self.send(caption)

    def send_all(self, messages):
        for message in messages:
            self.send(message)


@dataclass
class TaskInfo:
    task_id: str
    task_name: str = ""


@dataclass
class RepoTaskChanges:
    repo_id: str
    repo_name: str
    head_sha: str
    bootstrap: bool
    added: list = field(default_factory=list)
    modified: list = field(default_factory=list)
    removed: list = field(default_factory=list)

    @property
    def has_changes(self):
        return bool(self.added or self.modified or self.removed)


def quote_path_part(value):
    return urllib.parse.quote(value, safe="")


def raw_url(owner, repo, ref, path):
    return (
        "https://raw.githubusercontent.com/"
        f"{quote_path_part(owner)}/{quote_path_part(repo)}/"
        f"{quote_path_part(ref)}/{urllib.parse.quote(path)}"
    )


def task_file_matches(filename, patterns):
    if "/" in filename:
        return False
    if not filename.startswith(patterns["prefix"]):
        return False
    if Path(filename).suffix.lower() not in patterns["extensions"]:
        return False
    return True


def valid_task_name(value):
    name = value.strip()
    if not name or len(name) > 80:
        return ""
    lowered = name.lower()
    if name.startswith(("!", "/")) or "coding:" in lowered:
        return ""
    return name


def extract_task_name(content, filename):
    extension = Path(filename).suffix.lower()
    if extension in {".js", ".ts"}:
        match = re.search(r"new\s+Env\s*\(\s*['\"](.+?)['\"]\s*\)", content)
        return valid_task_name(match.group(1)) if match else ""

    if extension == ".py":
        patterns = [
            r"Env\s*\(\s*['\"](.+?)['\"]\s*\)",
            r"(?:name|task_name)\s*=\s*['\"](.+?)['\"]",
            r"^\s*#\s*(.+?)\s*$",
        ]
    elif extension == ".sh":
        patterns = [
            r"(?:TASK_NAME|NAME)\s*=\s*['\"](.+?)['\"]",
            r"^\s*#\s*(.+?)\s*$",
        ]
    else:
        return ""

    for pattern in patterns:
        for match in re.finditer(pattern, content, re.MULTILINE):
            name = valid_task_name(match.group(1))
            if name:
                return name
    return ""


def github_repo_path(owner, repo):
    return f"/repos/{quote_path_part(owner)}/{quote_path_part(repo)}"


def branch_head(http, owner, repo, branch):
    data = http.github(
        f"{github_repo_path(owner, repo)}/commits/{quote_path_part(branch)}"
    )
    sha = str((data or {}).get("sha") or "")
    if not sha:
        raise MonitorError(f"未获取到 {owner}/{repo}:{branch} 的 HEAD")
    return sha


def commits_since(http, owner, repo, branch, since):
    commits = []
    for page in range(1, MAX_COMMIT_PAGES + 1):
        data = http.github(
            f"{github_repo_path(owner, repo)}/commits",
            {
                "sha": branch,
                "since": since.isoformat().replace("+00:00", "Z"),
                "per_page": 100,
                "page": page,
            },
        )
        if not isinstance(data, list):
            raise MonitorError(f"{owner}/{repo} commits 响应格式错误")
        commits.extend(data)
        if len(data) < 100:
            return commits
    raise MonitorError(f"{owner}/{repo} 回溯 commit 超过 {MAX_COMMIT_PAGES * 100} 个")


def compare_commits(http, owner, repo, base_sha, head_sha):
    data = http.github(
        f"{github_repo_path(owner, repo)}/compare/"
        f"{quote_path_part(base_sha)}...{quote_path_part(head_sha)}"
    )
    if not isinstance(data, dict):
        raise MonitorError(f"{owner}/{repo} compare 响应格式错误")
    status = data.get("status")
    if status not in {"ahead", "identical"}:
        raise CursorError(f"{owner}/{repo} 游标已偏离当前分支: {status}")
    files = data.get("files") or []
    if not isinstance(files, list):
        raise MonitorError(f"{owner}/{repo} compare files 格式错误")
    if len(files) >= COMPARE_FILE_LIMIT:
        raise MonitorError(
            f"{owner}/{repo} compare 达到 {COMPARE_FILE_LIMIT} 文件上限，拒绝静默截断"
        )
    return files


def bootstrap_base(http, owner, repo, branch, hours):
    since = datetime.now(timezone.utc) - timedelta(hours=hours)
    commits = commits_since(http, owner, repo, branch, since)
    if not commits:
        return ""
    try:
        oldest = min(
            commits,
            key=lambda commit: commit["commit"]["committer"]["date"],
        )
    except (KeyError, TypeError) as err:
        raise MonitorError(f"{owner}/{repo} commit 时间信息不完整") from err
    parents = oldest.get("parents") or []
    base_sha = str((parents[0] if parents else {}).get("sha") or "")
    if not base_sha:
        raise MonitorError(f"{owner}/{repo} 无法确定首次回溯的基准 commit")
    return base_sha


def collect_task_changes(http, repo_config, patterns, previous_head, hours):
    owner, repo = split_repo(repo_config["repo"], f"tasks.{repo_config['id']}.repo")
    branch = repo_config["branch"]
    current_head = branch_head(http, owner, repo, branch)
    bootstrap = not previous_head

    if previous_head == current_head:
        files = []
    elif previous_head:
        try:
            files = compare_commits(http, owner, repo, previous_head, current_head)
        except (CursorError, NotFoundError) as err:
            log("task_cursor_reset", repo=repo_config["id"], reason=str(err))
            bootstrap = True
            base_sha = bootstrap_base(http, owner, repo, branch, hours)
            files = (
                compare_commits(http, owner, repo, base_sha, current_head)
                if base_sha
                else []
            )
    else:
        base_sha = bootstrap_base(http, owner, repo, branch, hours)
        files = compare_commits(http, owner, repo, base_sha, current_head) if base_sha else []

    changes = RepoTaskChanges(
        repo_id=repo_config["id"],
        repo_name=repo_config["name"],
        head_sha=current_head,
        bootstrap=bootstrap,
    )

    def add_current(filename, target):
        content = http.text(raw_url(owner, repo, current_head, filename))
        target.append(
            TaskInfo(
                task_id=Path(filename).stem,
                task_name=extract_task_name(content, filename) or "(未识别)",
            )
        )

    for file_info in files:
        filename = str(file_info.get("filename") or "")
        status = str(file_info.get("status") or "")
        previous_filename = str(file_info.get("previous_filename") or "")

        if status == "renamed":
            if previous_filename and task_file_matches(previous_filename, patterns):
                changes.removed.append(TaskInfo(task_id=Path(previous_filename).stem))
            if filename and task_file_matches(filename, patterns):
                add_current(filename, changes.added)
            continue
        if not filename or not task_file_matches(filename, patterns):
            continue
        if status in {"added", "copied"}:
            add_current(filename, changes.added)
        elif status == "removed":
            changes.removed.append(TaskInfo(task_id=Path(filename).stem))
        elif status in {"modified", "changed"}:
            add_current(filename, changes.modified)
        else:
            raise MonitorError(f"{owner}/{repo} 出现未处理的文件状态: {status}")

    changes.added.sort(key=lambda item: item.task_id)
    changes.modified.sort(key=lambda item: item.task_id)
    changes.removed.sort(key=lambda item: item.task_id)
    log(
        "task_repo_checked",
        repo=repo_config["id"],
        head=current_head[:12],
        added=len(changes.added),
        modified=len(changes.modified),
        removed=len(changes.removed),
    )
    return changes


def task_detail_messages(changes):
    messages = []
    categories = (
        ("🆕 新增任务", changes.added, True),
        ("🗑️ 删除任务", changes.removed, False),
        ("📝 修改任务", changes.modified, True),
    )
    for title, tasks, include_name in categories:
        if not tasks:
            continue
        prefix = f"<b>📦 {html.escape(changes.repo_name)} · {title}</b>\n<blockquote expandable>\n"
        suffix = "\n</blockquote>"
        lines = []
        for task in tasks:
            line = f"• <code>{html.escape(task.task_id)}</code>"
            if include_name:
                line += f" - {html.escape(task.task_name)}"
            candidate = prefix + "\n".join([*lines, line]) + suffix
            if len(candidate) > TELEGRAM_TEXT_LIMIT and lines:
                messages.append(prefix + "\n".join(lines) + suffix)
                lines = [line]
            else:
                lines.append(line)
        if lines:
            message = prefix + "\n".join(lines) + suffix
            if len(message) > TELEGRAM_TEXT_LIMIT:
                raise MonitorError(f"任务详情单行超过 Telegram 限制: {changes.repo_name}")
            messages.append(message)
    return messages


def build_task_messages(all_changes, hours, current_time):
    bootstrap = any(changes.bootstrap for changes in all_changes)
    lines = [
        "<b>📋 上游仓库任务变更通知</b>",
        f"<i>检测时间: {html.escape(current_time)}</i>",
    ]
    if bootstrap:
        lines.append(f"<i>首次回溯: 最近 {hours} 小时</i>")
    lines.append("")

    changed = [changes for changes in all_changes if changes.has_changes]
    if not changed:
        lines.append("✅ 无任务变更")
        return ["\n".join(lines)]

    for changes in changed:
        lines.extend(
            [
                f"<b>📦 {html.escape(changes.repo_name)}</b>",
                (
                    f"➕ {len(changes.added)}　➖ {len(changes.removed)}　"
                    f"✏️ {len(changes.modified)}"
                ),
                "",
            ]
        )
    summary = "\n".join(lines).rstrip()
    if len(summary) > TELEGRAM_TEXT_LIMIT:
        raise MonitorError("任务汇总超过 Telegram 消息限制")

    messages = [summary]
    for changes in changed:
        messages.extend(task_detail_messages(changes))
    return messages


def normalize_task_state(state):
    if not state:
        return {}
    if state.get("schema_version") != 1 or state.get("mode") != "tasks":
        raise MonitorError("任务状态格式或版本无效")
    repositories = state.get("repositories")
    if not isinstance(repositories, dict):
        raise MonitorError("任务状态 repositories 无效")
    normalized = {}
    for repo_id, sha in repositories.items():
        if not isinstance(repo_id, str) or not isinstance(sha, str) or not sha:
            raise MonitorError("任务状态仓库游标无效")
        normalized[repo_id] = sha
    return normalized


def run_tasks(config, http, telegram, state_path, hours, dry_run, zone):
    if not state_path and not dry_run:
        raise MonitorError("tasks 模式缺少 --state-file 或 MONITOR_STATE_FILE")
    previous_state = read_state(state_path)
    previous_heads = normalize_task_state(previous_state)
    task_config = config["tasks"]
    all_changes = []
    current_heads = {}

    for repo_config in task_config["repositories"]:
        changes = collect_task_changes(
            http,
            repo_config,
            task_config["files"],
            previous_heads.get(repo_config["id"], ""),
            hours,
        )
        all_changes.append(changes)
        current_heads[repo_config["id"]] = changes.head_sha

    current_time = datetime.now(zone).strftime("%Y-%m-%d %H:%M %Z")
    telegram.send_all(build_task_messages(all_changes, hours, current_time))
    current_state = {
        "schema_version": 1,
        "mode": "tasks",
        "repositories": current_heads,
    }
    if current_state != previous_state:
        write_state(state_path, current_state, dry_run)
    log("tasks_completed", repositories=len(all_changes))


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
    owner, repo = split_repo(source["repo"], f"versions.{source['id']}.repo")
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
    owner, repo = split_repo(source["repo"], f"versions.{source['id']}.repo")
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
        parts.append(
            f"\n{item['icon']} "
            f"<a href=\"{html.escape(item['url'], quote=True)}\">"
            f"<b>{html.escape(item['name'])}</b></a>\n"
            f"<code>{html.escape(item['previous'])}</code> ➜ "
            f"<code>{html.escape(item['version'])}</code>\n"
            f"🕐 {html.escape(item['updated_at'])}"
        )
    return "\n".join(parts)


def run_versions(config, http, telegram, state_path, dry_run, zone):
    if not state_path and not dry_run:
        raise MonitorError("versions 模式缺少 --state-file 或 MONITOR_STATE_FILE")
    sources = config["versions"]["sources"]
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
            config["versions"]["photo"],
        )
        write_state(state_path, current, dry_run)
        return

    if previous != current:
        write_state(state_path, current, dry_run)
        log("state_refreshed", state_key=state_digest(current))
        return

    log("upstream_unchanged", state_key=state_digest(current))


def parse_args():
    parser = argparse.ArgumentParser(description="上游任务与版本监控")
    parser.add_argument(
        "--config",
        default=str(Path(__file__).with_name("upstream_config.json")),
        help="配置文件路径",
    )
    subparsers = parser.add_subparsers(dest="mode", required=True)

    tasks = subparsers.add_parser("tasks", help="监控上游任务文件")
    tasks.add_argument("--hours", type=int, help="首次建态时的回溯小时数")
    tasks.add_argument("--state-file", default="", help="任务游标状态文件")
    tasks.add_argument("--dry-run", action="store_true")

    versions = subparsers.add_parser("versions", help="监控上游版本")
    versions.add_argument("--state-file", default="", help="版本状态文件")
    versions.add_argument("--dry-run", action="store_true")
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
    telegram = TelegramClient(http, config["telegram"], dry_run)
    if args.mode == "tasks":
        hours = args.hours or config["tasks"]["default_lookback_hours"]
        if hours <= 0:
            raise ConfigError("--hours 必须是正整数")
        run_tasks(config, http, telegram, state_path, hours, dry_run, zone)
    else:
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
