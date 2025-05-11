#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import requests
import os
import sys
import re

def fetch_qidian_plugin():
    """
    获取起点广告拦截插件
    """
    print("开始获取起点广告拦截插件...")
    
    url = "https://kelee.one/Tool/Loon/Plugin/QiDian_remove_ads.plugin"
    
    # 使用精确的Loon 3.0.7 UA
    headers = {
        "User-Agent": "Loon/3.0.7",
        "Accept": "*/*",
        "Accept-Language": "zh-CN,zh;q=0.9",
        "Connection": "keep-alive",
        "Cache-Control": "no-cache"
    }
    
    try:
        # 发送请求获取插件内容
        response = requests.get(url, headers=headers, timeout=15)
        print(f"响应状态码: {response.status_code}")
        
        # 打印部分响应头信息，便于调试
        print("响应头信息:")
        for key, value in response.headers.items():
            print(f"  {key}: {value}")
        
        if response.status_code == 200:
            content = response.text
            
            # 检查内容是否为HTML (可能是错误页面)
            if "<!DOCTYPE html>" in content or "<html" in content:
                print("获取到的是HTML页面，可能是错误页面")
                if "Cloudflare" in content:
                    print("内容包含Cloudflare信息，可能被防护墙拦截")
                print("内容预览:")
                print(content[:500])
                return False, False
            
            # 检查内容是否符合Loon插件格式
            if not ("[URL Rewrite]" in content or "[MITM]" in content):
                print("获取的内容不符合Loon插件格式")
                print("内容预览:")
                print(content[:500])
                return False, False
                
            # 创建存储临时文件的目录
            os.makedirs("tmp", exist_ok=True)
            
            # 保存原始插件内容
            with open("tmp/qidian_original.plugin", "w", encoding="utf-8") as f:
                f.write(content)
            
            # 移除包含gdt.qq.com的行
            content_filtered = ""
            for line in content.splitlines():
                if "gdt.qq.com" not in line:
                    content_filtered += line + "\n"
            
            # 保存处理后的插件内容
            with open("tmp/qidian_processed.plugin", "w", encoding="utf-8") as f:
                f.write(content_filtered)
            
            # 确保目标目录存在
            target_dir = os.path.join(os.environ.get("GITHUB_WORKSPACE", ""), "Module", "Loon")
            os.makedirs(target_dir, exist_ok=True)
            
            # 目标文件路径
            target_file = os.path.join(target_dir, "Qidian.plugin")
            
            # 检查是否有变化或文件不存在
            is_changed = True
            if os.path.exists(target_file):
                with open(target_file, "r", encoding="utf-8") as f:
                    old_content = f.read()
                is_changed = old_content != content_filtered
            
            # 保存处理后的内容到目标文件
            if is_changed:
                with open(target_file, "w", encoding="utf-8") as f:
                    f.write(content_filtered)
                print(f"已将处理后的插件保存到 {target_file}")
                print("文件内容已更新")
                # 预览文件内容
                preview_lines = content_filtered.splitlines()[:5]
                print("文件内容预览（前5行）:")
                for line in preview_lines:
                    print(f"  {line}")
                return True, True  # 成功获取且有变化
            else:
                print(f"目标文件 {target_file} 内容无变化，无需更新")
                return True, False  # 成功获取但无变化
        else:
            print(f"请求失败: HTTP {response.status_code}")
            print(f"响应内容: {response.text[:200]}")
            return False, False
            
    except Exception as e:
        print(f"请求异常: {e}")
        return False, False

if __name__ == "__main__":
    success, has_changes = fetch_qidian_plugin()
    
    # 获取GitHub输出文件路径（GitHub Actions 2.0环境变量）
    github_output = os.environ.get("GITHUB_OUTPUT")
    
    # 使用GitHub Actions的输出格式
    if github_output:
        # 新版GitHub Actions输出格式
        with open(github_output, "a") as f:
            f.write(f"success={'true' if success else 'false'}\n")
            f.write(f"has_changes={'true' if has_changes else 'false'}\n")
    else:
        # 为了兼容性，也输出旧版格式
        print(f"::set-output name=success::{str(success).lower()}")
        print(f"::set-output name=has_changes::{str(has_changes).lower()}")
    
    sys.exit(0 if success else 1) 