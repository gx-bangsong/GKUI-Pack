#!/system/bin/sh
# =============================================================================
# service.sh —— 启动完成后收尾
#
# 启动流程走到这里说明本次开机成功,于是:
#   1) 删除 post-fs-data.sh 留下的 .boot_flag(标记"本轮启动完成")
#      —— 见 post-fs-data.sh:残留的 .boot_flag 才代表启动失败。
#   2) 把本次成功启动的时间戳写入 last_boot.log。
#
# 本脚本不做任何系统改动:不挂载、不禁用、不修改任何自带应用。
# =============================================================================

MODDIR=${0%/*}

rm -f "$MODDIR/.boot_flag"

{
  printf '%s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')"
  printf 'epoch=%s\n' "$(date '+%s')"
  printf 'module=GKUI-Pack coexist 模式启动完成,APK 已由 system/app 提供\n'
} > "$MODDIR/last_boot.log" 2>/dev/null
