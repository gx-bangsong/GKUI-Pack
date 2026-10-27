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
#   C2  只写模块自身挂载目录;不替换/覆盖 stock 文件;开机后可逆管理 stock 启用状态
#   C3  只装 system/app(绝不使用特权应用目录),也不生成任何权限白名单;
#       system/ 下除 app/ 以外的任何落点都视为残留并清除(见第 5 步)
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
ui_print " 挂载 GKUI 应用;不替换或覆盖 stock 文件;默认开机后可逆停用对应 stock 应用"
ui_print "************************************************"

choose_stock_policy() {
  # 安装时重置旧选择;只有本轮明确按音量下才生成 keep-stock。
  rm -f "$MODPATH/keep-stock" 2>/dev/null
  ui_print "- stock 应用选择:默认在开机后停用 GKUI 对应的 ROM 自带应用。"
  ui_print "    10 秒内按音量下 = 保留 stock;按音量上或超时 = 默认停用。"

  GETEVENT_BIN="$(command -v getevent 2>/dev/null)"
  if [ -z "$GETEVENT_BIN" ] && [ -x /system/bin/getevent ]; then
    GETEVENT_BIN=/system/bin/getevent
  fi
  if [ -z "$GETEVENT_BIN" ]; then
    ui_print "    当前选择:默认停用 stock(getevent 不存在,未读取按键)。"
    return 0
  fi

  STOCK_KEY_EVENTS="$MODPATH/.stock-key-events"
  rm -f "$STOCK_KEY_EVENTS" 2>/dev/null
  if ! : > "$STOCK_KEY_EVENTS" 2>/dev/null; then
    ui_print "    当前选择:默认停用 stock(无法创建按键检测临时文件)。"
    return 0
  fi

  "$GETEVENT_BIN" -l > "$STOCK_KEY_EVENTS" 2>/dev/null &
  GETEVENT_PID=$!
  STOCK_KEY_CHOICE=""
  STOCK_KEY_WAITED=0
  STOCK_KEY_TIMED_OUT=0
  while [ "$STOCK_KEY_WAITED" -lt 10 ]; do
    if [ -s "$STOCK_KEY_EVENTS" ]; then
      STOCK_KEY_CHOICE="$(awk '
        {
          value = $NF
          if (value != "DOWN" && value != "1" && value != "00000001" && value != "0x00000001") next
          if ($0 ~ /KEY_VOLUMEDOWN/) { print "keep"; exit }
          if ($0 ~ /KEY_VOLUMEUP/) { print "disable"; exit }
        }
      ' "$STOCK_KEY_EVENTS" 2>/dev/null)"
      [ -n "$STOCK_KEY_CHOICE" ] && break
    fi
    if ! kill -0 "$GETEVENT_PID" 2>/dev/null; then
      break
    fi
    sleep 1
    STOCK_KEY_WAITED=$((STOCK_KEY_WAITED + 1))
  done
  if kill -0 "$GETEVENT_PID" 2>/dev/null; then
    STOCK_KEY_TIMED_OUT=1
    kill "$GETEVENT_PID" 2>/dev/null || true
  fi
  wait "$GETEVENT_PID" 2>/dev/null
  GETEVENT_RC=$?
  if [ -z "$STOCK_KEY_CHOICE" ] && [ -s "$STOCK_KEY_EVENTS" ]; then
    STOCK_KEY_CHOICE="$(awk '
      {
        value = $NF
        if (value != "DOWN" && value != "1" && value != "00000001" && value != "0x00000001") next
        if ($0 ~ /KEY_VOLUMEDOWN/) { print "keep"; exit }
        if ($0 ~ /KEY_VOLUMEUP/) { print "disable"; exit }
      }
    ' "$STOCK_KEY_EVENTS" 2>/dev/null)"
  fi
  rm -f "$STOCK_KEY_EVENTS" 2>/dev/null

  case "$STOCK_KEY_CHOICE" in
    keep)
      if : > "$MODPATH/keep-stock" 2>/dev/null; then
        ui_print "    当前选择:保留/恢复 stock(已创建 keep-stock)。"
      else
        ui_print "    当前选择:默认停用 stock(无法创建 keep-stock)。"
      fi
      ;;
    disable)
      ui_print "    当前选择:默认停用 stock(检测到音量上)。"
      ;;
    *)
      if [ "$STOCK_KEY_TIMED_OUT" -eq 1 ]; then
        ui_print "    当前选择:默认停用 stock(10 秒内未检测到音量键)。"
      elif [ "$GETEVENT_RC" -ne 0 ]; then
        ui_print "    当前选择:默认停用 stock(getevent 读取按键失败)。"
      else
        ui_print "    当前选择:默认停用 stock(未检测到音量键)。"
      fi
      ;;
  esac
}

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

