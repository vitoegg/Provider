# cron:5 0 * * *
# new Env('NodeSeek每日签到');
"""
Version: 2.1.0
Updated Time: 2026-01-05 10:30:00
Reference: https://github.com/wugeng20/NodeSeekSignin
"""
import os
import time

import cloudscraper
from notify import send as ql_notify

# ==============================================
# 常量定义（Constant Definitions）
# ==============================================
# 论坛基础URL
NODESEEK_URL = "https://www.nodeseek.com"


# ==============================================
# 初始化网络请求器（Initialize Network Scraper）
# ==============================================
def init_scraper():
    """初始化cloudscraper实例，用于处理带Cloudflare验证的请求"""
    return cloudscraper.create_scraper(
        interpreter="js2py",
        delay=6,
        enable_stealth=True,
        stealth_options={
            "min_delay": 5.0,
            "max_delay": 10.0,
            "human_like_delays": True,
            "randomize_headers": True,
            "browser_quirks": True,
        },
        browser="chrome",
        debug=False,
    )


# 初始化全局scraper实例
scraper = init_scraper()


# ==============================================
# 环境变量配置（Environment Configuration）
# ==============================================
# NodeSeek Cookie
NS_COOKIE = os.environ.get("NS_COOKIE", "")
# 签到模式配置（false=固定签到，true=随机签到）
NS_RANDOM = os.environ.get("NS_RANDOM", "false").lower()


# ==============================================
# 工具函数（Utility Functions）
# ==============================================
def get_current_time():
    """获取当前时间的格式化字符串"""
    return time.strftime("%Y-%m-%d %H:%M:%S", time.localtime())


def build_headers(base_url, cookie):
    """构建请求头，模拟真实Chrome浏览器"""
    return {
        "Accept": "*/*",
        "Accept-Encoding": "gzip, deflate, br, zstd",
        "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8",
        "Origin": base_url,
        "Referer": f"{base_url}/board",
        "Cookie": cookie,
        "Sec-CH-UA": '"Chromium";v="134", "Not:A-Brand";v="24", "Google Chrome";v="134"',
        "Sec-CH-UA-Mobile": "?0",
        "Sec-CH-UA-Platform": '"Windows"',
        "Sec-Fetch-Dest": "empty",
        "Sec-Fetch-Mode": "cors",
        "Sec-Fetch-Site": "same-origin",
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36",
    }


# ==============================================
# 签到功能（Sign-in Function）
# ==============================================
def nodeseek_signin(cookie):
    """
    执行NodeSeek签到

    :param cookie: 用户登录Cookie
    :return: 签到结果字典 {"success": bool, "message": str}
    """
    if not cookie:
        return {"success": False, "message": "❌ 未设置 NS_COOKIE 环境变量"}

    sign_url = f"{NODESEEK_URL}/api/attendance?random={NS_RANDOM}"
    headers = build_headers(NODESEEK_URL, cookie)

    try:
        response = scraper.post(sign_url, headers=headers)
        data = response.json()
        success = data.get("success", False)
        message = data.get("message", "签到状态未知")

        # 根据返回判断签到结果
        if success:
            return {"success": True, "message": f"✅ {message}"}
        elif "已完成签到" in message or "重复操作" in message:
            return {"success": True, "message": f"⚠️ {message}"}
        else:
            return {"success": False, "message": f"❌ {message}"}

    except Exception as e:
        return {"success": False, "message": f"❌ 签到异常：{str(e)}"}


# ==============================================
# 消息通知模块（Notification Module）
# ==============================================
def send_notification(sign_result):
    """
    发送签到结果通知到青龙面板

    :param sign_result: 签到结果字典 {"success": bool, "message": str}
    """
    title = "NodeSeek 每日签到"
    mode = "随机模式" if NS_RANDOM == "true" else "固定模式"
    content = f"{sign_result['message']}\n📌 签到模式：{mode}\n🕐 签到时间：{get_current_time()}"

    try:
        ql_notify(title, content)
        print("📤 青龙通知推送成功")
    except Exception as e:
        print(f"❌ 青龙通知推送失败：{str(e)}")


# ==============================================
# 主程序入口（Main Entry Point）
# ==============================================
def main():
    """主程序入口"""
    print("\n" + "=" * 50)
    print("🚀 NodeSeek 签到脚本启动")
    print("=" * 50 + "\n")

    # 检查Cookie配置
    if not NS_COOKIE:
        print("❌ 未配置 NS_COOKIE 环境变量，无法执行签到")
        return

    # 显示当前签到模式
    mode = "随机模式" if NS_RANDOM == "true" else "固定模式"
    print(f"📌 当前签到模式：{mode}")

    # 执行签到
    print("📝 正在执行 NodeSeek 签到...")
    sign_result = nodeseek_signin(NS_COOKIE)
    print(f"结果：{sign_result['message']}")

    # 推送通知
    print("📤 正在推送签到通知...")
    send_notification(sign_result)

    print("\n" + "=" * 50)
    print("🎉 NodeSeek 签到任务执行完毕")
    print("=" * 50 + "\n")


if __name__ == "__main__":
    main()
