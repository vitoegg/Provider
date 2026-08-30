# cron:10 8 * * *
# new Env('V2EX论坛签到');
"""
V2EX论坛 - 自动签到Cookie版
Reference: https://github.com/Sitoi/dailycheckin
"""
import os
import re
import random
import time
from html import unescape
from urllib.parse import urlparse

import requests

# ==============================================
# 配置区域 (Configuration Section)
# 所有配置通过环境变量获取，便于青龙面板管理
# ==============================================

# V2EX环境变量
## 获取V2EX Cookie环境变量
V2EX_COOKIE = os.environ.get("V2EX_COOKIE", "")

V2EX_ORIGIN = "https://www.v2ex.com"
REQUEST_TIMEOUT = 30
SUCCESS_MARKER = "每日登录奖励已领取"

# ==============================================
# 工具函数 (Utility Functions)
# ==============================================

def wait_random_interval(min_seconds, max_seconds):
    """等待min_seconds到max_seconds之间的随机时长"""
    delay = random.uniform(min_seconds, max_seconds)
    print(f"等待 {delay:.2f} 秒后继续...")
    time.sleep(delay)
    print("执行下一步操作！")

# ==============================================
# 核心功能 (Core Functions)
# ==============================================

def parse_cookie_header(cookie):
    """解析 Cookie 请求头，不依赖固定的分号空格格式。"""
    cookie_dict = {}
    for item in cookie.split(";"):
        item = item.strip()
        if not item or "=" not in item:
            continue
        key, value = item.split("=", 1)
        key = key.strip()
        if key:
            cookie_dict[key] = value.strip()
    return cookie_dict


def build_session(cookie):
    """创建仅向 V2EX 根域发送 Cookie 的会话。"""
    session = requests.Session()
    for key, value in parse_cookie_header(cookie).items():
        session.cookies.set(key, value, domain=".v2ex.com", path="/", secure=True)
    session.headers.update(
        {
            "user-agent": (
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                "AppleWebKit/537.36 (KHTML, like Gecko) "
                "Chrome/151.0.0.0 Safari/537.36"
            ),
            "accept": (
                "text/html,application/xhtml+xml,application/xml;q=0.9,"
                "image/avif,image/webp,image/apng,*/*;q=0.8,"
                "application/signed-exchange;v=b3;q=0.7"
            ),
            "accept-language": "en-US,en;q=0.9,zh-CN;q=0.8",
            "sec-ch-ua": (
                '"Not=A?Brand";v="99", "Google Chrome";v="151", '
                '"Chromium";v="151"'
            ),
            "sec-ch-ua-mobile": "?0",
            "sec-ch-ua-platform": '"macOS"',
        }
    )
    return session


def request_page(session, path, stage, **kwargs):
    """请求 V2EX，并输出不包含 Cookie 和 once 的结构化日志。"""
    response = session.get(
        url=f"{V2EX_ORIGIN}{path}", timeout=REQUEST_TIMEOUT, **kwargs
    )
    chain = [*response.history, response]
    route = ">".join(
        f"{item.status_code}:{urlparse(item.url).path}" for item in chain
    )
    print(f"V2EX请求：stage={stage} route={route}")
    response.raise_for_status()
    return response


def extract_redeem_path(html):
    match = re.search(
        r"location\.href\s*=\s*['\"]"
        r"(/mission/daily/redeem\?once=[A-Za-z0-9_-]+)['\"]",
        unescape(html),
    )
    return match.group(1) if match else ""


def extract_days(html):
    text = re.sub(r"<[^>]+>", " ", unescape(html))
    match = re.search(r"已连续登录\s*(\d+)\s*天", text)
    return f"{match.group(1)}天" if match else "获取失败"


def is_cookie_invalid(response):
    return urlparse(response.url).path.rstrip("/") == "/signin"


def is_signin_success(response):
    return (
        urlparse(response.url).path.rstrip("/") == "/mission/daily"
        and SUCCESS_MARKER in unescape(response.text)
    )


def serialize_session_cookies(session):
    cookies = {
        cookie.name: cookie.value
        for cookie in session.cookies
        if cookie.domain.lstrip(".").lower() in {"v2ex.com", "www.v2ex.com"}
        and cookie.path == "/"
        and not cookie.is_expired()
    }
    return "; ".join(f"{name}={cookies[name]}" for name in sorted(cookies))


def persist_cookie_if_changed(original_cookie, session):
    """登录确认后，将服务端更新的 Cookie 单次写回当前青龙变量。"""
    updated_cookie = serialize_session_cookies(session)
    if not updated_cookie or (
        parse_cookie_header(updated_cookie) == parse_cookie_header(original_cookie)
    ):
        return True, "unchanged"

    try:
        qlapi = QLAPI
    except NameError:
        return False, "青龙内置 API 不可用"

    try:
        response = qlapi.getEnvs({"searchValue": "V2EX_COOKIE"})
        if response.get("code") != 200:
            return False, "读取青龙环境变量失败"
        candidates = [
            item
            for item in response.get("data", [])
            if item.get("name") == "V2EX_COOKIE"
            and item.get("value") == original_cookie
        ]
        if len(candidates) != 1:
            return False, "无法唯一定位当前 V2EX_COOKIE，已拒绝覆盖"

        current_env = candidates[0]
        env_data = {
            "id": current_env["id"],
            "name": "V2EX_COOKIE",
            "value": updated_cookie,
        }
        if "remarks" in current_env:
            env_data["remarks"] = current_env["remarks"]
        response = qlapi.updateEnv({"env": env_data})
        if response.get("code") != 200:
            return False, "更新青龙环境变量失败"
        return True, "updated"
    except Exception as error:
        return False, f"写回青龙环境变量异常（{type(error).__name__}）"


