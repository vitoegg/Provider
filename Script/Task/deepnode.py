# cron:5 0 * * *
# new Env('NS+DF每日签到');
"""
Version: 1.0.0
Updated Time: 2025-10-06 22:01:09
Reference: https://github.com/wugeng20/NodeSeekSignin
"""
import os
import random
import time

import cloudscraper

# ==============================================
# 常量定义（Constant Definitions）
# ==============================================
# 论坛基础URL
NODESEEK_URL = "https://www.nodeseek.com"
DEEPFLOOD_URL = "https://www.deepflood.com"

# 随机等待时间配置（秒）
SIGNIN_WAIT_MIN = 5
SIGNIN_WAIT_MAX = 20

# 双论坛签到间隔时间（秒）
BETWEEN_SIGNIN_WAIT = 120  # 2分钟


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
class EnvConfig:
    """环境变量配置类，集中管理所有配置参数"""

    # NodeSeek配置
    ns_cookie = os.environ.get("NS_COOKIE", "")

    # DeepFlood配置
    df_cookie = os.environ.get("DF_COOKIE", "")


# 实例化配置对象
env = EnvConfig()

# 尝试导入青龙API（用于通知）
try:
    from notify import send

    QLAPI = send
except ImportError:
    QLAPI = None


# ==============================================
# 工具函数（Utility Functions）
# ==============================================
def random_wait(min_sec, max_sec):
    """随机等待一段时间，模拟人类操作间隔"""
    delay = random.uniform(min_sec, max_sec)
    print(f"⏳ 随机等待 {delay:.2f} 秒后继续操作...")
    time.sleep(delay)


def get_current_time():
    """获取当前时间的格式化字符串"""
    return time.strftime("%Y-%m-%d %H:%M:%S", time.localtime())


# ==============================================
# 论坛签到基类（Base Forum Sign-in Class）
# ==============================================
class BaseForum:
    """论坛签到基类，封装通用签到逻辑"""

    def __init__(self, base_url, cookie):
        """
        初始化论坛签到实例

        :param base_url: 论坛基础URL
        :param cookie: 用户登录Cookie
        """
        self.base_url = base_url.rstrip("/")
        self.cookie = cookie
        self.headers = self._init_headers()

    def _init_headers(self):
        """初始化请求头，模拟真实Chrome浏览器"""
        return {
            "Accept": "*/*",
            "Accept-Encoding": "gzip, deflate, br, zstd",
            "Accept-Language": "en-US,en;q=0.9,zh-CN;q=0.8,zh;q=0.7",
            "Origin": f"{self.base_url}",
            "Sec-CH-UA": '"Chromium";v="140", "Not:A-Brand";v="24", "Google Chrome";v="140"',
            "Sec-CH-UA-Mobile": "?0",
            "Sec-CH-UA-Platform": '"macOS"',
            "Sec-Fetch-Dest": "empty",
            "Sec-Fetch-Mode": "cors",
            "Sec-Fetch-Site": "same-origin",
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36",
        }

    def sign_in(self):
        """执行签到操作（需子类实现具体逻辑）"""
        raise NotImplementedError("子类必须实现sign_in方法")


# ==============================================
# 具体论坛实现（Specific Forum Implementations）
# ==============================================
class NodeSeekForum(BaseForum):
    """NodeSeek论坛签到实现"""

    def sign_in(self):
        """执行NodeSeek签到"""
        if not self.cookie:
            return {"success": False, "message": "❌ 未设置 NS_COOKIE 环境变量"}

        sign_url = f"{self.base_url}/api/attendance?random=true"
        self.headers["Referer"] = f"{self.base_url}/board"
        self.headers["Cookie"] = self.cookie

        try:
            response = scraper.post(sign_url, headers=self.headers)
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


class DeepFloodForum(BaseForum):
    """DeepFlood论坛签到实现"""

    def sign_in(self):
        """执行DeepFlood签到"""
        if not self.cookie:
            return {"success": False, "message": "❌ 未设置 DF_COOKIE 环境变量"}

        sign_url = f"{self.base_url}/api/attendance?random=true"
        self.headers["Referer"] = f"{self.base_url}/board"
        self.headers["Cookie"] = self.cookie

        try:
            response = scraper.post(sign_url, headers=self.headers)
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
def send_notification(forum_name, sign_result):
    """
    发送签到结果通知到青龙面板

    :param forum_name: 论坛名称
    :param sign_result: 签到结果字典 {"success": bool, "message": str}
    """
    if not QLAPI:
        print("⚠️ 非青龙环境，跳过通知推送")
        return

    # 构造通知内容
    title = f"{forum_name} 每日签到"
    content = f"{sign_result['message']}\n🕐 签到时间：{get_current_time()}"

    try:
        QLAPI(title, content)
        print("📤 青龙通知推送成功")
    except Exception as e:
        print(f"❌ 青龙通知推送失败：{str(e)}")


# ==============================================
# 主流程控制（Main Workflow Control）
# ==============================================
def run_forum_signin(forum, forum_name):
    """
    执行单个论坛的签到流程

    :param forum: 论坛实例
    :param forum_name: 论坛名称
    """
    print(f"\n{'=' * 50}")
    print(f"🎯 开始 {forum_name} 签到流程")
    print(f"{'=' * 50}")

    # 随机等待后执行签到
    random_wait(SIGNIN_WAIT_MIN, SIGNIN_WAIT_MAX)
    print(f"📝 正在执行 {forum_name} 签到...")
    sign_result = forum.sign_in()
    print(f"结果：{sign_result['message']}")

    # 推送通知
    print(f"📤 正在推送签到通知...")
    send_notification(forum_name, sign_result)

    print(f"{'=' * 50}")
    print(f"✨ {forum_name} 签到流程完成")
    print(f"{'=' * 50}\n")


def main():
    """主程序入口"""
    print("\n" + "=" * 50)
    print("🚀 论坛签到脚本启动")
    print("=" * 50 + "\n")

    # 检查配置情况
    has_ns = bool(env.ns_cookie)
    has_df = bool(env.df_cookie)

    if not has_ns and not has_df:
        print("❌ 未配置任何论坛的Cookie，无法执行签到")
        print("请设置 NS_COOKIE 或 DF_COOKIE 环境变量")
        return

    # 执行NodeSeek签到
    if has_ns:
        nodeseek = NodeSeekForum(base_url=NODESEEK_URL, cookie=env.ns_cookie)
        run_forum_signin(nodeseek, "NodeSeek")

        # 如果两个网站都配置了，中间等待2分钟
        if has_df:
            print(f"⏳ 等待 {BETWEEN_SIGNIN_WAIT} 秒后执行下一个论坛签到...")
            time.sleep(BETWEEN_SIGNIN_WAIT)
    else:
        print("⚠️ 未配置 NodeSeek Cookie，跳过 NodeSeek 签到\n")

    # 执行DeepFlood签到
    if has_df:
        deepflood = DeepFloodForum(base_url=DEEPFLOOD_URL, cookie=env.df_cookie)
        run_forum_signin(deepflood, "DeepFlood")
    else:
        print("⚠️ 未配置 DeepFlood Cookie，跳过 DeepFlood 签到\n")

    print("=" * 50)
    print("🎉 所有签到任务执行完毕")
    print("=" * 50 + "\n")


if __name__ == "__main__":
    main()
