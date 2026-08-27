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


def failure(category, message):
    return {"success": False, "category": category, "message": message}


def validate_response(response, stage):
    """验证响应状态与来源；异常时返回分类结果。"""
    status = response.status_code
    if status in {401, 403, 429}:
        return failure("访问受限", f"{stage}被拒绝（HTTP {status}）")
    if status >= 500:
        return failure("请求失败", f"签到服务异常（HTTP {status}）")
    if status >= 400:
        return failure("请求失败", f"{stage}请求失败（HTTP {status}）")

    response_url = urlparse(response.url)
    expected_url = urlparse(SB_URL)
    if response_url.scheme != "https" or response_url.netloc != expected_url.netloc:
        return failure("结果异常", f"{stage}响应跳转到非论坛域名")

    if response_url.path.rstrip("/") in {"/login", "/signin/login"}:
        return failure("登录失效", "Cookie 已失效")

    content_type = response.headers.get("Content-Type", "").lower()
    if "text/html" not in content_type:
        return failure("结果异常", f"{stage}返回非 HTML 内容")

    html = response.text.lower()
    if any(marker in html for marker in CHALLENGE_MARKERS):
        return failure("访问受限", f"{stage}遇到 Cloudflare 验证")

    return None


def parse_signin_result(html):
    """解析签到后的页面结果。"""
    text = page_text(html)
    days = re.search(r"连续签到第\s*(\d+)\s*天", text)
    reward = re.search(r"今日获得\s*(\d+)\s*饼", text)
    details = {
        "days": days.group(1) if days else "",
        "reward": reward.group(1) if reward else "",
    }

    if "今日已签到" in text or "已经签到" in text:
        return {"success": True, "message": "今日已签到", **details}
    if "签到成功" in text:
        return {"success": True, "message": "签到成功", **details}

    return failure("结果异常", "未识别到签到结果")


def sb_signin(cookie):
    """执行烧饼论坛签到。"""
    if not cookie:
        return failure("配置错误", "未设置 SB_COOKIE")

    missing = missing_cookie_names(cookie)
    if missing:
        return failure("配置错误", f"Cookie 缺少必要字段：{', '.join(missing)}")

    session = build_session(cookie)
    signin_url = f"{SB_URL}/signin/"

    try:
        wait_random_interval(START_DELAY, "签到任务启动")
        response = session.get(signin_url, timeout=TIMEOUT)
        error = validate_response(response, "签到页面")
        if error:
            return error

        if "今日已签到" in page_text(response.text):
            return parse_signin_result(response.text)

        parser = SigninFormParser()
        parser.feed(response.text)
        if not parser.csrf_token:
            return failure("登录失效", "未找到签到表单，Cookie 可能已失效")

        wait_random_interval(SUBMIT_DELAY, "提交签到前")
        response = session.post(
            signin_url,
            data={"_csrf": parser.csrf_token},
            headers={"Origin": SB_URL, "Referer": signin_url},
            timeout=TIMEOUT,
        )
        error = validate_response(response, "签到提交")
        if error:
            return error
        return parse_signin_result(response.text)
    except requests.RequestException as error:
        return failure("网络异常", f"连接签到服务失败：{error}")


def build_notification(result):
    """生成简洁的签到通知。"""
    if result["success"]:
        status = result["message"]
        if result.get("reward"):
            status += f",获得{result['reward']}饼"
        lines = [f"🎯【今日签到】：{status}"]
        if result.get("days"):
            lines.append(f"📅【连续签到】：已签到{result['days']}天")
    else:
        lines = [f"❌【{result['category']}】：{result['message']}"]

    lines.append(f"⏰ {time.strftime('%Y-%m-%d %H:%M:%S')}")
    return "\n".join(lines)


def message_push(title, message):
    """调用青龙系统通知。"""

    try:
        response = QLAPI.systemNotify({"title": title, "content": message})
        if response.get("code", 400) == 200:
            print("📤 青龙通知推送成功")
        else:
            print(f"❌ 青龙通知推送失败：{response}")
    except Exception as error:
        print(f"❌ 青龙通知推送失败：{error}")


def main():
    print("🚀 烧饼论坛签到脚本启动")
    result = sb_signin(SB_COOKIE)
    print(result["message"])
    content = build_notification(result)
    message_push("烧饼论坛签到", content)


if __name__ == "__main__":
    main()
