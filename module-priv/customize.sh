#!/system/bin/sh
# =============================================================================
# customize.sh —— GKUI-Pack 特权变体安装脚本(coexist / systemless)
#
# 构建时将 __APP_ENTRIES__ 渲染为一行一个条目:
#   <application_id>|<目录名>|<APK sha256>|app 或 priv
# 白名单 XML 是与本 ZIP 一起构建的静态文件,不在设备上临时生成。
# =============================================================================

has_func() { type "$1" >/dev/null 2>&1 || command -v "$1" >/dev/null 2>&1; }
if ! has_func ui_print; then ui_print() { echo "$1"; }; fi
if ! has_func abort; then abort() { ui_print "$1"; exit 1; }; fi
if ! has_func set_perm; then
  set_perm() { chown "$2:$3" "$1" 2>/dev/null; chmod "$4" "$1" 2>/dev/null; }
fi
if ! has_func set_perm_recursive; then
  set_perm_recursive() {
    chown -R "$2:$3" "$1" 2>/dev/null
    find "$1" -type d -exec chmod "$4" {} + 2>/dev/null
    find "$1" -type f -exec chmod "$5" {} + 2>/dev/null
  }
fi

ui_print "************************************************"
ui_print "⚠ GKUI-Pack 特权变体:白名单配置错误可能导致无法开机"
ui_print "恢复:禁用/删除 /data/adb/modules/gkui-pack,或刷回普通版 ZIP"
ui_print "************************************************"

ui_print "- 环境探测:"
ui_print "    MAGISK_VER_CODE = ${MAGISK_VER_CODE:-<未设置>}"
ui_print "    MAGISK_VER      = ${MAGISK_VER:-<未设置>}"
ui_print "    KSU             = ${KSU:-<未设置>}"
ui_print "    KSU_VER         = ${KSU_VER:-<未设置>}"
ui_print "    APATCH          = ${APATCH:-<未设置>}"
ui_print "    APATCH_VER      = ${APATCH_VER:-<未设置>}"
ui_print "    BOOTMODE        = ${BOOTMODE:-<未设置>}"
ui_print "    MODPATH         = ${MODPATH:-<未设置>}"

if [ -z "${MODPATH:-}" ] || [ ! -d "$MODPATH" ]; then
  abort "!! MODPATH 缺失或目录不存在:当前不是受支持的模块安装环境,拒绝继续。"
fi

APP_ENTRIES="
__APP_ENTRIES__
"
PRIVAPP_XML_NAME="__PRIVAPP_XML_NAME__"

if [ -z "$(printf '%s' "$APP_ENTRIES" | tr -d ' \n')" ]; then
  abort "拒绝安装:模块内没有应用清单,请使用 build.sh 生成的 ZIP。"
fi

BAD_ENTRY=""
PRIV_ENTRY_COUNT=0
while IFS='|' read -r PKG DIR APK_SHA LOCATION; do
  [ -n "$PKG" ] || continue
  case "$PKG" in *.*) : ;; *) BAD_ENTRY="$PKG" ;; esac
  case "$DIR" in ''|*[!A-Za-z0-9_]*) BAD_ENTRY="$PKG" ;; esac
  [ "$LOCATION" = "app" ] || [ "$LOCATION" = "priv" ] || BAD_ENTRY="$PKG"
  if [ "${#APK_SHA}" -ne 64 ]; then
    BAD_ENTRY="$PKG"
  else
    case "$APK_SHA" in *[!0-9a-f]*) BAD_ENTRY="$PKG" ;; esac
  fi
  [ "$LOCATION" = "priv" ] && PRIV_ENTRY_COUNT=$((PRIV_ENTRY_COUNT + 1))
done <<EOF
$APP_ENTRIES
EOF
[ -z "$BAD_ENTRY" ] || abort "拒绝安装:模块清单条目格式非法 '$BAD_ENTRY'"
[ "$PRIV_ENTRY_COUNT" -gt 0 ] || abort "拒绝安装:priv 变体清单没有特权应用"
case "$PRIVAPP_XML_NAME" in
  privapp-permissions-*.xml) : ;;
  *) abort "拒绝安装:白名单 XML 文件名未渲染或非法" ;;