def get_account_info(session):
    response = request_page(session, "/balance", "balance")
    if is_cookie_invalid(response):
        return None
    if urlparse(response.url).path.rstrip("/") != "/balance":
        raise RuntimeError("unexpected_balance_response")

    total = re.findall(
        r'<td class="d" style="text-align: right;">(\d+\.\d+)</td>',
        response.text,
    )
    today = re.findall(
        r'<td class="d"><span class="gray">(.*?)</span></td>', response.text
    )
    username = re.findall(
        r'<a href="/member/.*?" class="top">(.*?)</a>', response.text
    )
    return {
        "username": username[0] if username else "获取失败",
        "today": today[0] if today else "获取失败",
        "total": total[0] if total else "获取失败",
    }


def v2ex_signin(cookie):
    """
    V2EX签到函数
    :param cookie: 用户Cookie
    :return: 签到结果信息
    """
    if not cookie:
        print("未设置V2EX Cookie，请检查V2EX_COOKIE环境变量设置是否正确")
        return "签到异常：Cookie 已失效"

    session = build_session(cookie)
    stage = "daily"

    try:
        response = request_page(session, "/mission/daily", stage)
        if is_cookie_invalid(response):
            return "签到异常：Cookie 已失效"
        if is_signin_success(response):
            signin_status = "今日登录奖励已领取"
        else:
            redeem_path = extract_redeem_path(response.text)
            if not redeem_path:
                print("V2EX签到异常：stage=daily reason=unexpected_response")
                return "签到异常：V2EX 签到失败"

            stage = "redeem"
            response = request_page(
                session,
                redeem_path,
                stage,
                headers={"Referer": f"{V2EX_ORIGIN}/mission/daily"},
            )
            if is_cookie_invalid(response):
                return "签到异常：Cookie 已失效"
            if not is_signin_success(response):
                print("V2EX签到异常：stage=redeem reason=unexpected_response")
                return "签到异常：V2EX 签到失败"
            signin_status = "已成功领取每日登录奖励"

        days = extract_days(response.text)
        try:
            account = get_account_info(session)
        except Exception as error:
            print(f"V2EX账户信息异常：type={type(error).__name__}")
            account = {
                "username": "获取失败",
                "today": signin_status,
                "total": "获取失败",
            }
        if account is None:
            return "签到异常：Cookie 已失效"
        if account["today"] == "获取失败":
            account["today"] = signin_status
        result = (
            f"👤【用户名】：{account['username']}\n"
            f"🎯【今日签到】：{account['today']}\n"
            f"💰【账户余额】：{account['total']}\n"
            f"📅【签到天数】：{days}"
        )
    except Exception as error:
        print(f"V2EX签到异常：stage={stage} type={type(error).__name__}")
        return "签到异常：V2EX 签到失败"

    persist_ok, persist_status = persist_cookie_if_changed(cookie, session)
    if persist_status == "updated":
        print("V2EX Cookie 已自动续期并写回青龙环境变量")
    elif not persist_ok:
        print("V2EX Cookie 续期写回失败：", persist_status)
        result += f"\n⚠️【Cookie续期】：{persist_status}"
    return result

# 消息推送（调用的是青龙系统通知API）
def message_push(title, message):
    """
    消息推送通知
    :param title: 消息标题
    :param message: 消息内容
    """
    response = QLAPI.systemNotify({"title": title, "content": message})

    if response.get("code", 400) == 200:
        print("消息推送成功：", response)
    else:
        print("消息推送失败：", response)

# ==============================================
# 主程序入口 (Main Entry)
# ==============================================
if __name__ == "__main__":
    wait_random_interval(3, 10)  # 随机等待3-10秒
    print("===========================正在进行V2EX签到==========================")

    try:
        signin_result = v2ex_signin(V2EX_COOKIE)
        print(signin_result)
    except Exception as e:
        signin_result = "V2EX签到报错：V2EX签到失败，请检查Cookie是否正确或失效。"
        print("V2EX签到报错，错误信息: ", str(e))
        print(signin_result)

    wait_random_interval(2, 5)  # 随机等待2-5秒
    print("=========================正在推送V2EX签到信息=========================")

    try:
        content = f"{signin_result}\n⏰ {time.strftime('%Y-%m-%d %H:%M:%S', time.localtime())}"
        message_push("V2EX论坛签到", content)
    except Exception as e:
        print("推送失败，错误信息: ", str(e))
        print("请检查青龙系统设置-》通知设置-》是否配置。")

    print("=============================V2EX运行结束============================")