# 已登记的前驱版本(用于检测跨版本签名断裂,如 GKUIRecorder beta2 → beta3)
# 格式: <application_id>|<目录名>|<前驱标签>|<前驱 APK sha256>|<前驱签名 sha256>|<当前目标标签>
PREDECESSOR_ENTRIES="
__PREDECESSOR_ENTRIES__
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
# 4) C8:与 /data 用户空间中的同包名应用冲突检查及跨版本签名断裂保护
#    - 已安装 APK 字节与目标 sha256 一致时可正常接管;
#    - 检测到 beta2 → beta3 签名变更时,整包中止并给出明确指引
#      (备份 → 手动卸载或删旧模块 → 重启),严禁自动卸载或写 /data;
#    - 其余 /data 同包名应用 → 中止整个安装(禁止模块自行卸载);
#    - 其余 /system 已有同包名 → 视为模块已生效,该条目跳过。
# -----------------------------------------------------------------------------
ui_print "- 检查 /data 用户空间中的同包名应用与签名一致性(C8):"
CONFLICT=""
SIG_CONFLICT=""
SIG_TRANSITION=""
SIG_PATH=""
SKIP_LIST="|"
while IFS='|' read -r PKG DIR APK_SHA; do
  [ -n "$PKG" ] || continue
  [ -n "$DIR" ] || continue

  PRED_TAG=""
  PRED_SHA=""
  PRED_SIGNER=""
  TARGET_TAG=""
  while IFS='|' read -r P_PKG _P_DIR P_TAG P_SHA P_SIGNER P_CURR; do
    [ -n "$P_PKG" ] || continue
    [ "$P_PKG" = "$PKG" ] || continue
    PRED_TAG="$P_TAG"
    PRED_SHA="$P_SHA"
    PRED_SIGNER="$P_SIGNER"
    TARGET_TAG="$P_CURR"
  done <<EOF
