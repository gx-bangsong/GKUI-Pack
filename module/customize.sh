#!/system/bin/sh
# =============================================================================
# customize.sh —— GKUI-Pack systemless 模块安装脚本(coexist 模式)
#
# 由 Magisk / KernelSU / APatch 的模块安装器在解包后执行。
# 本文件中的 __APP_ENTRIES__ 占位符由仓库根目录的 build.sh 在构建时渲染为:
#
#     <application_id>|<目录名>|<该 APK 的 sha256>|app
#
# 一行一个应用。普通版所有条目的落点均为 /system/app。
# **直接打包本目录(不经过 build.sh)得到的 zip 是无效的**:
# 此时清单为空,脚本会拒绝安装(见下面的清单检查)。
#
# 硬约束落实:
#   C2  只写 system/app,绝不动任何 ROM 自带应用,不产生任何替换语义
#   C3  普通版只装 system/app;切换时清理本模块旧版特权挂载与 XML
#   C8  与 /data 中同包名应用冲突时:**中止整个安装**并让用户自行卸载,
#       模块绝不代为执行 pm uninstall
# =============================================================================

# --- 兼容垫片:Magisk 会先加载 util_functions.sh(提供 ui_print / set_perm* /
#     abort 等);KernelSU / APatch 沿用同一套模块约定。这里**只在确认缺失时**
#     才定义兜底实现,绝不覆盖安装器自带的同名函数。 ---------------------------
has_func() { type "$1" >/dev/null 2>&1 || command -v "$1" >/dev/null 2>&1; }

if ! has_func ui_print; then
  ui_print() { echo "$1"; }
fi
if ! has_func abort; then
  abort() { ui_print "$1"; exit 1; }
fi
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
ui_print " GKUI-Pack —— coexist 模式 systemless 模块"
ui_print " 只挂载 system/app;不替换、不修改、不禁用任何自带应用"
ui_print "************************************************"

# -----------------------------------------------------------------------------
# 1) 环境识别
# -----------------------------------------------------------------------------
ui_print "- 环境探测:"
ui_print "    MAGISK_VER_CODE = ${MAGISK_VER_CODE:-<未设置>}"
ui_print "    MAGISK_VER      = ${MAGISK_VER:-<未设置>}"
ui_print "    KSU             = ${KSU:-<未设置>}"
ui_print "    KSU_VER         = ${KSU_VER:-<未设置>}"
ui_print "    APATCH          = ${APATCH:-<未设置>}"
ui_print "    APATCH_VER      = ${APATCH_VER:-<未设置>}"
ui_print "    BOOTMODE        = ${BOOTMODE:-<未设置>}"
ui_print "    MODPATH         = ${MODPATH:-<未设置>}"

if [ -z "${MODPATH:-}" ]; then
  abort "!! MODPATH 未设置:当前不是受支持的模块安装环境,拒绝继续。"
fi

# -----------------------------------------------------------------------------
# 2) 模块清单(由 build.sh 渲染)
# -----------------------------------------------------------------------------
APP_ENTRIES="
__APP_ENTRIES__
"

if [ -z "$(printf '%s' "$APP_ENTRIES" | tr -d ' \n')" ]; then
  ui_print "!! 模块内没有应用清单:这个 zip 不是在仓库里用 build.sh 构建的。"
  ui_print "!! 请执行  bash build.sh  生成 dist/GKUI-Pack-*.zip 后重新刷入。"
  abort "拒绝安装:未渲染/空的模块清单"
fi

# 清单格式门禁:每行必须是 <application_id>|<目录名>|<64 位 hex 的 sha256>|app。
# 这样可以在安装前就发现"直接打包 module/ 目录"这类未渲染产物。
BAD_ENTRY=""
while IFS='|' read -r PKG DIR APK_SHA LOCATION; do
  [ -n "$PKG" ] || continue
  case "$PKG" in
    *.*) : ;;
    *) BAD_ENTRY="$PKG" ;;
  esac
  [ -n "$DIR" ] || BAD_ENTRY="$PKG"
  [ "$LOCATION" = "app" ] || BAD_ENTRY="$PKG"
  if [ "${#APK_SHA}" -ne 64 ]; then
    BAD_ENTRY="$PKG"
  else
    case "$APK_SHA" in
      *[!0-9a-f]*) BAD_ENTRY="$PKG" ;;
      *) : ;;
    esac
  fi
done <<EOF
$APP_ENTRIES
EOF

