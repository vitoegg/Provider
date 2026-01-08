#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
上游仓库任务变更监控脚本

功能:
    1. 检查指定上游仓库最近N小时内的 commits
    2. 分析变更的任务文件 (jd_*.js/py/sh/ts)，提取任务ID和任务名称
    3. 通过 Telegram Bot 推送变更通知

日期: 2026-01-08
"""

import os
import re
import sys
import json
import time
import requests
from datetime import datetime, timedelta, timezone
from typing import Dict, List, Optional, Tuple
from dataclasses import dataclass, field
from functools import wraps


# 重试配置
MAX_RETRIES = 3           # 最大重试次数
RETRY_DELAY = 2           # 重试间隔（秒）
REQUEST_INTERVAL = 0.5    # 请求间隔（秒），避免触发速率限制


def retry_on_failure(max_retries: int = MAX_RETRIES, delay: float = RETRY_DELAY):
    """
    重试装饰器：在请求失败时自动重试
    
    Args:
        max_retries: 最大重试次数
        delay: 重试间隔（秒）
    """
    def decorator(func):
        @wraps(func)
        def wrapper(*args, **kwargs):
            last_exception = None
            for attempt in range(max_retries + 1):
                try:
                    return func(*args, **kwargs)
                except requests.RequestException as e:
                    last_exception = e
                    if attempt < max_retries:
                        wait_time = delay * (2 ** attempt)  # 指数退避
                        print(f"  ⚠️ 请求失败，{wait_time}秒后重试 ({attempt + 1}/{max_retries}): {e}")
                        time.sleep(wait_time)
                    else:
                        print(f"  ❌ 请求失败，已达最大重试次数: {e}")
            return None
        return wrapper
    return decorator


@dataclass
class TaskInfo:
    """任务信息数据类"""
    task_id: str           # 任务ID (文件名，不含扩展名)
    task_name: str         # 任务名称 (从 new Env() 提取)
    file_path: str         # 文件路径
    file_ext: str          # 文件扩展名
    change_type: str       # 变更类型: added/modified/removed
    cron_expression: str = ""  # cron 表达式


@dataclass
class RepoChanges:
    """仓库变更信息"""
    repo_name: str
    added: List[TaskInfo] = field(default_factory=list)
    modified: List[TaskInfo] = field(default_factory=list)
    removed: List[TaskInfo] = field(default_factory=list)
    
    @property
    def has_changes(self) -> bool:
        return bool(self.added or self.modified or self.removed)
    
    @property
    def total_changes(self) -> int:
        return len(self.added) + len(self.modified) + len(self.removed)


class UpstreamChecker:
    """上游仓库变更检查器"""
    
    GITHUB_API_BASE = "https://api.github.com"
    GITHUB_RAW_BASE = "https://raw.githubusercontent.com"
    
    # 支持的文件扩展名
    SUPPORTED_EXTENSIONS = [".js", ".py", ".sh", ".ts"]
    
    def __init__(self):
        self.github_token = os.environ.get("GITHUB_TOKEN", "")
        self.telegram_token = os.environ.get("TELEGRAM_BOT_TOKEN", "")
        self.telegram_chat_id = os.environ.get("TELEGRAM_CHAT_ID", "")
        self.check_hours = int(os.environ.get("CHECK_HOURS", "24"))
        self.workspace = os.environ.get("GITHUB_WORKSPACE", ".")
        
        # 错误计数器
        self.error_count = 0
        self.max_errors = 10  # 累计错误达到此数量时安全退出
        
        # 加载配置
        self.config = self._load_config()
        
        # 设置请求头
        self.headers = {
            "Accept": "application/vnd.github.v3+json",
            "User-Agent": "UpstreamTaskChecker/1.0"
        }
        if self.github_token:
            self.headers["Authorization"] = f"token {self.github_token}"
    
    def _check_rate_limit(self) -> Tuple[bool, str]:
        """
        检查 GitHub API 速率限制状态
        
        Returns:
            (是否可继续, 状态信息)
        """
        try:
            response = requests.get(
                f"{self.GITHUB_API_BASE}/rate_limit",
                headers=self.headers,
                timeout=10
            )
            response.raise_for_status()
            data = response.json()
            
            core = data.get("resources", {}).get("core", {})
            remaining = core.get("remaining", 0)
            limit = core.get("limit", 60)
            reset_time = core.get("reset", 0)
            
            reset_datetime = datetime.fromtimestamp(reset_time)
            
            if remaining < 10:
                wait_seconds = reset_time - time.time()
                if wait_seconds > 0:
                    return False, f"API 配额不足 ({remaining}/{limit})，将于 {reset_datetime.strftime('%H:%M:%S')} 重置"
            
            return True, f"API 配额: {remaining}/{limit}"
            
        except requests.RequestException as e:
            print(f"⚠️ 检查速率限制失败: {e}")
            return True, "无法检查配额状态"
    
    def _record_error(self, context: str = "") -> bool:
        """
        记录错误并检查是否应安全退出
        
        Returns:
            True 表示应继续执行，False 表示应安全退出
        """
        self.error_count += 1
        if self.error_count >= self.max_errors:
            print(f"❌ 累计错误达到 {self.max_errors} 次，执行安全退出")
            if context:
                print(f"   最后错误上下文: {context}")
            return False
        return True
    
    def _safe_request(self, method: str, url: str, **kwargs) -> Optional[requests.Response]:
        """
        安全的 HTTP 请求封装，包含重试机制
        
        Args:
            method: HTTP 方法 (get/post)
            url: 请求 URL
            **kwargs: 传递给 requests 的其他参数
        
        Returns:
            Response 对象或 None
        """
        kwargs.setdefault("timeout", 30)
        
        for attempt in range(MAX_RETRIES + 1):
            try:
                # 请求间隔，避免触发速率限制
                if attempt > 0:
                    time.sleep(REQUEST_INTERVAL)
                
                response = requests.request(method, url, headers=self.headers, **kwargs)
                
                # 处理速率限制
                if response.status_code == 403:
                    remaining = response.headers.get("X-RateLimit-Remaining", "unknown")
                    if remaining == "0":
                        reset_time = int(response.headers.get("X-RateLimit-Reset", 0))
                        wait_seconds = max(reset_time - time.time(), 60)
                        print(f"  ⚠️ API 速率限制，等待 {int(wait_seconds)} 秒...")
                        time.sleep(min(wait_seconds, 300))  # 最多等待5分钟
                        continue
                
                response.raise_for_status()
                return response
                
            except requests.RequestException as e:
                if attempt < MAX_RETRIES:
                    wait_time = RETRY_DELAY * (2 ** attempt)
                    print(f"  ⚠️ 请求失败，{wait_time}秒后重试 ({attempt + 1}/{MAX_RETRIES}): {e}")
                    time.sleep(wait_time)
                else:
                    print(f"  ❌ 请求失败，已达最大重试次数: {e}")
                    self._record_error(f"URL: {url}")
                    return None
        
        return None
    
    def _load_config(self) -> dict:
        """加载配置文件"""
        config_path = os.path.join(self.workspace, "Script/Workflow/upstream_config.json")
        try:
            with open(config_path, "r", encoding="utf-8") as f:
                return json.load(f)
        except FileNotFoundError:
            print(f"⚠️ 配置文件不存在: {config_path}，使用默认配置")
            return {
                "upstream_repos": [
                    {"name": "jdpro", "owner": "6dylan6", "repo": "jdpro", "branch": "main"},
                    {"name": "faker2", "owner": "shufflewzc", "repo": "faker2", "branch": "main"}
                ],
                "file_patterns": {
                    "prefix": "jd_",
                    "extensions": [".js", ".py", ".sh", ".ts"],
                    "exclude": ["sendNotify.js", "sendNotify.py"]
                }
            }
    
    def _should_process_file(self, filename: str) -> bool:
        """判断文件是否应该被处理"""
        patterns = self.config.get("file_patterns", {})
        prefix = patterns.get("prefix", "jd_")
        extensions = patterns.get("extensions", self.SUPPORTED_EXTENSIONS)
        exclude_list = patterns.get("exclude", [])
        
        # 只处理根目录下的文件
        if "/" in filename:
            return False
        
        # 检查文件名前缀
        if not filename.startswith(prefix):
            return False
        
        # 检查文件扩展名
        file_ext = os.path.splitext(filename)[1].lower()
        if file_ext not in extensions:
            return False
        
        # 检查是否在排除列表中
        if filename in exclude_list:
            return False
        
        return True
    
    def _get_file_extension(self, filename: str) -> str:
        """获取文件扩展名"""
        return os.path.splitext(filename)[1].lower()
    
    def _get_commits_since(self, owner: str, repo: str, branch: str, since: datetime) -> List[dict]:
        """获取指定时间之后的所有 commits（带重试机制）"""
        url = f"{self.GITHUB_API_BASE}/repos/{owner}/{repo}/commits"
        params = {
            "sha": branch,
            "since": since.isoformat(),
            "per_page": 100
        }
        
        response = self._safe_request("get", url, params=params)
        if response:
            try:
                return response.json()
            except json.JSONDecodeError as e:
                print(f"❌ 解析 commits 响应失败 ({owner}/{repo}): {e}")
                self._record_error(f"JSON decode: {owner}/{repo}")
                return []
        
        print(f"❌ 获取 commits 失败 ({owner}/{repo})")
        return []
    
    def _get_commit_details(self, owner: str, repo: str, sha: str) -> Optional[dict]:
        """获取单个 commit 的详细信息（带重试机制）"""
        url = f"{self.GITHUB_API_BASE}/repos/{owner}/{repo}/commits/{sha}"
        
        # 添加请求间隔
        time.sleep(REQUEST_INTERVAL)
        
        response = self._safe_request("get", url)
        if response:
            try:
                return response.json()
            except json.JSONDecodeError as e:
                print(f"❌ 解析 commit 详情失败 ({sha[:7]}): {e}")
                self._record_error(f"JSON decode: {sha[:7]}")
                return None
        
        print(f"❌ 获取 commit 详情失败 ({sha[:7]})")
        return None
    
    def _get_file_content(self, owner: str, repo: str, branch: str, file_path: str) -> Optional[str]:
        """获取文件内容（带重试机制）"""
        url = f"{self.GITHUB_RAW_BASE}/{owner}/{repo}/{branch}/{file_path}"
        
        # 添加请求间隔
        time.sleep(REQUEST_INTERVAL)
        
        # raw.githubusercontent.com 不需要 API headers
        for attempt in range(MAX_RETRIES + 1):
            try:
                response = requests.get(url, timeout=30)
                response.raise_for_status()
                return response.text
            except requests.RequestException as e:
                if attempt < MAX_RETRIES:
                    wait_time = RETRY_DELAY * (2 ** attempt)
                    print(f"  ⚠️ 获取文件失败，{wait_time}秒后重试 ({attempt + 1}/{MAX_RETRIES})")
                    time.sleep(wait_time)
                else:
                    print(f"  ⚠️ 获取文件内容失败 ({file_path}): {e}")
                    return None
        
        return None
    
    def _extract_task_info(self, content: str, file_path: str, change_type: str) -> Optional[TaskInfo]:
        """从文件内容中提取任务信息"""
        filename = os.path.basename(file_path)
        file_ext = self._get_file_extension(filename)
        task_id = os.path.splitext(filename)[0]  # 去掉扩展名
        
        # 根据不同文件类型提取任务名称
        task_name = None
        
        if file_ext == ".js" or file_ext == ".ts":
            # JS/TS: new Env('任务名称') 或 new Env("任务名称")
            env_pattern = r"new\s+Env\s*\(\s*['\"](.+?)['\"]\s*\)"
            env_match = re.search(env_pattern, content)
            if env_match:
                task_name = env_match.group(1)
        
        elif file_ext == ".py":
            # Python: 尝试多种模式
            # 1. Env('任务名称') 或 Env("任务名称")
            # 2. 文件头部的 # 任务名称 注释
            # 3. name = "任务名称" 或 task_name = "任务名称"
            patterns = [
                r"Env\s*\(\s*['\"](.+?)['\"]\s*\)",
                r"^\s*#\s*(.+?)\s*$",
                r"(?:name|task_name)\s*=\s*['\"](.+?)['\"]"
            ]
            for pattern in patterns:
                match = re.search(pattern, content, re.MULTILINE)
                if match:
                    task_name = match.group(1)
                    # 过滤掉不像任务名称的内容
                    if len(task_name) > 50 or task_name.startswith("!") or task_name.startswith("/"):
                        task_name = None
                        continue
                    break
        
        elif file_ext == ".sh":
            # Shell: 尝试从注释中提取
            # 1. # 任务名称
            # 2. TASK_NAME="任务名称"
            patterns = [
                r"^\s*#\s*(.+?)\s*$",
                r"(?:TASK_NAME|NAME)\s*=\s*['\"](.+?)['\"]"
            ]
            for pattern in patterns:
                match = re.search(pattern, content, re.MULTILINE)
                if match:
                    task_name = match.group(1)
                    # 过滤掉 shebang 和不像任务名称的内容
                    if task_name.startswith("!") or task_name.startswith("/") or len(task_name) > 50:
                        task_name = None
                        continue
                    break
        
        if not task_name:
            # 如果没有找到任务名称，说明可能不是有效的任务文件
            return None
        
        # 提取 cron 表达式 (在注释块中)
        # 匹配格式: 分 时 日 月 周 filename
        cron_pattern = r'[\d\*\/\-,]+\s+[\d\*\/\-,]+\s+[\d\*\/\-,]+\s+[\d\*\/\-,]+\s+[\d\*\/\-,]+\s+' + re.escape(filename)
        cron_match = re.search(cron_pattern, content)
        cron_expression = ""
        if cron_match:
            full_match = cron_match.group(0)
            cron_expression = full_match.replace(filename, "").strip()
        
        return TaskInfo(
            task_id=task_id,
            task_name=task_name,
            file_path=file_path,
            file_ext=file_ext,
            change_type=change_type,
            cron_expression=cron_expression
        )
    
    def check_repo(self, repo_config: dict) -> Tuple[RepoChanges, bool]:
        """
        检查单个仓库的变更
        
        Returns:
            (RepoChanges, 是否应继续执行)
        """
        owner = repo_config["owner"]
        repo = repo_config["repo"]
        branch = repo_config.get("branch", "main")
        repo_name = repo_config.get("name", repo)
        
        print(f"\n{'='*60}")
        print(f"📦 检查仓库: {owner}/{repo} ({branch})")
        print(f"{'='*60}")
        
        changes = RepoChanges(repo_name=repo_name)
        
        # 检查 API 速率限制
        can_continue, rate_info = self._check_rate_limit()
        print(f"🔄 {rate_info}")
        if not can_continue:
            print(f"⚠️ {rate_info}，跳过此仓库")
            return changes, True  # 跳过但继续执行其他仓库
        
        # 计算时间范围
        since_time = datetime.now(timezone.utc) - timedelta(hours=self.check_hours)
        print(f"⏰ 检查时间范围: {since_time.strftime('%Y-%m-%d %H:%M')} UTC 至今")
        
        # 获取 commits
        commits = self._get_commits_since(owner, repo, branch, since_time)
        print(f"📝 找到 {len(commits)} 个 commits")
        
        if not commits:
            return changes, True
        
        # 检查错误计数
        if self.error_count >= self.max_errors:
            print(f"⚠️ 错误次数过多，安全退出")
            return changes, False
        
        # 收集所有变更的文件
        # 使用字典记录每个文件的最终状态
        file_changes: Dict[str, str] = {}  # filename -> change_type
        
        for commit in commits:
            sha = commit["sha"]
            details = self._get_commit_details(owner, repo, sha)
            if not details:
                # 检查是否应安全退出
                if self.error_count >= self.max_errors:
                    return changes, False
                continue
            
            files = details.get("files", [])
            for file_info in files:
                filename = file_info["filename"]
                status = file_info["status"]  # added, modified, removed, renamed
                
                if not self._should_process_file(filename):
                    continue
                
                # 处理 renamed 状态
                if status == "renamed":
                    previous_filename = file_info.get("previous_filename", "")
                    if previous_filename and self._should_process_file(previous_filename):
                        file_changes[previous_filename] = "removed"
                    file_changes[filename] = "added"
                else:
                    # 记录最终状态（后面的 commit 会覆盖前面的）
                    file_changes[filename] = status
        
        print(f"📄 发现 {len(file_changes)} 个相关文件变更")
        
        # 处理每个变更的文件
        for filename, change_type in file_changes.items():
            print(f"  处理: {filename} ({change_type})")
            
            # 检查错误计数
            if self.error_count >= self.max_errors:
                print(f"⚠️ 错误次数过多，停止处理剩余文件")
                break
            
            if change_type == "removed":
                # 删除的文件无法获取内容，只能记录文件名
                task_id = os.path.splitext(filename)[0]
                file_ext = self._get_file_extension(filename)
                task_info = TaskInfo(
                    task_id=task_id,
                    task_name="(已删除)",
                    file_path=filename,
                    file_ext=file_ext,
                    change_type=change_type
                )
                changes.removed.append(task_info)
            else:
                # 获取文件内容并提取任务信息
                content = self._get_file_content(owner, repo, branch, filename)
                if content:
                    task_info = self._extract_task_info(content, filename, change_type)
                    if task_info:
                        if change_type == "added":
                            changes.added.append(task_info)
                        else:  # modified
                            changes.modified.append(task_info)
                    else:
                        print(f"    ⚠️ 无法提取任务信息，可能不是有效的任务文件")
        
        return changes, True
    
    def format_telegram_message(self, all_changes: List[RepoChanges]) -> str:
        """格式化 Telegram 消息"""
        now = datetime.now().strftime("%Y-%m-%d %H:%M")
        
        # 检查是否有任何变更
        has_any_changes = any(c.has_changes for c in all_changes)
        
        if not has_any_changes:
            return f"<b>📋 上游仓库任务变更通知</b>\n<i>检测时间: {now}</i>\n\n✅ 最近 {self.check_hours} 小时内无任务变更"
        
        lines = [
            f"<b>📋 上游仓库任务变更通知</b>",
            f"<i>检测时间: {now}</i>",
            f"<i>检测范围: 最近 {self.check_hours} 小时</i>",
            ""
        ]
        
        for repo_changes in all_changes:
            if not repo_changes.has_changes:
                continue
            
            lines.append(f"<b>📦 {repo_changes.repo_name} 仓库变更</b>")
            
            # 汇总统计
            if repo_changes.added:
                lines.append(f"➕ 新增: {len(repo_changes.added)} 个任务")
            if repo_changes.removed:
                lines.append(f"➖ 删除: {len(repo_changes.removed)} 个任务")
            if repo_changes.modified:
                lines.append(f"✏️ 修改: {len(repo_changes.modified)} 个任务")
            
            lines.append("")
            
            # 变更详情 - 使用 blockquote expandable 实现折叠
            details_lines = []
            
            if repo_changes.added:
                details_lines.append("<b>🆕 新增任务:</b>")
                for task in repo_changes.added:
                    details_lines.append(f"• <code>{task.task_id}</code> - {task.task_name}")
                details_lines.append("")
            
            if repo_changes.removed:
                details_lines.append("<b>🗑️ 删除任务:</b>")
                for task in repo_changes.removed:
                    details_lines.append(f"• <code>{task.task_id}</code>")
                details_lines.append("")
            
            if repo_changes.modified:
                details_lines.append("<b>📝 修改任务:</b>")
                for task in repo_changes.modified:
                    details_lines.append(f"• <code>{task.task_id}</code> - {task.task_name}")
                details_lines.append("")
            
            # 使用 blockquote expandable 包裹详情
            lines.append("<blockquote expandable>")
            lines.extend(details_lines)
            lines.append("</blockquote>")
            lines.append("")
        
        return "\n".join(lines)
    
    def send_telegram_message(self, message: str) -> bool:
        """发送 Telegram 消息"""
        if not self.telegram_token or not self.telegram_chat_id:
            print("⚠️ 未配置 Telegram Token 或 Chat ID，跳过推送")
            print("\n" + "="*60)
            print("📤 消息预览:")
            print("="*60)
            # 移除 HTML 标签用于预览
            preview = re.sub(r'<[^>]+>', '', message)
            print(preview)
            return False
        
        url = f"https://api.telegram.org/bot{self.telegram_token}/sendMessage"
        
        telegram_config = self.config.get("telegram", {})
        
        payload = {
            "chat_id": self.telegram_chat_id,
            "text": message,
            "parse_mode": telegram_config.get("parse_mode", "HTML"),
            "disable_web_page_preview": telegram_config.get("disable_web_page_preview", True)
        }
        
        try:
            response = requests.post(url, json=payload, timeout=30)
            response.raise_for_status()
            result = response.json()
            
            if result.get("ok"):
                print("✅ Telegram 消息发送成功")
                return True
            else:
                print(f"❌ Telegram 消息发送失败: {result.get('description', 'Unknown error')}")
                return False
        except requests.RequestException as e:
            print(f"❌ Telegram 请求失败: {e}")
            return False
    
    def run(self) -> int:
        """
        运行检查
        
        Returns:
            退出码: 0 表示成功，1 表示有错误但完成，2 表示严重错误
        """
        print("🚀 开始检查上游仓库变更...")
        print(f"⏰ 当前时间: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
        print(f"🔍 检查范围: 最近 {self.check_hours} 小时")
        
        # 初始 API 速率检查
        can_continue, rate_info = self._check_rate_limit()
        print(f"🔄 初始 {rate_info}")
        if not can_continue:
            print(f"❌ {rate_info}")
            print("⚠️ API 配额不足，无法执行检查，稍后将自动重试")
            return 2
        
        repos = self.config.get("upstream_repos", [])
        if not repos:
            print("❌ 未配置上游仓库")
            return 1
        
        all_changes: List[RepoChanges] = []
        should_continue = True
        
        for repo_config in repos:
            if not should_continue:
                print(f"\n⚠️ 由于错误过多，跳过剩余仓库: {repo_config.get('name', repo_config['repo'])}")
                continue
            
            try:
                changes, should_continue = self.check_repo(repo_config)
                all_changes.append(changes)
                
                # 打印统计
                print(f"\n📊 {changes.repo_name} 统计:")
                print(f"   新增: {len(changes.added)}")
                print(f"   修改: {len(changes.modified)}")
                print(f"   删除: {len(changes.removed)}")
                
            except Exception as e:
                print(f"❌ 检查仓库时发生未预期错误: {e}")
                self._record_error(f"Unexpected: {e}")
                # 继续处理其他仓库
                continue
        
        # 生成并发送消息
        print("\n" + "="*60)
        print("📤 准备发送 Telegram 通知...")
        print("="*60)
        
        message = self.format_telegram_message(all_changes)
        send_success = self.send_telegram_message(message)
        
        # 打印错误汇总
        if self.error_count > 0:
            print(f"\n⚠️ 执行过程中共发生 {self.error_count} 次错误")
        
        if not should_continue:
            print("\n⚠️ 由于错误过多，部分检查被跳过")
            return 1
        
        print("\n✅ 检查完成")
        return 0 if send_success or not self.telegram_token else 0


def main():
    """主函数"""
    try:
        checker = UpstreamChecker()
        exit_code = checker.run()
        sys.exit(exit_code)
    except KeyboardInterrupt:
        print("\n⚠️ 用户中断执行")
        sys.exit(130)
    except Exception as e:
        print(f"\n❌ 发生未预期的致命错误: {e}")
        import traceback
        traceback.print_exc()
        sys.exit(2)


if __name__ == "__main__":
    main()

