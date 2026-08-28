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


def normalize_text(value):
    """将页面局部文本规范化为单行内容。"""
    return " ".join(value.split())


def log_excerpt(value, limit=500):
    """限制诊断文本长度，避免异常页面污染日志。"""
    text = normalize_text(value)
    return text if len(text) <= limit else f"{text[:limit]}..."


class SigninPageParser(HTMLParser):
    """提取签到页面的表单、状态及结果节点。"""

    CAPTURES = {
        "streak": "signin-streak-num",
        "hero_main": "signin-hero-main",
    }

    def __init__(self):
        super().__init__()
        self.in_signin_form = False
        self.has_signin_form = False
        self.csrf_token = ""
        self.already_signed = False
        self.hero_depth = 0
        self.result_depth = 0
        self.results = []
        self.depths = {name: 0 for name in self.CAPTURES}
        self.parts = {name: [] for name in self.CAPTURES}

    def handle_starttag(self, tag, attrs):
        attributes = dict(attrs)
        classes = set(attributes.get("class", "").split())

        if tag == "form":
            action = urlparse(attributes.get("action", "")).path.rstrip("/")
            method = attributes.get("method", "get").lower()
            self.in_signin_form = (
                "signin-form" in classes
                and action == "/signin"
                and method == "post"
            )
            self.has_signin_form = self.has_signin_form or self.in_signin_form
        elif tag == "input" and self.in_signin_form:
            if attributes.get("name") == "_csrf":
                self.csrf_token = attributes.get("value", "")

        if tag == "div":
            if self.hero_depth:
                self.hero_depth += 1
            if self.result_depth:
                self.result_depth += 1
            for name, depth in self.depths.items():
                if depth:
                    self.depths[name] = depth + 1

            if not self.hero_depth and "signin-hero" in classes:
                self.hero_depth = 1
            if not self.result_depth and "signin-result" in classes:
                self.result_depth = 1
                self.results.append({"classes": classes, "parts": []})
            for name, class_name in self.CAPTURES.items():
                if not self.depths[name] and class_name in classes:
                    self.depths[name] = 1

        if (
            tag == "button"
            and self.hero_depth
            and "btn-post" in classes
            and "disabled" in attributes
        ):
            self.already_signed = True

    def handle_endtag(self, tag):
        if tag == "form":
            self.in_signin_form = False

        if tag == "div":
            if self.hero_depth:
                self.hero_depth -= 1
            if self.result_depth:
                self.result_depth -= 1
            for name, depth in self.depths.items():
                if depth:
                    self.depths[name] = depth - 1

    def handle_data(self, data):
        if self.result_depth:
            self.results[-1]["parts"].append(data)
        for name, depth in self.depths.items():
            if depth:
                self.parts[name].append(data)

    def text(self, name):
        return normalize_text(" ".join(self.parts[name]))

    def signin_results(self):
        return tuple(
            (result["classes"], normalize_text(" ".join(result["parts"])))
            for result in self.results
        )


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


def parse_signin_page(html):
    parser = SigninPageParser()
    parser.feed(html)
    parser.close()
    return parser


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


def build_result(
    status,
    message,
    *,
    days="",
    reward="",
    warnings=(),
    log_details=(),
):
    return {
        "success": status != "failed",
        "status": status,
        "message": message,
        "days": days,
        "reward": reward,
        "warnings": warnings,
        "log_details": log_details,
    }


def failure(message, detail):
    return build_result("failed", message, log_details=(detail,))


def parse_streak_days(page):
    """从固定的连续签到数字节点读取天数。"""
    streak = page.text("streak")
    if re.fullmatch(r"\d+", streak):
        return streak, None

    if streak:
        detail = (
            "连续签到天数解析失败：内容不是有效整数；"
            f"source=.signin-streak-num text={log_excerpt(streak)!r}"
        )
    else:
        detail = (
            "连续签到天数解析失败：未找到目标节点；"
            "source=.signin-streak-num context=.signin-hero-main "
            f"text={log_excerpt(page.text('hero_main'))!r}"
        )

    return "", ("连续签到天数解析失败", detail)


def parse_reward(result_text):
    """从签到成功提示中的“共 N 饼”读取最终奖励。"""
    rewards = re.findall(r"共\s*(\d+)\s*饼", result_text)
    if len(rewards) == 1:
        return rewards[0], None

    return "", (
        "本次获得烧饼数解析失败",
        (
            "本次获得烧饼数解析失败：未找到唯一的“共 N 饼”；"
            "source=.signin-result.success "
            f"text={log_excerpt(result_text)!r}"
        ),
    )


def parse_post_result(html):
    """仅依据 POST 响应中的结果节点判断签到是否成功。"""
    page = parse_signin_page(html)
    results = page.signin_results()
    if len(results) != 1:
        if results:
            nodes = "; ".join(
                (
                    f"#{index} class={' '.join(sorted(classes))!r} "
                    f"text={log_excerpt(text)!r}"
                )
                for index, (classes, text) in enumerate(results, 1)
            )
            detail = (
                "POST 未确认签到结果：.signin-result 节点数量异常；"
                f"count={len(results)} nodes=[{nodes}]"
            )
        else:
            detail = "POST 未确认签到成功：未找到 .signin-result"
        return failure("签到失败", detail)

    result_classes, result_text = results[0]
    if "success" not in result_classes:
        detail = (
            "POST 未确认签到成功："
            f"result_class={' '.join(sorted(result_classes))!r} "
            f"result={log_excerpt(result_text)!r}"
        )
        return failure("签到失败", detail)

    days, days_warning = parse_streak_days(page)
    reward, reward_warning = parse_reward(result_text)
    warnings = tuple(item for item in (days_warning, reward_warning) if item)
    return build_result(
        "success",
        "签到成功",
        days=days,
        reward=reward,
        warnings=warnings,
    )


