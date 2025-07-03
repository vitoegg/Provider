# cron:10 8 * * *
# new Env('V2EX论坛签到');
"""
V2EX论坛 - 自动签到Cookie版
Version: 1.0.0
Create Time: 2025-07-03 09:30:30
Author: AI Assistant
Description: 用于 V2EX 论坛的每日自动签到
"""
import os
import re
import random
import time

import requests
import urllib3

urllib3.disable_warnings()

# ==============================================
# 配置区域 (Configuration Section)
# 所有配置通过环境变量获取，便于青龙面板管理
# ==============================================

# V2EX环境变量
## 获取V2EX Cookie环境变量
V2EX_COOKIE = os.environ.get("V2EX_COOKIE", "")

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

def v2ex_signin(cookie):
    """
    V2EX签到函数
    :param cookie: 用户Cookie
    :return: 签到结果信息
    """
    if not cookie:
        print("未设置V2EX Cookie，请检查V2EX_COOKIE环境变量设置是否正确")
        return "签到失败：未设置V2EX Cookie，请检查V2EX_COOKIE环境变量设置是否正确"

    # 创建会话
    session = requests.session()
    
    # 解析Cookie
    cookie_dict = {}
    for item in cookie.split("; "):
        if "=" in item:
            key, value = item.split("=", 1)
            cookie_dict[key] = value
    
    # 添加Cookie到会话
    requests.utils.add_dict_to_cookiejar(session.cookies, cookie_dict)
    
    # 设置请求头
    session.headers.update({
        "user-agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/87.0.4280.88 Safari/537.36 Edg/87.0.664.66",
        "accept": "text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.9",
        "accept-language": "zh-CN,zh;q=0.9,en;q=0.8",
    })

    try:
        # 获取签到页面
        response = session.get(url="https://www.v2ex.com/mission/daily", verify=False)
        
        # 查找签到按钮
        pattern = (
            r"<input type=\"button\" class=\"super normal button\""
            r" value=\".*?\" onclick=\"location\.href = \'(.*?)\';\" />"
        )
        urls = re.findall(pattern=pattern, string=response.text)
        url = urls[0] if urls else None
        
        if url is None:
            return "签到失败：cookie 可能过期或已签到"
        elif url != "/balance":
            # 执行签到
            headers = {"Referer": "https://www.v2ex.com/mission/daily"}
            data = {"once": url.split("=")[-1]}
            _ = session.get(
                url="https://www.v2ex.com" + url,
                verify=False,
                headers=headers,
                params=data,
            )
        
        # 获取账户信息
        response = session.get(url="https://www.v2ex.com/balance", verify=False)
        
        # 解析账户余额
        total = re.findall(
            pattern=r"<td class=\"d\" style=\"text-align: right;\">(\d+\.\d+)</td>",
            string=response.text,
        )
        total = total[0] if total else "获取失败"
        
        # 解析今日签到信息
        today = re.findall(
            pattern=r'<td class="d"><span class="gray">(.*?)</span></td>',
            string=response.text,
        )
        today = today[0] if today else "获取失败"
        
        # 解析用户名
        username = re.findall(
            pattern=r"<a href=\"/member/.*?\" class=\"top\">(.*?)</a>",
            string=response.text,
        )
        username = username[0] if username else "获取失败"
        
        # 获取连续签到天数
        response = session.get(url="https://www.v2ex.com/mission/daily", verify=False)
        data = re.findall(
            pattern=r"<div class=\"cell\">(.*?)天</div>", string=response.text
        )
        days = data[0] + "天" if data else "获取失败"
        
        return f"用户信息：\n【用户名】：{username}\n【今日签到】：{today}\n【账户余额】：{total}\n【签到天数】：{days}"
        
    except Exception as e:
        print("V2EX签到报错，错误信息: ", str(e))
        return "签到报错：V2EX签到失败，请检查Cookie是否正确或网络连接"

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
        content = f"{signin_result}\n时间：{time.strftime('%Y-%m-%d %H:%M:%S', time.localtime())}"
        message_push("「V2EX论坛签到」", content)
    except Exception as e:
        print("推送失败，错误信息: ", str(e))
        print("请检查青龙系统设置-》通知设置-》是否配置。")
    
    print("=============================V2EX运行结束============================")