esac

# 记录安装环境属性,作为本地诊断材料。
GETPROP_BIN="$(command -v getprop 2>/dev/null || true)"
get_prop() {
  if [ -n "$GETPROP_BIN" ]; then "$GETPROP_BIN" "$1" 2>/dev/null; else printf ''; fi
}
BUILD_SDK="$(get_prop ro.build.version.sdk)"
BUILD_RELEASE="$(get_prop ro.build.version.release)"
BUILD_TYPE="$(get_prop ro.build.type)"
PRIVAPP_POLICY="$(get_prop ro.control_privapp_permissions)"
BUILD_SDK="${BUILD_SDK:-<未知>}"
BUILD_RELEASE="${BUILD_RELEASE:-<未知>}"
BUILD_TYPE="${BUILD_TYPE:-<未知>}"
PRIVAPP_POLICY="${PRIVAPP_POLICY:-<未知>}"
INSTALL_LOG="$MODPATH/install.log"
{
  printf 'sdk=%s release=%s build_type=%s ro.control_privapp_permissions=%s\n' \
    "$BUILD_SDK" "$BUILD_RELEASE" "$BUILD_TYPE" "$PRIVAPP_POLICY"
} >> "$INSTALL_LOG" 2>/dev/null
ui_print "- 设备属性: sdk=$BUILD_SDK release=$BUILD_RELEASE type=$BUILD_TYPE ro.control_privapp_permissions=$PRIVAPP_POLICY"

PM_BIN=""
for CAND in pm /system/bin/pm; do
  if command -v "$CAND" >/dev/null 2>&1; then PM_BIN="$CAND"; break; fi
done
[ -n "$PM_BIN" ] || abort "!! 当前环境没有可用的 pm;特权版拒绝在 recovery/不完整环境中安装。"
PM_PACKAGE_LIST="$("$PM_BIN" list packages 2>/dev/null)" || abort "!! pm list packages 失败,无法完成 C8 冲突检查。"
[ -n "$PM_PACKAGE_LIST" ] || abort "!! pm list packages 未返回任何条目,无法完成 C8 冲突检查。"

XML_PATH="$MODPATH/system/etc/permissions/$PRIVAPP_XML_NAME"
[ -s "$XML_PATH" ] || abort "!! 模块内缺少白名单 XML: $XML_PATH"
XML_PAIRS="$(awk '
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
XML_PERMISSION_COUNT="$(printf '%s\n' "$XML_PAIRS" | grep -c . || true)"
[ "$XML_PERMISSION_COUNT" -gt 0 ] || abort "!! 白名单 XML 没有任何 permission 条目,拒绝安装。"

# 安装期真机复核(fail-closed):优先使用文档要求的 -f;某些 ROM 输出不含
# protectionLevel 时,再尝试仍以 -f 在前的组合 -fg。不能解析就拒绝部署。
PM_PERMISSION_STATUS=0
PM_PERMISSION_DUMP="$("$PM_BIN" list permissions -f 2>/dev/null)" || PM_PERMISSION_STATUS=$?
if [ "$PM_PERMISSION_STATUS" -ne 0 ] \
   || ! printf '%s\n' "$PM_PERMISSION_DUMP" | grep -qi 'protectionLevel'; then
  PM_PERMISSION_STATUS=0
  PM_PERMISSION_DUMP="$("$PM_BIN" list permissions -fg 2>/dev/null)" || PM_PERMISSION_STATUS=$?
fi
if [ "$PM_PERMISSION_STATUS" -ne 0 ]; then
  abort "!! pm list permissions -f/-fg 调用失败(exit=$PM_PERMISSION_STATUS),无法复核白名单。"
fi
if ! printf '%s\n' "$PM_PERMISSION_DUMP" | grep -qi 'protectionLevel'; then
  abort "!! pm list permissions -f/-fg 均未输出 protectionLevel,无法复核白名单。"
fi