def validate_response(response, stage):
    """验证响应状态与来源；异常时返回分类结果。"""
    status = response.status_code
    if status in {401, 403, 429}:
        return failure(
            "访问受限，签到未完成",
            f"{stage}被拒绝：status={status} url={response.url!r}",
        )
    if status >= 500:
        return failure(
            "论坛服务异常，签到未完成",
            f"论坛服务异常：stage={stage} status={status} url={response.url!r}",
        )
    if status >= 400:
        return failure(
            "签到请求异常",
            f"请求异常：stage={stage} status={status} url={response.url!r}",
        )

    response_url = urlparse(response.url)
    expected_url = urlparse(SB_URL)
    if response_url.scheme != "https" or response_url.netloc != expected_url.netloc:
        return failure(
            "签到响应异常",
            f"响应跳转到非论坛域名：stage={stage} final_url={response.url!r}",
        )

    if response_url.path.rstrip("/") in {"/login", "/signin/login"}:
        return failure(
            "登录已失效，请更新 Cookie",
            f"登录失效：{stage}跳转到 {response_url.path}",
        )

    content_type = response.headers.get("Content-Type", "").lower()
    if "text/html" not in content_type:
        return failure(
            "签到响应异常",
            f"响应类型异常：stage={stage} content_type={content_type!r}",
        )

    html = response.text.lower()
    if any(marker in html for marker in CHALLENGE_MARKERS):
        return failure(
            "访问受限，签到未完成",
            f"{stage}遇到 Cloudflare 验证",
        )

    return None


def sb_signin(cookie):
    """执行烧饼论坛签到。"""
    if not cookie:
        return failure(
            "配置异常，签到未执行",
            "配置异常：未设置 SB_COOKIE",
        )

    missing = missing_cookie_names(cookie)
    if missing:
        return failure(
            "配置异常，签到未执行",
            f"配置异常：Cookie 缺少必要字段：{', '.join(missing)}",
        )

    session = build_session(cookie)
    signin_url = f"{SB_URL}/signin/"

    try:
        wait_random_interval(START_DELAY, "签到任务启动")
        response = session.get(signin_url, timeout=TIMEOUT)
        error = validate_response(response, "签到页面")
        if error:
            return error
        print("[INFO] GET 签到页面成功")

        page = parse_signin_page(response.text)
        if page.already_signed:
            print("[INFO] 检测到今日已签到，本次不发起 POST")
            return build_result("already_signed", "今日已签到")

        if not page.has_signin_form:
            results = page.signin_results()
            return failure(
                "签到页面结构异常",
                (
                    "GET 页面结构异常：未找到已签到状态或签到表单；"
                    f"result_count={len(results)} "
                    f"context={log_excerpt(page.text('hero_main'))!r}"
                ),
            )
        if not page.csrf_token:
            return failure(
                "签到页面结构异常",
                "GET 页面结构异常：签到表单缺少 _csrf",
            )
        print("[INFO] 找到签到表单和 CSRF token")

        wait_random_interval(SUBMIT_DELAY, "提交签到前")
        response = session.post(
            signin_url,
            data={"_csrf": page.csrf_token},
            headers={"Origin": SB_URL, "Referer": signin_url},
            timeout=TIMEOUT,
        )
        error = validate_response(response, "签到提交")
        if error:
            return error
        print("[INFO] POST 签到请求成功")
        return parse_post_result(response.text)
    except requests.RequestException as error:
        return failure(
            "网络异常，签到未完成",
            f"网络异常：error={error!r}",
        )


def build_notification(result, executed_at):
    """生成面向 Telegram 的简洁通知。"""
    if result["status"] == "already_signed":
        lines = ["☑️ 今日已签到"]
    elif result["status"] == "success":
        lines = ["✅ 签到成功"]
        if result["reward"]:
            lines.append(f"🍪 本次获得：{result['reward']} 饼")
        if result["days"]:
            lines.append(f"📅 连续签到：{result['days']} 天")
        lines.extend(f"⚠️ {message}" for message, _ in result["warnings"])
    else:
        lines = [f"❌ {result['message']}"]

    lines.append(f"⏰ 执行时间：{executed_at}")
    return "\n".join(lines)


def log_result(result):
    """输出仅供诊断的详细日志。"""
    level = "INFO" if result["success"] else "ERROR"
    print(f"[{level}] 签到结果：{result['message']}")
    for detail in result["log_details"]:
        print(f"[ERROR] {detail}")
    for _, detail in result["warnings"]:
        print(f"[WARN] {detail}")


def message_push(title, message):
    """调用青龙系统通知。"""

    try:
        response = QLAPI.systemNotify({"title": title, "content": message})
        if response.get("code", 400) == 200:
            print("[INFO] Telegram 通知推送成功")
        else:
            print(f"[ERROR] Telegram 通知推送失败：response={response!r}")
    except Exception as error:
        print(f"[ERROR] Telegram 通知推送异常：error={error!r}")


def main():
    print("🚀 烧饼论坛签到脚本启动")
    result = sb_signin(SB_COOKIE)
    log_result(result)
    executed_at = time.strftime("%Y-%m-%d %H:%M:%S")
    content = build_notification(result, executed_at)
    message_push("烧饼论坛签到", content)


if __name__ == "__main__":
    main()
