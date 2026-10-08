#!/system/bin/sh
# =============================================================================
# uninstall.sh —— 特权变体卸载确认
#
# systemless 模块卸载后,APK 与白名单 XML 随模块目录整体移除;系统分区没有被写入。
# 本脚本不代替用户卸载任何应用,也不修改 ROM 自带应用状态。
# =============================================================================

MODDIR=${0%/*}
rm -f "$MODDIR/.boot_flag" "$MODDIR/disable" "$MODDIR/last_boot.log" \
  "$MODDIR/install.log" "$MODDIR/.preflight.json" 2>/dev/null

echo "************************************************"
echo " GKUI-Pack 特权变体已卸载并完全还原(systemless)"
echo "************************************************"
echo "- 本模块的 APK 与 privapp 白名单 XML 已随模块目录移除;系统分区未写入。"
echo "- 如仍需 GKUI 应用,可刷回同 id 的普通版 GKUI-Pack ZIP。"
echo "- 若你曾手动禁用过 ROM 自带应用,请自行恢复:"
echo ""

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
echo "- 应用数据按包名保留;如果曾卸载 /data 中的旧包以满足 C8,对应数据可能已丢失。"