permission_level() {
  wanted="$1"
  printf '%s\n' "$PM_PERMISSION_DUMP" | awk -v wanted="$wanted" '
    function finish_record() {
      if (active != wanted) return
      if (record_level == "") {
        missing=1
      } else {
        seen[record_level]=1
      }
    }
    {
      line=$0
      current=""
      has_start=0
      if (match(line, /permission[[:space:]]*[:=]/)) {
        has_start=1
        rest=substr(line, RSTART + RLENGTH)
        sub(/^[[:space:]]*/, "", rest)
        sub(/[^A-Za-z0-9_.].*$/, "", rest)
        if (rest ~ /^[A-Za-z]/) current=rest
      } else if (match(line, /Permission[[:space:]]+\[/)) {
        has_start=1
        rest=substr(line, RSTART + RLENGTH)
        sub(/\].*$/, "", rest)
        if (rest ~ /^[A-Za-z][A-Za-z0-9_.]+$/) current=rest
      }
      if (has_start) {
        finish_record()
        active=current
        record_level=""
      }
      if (active == wanted && tolower(line) ~ /protectionlevel[[:space:]]*[:=]/) {
        level=line
        sub(/^.*[Pp]rotectionLevel[[:space:]]*[:=][[:space:]]*/, "", level)
        gsub(/[[:space:]]/, "", level)
        sub(/[,;].*$/, "", level)
        level=tolower(level)
        if (level == "") {
          invalid=1
        } else if (record_level != "" && record_level != level) {
          invalid=1
        } else {
          record_level=level
        }
      }
    }
    END {
      finish_record()
      count=0
      for (level in seen) {
        count++
        result=level
      }
      if (missing || invalid || count != 1) exit 1
      print result
    }
  '
}

ui_print "- 白名单真机复核:"
while IFS='|' read -r XML_PKG XML_PERMISSION; do
  [ -n "$XML_PERMISSION" ] || continue
  LEVEL_STATUS=0
  LEVEL="$(permission_level "$XML_PERMISSION")" || LEVEL_STATUS=$?
  if [ "$LEVEL_STATUS" -ne 0 ] || [ -z "$LEVEL" ]; then
    ui_print "    [失败] $XML_PERMISSION:设备转储中权限级别缺失或不唯一/不明确"
    abort "安装中止:白名单权限无法唯一复核(fail-closed)"
  fi
  case "|$LEVEL|" in
    *"|privileged|"*)
      ui_print "    [ok] $XML_PKG: $XML_PERMISSION [$LEVEL]" ;;
    *)
      ui_print "    [失败] $XML_PKG: $XML_PERMISSION [$LEVEL] 不含 privileged"
      abort "安装中止:白名单与当前设备权限定义不匹配(fail-closed)" ;;
  esac
done <<EOF
$XML_PAIRS
EOF

# C8:同包名 /data 副本必须人工卸载;本模块绝不代为卸载。
ui_print "- 检查 /data 用户空间冲突(C8):"
CONFLICTS=""
SKIP_LIST="|"
PRIV_APP_SEGMENT="priv"
PRIV_APP_SEGMENT="${PRIV_APP_SEGMENT}-app"
while IFS='|' read -r PKG DIR APK_SHA LOCATION; do
  [ -n "$PKG" ] || continue
  PACKAGE_LISTED=0
  while IFS= read -r PACKAGE_LINE; do
    [ "$PACKAGE_LINE" = "package:$PKG" ] && PACKAGE_LISTED=1
  done <<EOF