if [ -n "$BAD_ENTRY" ]; then
  ui_print "!! 模块清单条目格式非法: '$BAD_ENTRY'"
  ui_print "!! 这通常意味着该 zip 的占位符未被渲染(直接打包 module/ 目录得到的 zip"
  ui_print "!! 是无效的)。请执行  bash build.sh  生成 dist/GKUI-Pack-*.zip 后重新刷入。"
  abort "拒绝安装:模块清单格式非法(未渲染)"
fi

# -----------------------------------------------------------------------------
# 3) 安装环境可用性:必须有可用的 pm(C8 的冲突检查依赖它)
# -----------------------------------------------------------------------------
PM_BIN=""
for cand in pm /system/bin/pm; do
  if command -v "$cand" >/dev/null 2>&1; then
    PM_BIN="$cand"
    break
  fi
done
if [ -z "$PM_BIN" ]; then
  ui_print "!! 当前环境没有可用的 pm(Package Manager)"
  ui_print "!! 这通常意味着你在 recovery 下刷入。本模块必须先确认 /data 中没有"
  ui_print "!! 同包名应用,否则会出现两个同包名应用互相抢夺的情况。"
  ui_print "!! 请在系统已启动时用 Magisk / KernelSU / APatch 管理器安装本模块,"
  ui_print "!! 或改用免 root 的 adb 安装方案(scripts/install_all.sh)。"
  abort "拒绝安装:无法检测 /data 冲突(C8)"
fi
PM_PACKAGE_LIST="$("$PM_BIN" list packages 2>/dev/null)" || abort "拒绝安装:pm list packages 失败,无法完成冲突检查(C8)"
[ -n "$PM_PACKAGE_LIST" ] || abort "拒绝安装:pm list packages 未返回任何条目,无法完成冲突检查(C8)"

# -----------------------------------------------------------------------------
# 4) C8:与 /data 用户空间中的同包名应用冲突检查
#    任一命中 → 中止整个安装(禁止模块自行卸载)
#    /system 目标路径已有同包名 → 视为模块已生效,该条目跳过
# -----------------------------------------------------------------------------
OLD_PRIV_APP_DIR="priv"
OLD_PRIV_APP_DIR="${OLD_PRIV_APP_DIR}-app"
ui_print "- 检查 /data 用户空间中的同包名应用(C8):"
CONFLICT=""
SKIP_LIST="|"
while IFS='|' read -r PKG DIR APK_SHA LOCATION; do
  [ -n "$PKG" ] || continue
  [ -n "$DIR" ] || continue
  PACKAGE_LISTED=0
  while IFS= read -r PACKAGE_LINE; do
    [ "$PACKAGE_LINE" = "package:$PKG" ] && PACKAGE_LISTED=1
  done <<EOF
