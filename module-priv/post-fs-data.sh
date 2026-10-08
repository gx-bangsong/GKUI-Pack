#!/system/bin/sh
# =============================================================================
# post-fs-data.sh —— bootloop 自救机制
#
# 原理:每次开机进到 post-fs-data 阶段时——
#   若模块目录中**已存在** .boot_flag,说明上一次开机没有跑到 service.sh
#   (即启动流程中途失败了),此时写入 disable 文件让模块在下一次开机时被
#   管理器自动跳过,从而打破 bootloop;随后退出。
#   若**不存在** .boot_flag,则创建它,表示"本轮启动开始"。
#
# 标记的正常生命周期:.boot_flag 由 post-fs-data.sh 创建 → 由 service.sh 删除。
# =============================================================================

MODDIR=${0%/*}

if [ -f "$MODDIR/.boot_flag" ]; then
  # 上一次启动未完成:本轮先禁用自身,保证能正常开机
  touch "$MODDIR/disable"
  echo "$(date '+%Y-%m-%dT%H:%M:%S%z') 检测到未完成的启动标记,已写入 disable 以解除 bootloop" \
    >> "$MODDIR/last_boot.log" 2>/dev/null
  exit 0
fi

touch "$MODDIR/.boot_flag"
