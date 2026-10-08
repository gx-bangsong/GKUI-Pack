#!/system/bin/sh
# =============================================================================
# customize.sh —— GKUI-Pack systemless 模块安装脚本(coexist 模式)
#
# 由 Magisk / KernelSU / APatch 的模块安装器在解包后执行。
# 本文件中的 __APP_ENTRIES__ 占位符由仓库根目录的 build.sh 在构建时渲染为:
#
#     <application_id>|<目录名>|<该 APK 的 sha256>
#
# 一行一个应用。**直接打包本目录(不经过 build.sh)得到的 zip 是无效的**:
# 此时清单为空,脚本会拒绝安装(见下面的清单检查)。
#
# 硬约束落实:
#   C2  只写 system/app,绝不动任何 ROM 自带应用,不产生任何替换语义
#   C3  只装 system/app(绝不使用特权应用目录),也不生成任何权限白名单
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
  set_perm() { chown "$1:$2" "$4" 2>/dev/null; chmod "$3" "$4" 2>/dev/null; }
fi
if ! has_func set_perm_recursive; then
  set_perm_recursive() {
    chown "$1:$2" "$5" 2>/dev/null
    chmod "$3" "$5" 2>/dev/null
    find "$5" -type d -exec chmod "$3" {} + 2>/dev/null
    find "$5" -type f -exec chmod "$4" {} + 2>/dev/null
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

# 清单格式门禁:每行必须是 <application_id>|<目录名>|<64 位 hex 的 sha256>
# 这样可以在安装前就发现"直接打包 module/ 目录"这类未渲染产物。
BAD_ENTRY=""
while IFS='|' read -r PKG DIR APK_SHA; do
  [ -n "$PKG" ] || continue
  case "$PKG" in
    *.*) : ;;
    *) BAD_ENTRY="$PKG" ;;
  esac
  [ -n "$DIR" ] || BAD_ENTRY="$PKG"
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
if ! "$PM_BIN" list packages >/dev/null 2>&1; then
  ui_print "!! pm 存在但不可用(pm list packages 失败),无法完成冲突检查。"
  abort "拒绝安装:pm 不可用(C8)"
fi

# -----------------------------------------------------------------------------
# 4) C8:与 /data 用户空间中的同包名应用冲突检查
#    任一命中 → 中止整个安装(禁止模块自行卸载)
#    /system 已有同包名 → 视为模块已生效,该条目跳过
# -----------------------------------------------------------------------------
ui_print "- 检查 /data 用户空间中的同包名应用(C8):"
CONFLICT=""
SKIP_LIST="|"
while IFS='|' read -r PKG DIR APK_SHA; do
  [ -n "$PKG" ] || continue
  [ -n "$DIR" ] || continue
  PATHS="$("$PM_BIN" path "$PKG" 2>/dev/null)"
  if [ -z "$PATHS" ]; then
    ui_print "    [ok] $PKG 未安装,可安全挂载"
    continue
  fi
  HIT_DATA=""
  HIT_SYSTEM=""
  while IFS= read -r p; do
    case "$p" in
      package:/data/*|/data/*) HIT_DATA="$p" ;;
      package:/system/*|/system/*) HIT_SYSTEM="$p" ;;
      *) : ;;
    esac
  done <<EOF
$PATHS
EOF
  if [ -n "$HIT_DATA" ]; then
    ui_print "    [冲突] $PKG 已安装于用户空间: $HIT_DATA"
    [ -n "$CONFLICT" ] || CONFLICT="$PKG"
    continue
  fi
  if [ -n "$HIT_SYSTEM" ]; then
    ui_print "    [跳过] $PKG 已由系统分区提供($HIT_SYSTEM):模块已生效,不再重复挂载"
    SKIP_LIST="$SKIP_LIST$PKG|"
    continue
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
# 5) 逐个应用:APK → system/app/<目录名>/<目录名>.apk,并设置权限
# -----------------------------------------------------------------------------
ui_print "- 开始挂载应用:"
INSTALLED_COUNT=0
while IFS='|' read -r PKG DIR APK_SHA; do
  [ -n "$PKG" ] || continue
  [ -n "$DIR" ] || continue

  case "$SKIP_LIST" in
    *"|$PKG|"*)
      ui_print "    [跳过] $PKG:系统分区已有同包名应用,无需挂载"
      continue
      ;;
  esac

  SRC="$MODPATH/apks/$DIR.apk"
  DEST_DIR="$MODPATH/system/app/$DIR"
  DEST="$DEST_DIR/$DIR.apk"

  if [ ! -f "$SRC" ]; then
    abort "!! 模块内缺少 $SRC(应来自 build.sh 构建产物)"
  fi

  # 完整性:比对该 APK 的 sha256 与构建时记录值(缺少 sha256sum 时降级为警告)
  if command -v sha256sum >/dev/null 2>&1; then
    ACTUAL="$(sha256sum "$SRC")"
    ACTUAL="${ACTUAL%% *}"
    if [ "$ACTUAL" != "$APK_SHA" ]; then
      ui_print "!! $DIR.apk 校验失败:期望 $APK_SHA,实际 $ACTUAL"
      abort "安装中止:APK 完整性校验失败"
    fi
  else
    ui_print "    [警告] 缺少 sha256sum,跳过 $DIR.apk 的完整性校验"
  fi

  mkdir -p "$DEST_DIR" || abort "!! 无法创建 $DEST_DIR"
  cp -f "$SRC" "$DEST" || abort "!! 无法写入 $DEST"
  set_perm_recursive "$DEST_DIR" 0 0 0755 0644
  INSTALLED_COUNT=$((INSTALLED_COUNT + 1))
  ui_print "    [完成] $PKG → /system/app/$DIR/$DIR.apk"
done <<EOF
$APP_ENTRIES
EOF

if [ "$INSTALLED_COUNT" -eq 0 ]; then
  ui_print "!! 所有条目都已由系统分区提供:本模块没有需要挂载的内容。"
  ui_print "!! 这通常说明你已经刷过本模块(或同等内容),无需重复安装。"
  abort "安装中止:没有需要挂载的应用"
fi

# 安装期辅助目录不再需要,清理掉(避免占用模块空间)
rm -rf "$MODPATH/apks" 2>/dev/null

# -----------------------------------------------------------------------------
# 6) 安装摘要(路径 + 体积)
# -----------------------------------------------------------------------------
ui_print "- 安装摘要:"
TOTAL=0
while IFS='|' read -r PKG DIR APK_SHA; do
  [ -n "$PKG" ] || continue
  [ -n "$DIR" ] || continue
  F="$MODPATH/system/app/$DIR/$DIR.apk"
  if [ -f "$F" ]; then
    SZ="$(wc -c < "$F" | tr -d ' ')"
    TOTAL=$((TOTAL + SZ))
    ui_print "    /system/app/$DIR/$DIR.apk  $SZ 字节  ($PKG)"
  else
    ui_print "    (未挂载) $PKG —— 系统分区已有同包名应用"
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