$PREDECESSOR_ENTRIES
EOF

  PATHS="$("$PM_BIN" path "$PKG" 2>/dev/null)"
  if [ -z "$PATHS" ] && [ -n "${EXISTING_MODDIR:-}" ] && [ -f "$EXISTING_MODDIR/system/app/$DIR/$DIR.apk" ]; then
    PATHS="package:$EXISTING_MODDIR/system/app/$DIR/$DIR.apk"
  fi
  if [ -z "$PATHS" ]; then
    ui_print "    [ok] $PKG 未安装,可安全挂载"
    continue
  fi
  HIT_DATA=""
  HIT_SYSTEM=""
  HIT_ADOPT=""
  HIT_SIG=""
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    clean_p="${p#package:}"
    INST_SHA=""
    if [ -n "${FAKE_PM_SHA256:-}" ] && [ "$PKG" = "${FAKE_PM_PKG:-}" ]; then
      INST_SHA="$FAKE_PM_SHA256"
    elif [ -f "$clean_p" ] && command -v sha256sum >/dev/null 2>&1; then
      INST_SHA="$(sha256sum "$clean_p")"
      INST_SHA="${INST_SHA%% *}"
    fi
    INST_SIGNER=""
    if [ -n "${FAKE_PM_SIGNER:-}" ] && [ "$PKG" = "${FAKE_PM_PKG:-}" ]; then
      INST_SIGNER="$FAKE_PM_SIGNER"
    fi

    # 1) 检查是否命中已登记前驱(如 beta2 → beta3 签名断裂)
    if { [ -n "$PRED_SHA" ] && [ -n "$INST_SHA" ] && [ "$INST_SHA" = "$PRED_SHA" ]; } || \
       { [ -n "$PRED_SIGNER" ] && [ -n "$INST_SIGNER" ] && [ "$INST_SIGNER" = "$PRED_SIGNER" ]; } || \
       { [ -n "$PRED_SHA" ] && [ -n "$INST_SHA" ] && [ "$INST_SHA" != "$APK_SHA" ]; }; then
      HIT_SIG="$clean_p"
      break
    fi

    # 2) 已安装 APK 字节与目标 sha256 一致时可正常接管
    if [ -n "$INST_SHA" ] && [ "$INST_SHA" = "$APK_SHA" ]; then
      HIT_ADOPT="$clean_p"
      continue
    fi

    case "$p" in
      package:/data/*|/data/*) HIT_DATA="$p" ;;
      package:/system/*|/system/*) HIT_SYSTEM="$p" ;;
      *) : ;;
    esac
  done <<EOF
$PATHS
EOF
  if [ -n "$HIT_SIG" ]; then
    trans="${PRED_TAG:-旧版} → ${TARGET_TAG:-新版}"
    ui_print "    [签名变更] $PKG ($DIR) 检测到 $trans 签名不一致: $HIT_SIG"
    if [ -z "$SIG_CONFLICT" ]; then
      SIG_CONFLICT="$PKG"
      SIG_TRANSITION="$trans"
      SIG_PATH="$HIT_SIG"
    fi
    continue
  fi
  if [ -n "$HIT_DATA" ]; then
    ui_print "    [冲突] $PKG 已安装于用户空间: $HIT_DATA"
    [ -n "$CONFLICT" ] || CONFLICT="$PKG"
    continue
  fi
  if [ -n "$HIT_ADOPT" ]; then
    ui_print "    [接管] $PKG 已安装 APK 字节与目标 sha256 一致($HIT_ADOPT),可正常接管"
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

if [ -n "$SIG_CONFLICT" ]; then
  rm -rf "$MODPATH/system" "$MODPATH/apks" 2>/dev/null
  ui_print ""
  ui_print "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
  ui_print "检测到 $SIG_CONFLICT 存在跨版本签名变更($SIG_TRANSITION)!"
  ui_print "已安装路径: $SIG_PATH"
  ui_print "直接覆盖会导致系统因签名不一致(INSTALL_FAILED_UPDATE_INCOMPATIBLE)拒绝加载该应用。"
  ui_print "请按以下步骤手动处理后再刷入:"
  ui_print "  1. 备份:先备份该应用内的重要数据(如录音机已录制的音频文件);"
  ui_print "  2. 手动卸载或删旧模块:在「设置 → 应用」中手动卸载(或执行 \`pm uninstall $SIG_CONFLICT\`),"
  ui_print "     若来自旧版模块则在管理器中删除旧模块;"
  ui_print "  3. 重启:重启手机后,再重新刷入本模块。"
  ui_print "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
  ui_print "本模块严禁自动卸载或写 /data:所有卸载与清理必须由你手动完成。"
  abort "安装中止:检测到 $SIG_TRANSITION 签名变更(C8)"
fi

if [ -n "$CONFLICT" ]; then
  rm -rf "$MODPATH/system" "$MODPATH/apks" 2>/dev/null
  ui_print ""
  ui_print "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
  ui_print "检测到 $CONFLICT 已安装于用户空间。请先 \`pm uninstall $CONFLICT\`"
  ui_print "(日历/图库数据存于系统 Provider 不受影响,时钟闹钟/计算器历史/录音机设置会丢失),"
  ui_print "重启后再刷入本模块。"
  ui_print "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
  ui_print "本模块不会替你执行卸载:卸载必须由你显式执行。"
  abort "安装中止:/data 中存在同包名应用(C8)"
fi

choose_stock_policy

# -----------------------------------------------------------------------------
# 5) 清理另一种落点(从普通版刷到特权版时,移除 system/app/GKUIRecorder 残留)
# -----------------------------------------------------------------------------
if [ -d "$MODPATH/system/app/GKUIRecorder" ]; then
  ui_print "    [清理] 移除普通版残留落点: system/app/GKUIRecorder"
  rm -rf "$MODPATH/system/app/GKUIRecorder"
fi
if [ -d "$MODPATH/system" ]; then
  for p in "$MODPATH/system"/* "$MODPATH/system"/.[!.]*; do
    [ -e "$p" ] || continue
    case "$p" in
      "$MODPATH/system/app"|"$MODPATH/system/priv-app"|"$MODPATH/system/etc") continue ;;
    esac
    ui_print "    [清理] 移除非预期残留落点: ${p#"$MODPATH"/}"
    rm -rf "$p"
  done
fi

# -----------------------------------------------------------------------------
# 6) 逐个应用:GKUIRecorder → system/priv-app/GKUIRecorder,其余 → system/app/<目录名>
#    并写入 privapp-permissions-org.lineageos.recorder.dev.xml
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
  SUBDIR="app"
  [ "$DIR" = "GKUIRecorder" ] && SUBDIR="priv-app"
  DEST_DIR="$MODPATH/system/$SUBDIR/$DIR"
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
  ui_print "    [完成] $PKG → /system/$SUBDIR/$DIR/$DIR.apk"
done <<EOF
$APP_ENTRIES
EOF

PERM_DIR="$MODPATH/system/etc/permissions"
PERM_XML="$PERM_DIR/privapp-permissions-org.lineageos.recorder.dev.xml"
mkdir -p "$PERM_DIR" || abort "!! 无法创建 $PERM_DIR"
cat > "$PERM_XML" <<'PRIVXML'
__PRIVAPP_PERMISSIONS_XML__
PRIVXML
set_perm_recursive "$MODPATH/system/etc" 0 0 0755 0644
ui_print "    [白名单] → /system/etc/permissions/privapp-permissions-org.lineageos.recorder.dev.xml"

if [ "$INSTALLED_COUNT" -eq 0 ]; then
  ui_print "!! 所有条目都已由系统分区提供:本模块没有需要挂载的内容。"
  ui_print "!! 这通常说明你已经刷过本模块(或同等内容),无需重复安装。"
  abort "安装中止:没有需要挂载的应用"
fi

# 安装期辅助目录不再需要,清理掉(避免占用模块空间)
rm -rf "$MODPATH/apks" 2>/dev/null

# -----------------------------------------------------------------------------
# 7) 安装摘要(路径 + 体积)
# -----------------------------------------------------------------------------
ui_print "- 安装摘要:"
TOTAL=0
while IFS='|' read -r PKG DIR APK_SHA; do
  [ -n "$PKG" ] || continue
  [ -n "$DIR" ] || continue
  SUBDIR="app"
  [ "$DIR" = "GKUIRecorder" ] && SUBDIR="priv-app"
  F="$MODPATH/system/$SUBDIR/$DIR/$DIR.apk"
  if [ -f "$F" ]; then
    SZ="$(wc -c < "$F" | tr -d ' ')"
    TOTAL=$((TOTAL + SZ))
    ui_print "    /system/$SUBDIR/$DIR/$DIR.apk  $SZ 字节  ($PKG)"
  else
    ui_print "    (未挂载) $PKG —— 系统分区已有同包名应用"
  fi
done <<EOF
$APP_ENTRIES
EOF
ui_print "    本次挂载: $INSTALLED_COUNT 项,合计 $TOTAL 字节"

ui_print "- 提示:"
ui_print "    service.sh 会在开机后按 stock-packages.list 可逆停用对应 stock 应用。"
ui_print "    安装后可在模块目录创建 keep-stock 文件并重启以保留/恢复 stock;删除该文件后重启则恢复默认停用。"
ui_print "    卸载模块会安排下一次启动自动恢复本模块曾停用的 stock 应用。"
ui_print "    若刷入后无法正常开机,下一次开机时模块会检测到未完成的启动标记并自动禁用自身,从而打破 bootloop。"
