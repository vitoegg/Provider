# cron:37 7 * * *
# new Env('烧饼论坛每日签到');
"""
烧饼论坛每日签到

环境变量：
- SB_COOKIE：论坛 Cookie
- SB_USER_AGENT：与该 Cookie 登录时一致的浏览器 User-Agent
"""
import os
import random
import re
import time
from html.parser import HTMLParser
from urllib.parse import urlparse

import requests


SB_URL = "https://sb.sb"
SB_COOKIE = os.environ.get("SB_COOKIE", "")
SB_USER_AGENT = os.environ.get(
    "SB_USER_AGENT",
    (
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        "AppleWebKit/537.36 (KHTML, like Gecko) "
        "Chrome/151.0.0.0 Safari/537.36"
    ),
)
TIMEOUT = 30
START_DELAY = (30, 300)
SUBMIT_DELAY = (3, 8)
REQUIRED_COOKIES = {"__Host-bbs_session"}
CHALLENGE_MARKERS = (
    "cf-chl-",
    "cf-browser-verification",
    "challenge-platform",
    "just a moment...",
    "enable javascript and cookies to continue",
)


class SigninFormParser(HTMLParser):
    """提取 /signin/ POST 表单中的 CSRF token。"""

    def __init__(self):
        super().__init__()
        self.in_signin_form = False
        self.csrf_token = ""

    def handle_starttag(self, tag, attrs):
        attributes = dict(attrs)

        if tag == "form":
            action = urlparse(attributes.get("action", "")).path.rstrip("/")
            method = attributes.get("method", "get").lower()
            self.in_signin_form = action in {"", "/signin"} and method == "post"
        elif tag == "input" and self.in_signin_form:
            if attributes.get("name") == "_csrf":
                self.csrf_token = attributes.get("value", "")

    def handle_endtag(self, tag):
        if tag == "form":
            self.in_signin_form = False


class TextParser(HTMLParser):
    """将 HTML 响应转换为便于判断的纯文本。"""

    def __init__(self):
        super().__init__()
        self.parts = []

    def handle_data(self, data):
        if data.strip():
            self.parts.append(data.strip())

    def text(self):
        return " ".join(self.parts)


def build_session(cookie):
    """创建携带论坛 Cookie 的请求会话。"""
    session = requests.Session()
    session.headers.update(
        {
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8",
            "Cookie": cookie,
            "User-Agent": SB_USER_AGENT,
        }
    )
    return session


def page_text(html):
    parser = TextParser()
    parser.feed(html)
    return parser.text()


def missing_cookie_names(cookie):
    """检查签到所需 Cookie，仅返回缺失的字段名。"""
    names = {
        item.split("=", 1)[0].strip()
        for item in cookie.split(";")
        if "=" in item
    }
    return sorted(REQUIRED_COOKIES - names)


def wait_random_interval(delay_range, stage):
    """在指定阶段执行有界随机等待。"""
    delay = random.uniform(*delay_range)
    print(f"⏳ {stage}，等待 {delay:.1f} 秒")
    time.sleep(delay)


def validate_response(response, stage):
    """验证响应状态与来源；异常时返回用户可读消息。"""
    status = response.status_code
    if status in {401, 403, 429}:
        return f"❌ {stage}被拒绝（HTTP {status}），已停止且不会重试"
    if status >= 500:
        return f"❌ {stage}服务异常（HTTP {status}），已停止且不会重试"
    if status >= 400:
        return f"❌ {stage}请求失败（HTTP {status}），已停止且不会重试"

    response_url = urlparse(response.url)
    expected_url = urlparse(SB_URL)
    if response_url.scheme != "https" or response_url.netloc != expected_url.netloc:
        return f"❌ {stage}响应跳转到非论坛域名，已停止"

    if response_url.path.rstrip("/") in {"/login", "/signin/login"}:
        return "❌ Cookie 已失效，签到页面跳转到登录页"

    content_type = response.headers.get("Content-Type", "").lower()
    if "text/html" not in content_type:
        return f"❌ {stage}返回非 HTML 内容，已停止"

    html = response.text.lower()
    if any(marker in html for marker in CHALLENGE_MARKERS):
        return f"❌ {stage}遇到 Cloudflare 验证，已停止且不会尝试绕过"

    return ""


def parse_signin_result(html):
    """解析签到后的页面结果。"""
    text = page_text(html)
    success = re.search(
        r"签到成功。?\s*连续签到第\s*(\d+)\s*天[，,\s]+"
        r"今日获得\s*(\d+)\s*饼",
        text,
    )

    if success:
        days, points = success.groups()
        return {
            "success": True,
            "message": f"✅ 签到成功：连续签到第 {days} 天，今日获得 {points} 饼",
        }
    if "签到成功" in text:
        return {"success": True, "message": "✅ 签到成功"}
    if "今日已签到" in text or "已经签到" in text:
        return {"success": True, "message": "⚠️ 今日已签到"}

    return {"success": False, "message": "❌ 未识别到签到结果"}


def sb_signin(cookie):
    """执行烧饼论坛签到。"""
    if not cookie:
        return {"success": False, "message": "❌ 未设置 SB_COOKIE 环境变量"}

    missing = missing_cookie_names(cookie)
    if missing:
        return {
            "success": False,
            "message": f"❌ Cookie 缺少必要字段：{', '.join(missing)}",
        }

    session = build_session(cookie)
    signin_url = f"{SB_URL}/signin/"

    try:
        wait_random_interval(START_DELAY, "签到任务启动")
        response = session.get(signin_url, timeout=TIMEOUT)
        error = validate_response(response, "签到页面")
        if error:
            return {"success": False, "message": error}

        if "今日已签到" in page_text(response.text):
            return {"success": True, "message": "⚠️ 今日已签到"}

        parser = SigninFormParser()
        parser.feed(response.text)
        if not parser.csrf_token:
            return {
                "success": False,
                "message": "❌ 未找到签到表单，Cookie 可能已失效",
            }

        wait_random_interval(SUBMIT_DELAY, "提交签到前")
        response = session.post(
            signin_url,
            data={"_csrf": parser.csrf_token},
            headers={"Origin": SB_URL, "Referer": signin_url},
            timeout=TIMEOUT,
        )
        error = validate_response(response, "签到提交")
        if error:
            return {"success": False, "message": error}
        return parse_signin_result(response.text)
    except requests.RequestException as error:
        return {"success": False, "message": f"❌ 签到请求异常：{error}"}


def send_notification(result):
    """发送青龙通知。"""
    content = f"{result['message']}\n🕐 签到时间：{time.strftime('%Y-%m-%d %H:%M:%S')}"

    try:
        from notify import send as ql_notify

        ql_notify("烧饼论坛每日签到", content)
        print("📤 青龙通知推送成功")
    except Exception as error:
        print(f"❌ 青龙通知推送失败：{error}")


def main():
    print("🚀 烧饼论坛签到脚本启动")
    result = sb_signin(SB_COOKIE)
    print(result["message"])
    send_notification(result)


if __name__ == "__main__":
    main()