$PM_PACKAGE_LIST
EOF
  if [ "$PACKAGE_LISTED" -eq 0 ]; then
    ui_print "    [ok] $PKG 未安装,可安全挂载"
    continue
  fi
  PATHS="$("$PM_BIN" path "$PKG" 2>/dev/null)" || abort "安装中止:pm path $PKG 失败,无法检查 /data 冲突(C8)"
  [ -n "$PATHS" ] || abort "安装中止:pm list packages 含 $PKG 但 pm path 无结果,无法检查 /data 冲突(C8)"
  HIT_DATA=""
  HIT_SYSTEM=""
  BAD_PATH=""
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    case "$p" in package:*) PATH_VALUE="${p#package:}" ;; *) PATH_VALUE="$p" ;; esac
    case "$PATH_VALUE" in
      /data/*|/mnt/expand/*) HIT_DATA="$p" ;;
      /*) HIT_SYSTEM="$p" ;;
      *) BAD_PATH="$p" ;;
    esac
  done <<EOF
$PATHS
EOF
  [ -z "$BAD_PATH" ] || abort "安装中止:pm path $PKG 返回无法识别的路径 '$BAD_PATH',C8 检查不完整"
  if [ -n "$HIT_DATA" ]; then
    ui_print "    [冲突] $PKG 已安装于用户空间: $HIT_DATA"
    [ -n "$CONFLICT" ] || CONFLICT="$PKG"
    continue
  fi
  if [ -n "$HIT_SYSTEM" ]; then
    case "$HIT_SYSTEM" in
      *"/system/$OLD_PRIV_APP_DIR/$DIR/"*)
        ui_print "    [切换] $PKG 当前位于旧特权落点,将由普通变体迁移到 /system/app"
        continue
        ;;
      *)
        ui_print "    [跳过] $PKG 已由系统分区提供($HIT_SYSTEM):模块已生效,不再重复挂载"
        SKIP_LIST="$SKIP_LIST$PKG|"
        continue
        ;;
    esac
  fi
  ui_print "    [ok] $PKG 未在用户空间安装(路径: $PATHS)"
done <<EOF
$APP_ENTRIES
EOF

if [ -n "$CONFLICT" ]; then
  ui_print ""
  ui_print "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
  ui_print "检测到 $CONFLICT 已安装于用户空间。请先 \`pm uninstall $CONFLICT\`"
  ui_print "(日历/图库数据存于系统 Provider 不受影响,时钟闹钟/计算器历史/录音机设置会丢失),"
  ui_print "重启后再刷入本模块。"
  ui_print "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
  ui_print "本模块不会替你执行卸载:卸载必须由你显式执行。"
  abort "安装中止:/data 中存在同包名应用(C8)"
fi

# -----------------------------------------------------------------------------
# 5) 验证 ZIP 中的静态 APK 布局与哈希,不在安装期复制 APK。
# -----------------------------------------------------------------------------
ui_print "- 校验静态 APK (system/app/<Name>/<Name>.apk):"
while IFS='|' read -r PKG DIR APK_SHA LOCATION; do
  [ -n "$PKG" ] || continue
  SRC="$MODPATH/system/app/$DIR/$DIR.apk"
  [ -f "$SRC" ] || abort "!! ZIP 中缺少静态 APK: $SRC"
  if command -v sha256sum >/dev/null 2>&1; then
    ACTUAL="$(sha256sum "$SRC")"
    ACTUAL="${ACTUAL%% *}"
    [ "$ACTUAL" = "$APK_SHA" ] || abort "安装中止:$DIR.apk sha256 不匹配"
  else
    ui_print "    [警告] 缺少 sha256sum,跳过 $DIR.apk 哈希复核"
  fi
done <<EOF
$APP_ENTRIES
EOF

# -----------------------------------------------------------------------------
# 6) 变体切换:普通版移除旧特权树/XML;若 ROM 已提供同包,移除 ZIP 内副本。
# -----------------------------------------------------------------------------
rm -rf "$MODPATH/system/$OLD_PRIV_APP_DIR" 2>/dev/null
PRIVAPP_XML_NAME="__PRIVAPP_XML_NAME__"
rm -f "$MODPATH/system/etc/permissions/$PRIVAPP_XML_NAME" 2>/dev/null

INSTALLED_COUNT=0
ui_print "- 准备普通版静态挂载:"
while IFS='|' read -r PKG DIR APK_SHA LOCATION; do
  [ -n "$PKG" ] || continue
  DEST_DIR="$MODPATH/system/app/$DIR"
  case "$SKIP_LIST" in
    *"|$PKG|"*)
      rm -rf "$DEST_DIR" 2>/dev/null
      ui_print "    [跳过] $PKG:系统分区已有同包名应用,已移除 ZIP 副本"
      continue
      ;;
  esac
  [ -f "$DEST_DIR/$DIR.apk" ] || abort "!! 静态 APK 意外缺失: $DEST_DIR/$DIR.apk"
  set_perm_recursive "$DEST_DIR" 0 0 0755 0644
  INSTALLED_COUNT=$((INSTALLED_COUNT + 1))
  ui_print "    [完成] $PKG → /system/app/$DIR/$DIR.apk (ZIP 静态布局)"
done <<EOF
$APP_ENTRIES
EOF

# -----------------------------------------------------------------------------
# 7) 安装摘要(路径 + 体积)
# -----------------------------------------------------------------------------
ui_print "- 安装摘要:"
TOTAL=0
while IFS='|' read -r PKG DIR APK_SHA LOCATION; do
  [ -n "$PKG" ] || continue
  F="$MODPATH/system/app/$DIR/$DIR.apk"
  if [ -f "$F" ]; then
    SZ="$(wc -c < "$F" | tr -d ' ')"
    TOTAL=$((TOTAL + SZ))
    ui_print "    /system/app/$DIR/$DIR.apk  $SZ 字节  ($PKG)"
  else
    ui_print "    (未挂载) $PKG —— ROM 已提供同包名应用"
  fi
done <<EOF
$APP_ENTRIES
EOF
ui_print "    本次挂载: $INSTALLED_COUNT 项,合计 $TOTAL 字节"

ui_print "- 提示:"
ui_print "    本模块为 coexist 模式,未改动任何自带应用。"
ui_print "    如需隐藏自带应用,请自行执行(本模块不会替你做):"
ui_print "        pm disable-user --user 0 <stock_package>"
ui_print "    重启后生效。若刷入后无法正常开机,下一次开机时本模块会检测到未完成的"
ui_print "    启动标记并自动禁用自身,从而打破 bootloop(见 post-fs-data.sh)。"
