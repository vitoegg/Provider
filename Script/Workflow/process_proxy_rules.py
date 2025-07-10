#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
规则处理脚本
功能: 去重域名规则、优化规则集合
"""

import sys
import time
import os

def main():
    # 检查命令行参数
    if len(sys.argv) < 2:
        print("用法: {} <输入文件路径>".format(sys.argv[0]), file=sys.stderr)
        sys.exit(1)
        
    input_file = sys.argv[1]
    
    # 检查输入文件是否存在
    if not os.path.exists(input_file):
        print("错误: 输入文件 '{}' 不存在".format(input_file), file=sys.stderr)
        sys.exit(1)
    
    start_time = time.time()
    
    # 初始化统计信息
    stats = {
        "total": 0,          # 总规则数
        "duplicates": 0,     # 重复规则数
        "wildcard_covered": 0, # 被泛域名覆盖的规则数
        "exact_covered": 0,  # 被泛域名覆盖的精确域名规则数
        "kept": 0            # 保留的规则数
    }
    
    # 初始化数据结构
    all_rules = set()           # 存储所有规则
    wildcard_domains = set()    # 存储所有泛域名（不带前导点）
    wildcard_rules = []         # 存储泛域名规则
    exact_rules = []            # 存储精确域名规则
    
    try:
        # 1. 读取文件并进行基础分类
        print("[1/4] 读取规则文件...", file=sys.stderr)
        with open(input_file, 'r', encoding='utf-8') as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                    
                stats["total"] += 1
                
                # 基础去重
                if line in all_rules:
                    stats["duplicates"] += 1
                    continue
                    
                all_rules.add(line)
                
                # 区分泛域名和精确域名规则
                if line.startswith('.'):
                    domain = line[1:]  # 去掉前导点
                    wildcard_rules.append((domain, line))
                else:
                    exact_rules.append(line)
        
        # 2. 处理泛域名规则
        print(f"[2/4] 处理泛域名规则 ({len(wildcard_rules)} 条)...", file=sys.stderr)
        # 优先处理短域名
        wildcard_rules.sort(key=lambda x: (len(x[0].split('.')), x[0]))
        
        kept_wildcards = []
        for domain, original in wildcard_rules:
            keep = True
            # 检查是否被更短的泛域名覆盖
            domain_parts = domain.split('.')
            for i in range(1, len(domain_parts)):
                parent = '.'.join(domain_parts[i:])
                if parent in wildcard_domains:
                    keep = False
                    stats["wildcard_covered"] += 1
                    break
            
            if keep:
                wildcard_domains.add(domain)
                kept_wildcards.append(original)
                stats["kept"] += 1
        
        # 3. 处理精确域名规则
        print(f"[3/4] 处理精确域名规则 ({len(exact_rules)} 条)...", file=sys.stderr)
        kept_exact = []
        for line in exact_rules:
            keep = True
            # 检查是否被泛域名覆盖
            domain_parts = line.split('.')
            for i in range(0, len(domain_parts)):
                parent = '.'.join(domain_parts[i:])
                if parent in wildcard_domains:
                    keep = False
                    stats["exact_covered"] += 1
                    break
            
            if keep:
                kept_exact.append(line)
                stats["kept"] += 1
        
        # 4. 生成最终规则
        print(f"[4/4] 生成最终规则...", file=sys.stderr)
        for rule in sorted(kept_wildcards + kept_exact):
            print(rule)
        
        # 输出统计信息
        end_time = time.time()
        print(f"处理时间: {end_time - start_time:.2f} 秒", file=sys.stderr)
        print(f"总规则数: {stats['total']}", file=sys.stderr)
        print(f"重复规则: {stats['duplicates']}", file=sys.stderr)
        print(f"泛域名被覆盖: {stats['wildcard_covered']}", file=sys.stderr)
        print(f"精确域名被覆盖: {stats['exact_covered']}", file=sys.stderr)
        print(f"保留规则: {stats['kept']}", file=sys.stderr)
    
    except Exception as e:
        print(f"处理出错: {str(e)}", file=sys.stderr)
        sys.exit(1)

if __name__ == "__main__":
    main() 