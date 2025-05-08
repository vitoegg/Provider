#!/bin/bash
set -eo pipefail

process_rule() {
  local rule_name="$1"
  local output_path="$2"
  local urls="$3"
  
  local output_dir=$(dirname "$output_path")
  mkdir -p "$output_dir"
  
  # 创建临时日志文件
  local log_file="$output_path.tmp.log"
  touch "$log_file"
  
  echo "┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" | tee -a "$log_file"
  echo "┃ 🔄 规则集处理: $rule_name" | tee -a "$log_file"
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
    
    (curl -sL --fail --connect-timeout 10 --max-time 30 "$url" > "$tmp_file" && 
     echo "┃   ✅ 下载成功: $url" || 
     echo "┃   ❌ 下载失败: $url") &
    
    download_pids+=($!)
    download_count=$((download_count + 1))
  done
  
  for pid in "${download_pids[@]}"; do
    wait $pid
  done
  
  echo "┃ 🔄 正在合并和清理规则数据..." | tee -a "$log_file"
  
  cat "${tmp_dir}"/download_* > "$merged_file"
  
  sed -e 's/[[:space:]]*[#;\/\/].*$//' \
      -e 's/^[[:space:]]*//;s/[[:space:]]*$//' \
      -e '/^$/d' \
      -e '/^[[:space:]]*[#;\/\/]/d' \
      -e '/^payload:/d' \
      -e '/^[[:space:]]*\/\*/d;/\*\//d' \
      "$merged_file" > "$cleaned_file"
  
  local cleaned_count=$(wc -l < "$cleaned_file")
  echo "┃ 📊 清理后的规则条数: $cleaned_count" | tee -a "$log_file"
  
  if [[ -s "$cleaned_file" ]]; then
    echo "┃ 🧹 正在对规则进行清洗..." | tee -a "$log_file"
    
    local final_file=$(mktemp)
    
    echo "┃   ▶️ 使用Python脚本进行规则清洗..." | tee -a "$log_file"
    
    script_path="${GITHUB_WORKSPACE}/Script/Workflow/process_rules.py"
    chmod +x "$script_path"
    
    local stats_file=$(mktemp)
    
    python3 "$script_path" "$cleaned_file" > "$final_file" 2> "$stats_file"
    python_exit=$?
    
    if [ $python_exit -ne 0 ]; then
      echo "┃   ⚠️ Python脚本执行失败，使用基础清洗方法" | tee -a "$log_file"
      echo "┃   🔴 错误信息: $(cat "$stats_file")" | tee -a "$log_file"
      sort -u "$cleaned_file" > "$final_file"
    else
      echo "┃   📋 处理统计:" | tee -a "$log_file"
      while IFS= read -r line; do
        echo "┃     $line" | tee -a "$log_file"
      done < "$stats_file"
      echo "┃   ✅ 规则清洗完成" | tee -a "$log_file"
    fi
    
    rm -f "$stats_file"
    
    local final_count=$(wc -l < "$final_file")
    local removed_count=$((cleaned_count - final_count))
    echo "┃ 📊 去重后的规则条数: $final_count (减少了 $removed_count 条重复规则)" | tee -a "$log_file"
    
    echo "┃ 📝 正在生成最终规则文件..." | tee -a "$log_file"
    
    local meta_file=$(mktemp)
    
    {
      echo "# 规则来源:"
      for url in $urls; do
        repo_url=$(echo "$url" | sed -E 's|raw.githubusercontent.com/([^/]+/[^/]+).*|github.com/\1|')
        echo "# - https://$repo_url"
      done
      echo ""
      cat "$final_file"
    } > "$meta_file"
    
    local changed=0
    local new_rules_count=$(grep -v "^#" "$meta_file" | wc -l)
    local old_rules_count=0
    local added_rules=0
    local removed_rules=0
    
    echo "┃ 📊 最新规则文件包含 $new_rules_count 条规则" | tee -a "$log_file"
    
    if [ -f "$output_path" ]; then
      local old_file=$(mktemp)
      grep -v "^# Update time:" "$output_path" > "$old_file"
      
      old_rules_count=$(grep -v "^#" "$old_file" | wc -l)
      echo "┃ 📊 仓库中已有规则文件包含 $old_rules_count 条规则" | tee -a "$log_file"
      
      # 比较实际规则内容而不是整个文件
      local old_rules_content=$(mktemp)
      local new_rules_content=$(mktemp)
      
      # 提取并排序规则内容进行比较
      grep -v "^#" "$old_file" | sort > "$old_rules_content"
      grep -v "^#" "$meta_file" | sort > "$new_rules_content"
      
      if ! cmp -s "$old_rules_content" "$new_rules_content"; then
        changed=1
        
        # 创建临时文件存储规则 (不含注释)
        local old_rules="$old_rules_content"
        local new_rules="$new_rules_content"
        
        # 计算新增的规则
        local added_rules_file=$(mktemp)
        comm -23 "$new_rules" "$old_rules" > "$added_rules_file"
        added_rules=$(wc -l < "$added_rules_file")
        
        # 计算删除的规则
        local removed_rules_file=$(mktemp)
        comm -13 "$new_rules" "$old_rules" > "$removed_rules_file"
        removed_rules=$(wc -l < "$removed_rules_file")
        
        echo "┃ 📋 规则变化详情:" | tee -a "$log_file"
        echo "┃   ➕ 新增规则: $added_rules 条" | tee -a "$log_file"
        echo "┃   ➖ 移除规则: $removed_rules 条" | tee -a "$log_file"
        
        # 在日志中显示变化的规则（最多显示20条）
        if [ $added_rules -gt 0 ]; then
          if [ $added_rules -gt 20 ]; then
            echo "┃ 📋 新增规则预览(前20条):" | tee -a "$log_file"
            while IFS= read -r line; do
              echo "┃   + $line" | tee -a "$log_file"
            done < <(head -n 20 "$added_rules_file")
            echo "┃   ... 以及其他 $((added_rules - 20)) 条规则" | tee -a "$log_file"
          else
            echo "┃ 📋 新增规则列表:" | tee -a "$log_file"
            while IFS= read -r line; do
              echo "┃   + $line" | tee -a "$log_file"
            done < "$added_rules_file"
          fi
        fi
        
        if [ $removed_rules -gt 0 ]; then
          if [ $removed_rules -gt 20 ]; then
            echo "┃ 📋 移除规则预览(前20条):" | tee -a "$log_file"
            while IFS= read -r line; do
              echo "┃   - $line" | tee -a "$log_file"
            done < <(head -n 20 "$removed_rules_file")
            echo "┃   ... 以及其他 $((removed_rules - 20)) 条规则" | tee -a "$log_file"
          else
            echo "┃ 📋 移除规则列表:" | tee -a "$log_file"
            while IFS= read -r line; do
              echo "┃   - $line" | tee -a "$log_file"
            done < "$removed_rules_file"
          fi
        fi
        
        # 清理临时文件
        rm -f "$old_rules_content" "$new_rules_content" "$added_rules_file" "$removed_rules_file"
      else
        echo "┃ 🔄 规则对比: 内容完全相同，无需更新 ❌" | tee -a "$log_file"
        # 清理临时文件
        rm -f "$old_rules_content" "$new_rules_content"
      fi
      rm -f "$old_file"
    else
      changed=1
      added_rules=$new_rules_count
      echo "┃ 📝 新建规则文件，共添加 $added_rules 条规则 ✅" | tee -a "$log_file"
    fi
    
    # 总结规则状态
    echo "┃ 📊 规则更新摘要:" | tee -a "$log_file"
    echo "┃   📄 文件: $(basename "$output_path")" | tee -a "$log_file"
    echo "┃   🔢 最新规则条数: $new_rules_count" | tee -a "$log_file"
    echo "┃   🔢 原有规则条数: $old_rules_count" | tee -a "$log_file"
    echo "┃   ➕ 新增规则条数: $added_rules" | tee -a "$log_file"
    echo "┃   ➖ 移除规则条数: $removed_rules" | tee -a "$log_file"
    echo "┃   🔄 是否有变更: $([ $changed -eq 1 ] && echo '✅ 是' || echo '❌ 否')" | tee -a "$log_file"
    
    if [ $changed -eq 1 ]; then
      {
        echo "# 更新时间: $(date '+%Y-%m-%d %H:%M:%S')"
        cat "$meta_file"
      } > "$output_path"
      echo "┃ ✅ 规则已成功更新" | tee -a "$log_file"
    else
      echo "┃ ℹ️ 规则无变化，无需更新 ❌" | tee -a "$log_file"
    fi
    
    rm -f "$final_file" "$meta_file"
  else
    echo "┃ ⚠️ 警告: 没有找到有效内容，跳过处理" | tee -a "$log_file"
  fi
  
  rm -f "$merged_file" "$cleaned_file"
  rm -rf "$tmp_dir"
  
  local duration=$((SECONDS - start_time))
  echo "┃ ⏱️ 处理完成，用时: $duration 秒" | tee -a "$log_file"
  echo "┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" | tee -a "$log_file"
}

