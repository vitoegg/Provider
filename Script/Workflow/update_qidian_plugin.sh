#!/bin/bash

# 设置工作目录为仓库根目录
cd ${GITHUB_WORKSPACE}

# 安装必要的Python依赖
pip install requests

# 执行Python脚本获取插件
echo "执行Python脚本获取起点广告拦截插件..."
python ${GITHUB_WORKSPACE}/Script/Workflow/fetch_qidian_plugin.py

# 检查脚本执行结果
if [ $? -ne 0 ]; then
  echo "Python脚本执行失败，无法获取插件内容"
  exit 1
fi

# 在新版GitHub Actions中，Python脚本已经直接写入GITHUB_OUTPUT文件
# 我们可以使用一个占位变量表示成功，这样工作流可以继续
echo "change_summary=更新起点去广告插件 $(date '+%Y-%m-%d %H:%M:%S')" >> ${GITHUB_OUTPUT}

exit 0 