#!/system/bin/sh
# =============================================================================
# service.sh —— 特权变体启动完成后收尾与白名单权限自检
#
# 只有系统完整进入 service 阶段才会清除 .boot_flag。特权白名单相关启动失败
# 会留下标记,下次 post-fs-data 自动禁用本模块以解除 bootloop。
# =============================================================================

MODDIR=${0%/*}
XML_NAME="__PRIVAPP_XML_NAME__"
XML_PATH="$MODDIR/system/etc/permissions/$XML_NAME"
LOG="$MODDIR/last_boot.log"

rm -f "$MODDIR/.boot_flag"
{
  printf '%s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')"
  printf 'epoch=%s\n' "$(date '+%s')"
  printf 'module=GKUI-Pack privileged variant boot completed\n'
  printf 'ro.build.version.sdk=%s\n' "$(getprop ro.build.version.sdk 2>/dev/null)"
  printf 'ro.build.version.release=%s\n' "$(getprop ro.build.version.release 2>/dev/null)"
  printf 'ro.build.type=%s\n' "$(getprop ro.build.type 2>/dev/null)"
  printf 'ro.control_privapp_permissions=%s\n' "$(getprop ro.control_privapp_permissions 2>/dev/null)"
} > "$LOG" 2>/dev/null

PM_BIN="$(command -v pm 2>/dev/null || true)"
[ -n "$PM_BIN" ] || PM_BIN="/system/bin/pm"
if [ ! -x "$PM_BIN" ] && ! command -v "$PM_BIN" >/dev/null 2>&1; then
  printf 'permission_self_check=pm_unavailable\n' >> "$LOG" 2>/dev/null
  exit 0
fi
if [ ! -s "$XML_PATH" ]; then
  printf 'permission_self_check=xml_missing:%s\n' "$XML_PATH" >> "$LOG" 2>/dev/null
  exit 0
fi

CHECKS="$(awk '
  /<privapp-permissions[[:space:]]/ {
    line=$0
    sub(/^.*package=\"/, "", line)
    sub(/\".*/, "", line)
    package=line
  }
  /<permission[[:space:]]/ {
    line=$0
    sub(/^.*name=\"/, "", line)
    sub(/\".*/, "", line)
    if (package != "" && line != "") print package "|" line
  }
' "$XML_PATH")"

CHECK_COUNT=0
GRANTED_COUNT=0
while IFS='|' read -r PKG PERMISSION; do
  [ -n "$PERMISSION" ] || continue
  CHECK_COUNT=$((CHECK_COUNT + 1))
  RESULT="$("$PM_BIN" check-permission "$PERMISSION" "$PKG" 0 2>/dev/null | tr '[:upper:]' '[:lower:]' | tr -d '\r')"
  case "$RESULT" in
    granted|true|0)
      GRANTED_COUNT=$((GRANTED_COUNT + 1))
      printf 'permission[%s,%s]=granted\n' "$PKG" "$PERMISSION" >> "$LOG" 2>/dev/null
      ;;
    denied|false|1)
      printf 'permission[%s,%s]=denied\n' "$PKG" "$PERMISSION" >> "$LOG" 2>/dev/null
      ;;
    *)
      printf 'permission[%s,%s]=unknown:%s\n' "$PKG" "$PERMISSION" "${RESULT:-empty}" >> "$LOG" 2>/dev/null
      ;;
  esac
done <<EOF
$CHECKS
EOF
printf 'permission_self_check=%s/%s granted\n' "$GRANTED_COUNT" "$CHECK_COUNT" >> "$LOG" 2>/dev/null