main() {
  config_file="${GITHUB_WORKSPACE}/Script/Workflow/rules_config.json"
  
  echo "┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "┃ 🚀 规则集更新工具"
  echo "┃ 🕒 开始时间: $(date '+%Y-%m-%d %H:%M:%S')"
  echo "┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  
  # 保存每个规则文件的路径
  declare -a rule_files
  # 保存每个规则文件的变更状态
  declare -A rule_changes
  
  echo "┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "┃ 🔍 规则配置检查"
  echo "┣━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  
  # 检查配置文件是否存在
  if [ ! -f "$config_file" ]; then
    echo "┃ ❌ 配置文件不存在: $config_file"
    echo "┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    exit 1
  fi
  
  # 读取配置文件
  rules_json=$(cat "$config_file")
  
  # 获取规则数量
  rule_count=$(echo "$rules_json" | jq '.rules | length')
  echo "┃ ✅ 从配置文件中找到 $rule_count 个规则集定义"
  
  if [ "$rule_count" -eq 0 ]; then
    echo "┃ ❌ 没有找到规则配置，程序结束"
    echo "┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    return
  fi
  
  # 显示找到的规则配置
  for (( i=0; i<rule_count; i++ )); do
    rule_name=$(echo "$rules_json" | jq -r ".rules[$i].name")
    rule_path=$(echo "$rules_json" | jq -r ".rules[$i].path")
    url_count=$(echo "$rules_json" | jq ".rules[$i].urls | length")
    
    echo "┃ 找到规则集: $rule_name"
    echo "┃ - 保存位置: $rule_path"
    echo "┃ - 下载地址数量: $url_count"
    
    # 将路径添加到文件列表
    rule_files+=("$rule_path")
  done
  
  echo "┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  
  # 处理每个规则
  local start_time=$SECONDS
  
  for (( i=0; i<rule_count; i++ )); do
    rule_name=$(echo "$rules_json" | jq -r ".rules[$i].name")
    rule_path=$(echo "$rules_json" | jq -r ".rules[$i].path")
    
    # 将URL数组转换为空格分隔的字符串
    urls=$(echo "$rules_json" | jq -r ".rules[$i].urls | join(\" \")")
    
    process_rule "$rule_name" "$rule_path" "$urls"
    
    # 记录规则文件的变更状态
    if [ -f "$rule_path" ]; then
      # 读取process_rule函数中的changed变量，通过检查文件内容判断
      if grep -q "是否有变更: 是" "$rule_path.tmp.log" 2>/dev/null || \
         grep -q "规则已成功更新" "$rule_path.tmp.log" 2>/dev/null; then
        rule_changes["$rule_path"]=true
      else
        rule_changes["$rule_path"]=false
      fi
      rm -f "$rule_path.tmp.log" 2>/dev/null || true
    fi
  done
  
  local duration=$((SECONDS - start_time))
  echo "┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "┃ ✅ 所有规则处理完成"
  echo "┃ ⏱️ 总用时: $((duration / 60))分$((duration % 60))秒"
  echo "┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  
  local has_changes=false
  local change_summary=""
  local total_added=0
  local total_removed=0
  
  # 将所有规则文件添加到暂存区以检查变化
  git add "${rule_files[@]}" 2>/dev/null || true
  
  echo "┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "┃ 📋 规则变更总结"
  echo "┣━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  
  for file in "${rule_files[@]}"; do
    if [ -f "$file" ]; then
      local file_changed=${rule_changes["$file"]:-false}
      
      # 获取规则数量（不含注释）
      local new_count_file=$(mktemp)
      awk '!/^#/' "$file" > "$new_count_file"
      local new_count=$(wc -l < "$new_count_file")
      rm -f "$new_count_file"
      
      local basename=$(basename "$file")
      
      echo "┃ 📄 文件: $basename"
      echo "┃   🔢 规则条数: $new_count"
      echo "┃   🔄 是否有变更: $([ "$file_changed" = "true" ] && echo "✅ 是" || echo "❌ 否")"
      
      # 如果有变更，从git diff中获取变更详情
      if [ "$file_changed" = "true" ]; then
        has_changes=true
        
        # 提取规则类型名称 (去掉.list后缀)
        local rule_name=$(basename "$file" .list)
        
        # 初始化变更行数变量
        local added_lines=0
        local removed_lines=0
        
        # 尝试从git diff中获取变更行数
        local diff_file=$(mktemp)
        git diff --cached --no-color "$file" > "$diff_file"
        
        # 过滤掉更新时间的变化
        local filtered_diff=$(mktemp)
        awk '!/^[+-]# Update time:/' "$diff_file" > "$filtered_diff"
        
        # 计算变更行数
        local add_count=$(grep "^+" "$filtered_diff" | grep -v "^+++" | wc -l || echo 0)
        local del_count=$(grep "^-" "$filtered_diff" | grep -v "^---" | wc -l || echo 0)
        
        # 从process_rule函数中获取的实际变更数
        if [ -f "$file.tmp.log" ]; then
            # 尝试从临时日志中获取实际的新增/移除规则数
            local log_added=$(grep -oP "➕ 新增规则: \K[0-9]+" "$file.tmp.log" 2>/dev/null || echo 0)
            local log_removed=$(grep -oP "➖ 移除规则: \K[0-9]+" "$file.tmp.log" 2>/dev/null || echo 0)
            
            # 如果能找到日志中的数据，优先使用
            if [ "$log_added" -gt 0 ] || [ "$log_removed" -gt 0 ]; then
                added_lines=$log_added
                removed_lines=$log_removed
            else
                added_lines=$add_count
                removed_lines=$del_count
            fi
        else
            added_lines=$add_count
            removed_lines=$del_count
        fi
        
        # 更新变更摘要
        change_summary="${change_summary}${rule_name}(+${added_lines}/-${removed_lines}) "
        
        # 更新总计
        total_added=$((total_added + added_lines))
        total_removed=$((total_removed + removed_lines))
        
        rm -f "$filtered_diff" "$diff_file"
      fi
      
      echo "┃   ---------------------------"
    fi
  done
  
  echo "┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  
  echo "┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "┃ 📝 提交结果"
  
  if [ "$has_changes" = true ]; then
    # 移除末尾的空格
    change_summary=$(echo "$change_summary" | sed 's/ $//')
    echo "┃ ✅ 新的提交信息: Update rules: $change_summary"
    
    if [ -n "$GITHUB_OUTPUT" ]; then
      echo "has_changes=true" >> $GITHUB_OUTPUT
      echo "change_summary=${change_summary}" >> $GITHUB_OUTPUT
    fi
  else
    echo "┃ ℹ️ 总结: 所有规则文件均无变化 ❌"
    
    if [ -n "$GITHUB_OUTPUT" ]; then
      echo "has_changes=false" >> $GITHUB_OUTPUT
    fi
    # 如果没有变化，恢复暂存区
    git restore --staged "${rule_files[@]}" 2>/dev/null || true
  fi
  echo "┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

main 