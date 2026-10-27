#!/system/bin/sh
# =============================================================================
# uninstall.sh —— 卸载模块时安排恢复本模块停用的 stock 应用
#
# 卸载阶段不调用 PackageManager:此阶段命令可能不可用,且模块目录即将删除。
# 若有 stock-disabled.list,生成一个 service.d 一次性脚本,在下一次启动完成后
# 逐个 enable 并记录结果;服务脚本执行后自行删除。
# =============================================================================

MODDIR=${0%/*}
STOCK_PACKAGES_FILE="$MODDIR/stock-packages.list"
DISABLED_FILE="$MODDIR/stock-disabled.list"
RESTORE_LIST="$MODDIR/.stock-restore-packages.tmp"
RESTORE_DIR=/data/adb/service.d
RESTORE_SCRIPT="$RESTORE_DIR/gkui-pack-restore-stock.sh"
RESTORE_SEEN='|'

valid_stock_package() {
  case "$1" in
    ''|*[!A-Za-z0-9_.]*|.*|*..*|*.) return 1 ;;
  esac
  case "$1" in
    [A-Za-z]*.*) return 0 ;;
    *) return 1 ;;
  esac
}

stock_package_listed() {
  [ -r "$STOCK_PACKAGES_FILE" ] || return 1
  grep -Fqx "$1" "$STOCK_PACKAGES_FILE" 2>/dev/null
}

if [ -s "$DISABLED_FILE" ]; then
  if : > "$RESTORE_LIST" 2>/dev/null; then
    while IFS= read -r PKG; do
      [ -n "$PKG" ] || continue
      if ! valid_stock_package "$PKG"; then
        echo "- 忽略无效的 stock 包名记录: $PKG"
        continue
      fi
      if ! stock_package_listed "$PKG"; then
        echo "- 忽略不在 stock-packages.list 中的记录: $PKG"
        continue
      fi
      case "$RESTORE_SEEN" in
        *"|$PKG|"*) continue ;;
      esac
      RESTORE_SEEN="${RESTORE_SEEN}${PKG}|"
      if printf '%s\n' "$PKG" >> "$RESTORE_LIST" 2>/dev/null; then
        :
      else
        echo "!! 无法写入恢复清单,不会安排 stock 恢复脚本。"
        break
      fi
    done < "$DISABLED_FILE"
  else
    echo "!! 无法创建临时恢复清单,不会安排 stock 恢复脚本。"
  fi

  if [ -s "$RESTORE_LIST" ]; then
    if mkdir -p "$RESTORE_DIR" 2>/dev/null; then
      {
        cat <<'RESTORE_HEAD'
#!/system/bin/sh
# GKUI-Pack one-shot stock restoration; generated during module uninstall.
RESTORE_LOG=/data/adb/gkui-pack-restore.log
RESTORE_PM=pm
while [ "$(getprop sys.boot_completed 2>/dev/null)" != "1" ]; do
  sleep 1
 done
while IFS= read -r PKG; do
  [ -n "$PKG" ] || continue
  "$RESTORE_PM" enable "$PKG" >/dev/null 2>&1
  RC=$?
  TIMESTAMP="$(date '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null)"
  [ -n "$TIMESTAMP" ] || TIMESTAMP=unknown
  printf '%s package=%s action=enable rc=%s\n' "$TIMESTAMP" "$PKG" "$RC" >> "$RESTORE_LOG" 2>/dev/null
 done <<'GKUI_RESTORE_PACKAGES'
RESTORE_HEAD
        cat "$RESTORE_LIST"
        cat <<'RESTORE_TAIL'
GKUI_RESTORE_PACKAGES
rm -f "$0"
RESTORE_TAIL
      } > "$RESTORE_SCRIPT" 2>/dev/null
      WRITE_RC=$?
      if [ "$WRITE_RC" -eq 0 ] && chmod 755 "$RESTORE_SCRIPT" 2>/dev/null; then
        echo "- 已安排在下次启动时恢复本模块停用的 stock 应用。"
        echo "  一次性脚本: $RESTORE_SCRIPT"
        echo "  执行结果日志: /data/adb/gkui-pack-restore.log"
      else
        rm -f "$RESTORE_SCRIPT" 2>/dev/null
        echo "!! 无法写入或设置恢复脚本权限;stock 应用可能需要手动恢复。"
      fi
    else
      echo "!! 无法创建 $RESTORE_DIR;stock 应用可能需要手动恢复。"
    fi
  else
    echo "- 没有有效的本模块 stock 恢复记录。"
  fi
else
  echo "- 本模块没有记录曾停用的 stock 应用,无需安排恢复。"
fi

# 清理本模块自己的标记与诊断日志;保留 stock-disabled.list 直到模块目录移除。
rm -f "$MODDIR/.boot_flag" \
      "$MODDIR/disable" \
      "$MODDIR/last_boot.log" \
      "$MODDIR/.preflight.json" \
      "$MODDIR/GKUI-diag.txt" \
      "$MODDIR/stock-toggle.log" \
      "$MODDIR/.stock-disabled.list.tmp" \
      "$RESTORE_LIST" 2>/dev/null

echo "************************************************"
echo " GKUI-Pack 模块已卸载"
echo "************************************************"
echo "- GKUI 应用 APK 已随模块目录移除;你此前通过 adb 安装的用户空间版本不受影响。"
echo "- 仅恢复 stock-disabled.list 中由本模块停用并记录的包;用户自行停用的应用不会被改动。"
echo "- 本模块不会写入 /data/data。"
echo "- 如需重新恢复默认应用设置,请在系统「设置 → 默认应用」中手动切换。"
echo "- systemless 模块卸载后无需手动删除 system/app 中的任何内容。"
