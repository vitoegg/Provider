#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
MosDNS规则处理脚本
功能: 
1. 将AdGuard Home规则转换为MosDNS规则
2. 去掉正则匹配类型的规则
3. 按域名进行合并，相同的合并，包含关系的合并（主域名覆盖子域名）
4. 输出详细的处理日志
"""

import sys
import time
import os
import re
from typing import Set, List, Tuple, Dict

# 编译正则模式以提升性能
REGEX_PATTERN = re.compile(r'[\*\[\]\(\)\\+\?\^\$\|]')

def is_regex_rule(rule: str) -> bool:
    """检查MosDNS规则是否为正则表达式规则"""
    if rule.startswith('domain:') or rule.startswith('full:'):
        domain_part = rule.split(':', 1)[1]
        return bool(REGEX_PATTERN.search(domain_part))
    return False

def convert_adguard_to_mosdns(rule: str) -> Tuple[str, str]:
    """
    将AdGuard Home规则转换为MosDNS规则
    返回: (转换后的规则, 规则类型)
    """
    original_rule = rule.strip()
    
    # 跳过注释和空行
    if not original_rule or original_rule.startswith('#') or original_rule.startswith('!'):
        return "", "comment"
    
    # 跳过允许规则（@@开头）
    if original_rule.startswith('@@'):
        return "", "allow"
    
    # 跳过 keyword: 和 regexp: 类型规则
    if original_rule.startswith('keyword:') or original_rule.startswith('regexp:'):
        return "", "keyword_or_regexp"
    
    # 格式7: 已经是MosDNS格式 (domain:example.com 或 full:example.com)
    if original_rule.startswith('domain:') or original_rule.startswith('full:'):
        return original_rule, "mosdns"
    
    # 处理不同格式的AdGuard规则
    domain = ""
    rule_type = "unknown"
    
    # 格式1: ||example.com^
    if original_rule.startswith('||') and original_rule.endswith('^'):
        domain = original_rule[2:-1]
        rule_type = "domain"
    
    # 格式2: ||example.com^$third-party
    elif original_rule.startswith('||') and '^' in original_rule:
        domain = original_rule[2:original_rule.index('^')]
        rule_type = "domain"
    
    # 格式3: |http://example.com
    elif original_rule.startswith('|http://'):
        domain = original_rule[8:]
        if '/' in domain:
            domain = domain[:domain.index('/')]
        rule_type = "domain"
    
    # 格式4: |https://example.com
    elif original_rule.startswith('|https://'):
        domain = original_rule[9:]
        if '/' in domain:
            domain = domain[:domain.index('/')]
        rule_type = "domain"
    
    # 格式6: .example.com (泛域名)
    elif original_rule.startswith('.'):
        domain = original_rule
        rule_type = "wildcard"
    
    # 格式5: example.com (简单域名格式)
    elif '.' in original_rule and not original_rule.startswith('.'):
        domain = original_rule
        rule_type = "domain"
    
    # 清理域名
    if domain:
        # 移除端口号
        if ':' in domain and not domain.startswith('domain:') and not domain.startswith('full:'):
            domain = domain[:domain.index(':')]
        
        # 移除路径
        if '/' in domain:
            domain = domain[:domain.index('/')]
        
        # 移除查询参数
        if '?' in domain:
            domain = domain[:domain.index('?')]
        
        # 基本验证域名格式（允许一些特殊字符，后续再过滤）
        if not re.match(r'^[a-zA-Z0-9._*+?^$|()\[\]\\-]+$', domain):
            return "", "invalid"
        
        # 转换为MosDNS格式
        if rule_type == "wildcard":
            return f"domain:{domain[1:]}", "converted"
        else:
            return f"domain:{domain}", "converted"
    
    return "", "unknown"

def filter_regex_rules(rules: List[str]) -> Tuple[List[str], int]:
    """
    过滤掉正则表达式规则
    返回: (过滤后的规则列表, 被过滤的数量)
    """
    filtered_rules = []
    regex_count = 0
    
    for rule in rules:
        if is_regex_rule(rule):
            regex_count += 1
        else:
            filtered_rules.append(rule)
    
    return filtered_rules, regex_count

def optimize_domains(rules: List[str]) -> Tuple[List[str], Dict[str, int]]:
    """
    优化域名规则，合并重复和包含关系的域名
    返回: (优化后的规则列表, 统计信息)
    """
    stats = {
        "total": len(rules),
        "duplicates": 0,
        "wildcard_covered": 0,
        "domain_covered_full": 0,
        "kept": 0
    }
    
    # 分离不同类型的规则
    domain_rules = []  # domain:example.com
    full_rules = []    # full:example.com
    other_rules = []   # 其他格式
    
    for rule in rules:
        if rule.startswith('domain:'):
            domain_rules.append(rule[7:])  # 去掉 domain: 前缀
        elif rule.startswith('full:'):
            full_rules.append(rule[5:])  # 去掉 full: 前缀
        else:
            other_rules.append(rule)
    
    # 去重
    original_count = len(domain_rules) + len(full_rules) + len(other_rules)
    domain_rules = list(set(domain_rules))
    full_rules = list(set(full_rules))
    other_rules = list(set(other_rules))
    
    stats["duplicates"] = original_count - len(domain_rules) - len(full_rules) - len(other_rules)
    
    # 优化domain规则 - 按域名长度排序，短的在前
    sorted_domains = sorted(domain_rules, key=lambda x: (len(x.split('.')), x))
    
    # 使用集合进行高效查找
    kept_domains = set()
    for domain in sorted_domains:
        is_covered = False
        domain_parts = domain.split('.')
        
        # 检查是否被已保留的更短域名覆盖
        for i in range(1, len(domain_parts)):
            parent_domain = '.'.join(domain_parts[i:])
            if parent_domain in kept_domains:
                # 确保父域名确实能覆盖当前域名
                if domain.endswith('.' + parent_domain):
                    is_covered = True
                    stats["wildcard_covered"] += 1
                    break
        
        if not is_covered:
            kept_domains.add(domain)
    
    # 处理 full 规则 - 检查是否被 domain 规则覆盖
    kept_full_rules = []
    for full_domain in full_rules:
        is_covered = False
        
        # 检查 full 域名本身是否在 domain 集合中
        if full_domain in kept_domains:
            is_covered = True
            stats["domain_covered_full"] += 1
        else:
            # 检查 full 域名的任何父域名是否在 domain 集合中
            domain_parts = full_domain.split('.')
            for i in range(1, len(domain_parts)):
                parent_domain = '.'.join(domain_parts[i:])
                if parent_domain in kept_domains:
                    is_covered = True
                    stats["domain_covered_full"] += 1
                    break
        
        if not is_covered:
            kept_full_rules.append(f"full:{full_domain}")
    
    # 组装最终规则
    optimized_domains = [f"domain:{d}" for d in kept_domains]
    final_rules = optimized_domains + kept_full_rules + other_rules
    stats["kept"] = len(final_rules)
    
    return sorted(final_rules), stats

def main():
    if len(sys.argv) < 2:
        print("用法: {} <输入文件路径>".format(sys.argv[0]), file=sys.stderr)
        sys.exit(1)
        
    input_file = sys.argv[1]
    
    if not os.path.exists(input_file):
        print("错误: 输入文件 '{}' 不存在".format(input_file), file=sys.stderr)
        sys.exit(1)
    
    start_time = time.time()
    
    # 初始化统计信息
    conversion_stats = {
        "total_lines": 0,
        "comments": 0,
        "allow_rules": 0,
        "keyword_or_regexp_rules": 0,
        "regex_rules": 0,
        "converted": 0,
        "mosdns_format": 0,
        "invalid": 0,
        "unknown": 0
    }
    
    print("[1/4] 读取和转换规则文件...", file=sys.stderr)
    
    converted_rules = []
    
    try:
        with open(input_file, 'r', encoding='utf-8') as f:
            for line in f:
                line = line.strip()
                conversion_stats["total_lines"] += 1
                
                if not line:
                    continue
                
                converted_rule, rule_type = convert_adguard_to_mosdns(line)
                
                # 统计转换结果
                if rule_type == "comment":
                    conversion_stats["comments"] += 1
                elif rule_type == "allow":
                    conversion_stats["allow_rules"] += 1
                elif rule_type == "keyword_or_regexp":
                    conversion_stats["keyword_or_regexp_rules"] += 1
                elif rule_type == "regex":
                    conversion_stats["regex_rules"] += 1
                elif rule_type == "converted":
                    conversion_stats["converted"] += 1
                    converted_rules.append(converted_rule)
                elif rule_type == "mosdns":
                    conversion_stats["mosdns_format"] += 1
                    converted_rules.append(converted_rule)
                elif rule_type == "invalid":
                    conversion_stats["invalid"] += 1
                else:
                    conversion_stats["unknown"] += 1
        
        print(f"[2/4] 过滤正则表达式规则 ({len(converted_rules)} 条)...", file=sys.stderr)
        
        # 过滤掉正则表达式规则
        filtered_rules, regex_count = filter_regex_rules(converted_rules)
        conversion_stats["regex_rules"] = regex_count # 更新统计信息
        
        print(f"[3/4] 优化域名规则 ({len(filtered_rules)} 条)...", file=sys.stderr)
        
        # 优化域名规则
        final_rules, optimization_stats = optimize_domains(filtered_rules)
        
        print(f"[4/4] 生成最终规则 ({len(final_rules)} 条)...", file=sys.stderr)
        
        # 输出最终规则
        for rule in final_rules:
            print(rule)
        
        print("[5/5] 输出统计信息...", file=sys.stderr)
        
        # 输出统计信息
        end_time = time.time()
        print(f"处理时间: {end_time - start_time:.2f} 秒", file=sys.stderr)
        print(f"总行数: {conversion_stats['total_lines']}", file=sys.stderr)
        print(f"注释行: {conversion_stats['comments']}", file=sys.stderr)
        print(f"允许规则: {conversion_stats['allow_rules']}", file=sys.stderr)
        print(f"Keyword/Regexp规则: {conversion_stats['keyword_or_regexp_rules']}", file=sys.stderr)
        print(f"正则规则: {conversion_stats['regex_rules']}", file=sys.stderr)
        print(f"转换规则: {conversion_stats['converted']}", file=sys.stderr)
        print(f"MosDNS格式: {conversion_stats['mosdns_format']}", file=sys.stderr)
        print(f"无效规则: {conversion_stats['invalid']}", file=sys.stderr)
        print(f"未知格式: {conversion_stats['unknown']}", file=sys.stderr)
        print(f"重复规则: {optimization_stats['duplicates']}", file=sys.stderr)
        print(f"被父域名覆盖: {optimization_stats['wildcard_covered']}", file=sys.stderr)
        print(f"被domain规则覆盖的full规则: {optimization_stats['domain_covered_full']}", file=sys.stderr)
        print(f"最终保留: {optimization_stats['kept']}", file=sys.stderr)
        
    except Exception as e:
        print(f"处理出错: {str(e)}", file=sys.stderr)
        sys.exit(1)

if __name__ == "__main__":
    main() 