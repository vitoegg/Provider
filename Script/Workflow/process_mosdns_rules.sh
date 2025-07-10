#!/bin/bash
set -eo pipefail

# 从配置文件读取MosDNS规则配置
get_mosdns_config() {
  local config_file="${GITHUB_WORKSPACE}/Script/Workflow/rules_config.json"
  
  if [ ! -f "$config_file" ]; then
    echo "错误: 配置文件 $config_file 不存在" >&2
    exit 1
  fi
  
  # 检查是否安装了jq
  if ! command -v jq &> /dev/null; then
    echo "错误: 需要安装jq来解析JSON配置文件" >&2
    exit 1
  fi
  
  # 提取MosDNS规则配置
  local mosdns_config=$(jq -r '.rules[] | select(.name == "MOSDNS_REJECT")' "$config_file")
  
  if [ -z "$mosdns_config" ] || [ "$mosdns_config" = "null" ]; then
    echo "错误: 在配置文件中未找到MOSDNS_REJECT规则配置" >&2
    exit 1
  fi
  
  echo "$mosdns_config"
}

process_mosdns_rule() {
  local rule_name="$1"
  local output_path="$2"
  local urls="$3"
  
  local output_dir=$(dirname "$output_path")
  mkdir -p "$output_dir"
  
  # 创建临时日志文件
  local log_file="$output_path.tmp.log"
  touch "$log_file"
  
  echo "┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" | tee -a "$log_file"
  echo "┃ 🔄 MosDNS规则集处理: $rule_name" | tee -a "$log_file"
  echo "┃ 📁 保存位置: $output_path" | tee -a "$log_file"
  echo "┣━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" | tee -a "$log_file"
  
  local start_time=$SECONDS
  
  echo "┃ ⬇️ 正在下载规则数据..." | tee -a "$log_file"
  
  local merged_file=$(mktemp)
  local cleaned_file=$(mktemp)
  local tmp_dir=$(mktemp -d)
  
  local download_count=0
  local download_pids=()
  
  for url in $urls; do
    local tmp_file="${tmp_dir}/download_${download_count}"
    local error_flag="${tmp_dir}/error_${download_count}"
    
    (curl -sL --fail --connect-timeout 10 --max-time 30 "$url" > "$tmp_file" && 
     echo "┃   ✅ 下载成功: $url" || 
     { echo "┃   ❌ 下载失败: $url"; touch "$error_flag"; }) &
    
    download_pids+=($!)
    download_count=$((download_count + 1))
  done
  
  for pid in "${download_pids[@]}"; do
    wait $pid || true
  done
  
  # 检查是否有任何错误标记文件
  if ls "${tmp_dir}"/error_* 1> /dev/null 2>&1; then
    echo "┃ ❌ 检测到有上游规则下载失败，本地规则未做任何更改，跳过本次更新" | tee -a "$log_file"
    rm -f "$merged_file" "$cleaned_file"
    rm -rf "$tmp_dir"
    local duration=$((SECONDS - start_time))
    echo "┃ ⏱️ 处理完成，用时: $duration 秒" | tee -a "$log_file"
    echo "┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" | tee -a "$log_file"
    return 0
  fi
  
  echo "┃ 🔄 正在合并规则数据..." | tee -a "$log_file"
  
  cat "${tmp_dir}"/download_* > "$merged_file"
  
  # 基础清理：移除注释和空行
  awk '
    !/^[[:space:]]*[#;!\/\/]/ && 
    !/^[[:space:]]*$/ && 
    !/^payload:/ && 
    !/^[[:space:]]*\/\*/ && 
    !/\*\// { 
      gsub(/[[:space:]]*[#;!\/\/].*$/, "");
      gsub(/^[[:space:]]*/, "");
      gsub(/[[:space:]]*$/, "");
      if (length($0) > 0) print;
    }
  ' "$merged_file" > "$cleaned_file"
  
  # 统计清理后的规则行数
  local cleaned_count=$(wc -l < "$cleaned_file")
  echo "┃ 📊 清理后的规则条数: $cleaned_count" | tee -a "$log_file"
  
  if [[ -s "$cleaned_file" ]]; then
    echo "┃ 🧹 正在对MosDNS规则进行专业清洗..." | tee -a "$log_file"
    
    local final_file=$(mktemp)
    
    echo "┃   ▶️ 使用MosDNS专用Python脚本进行规则处理..." | tee -a "$log_file"
    
    script_path="${GITHUB_WORKSPACE}/Script/Workflow/process_mosdns_rules.py"
    chmod +x "$script_path"
    
    local stats_file=$(mktemp)
    
    python3 "$script_path" "$cleaned_file" > "$final_file" 2> "$stats_file"
    python_exit=$?
    
    if [ $python_exit -ne 0 ]; then
      echo "┃   ⚠️ Python脚本执行失败，使用基础清洗方法" | tee -a "$log_file"
      echo "┃   🔴 错误信息: $(cat "$stats_file")" | tee -a "$log_file"
      sort -u "$cleaned_file" > "$final_file"
    else
      echo "┃   📋 MosDNS规则处理统计:" | tee -a "$log_file"
      while IFS= read -r line; do
        echo "┃     $line" | tee -a "$log_file"
      done < "$stats_file"
      echo "┃   ✅ MosDNS规则处理完成" | tee -a "$log_file"
    fi
    
    rm -f "$stats_file"
    
    # 统计最终有效规则数量
    local final_count=$(wc -l < "$final_file")
    local removed_count=$((cleaned_count - final_count))
    echo "┃ 📊 优化后的规则条数: $final_count (减少了 $removed_count 条)" | tee -a "$log_file"
    
    echo "┃ 📝 正在生成最终MosDNS规则文件..." | tee -a "$log_file"
    
    local meta_file=$(mktemp)
    
    # 生成带有元数据的最终文件
    {
      echo "# Customized Ads Rule for MosDNS"
      echo "# Version: 2.0"
      echo "# Homepage: https://github.com/vitoegg/Provider/tree/master/RuleSet/Extra/MosDNS"
      echo "# Update time: $(TZ='Asia/Shanghai' date '+%Y-%m-%d %H:%M:%S UTC+8')"
      echo "# Converted from AdGuard Home format"
      echo ""
      echo "# 规则来源:"
      for url in $urls; do
        repo_url=$(echo "$url" | sed -E 's|raw.githubusercontent.com/([^/]+/[^/]+).*|github.com/\1|')
        echo "# - https://$repo_url"
      done
      echo ""
      echo "# Note: Allow rules (@@) are not supported in MosDNS reject list"
      echo "# These rules should be added to allow list instead"
      echo ""
      cat "$final_file"
    } > "$meta_file"
    
    local changed=0
    local new_rules_count=$(awk '!/^#/ && !/^[[:space:]]*$/' "$meta_file" | wc -l)
    local old_rules_count=0
    local added_rules=0
    local removed_rules=0
    
    echo "┃ 📊 最新MosDNS规则文件包含 $new_rules_count 条规则" | tee -a "$log_file"
    
    if [ -f "$output_path" ]; then
      local old_file=$(mktemp)
      grep -v "^# Update time:" "$output_path" > "$old_file"
      
      old_rules_count=$(awk '!/^#/ && !/^[[:space:]]*$/' "$old_file" | wc -l)
      echo "┃ 📊 仓库中已有规则文件包含 $old_rules_count 条规则" | tee -a "$log_file"
      
      # 比较实际规则内容
      local old_rules_content=$(mktemp)
      local new_rules_content=$(mktemp)
      
      awk '!/^#/ && !/^[[:space:]]*$/' "$old_file" | sort > "$old_rules_content"
      awk '!/^#/ && !/^[[:space:]]*$/' "$meta_file" | sort > "$new_rules_content"
      
      if ! cmp -s "$old_rules_content" "$new_rules_content"; then
        changed=1
        
        # 计算新增的规则
        local added_rules_file=$(mktemp)
        comm -23 "$new_rules_content" "$old_rules_content" > "$added_rules_file"
        added_rules=$(wc -l < "$added_rules_file")
        
        # 计算删除的规则
        local removed_rules_file=$(mktemp)
        comm -13 "$new_rules_content" "$old_rules_content" > "$removed_rules_file"
        removed_rules=$(wc -l < "$removed_rules_file")
        
        echo "┃ 📋 MosDNS规则变化详情:" | tee -a "$log_file"
        echo "┃   ➕ 新增规则: $added_rules 条" | tee -a "$log_file"
        echo "┃   ➖ 移除规则: $removed_rules 条" | tee -a "$log_file"
        
        # 显示变化的规则（最多显示15条）
        if [ $added_rules -gt 0 ]; then
          if [ $added_rules -gt 15 ]; then
            echo "┃ 📋 新增规则预览(前15条):" | tee -a "$log_file"
            while IFS= read -r line; do
              echo "┃   + $line" | tee -a "$log_file"
            done < <(head -n 15 "$added_rules_file")
            echo "┃   ... 以及其他 $((added_rules - 15)) 条规则" | tee -a "$log_file"
          else
            echo "┃ 📋 新增规则列表:" | tee -a "$log_file"
            while IFS= read -r line; do
              echo "┃   + $line" | tee -a "$log_file"
            done < "$added_rules_file"
          fi
        fi
        
        if [ $removed_rules -gt 0 ]; then
          if [ $removed_rules -gt 15 ]; then
            echo "┃ 📋 移除规则预览(前15条):" | tee -a "$log_file"
            while IFS= read -r line; do
              echo "┃   - $line" | tee -a "$log_file"
            done < <(head -n 15 "$removed_rules_file")
            echo "┃   ... 以及其他 $((removed_rules - 15)) 条规则" | tee -a "$log_file"
          else
            echo "┃ 📋 移除规则列表:" | tee -a "$log_file"
            while IFS= read -r line; do
              echo "┃   - $line" | tee -a "$log_file"
            done < "$removed_rules_file"
          fi
        fi
        
        rm -f "$added_rules_file" "$removed_rules_file"
        rm -f "$old_rules_content" "$new_rules_content"
      else
        echo "┃ ✅ 规则内容无变化，跳过更新" | tee -a "$log_file"
      fi
      
      rm -f "$old_file"
    else
      changed=1
      added_rules=$new_rules_count
      echo "┃ 📝 首次创建MosDNS规则文件" | tee -a "$log_file"
    fi
    
    if [ $changed -eq 1 ]; then
      cp "$meta_file" "$output_path"
      echo "┃ ✅ 规则文件已更新" | tee -a "$log_file"
      
      # 设置输出变量 - 修改提交日志格式
      echo "has_changes=true" >> "$GITHUB_OUTPUT"
      echo "change_summary=reject (+$added_rules -$removed_rules)" >> "$GITHUB_OUTPUT"
    else
      echo "has_changes=false" >> "$GITHUB_OUTPUT"
    fi
    
    rm -f "$meta_file" "$final_file"
  else
    echo "┃ ⚠️ 清理后的规则文件为空，跳过处理" | tee -a "$log_file"
    echo "has_changes=false" >> "$GITHUB_OUTPUT"
  fi
  
  # 清理临时文件
  rm -f "$merged_file" "$cleaned_file"
  rm -rf "$tmp_dir"
  
  local duration=$((SECONDS - start_time))
  echo "┃ ⏱️ 处理完成，用时: $duration 秒" | tee -a "$log_file"
  echo "┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" | tee -a "$log_file"
  
  # 将日志内容追加到主日志
  if [ -f "$log_file" ]; then
    cat "$log_file" >> "${GITHUB_WORKSPACE}/mosdns_rules_update.log"
    rm -f "$log_file"
  fi
}

# 主函数
main() {
  echo "🚀 开始更新MosDNS规则集..."
  
  # 创建主日志文件
  echo "MosDNS规则更新日志 - $(TZ='Asia/Shanghai' date '+%Y-%m-%d %H:%M:%S UTC+8')" > "${GITHUB_WORKSPACE}/mosdns_rules_update.log"
  echo "================================================================" >> "${GITHUB_WORKSPACE}/mosdns_rules_update.log"
  
  # 从配置文件读取MosDNS规则配置
  local mosdns_config=$(get_mosdns_config)
  local rule_name=$(echo "$mosdns_config" | jq -r '.name')
  local output_path="${GITHUB_WORKSPACE}/$(echo "$mosdns_config" | jq -r '.path')"
  local rule_urls=$(echo "$mosdns_config" | jq -r '.urls | join(" ")')
  
  echo "📋 从配置文件读取到的MosDNS规则配置:"
  echo "  规则名称: $rule_name"
  echo "  输出路径: $output_path"
  echo "  规则源数量: $(echo "$mosdns_config" | jq -r '.urls | length')"
  
  # 处理MosDNS规则
  process_mosdns_rule "MosDNS拦截规则" "$output_path" "$rule_urls"
  
  echo "✅ MosDNS规则集更新完成"
  
  # 显示完整日志
  echo ""
  echo "📋 完整处理日志:"
  cat "${GITHUB_WORKSPACE}/mosdns_rules_update.log"
}

# 如果脚本直接运行，则执行主函数
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi 