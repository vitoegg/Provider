#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
规则处理脚本：执行规则的去重和优化
功能：
1. 基础去重 - 移除完全相同的规则
2. 泛域名去重 - 如果.x.com存在，则.a.x.com被视为重复并移除
3. 精确域名去重 - 如果.x.com存在，则a.x.com被视为重复并移除
"""

import sys
import time
import os

def main():
    # 检查参数
    if len(sys.argv) < 2:
        print("用法: {} <input_file>".format(sys.argv[0]), file=sys.stderr)
        sys.exit(1)
        
    input_file = sys.argv[1]
    
    # 检查输入文件是否存在
    if not os.path.exists(input_file):
        print("错误: 输入文件 '{}' 不存在".format(input_file), file=sys.stderr)
        sys.exit(1)
    
    start_time = time.time()
    
    # 统计信息
    stats = {
        "total": 0,
        "duplicates": 0,
        "wildcard_covered": 0,
        "exact_covered": 0,
        "kept": 0
    }
    
    # 数据结构
    all_rules = set()           # 存储所有规则，用于基础去重
    wildcard_domains = set()    # 存储所有泛域名（不带前导点）
    
    # 临时保存规则
    wildcard_rules = []
    exact_rules = []
    
    try:
        print("[1/4] 读取规则文件...", file=sys.stderr)
        # 第一遍：读取文件，进行基础分类和去重
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
                
                # 区分泛域名和精确域名
                if line.startswith('.'):
                    domain = line[1:]  # 去掉前导点
                    wildcard_rules.append((domain, line))
                else:
                    exact_rules.append(line)
        
        print(f"[2/4] 处理泛域名规则 ({len(wildcard_rules)} 条)...", file=sys.stderr)
        # 对泛域名排序，优先处理短的域名（如.com比.example.com先处理）
        wildcard_rules.sort(key=lambda x: (len(x[0].split('.')), x[0]))
        
        # 处理泛域名规则
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
        
        print(f"[3/4] 处理精确域名规则 ({len(exact_rules)} 条)...", file=sys.stderr)
        # 处理精确域名规则
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
        
        print(f"[4/4] 生成最终规则...", file=sys.stderr)
        # 输出所有保留的规则
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