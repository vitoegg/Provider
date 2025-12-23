#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
规则处理脚本
功能: 去重域名规则、优化规则集合
"""

import sys
import time
import os
import re

def is_valid_domain(domain):
    """
    验证域名是否合法
    
    Args:
        domain (str): 要验证的域名
        
    Returns:
        bool: 域名是否合法
    """
    if not domain or len(domain) > 253:
        return False
    
    # 检查是否包含非法字符
    if not re.match(r'^[a-zA-Z0-9.-]+$', domain):
        return False
    
    # 检查是否以点开始或结束（除了泛域名的情况）
    if domain.startswith('.') or domain.endswith('.'):
        return False
    
    # 检查是否有连续的点
    if '..' in domain:
        return False
    
    # 检查每个部分的长度
    parts = domain.split('.')
    for part in parts:
        if not part or len(part) > 63:
            return False
        # 每个部分不能以连字符开始或结束
        if part.startswith('-') or part.endswith('-'):
            return False
    
    return True


def sanitize_rule(line):
    """
    清理和验证规则行
    
    Args:
        line (str): 原始规则行
        
    Returns:
        tuple: (is_valid, cleaned_rule, is_wildcard)
    """
    line = line.strip()
    
    # 跳过空行和注释
    if not line or line.startswith('#'):
        return False, None, False
    
    # 处理泛域名
    if line.startswith('.'):
        domain = line[1:]
        if is_valid_domain(domain):
            return True, line, True
        else:
            return False, None, False
    else:
        # 处理精确域名
        if is_valid_domain(line):
            return True, line, False
        else:
            return False, None, False


def read_and_classify_rules(input_file):
    """
    读取和分类规则
    
    Args:
        input_file (str): 输入文件路径
        
    Returns:
        tuple: (wildcard_rules, exact_rules, stats)
        
    Raises:
        FileNotFoundError: 文件不存在
        PermissionError: 文件权限不足
        UnicodeDecodeError: 文件编码错误
    """
    stats = {
        "total": 0,
        "duplicates": 0,
        "invalid": 0
    }
    
    all_rules = set()
    wildcard_rules = []
    exact_rules = []
    
    print("[1/4] 读取规则文件...", file=sys.stderr)
    
    try:
        with open(input_file, 'r', encoding='utf-8') as f:
            for line_num, line in enumerate(f, 1):
                try:
                    stats["total"] += 1
                    
                    # 清理和验证规则
                    is_valid, cleaned_rule, is_wildcard = sanitize_rule(line)
                    
                    if not is_valid:
                        if line.strip() and not line.strip().startswith('#'):
                            stats["invalid"] += 1
                            print(f"警告: 第{line_num}行无效规则: {line.strip()[:50]}{'...' if len(line.strip()) > 50 else ''}", file=sys.stderr)
                        continue
                    
                    # 基础去重
                    if cleaned_rule in all_rules:
                        stats["duplicates"] += 1
                        continue
                        
                    all_rules.add(cleaned_rule)
                    
                    # 区分泛域名和精确域名规则
                    if is_wildcard:
                        domain = cleaned_rule[1:]  # 去掉前导点
                        wildcard_rules.append((domain, cleaned_rule))
                    else:
                        exact_rules.append(cleaned_rule)
                        
                except Exception as e:
                    print(f"错误: 处理第{line_num}行时发生错误: {str(e)}", file=sys.stderr)
                    continue
    
    except FileNotFoundError:
        raise FileNotFoundError(f"输入文件 '{input_file}' 不存在")
    except PermissionError:
        raise PermissionError(f"无权限读取文件 '{input_file}'")
    except UnicodeDecodeError as e:
        raise UnicodeDecodeError(e.encoding, e.object, e.start, e.end, 
                                f"文件 '{input_file}' 编码错误，请检查文件是否为UTF-8编码")
    except Exception as e:
        raise RuntimeError(f"读取文件 '{input_file}' 时发生未知错误: {str(e)}")
    
    if stats["invalid"] > 0:
        print(f"警告: 发现 {stats['invalid']} 条无效规则，已跳过", file=sys.stderr)
    
    # 检查是否有有效规则
    total_valid = len(wildcard_rules) + len(exact_rules)
    if total_valid == 0:
        print("警告: 没有找到任何有效规则", file=sys.stderr)
    
    return wildcard_rules, exact_rules, stats


def process_wildcard_rules(wildcard_rules):
    """
    处理泛域名规则，去除被覆盖的规则
    
    Args:
        wildcard_rules (list): 泛域名规则列表
        
    Returns:
        tuple: (kept_wildcards, wildcard_domains, covered_count)
    """
    print(f"[2/4] 处理泛域名规则 ({len(wildcard_rules)} 条)...", file=sys.stderr)
    
    # 预先计算所有域名的分割结果，避免重复计算
    wildcard_data = []
    for domain, original in wildcard_rules:
        parts = domain.split('.')
        wildcard_data.append((domain, original, parts, len(parts)))
    
    # 按域名层级和字典序排序，优先处理短域名
    wildcard_data.sort(key=lambda x: (x[3], x[0]))
    
    wildcard_domains = set()
    kept_wildcards = []
    covered_count = 0
    
    for domain, original, domain_parts, part_count in wildcard_data:
        keep = True
        # 检查是否被更短的泛域名覆盖
        for i in range(1, part_count):
            parent = '.'.join(domain_parts[i:])
            if parent in wildcard_domains:
                keep = False
                covered_count += 1
                break
        
        if keep:
            wildcard_domains.add(domain)
            kept_wildcards.append(original)
    
    return kept_wildcards, wildcard_domains, covered_count


def process_exact_rules(exact_rules, wildcard_domains):
    """
    处理精确域名规则，去除被泛域名覆盖的规则
    
    Args:
        exact_rules (list): 精确域名规则列表
        wildcard_domains (set): 泛域名集合
        
    Returns:
        tuple: (kept_exact, covered_count)
    """
    print(f"[3/4] 处理精确域名规则 ({len(exact_rules)} 条)...", file=sys.stderr)
    
    kept_exact = []
    covered_count = 0
    
    for line in exact_rules:
        keep = True
        # 检查是否被泛域名覆盖
        domain_parts = line.split('.')
        part_count = len(domain_parts)
        
        # 从1开始，避免检查自身
        for i in range(1, part_count):
            parent = '.'.join(domain_parts[i:])
            if parent in wildcard_domains:
                keep = False
                covered_count += 1
                break
        
        if keep:
            kept_exact.append(line)
    
    return kept_exact, covered_count


def generate_final_output(kept_wildcards, kept_exact):
    """
    生成最终输出
    
    Args:
        kept_wildcards (list): 保留的泛域名规则
        kept_exact (list): 保留的精确域名规则
    """
    print(f"[4/4] 生成最终规则...", file=sys.stderr)
    
    # 合并并排序输出
    all_rules = kept_wildcards + kept_exact
    for rule in sorted(all_rules):
        print(rule)


def print_statistics(stats, wildcard_covered, exact_covered, kept_count, processing_time):
    """
    打印处理统计信息
    
    Args:
        stats (dict): 基础统计信息
        wildcard_covered (int): 被覆盖的泛域名数量
        exact_covered (int): 被覆盖的精确域名数量
        kept_count (int): 保留的规则数量
        processing_time (float): 处理时间
    """
    print(f"处理时间: {processing_time:.2f} 秒", file=sys.stderr)
    print(f"总规则数: {stats['total']}", file=sys.stderr)
    print(f"重复规则: {stats['duplicates']}", file=sys.stderr)
    if 'invalid' in stats:
        print(f"无效规则: {stats['invalid']}", file=sys.stderr)
    print(f"泛域名被覆盖: {wildcard_covered}", file=sys.stderr)
    print(f"精确域名被覆盖: {exact_covered}", file=sys.stderr)
    print(f"保留规则: {kept_count}", file=sys.stderr)


def main():
    """
    主函数：协调整个处理流程
    """
    # 检查命令行参数
    if len(sys.argv) < 2:
        print("用法: {} <输入文件路径>".format(sys.argv[0]), file=sys.stderr)
        print("示例: {} rules.txt".format(sys.argv[0]), file=sys.stderr)
        sys.exit(1)
        
    input_file = sys.argv[1]
    
    # 检查输入文件是否存在
    if not os.path.exists(input_file):
        print(f"错误: 输入文件 '{input_file}' 不存在", file=sys.stderr)
        sys.exit(1)
    
    # 检查文件是否可读
    if not os.access(input_file, os.R_OK):
        print(f"错误: 无权限读取文件 '{input_file}'", file=sys.stderr)
        sys.exit(1)
    
    # 检查文件大小
    try:
        file_size = os.path.getsize(input_file)
        if file_size == 0:
            print(f"警告: 输入文件 '{input_file}' 为空", file=sys.stderr)
        elif file_size > 100 * 1024 * 1024:  # 100MB
            print(f"警告: 输入文件 '{input_file}' 较大 ({file_size / 1024 / 1024:.1f}MB)，处理可能需要较长时间", file=sys.stderr)
    except OSError as e:
        print(f"警告: 无法获取文件大小: {str(e)}", file=sys.stderr)
    
    start_time = time.time()
    
    try:
        # 1. 读取和分类规则
        wildcard_rules, exact_rules, read_stats = read_and_classify_rules(input_file)
        
        # 检查是否有有效规则
        total_valid = len(wildcard_rules) + len(exact_rules)
        if total_valid == 0:
            print("错误: 没有找到任何有效规则，无法继续处理", file=sys.stderr)
            sys.exit(1)
        
        # 2. 处理泛域名规则
        kept_wildcards, wildcard_domains, wildcard_covered = process_wildcard_rules(wildcard_rules)
        
        # 3. 处理精确域名规则
        kept_exact, exact_covered = process_exact_rules(exact_rules, wildcard_domains)
        
        # 4. 生成最终输出
        generate_final_output(kept_wildcards, kept_exact)
        
        # 5. 输出统计信息
        end_time = time.time()
        kept_count = len(kept_wildcards) + len(kept_exact)
        print_statistics(read_stats, wildcard_covered, exact_covered, kept_count, end_time - start_time)
    
    except FileNotFoundError as e:
        print(f"文件错误: {str(e)}", file=sys.stderr)
        sys.exit(1)
    except PermissionError as e:
        print(f"权限错误: {str(e)}", file=sys.stderr)
        sys.exit(1)
    except UnicodeDecodeError as e:
        print(f"编码错误: {str(e)}", file=sys.stderr)
        print("建议: 请确保输入文件使用UTF-8编码", file=sys.stderr)
        sys.exit(1)
    except MemoryError:
        print("内存错误: 文件过大，系统内存不足", file=sys.stderr)
        print("建议: 将大文件分割为小文件后处理", file=sys.stderr)
        sys.exit(1)
    except KeyboardInterrupt:
        print("用户中断了处理过程", file=sys.stderr)
        sys.exit(130)  # 标准的中断退出码
    except Exception as e:
        print(f"未知错误: {str(e)}", file=sys.stderr)
        print("请检查输入文件格式是否正确，或联系开发者报告问题", file=sys.stderr)
        sys.exit(1)

if __name__ == "__main__":
    main() 