$PM_PACKAGE_LIST
EOF
  if [ "$PACKAGE_LISTED" -eq 0 ]; then
    ui_print "    [ok] $PKG 未安装"
    continue
  fi
  PATHS="$("$PM_BIN" path "$PKG" 2>/dev/null)" || abort "安装中止:pm path $PKG 失败,无法检查 /data 冲突(C8)"
  [ -n "$PATHS" ] || abort "安装中止:pm list packages 含 $PKG 但 pm path 无结果,无法检查 /data 冲突(C8)"
  HIT_DATA=""
  HIT_SYSTEM=""
  BAD_PATH=""
  while IFS= read -r P; do
    [ -n "$P" ] || continue
    case "$P" in package:*) PATH_VALUE="${P#package:}" ;; *) PATH_VALUE="$P" ;; esac
    case "$PATH_VALUE" in
      /data/*|/mnt/expand/*) HIT_DATA="$P" ;;
      /*) HIT_SYSTEM="$P" ;;
      *) BAD_PATH="$P" ;;
    esac
  done <<EOF
$PATHS
EOF
  [ -z "$BAD_PATH" ] || abort "安装中止:pm path $PKG 返回无法识别的路径 '$BAD_PATH',C8 检查不完整"
  if [ -n "$HIT_DATA" ]; then
    ui_print "    [冲突] $PKG 已安装于用户空间: $HIT_DATA"
    CONFLICTS="${CONFLICTS}${PKG}|"
    continue
  fi
  if [ -n "$HIT_SYSTEM" ]; then
    case "$LOCATION:$HIT_SYSTEM" in
      app:*"/system/app/$DIR/"*)
        ui_print "    [跳过] $PKG 已由目标系统路径提供($HIT_SYSTEM)"
        SKIP_LIST="$SKIP_LIST$PKG|"
        ;;
      priv:*"/system/$PRIV_APP_SEGMENT/$DIR/"*)
        ui_print "    [跳过] $PKG 已由目标系统路径提供($HIT_SYSTEM)"
        SKIP_LIST="$SKIP_LIST$PKG|"
        ;;
      app:*"/system/$PRIV_APP_SEGMENT/$DIR/"*)
        ui_print "    [切换] $PKG 当前在旧特权落点,将迁移到普通 app 路径" ;;
      priv:*"/system/app/$DIR/"*)
        ui_print "    [切换] $PKG 当前在普通 app 落点,将迁移到特权路径" ;;
      *)
        ui_print "    [跳过] $PKG 已由其它系统路径提供($HIT_SYSTEM)"
        SKIP_LIST="$SKIP_LIST$PKG|"
        ;;
    esac
  else
    ui_print "    [ok] $PKG 不在 /data 中(路径: $PATHS)"
  fi
done <<EOF
$APP_ENTRIES
EOF

if [ -n "$CONFLICTS" ]; then
  ui_print ""
  ui_print "检测到以下 /data 副本。请先自行执行对应命令,重启后再刷模块:"
  OLD_IFS="$IFS"
  IFS='|'
  for PKG in $CONFLICTS; do
    [ -n "$PKG" ] && ui_print "    adb uninstall $PKG"
  done
  IFS="$OLD_IFS"
  ui_print "本模块不会代为卸载;录音机设置等应用数据可能丢失。"
  abort "安装中止:/data 中存在同包名应用(C8)"
fi

# ZIP 已采用静态 system/ 布局;安装器只校验哈希,不从临时目录复制 APK。
ui_print "- 静态 APK 完整性预检:"
while IFS='|' read -r PKG DIR APK_SHA LOCATION; do
  [ -n "$PKG" ] || continue
  case "$LOCATION" in
    app) DEST_BASE="$MODPATH/system/app"; OUT_BASE="/system/app" ;;
    priv) DEST_BASE="$MODPATH/system/$PRIV_APP_SEGMENT"; OUT_BASE="/system/$PRIV_APP_SEGMENT" ;;
    *) abort "!! 非法落点: $LOCATION" ;;
  esac
  SRC="$DEST_BASE/$DIR/$DIR.apk"
  [ -f "$SRC" ] || abort "!! ZIP 中缺少静态 APK: $SRC"
  if command -v sha256sum >/dev/null 2>&1; then
    ACTUAL="$(sha256sum "$SRC" | awk '{print $1}')"
    [ "$ACTUAL" = "$APK_SHA" ] || abort "安装中止:$DIR.apk sha256 不匹配"
  else
    ui_print "    [警告] 缺少 sha256sum,跳过 $DIR.apk 哈希复核"
  fi
done <<EOF
$APP_ENTRIES
EOF

# 同模块 id 切换变体:清除另一落点的旧副本;ROM 已提供同包名时移除 ZIP 副本。
while IFS='|' read -r PKG DIR APK_SHA LOCATION; do
  [ -n "$PKG" ] || continue
  case "$LOCATION" in
    app)
      rm -rf "$MODPATH/system/$PRIV_APP_SEGMENT/$DIR" 2>/dev/null
      TARGET_BASE="$MODPATH/system/app"
      ;;
    priv)
      rm -rf "$MODPATH/system/app/$DIR" 2>/dev/null
      TARGET_BASE="$MODPATH/system/$PRIV_APP_SEGMENT"
      ;;
    *) abort "!! 非法落点: $LOCATION" ;;
  esac
  case "$SKIP_LIST" in
    *"|$PKG|"*) rm -rf "$TARGET_BASE/$DIR" 2>/dev/null ;;
  esac
done <<EOF
$APP_ENTRIES
EOF

mkdir -p "$MODPATH/system/etc/permissions" || abort "!! 无法创建权限 XML 目录"
chmod 0755 "$MODPATH/system" "$MODPATH/system/etc" "$MODPATH/system/etc/permissions" 2>/dev/null
chmod 0644 "$XML_PATH" 2>/dev/null

ui_print "- 准备特权版静态挂载:"
INSTALLED_COUNT=0
while IFS='|' read -r PKG DIR APK_SHA LOCATION; do
  [ -n "$PKG" ] || continue
  DEST_BASE="$MODPATH/system/app"
  OUT_BASE="/system/app"
  if [ "$LOCATION" = "priv" ]; then
    DEST_BASE="$MODPATH/system/$PRIV_APP_SEGMENT"
    OUT_BASE="/system/$PRIV_APP_SEGMENT"
  fi
  DEST_DIR="$DEST_BASE/$DIR"
  DEST="$DEST_DIR/$DIR.apk"
  case "$SKIP_LIST" in
    *"|$PKG|"*)
      ui_print "    [跳过] $PKG:系统分区已有同包名应用,已移除 ZIP 副本"
      continue
      ;;
  esac
  [ -f "$DEST" ] || abort "!! 静态 APK 意外缺失: $DEST"
  set_perm_recursive "$DEST_DIR" 0 0 0755 0644
  INSTALLED_COUNT=$((INSTALLED_COUNT + 1))
  ui_print "    [完成] $PKG → $OUT_BASE/$DIR/$DIR.apk (ZIP 静态布局)"
done <<EOF
$APP_ENTRIES
EOF

[ "$INSTALLED_COUNT" -gt 0 ] || abort "安装中止:没有需要部署的应用"

ui_print "- 安装摘要:"
TOTAL_BYTES=0
while IFS='|' read -r PKG DIR APK_SHA LOCATION; do
  [ -n "$PKG" ] || continue
  if [ "$LOCATION" = "priv" ]; then
    DEST="$MODPATH/system/$PRIV_APP_SEGMENT/$DIR/$DIR.apk"
    OUT_BASE="/system/$PRIV_APP_SEGMENT"
  else
    DEST="$MODPATH/system/app/$DIR/$DIR.apk"
    OUT_BASE="/system/app"
  fi
  if [ -f "$DEST" ]; then
    SIZE="$(wc -c < "$DEST" | tr -d ' ')"
    TOTAL_BYTES=$((TOTAL_BYTES + SIZE))
    ui_print "    $OUT_BASE/$DIR/$DIR.apk  $SIZE 字节  ($PKG)"
  else
    ui_print "    (未挂载) $PKG —— 系统路径已有同包名应用"
  fi
done <<EOF
$APP_ENTRIES
EOF
ui_print "    本次部署: $INSTALLED_COUNT 项,$TOTAL_BYTES 字节;privapp 白名单 $XML_PERMISSION_COUNT 条"
ui_print "    sdk=$BUILD_SDK release=$BUILD_RELEASE type=$BUILD_TYPE ro.control_privapp_permissions=$PRIVAPP_POLICY"
ui_print "- 安装日志: $INSTALL_LOG"
ui_print "- 风险提示:特权白名单仅适用于采集转储对应的设备;若 ROM/SDK 不同,请重新构建并复核。"
ui_print "- 恢复:禁用/删除 /data/adb/modules/gkui-pack,或刷回普通版 ZIP。"
