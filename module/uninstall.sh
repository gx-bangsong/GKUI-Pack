#!/system/bin/sh
# =============================================================================
# uninstall.sh —— 卸载本模块时的清理与提示
#
# 做两件事:
#   1) 清理本模块自己产生的标记/日志文件;
#   2) 提示用户:如果你**自己**曾对 ROM 自带应用执行过 disable-user,
#      那是你的手动操作,与本模块无关,需要你自己恢复。
#
# 注意:本脚本**不会**替你执行 pm enable / pm uninstall / pm disable,
#       所有与系统应用状态相关的操作都必须由用户显式执行。
# =============================================================================

MODDIR=${0%/*}

# 1) 清理标记与日志
rm -f "$MODDIR/.boot_flag" \
      "$MODDIR/disable" \
      "$MODDIR/last_boot.log" \
      "$MODDIR/.preflight.json" 2>/dev/null

echo "************************************************"
echo " GKUI-Pack 模块已卸载"
echo "************************************************"
echo "- GKUI 应用的 APK 已随模块目录移除;你此前通过 adb 安装的用户空间版本不受影响。"
echo "- 若你曾自行对本 ROM 自带应用执行过禁用,请自行恢复:"
echo ""

# 2) 提示恢复命令(由 build.sh 渲染成本次模块实际涉及的 stock 包名)
STOCK_PACKAGES="
__STOCK_PACKAGES__
"
while IFS= read -r PKG; do
  [ -n "$PKG" ] || continue
  echo "      pm enable $PKG"
done <<EOF
$STOCK_PACKAGES
EOF

echo ""
echo "- 如需重新恢复默认应用设置,请在系统「设置 → 默认应用」中手动切换。"
echo "- 提醒:本模块是 systemless 的,卸载后无需再手动删除 system/app 中的任何内容。"
