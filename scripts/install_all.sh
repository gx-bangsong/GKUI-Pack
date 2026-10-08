#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
# scripts/install_all.sh —— 【主推方案】通过 adb 免 root 批量安装 GKUI 应用
#
# 为什么这是主推方案:
#   * 不需要 root、不需要解锁、不修改任何系统分区;
#   * 失败可回退(adb uninstall 即可);
#   * 不会与 ROM 自带应用产生任何替换/挂载层面的交互。
#   (次方案 systemless 模块需要先卸载 /data 中的同包名应用,见 README)
#
# 用法:
#   bash scripts/install_all.sh [选项]
#
# 选项:
#   --apk-dir DIR     APK 目录(默认 <repo>/dist/apks,可用环境变量 APK_DIR)
#   -s, --device ID   指定设备序列号(连接多台设备时必须指定)
#   --dry-run         只打印将要执行的命令,不实际安装
#   --skip-sha-check  跳过资产 sha256 校验(不推荐)
#   --no-color
#   -h, --help
#
# 退出码:0 全部成功 | 1 存在失败 | 2 环境/用法问题(含无设备) | 3 用法错误
#
# 行为边界(硬性):
#   * 只执行 `adb install -r`:不卸载、不禁用、不修改任何已有应用。
#   * 卸载/隐藏等破坏性操作只以**建议命令**的形式打印,绝不代执行。
# =============================================================================

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APK_DIR="${APK_DIR:-$ROOT/dist/apks}"
SERIAL=""
DRY_RUN=0
SKIP_SHA=0

if [ -t 1 ]; then
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'; C_BLD=$'\033[1m'; C_RST=$'\033[0m'
else
  C_RED=''; C_GRN=''; C_YEL=''; C_BLD=''; C_RST=''
fi

info() { printf '%s\n' "[信息] $*"; }
warn() { printf '%s%s%s\n' "$C_YEL" "[警告] $*" "$C_RST" >&2; }
err()  { printf '%s%s%s\n' "$C_RED" "[失败] $*" "$C_RST" >&2; }

usage() { sed -n '3,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "${1:-}" in
    --apk-dir) APK_DIR="${2:-}"; shift 2 ;;
    -s|--device) SERIAL="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --skip-sha-check) SKIP_SHA=1; shift ;;
    --no-color) C_RED=''; C_GRN=''; C_YEL=''; C_BLD=''; C_RST=''; shift ;;
    -h|--help) usage; exit 0 ;;
    *) err "未知参数: $1"; usage; exit 3 ;;
  esac
done

# -----------------------------------------------------------------------------
# 1) 环境:adb 与设备
# -----------------------------------------------------------------------------
if ! command -v adb >/dev/null 2>&1; then
  err "找不到 adb 命令。请先安装 Android Platform Tools 并确保 adb 在 PATH 中。"
  err "提示:部分发行版可用包管理器安装(android-tools-adb / android-platform-tools)。"
  exit 2
fi

if ! command -v python3 >/dev/null 2>&1; then
  err "找不到 python3:本脚本通过 build.sh 解析 apps.yaml,需要 python3(标准库即可)。"
  exit 2
fi

ADB=(adb)
if [ -n "$SERIAL" ]; then
  ADB=(adb -s "$SERIAL")
fi

check_device() {
  local out devices count
  out="$(adb devices 2>&1)" || { err "adb devices 执行失败: $out"; return 2; }
  devices="$(printf '%s\n' "$out" | awk 'NR>1 && $2=="device" {print $1}')"
  count="$(printf '%s' "$devices" | grep -c . || true)"
  local pending
  pending="$(printf '%s\n' "$out" | awk 'NR>1 && ($2=="unauthorized" || $2=="offline" || $2=="no permissions") {print $1" ("$2")"}')"
  if [ "$count" -eq 0 ]; then
    err "没有检测到已授权的设备。本脚本**不会**做任何修改,已安全退出。"
    printf '请依次确认:\n' >&2
    printf '  1) 用 USB 线连接手机,并在手机上把 USB 模式设为「文件传输 / MTP」;\n' >&2
    printf '  2) 在「开发者选项」中打开「USB 调试」(部分机型还需打开「USB 安装」);\n' >&2
    printf '  3) 手机屏幕上弹出的「允许 USB 调试吗?」请勾选「一律允许」并确认;\n' >&2
    printf '  4) 重新执行本脚本,或先用  adb devices  确认状态为 device。\n' >&2
    if [ -n "$pending" ]; then
      printf '当前未授权/离线的设备:%s\n' "$pending" >&2
    fi
    return 1
  fi
  if [ "$count" -gt 1 ] && [ -z "$SERIAL" ]; then
    err "检测到多台设备,请用 -s <序列号> 指定目标:"
    printf '%s\n' "$devices" | sed 's/^/      /' >&2
    return 1
  fi
  if [ -n "$SERIAL" ]; then
    case "$(printf '%s\n' "$devices")" in
      *"$SERIAL"*) : ;;
      *) err "指定的设备 $SERIAL 不在已授权设备列表中:"; printf '%s\n' "$devices" | sed 's/^/      /' >&2; return 1 ;;
    esac
    info "使用设备: $SERIAL"
  else
    info "使用设备: $(printf '%s' "$devices" | head -1)"
  fi
  return 0
}

if [ "$DRY_RUN" = 1 ]; then
  info "--dry-run:跳过 adb 设备检查,只打印将要执行的命令"
  if command -v adb >/dev/null 2>&1; then
    adb devices 2>/dev/null | sed 's/^/      /' || true
  fi
else
  check_device || exit 2
fi

# -----------------------------------------------------------------------------
# 2) 读取清单(唯一解析入口:build.sh,禁止本脚本自行解析 YAML)
# -----------------------------------------------------------------------------
TSV="$(bash "$ROOT/build.sh" --emit-tsv)" || {
  err "读取 apps.yaml 失败:请先执行  bash build.sh --check  查看具体问题。"
  exit 2
}
[ -n "$TSV" ] || { err "apps.yaml 中没有任何 enabled: true 的条目"; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/gkui-install.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  else err "缺少 sha256sum / shasum,无法校验资产完整性(可加 --skip-sha-check 跳过)"; exit 2
  fi
}

# 失败原因解释:把 adb 的错误码翻译成人话
explain_failure() { # $1=应用 id $2=包名 $3=adb 输出
  local app_id="$1" pkg="$2" out="$3" code=""
  code="$(printf '%s' "$out" | sed -n 's/.*Failure \[\([A-Z_]*\).*/\1/p' | head -1)"
  [ -n "$code" ] || code="$(printf '%s' "$out" | grep -oE 'INSTALL_[A-Z_]+' | head -1 || true)"
  printf '\n'
  case "$code" in
    INSTALL_FAILED_UPDATE_INCOMPATIBLE)
      err "$app_id: INSTALL_FAILED_UPDATE_INCOMPATIBLE —— 已安装版本的签名与本次 APK 不兼容。"
      printf '      原因:GKUI 应用都是 **debug 构建**(debug keystore 签名),\n'
      printf '            不同构建环境的 debug keystore 可能不同,Android 会拒绝覆盖安装。\n'
      printf '      处理:只能先卸载已安装版本,再安装本 APK。\n'
      printf '      ⚠️ 数据会丢失:日历/图库的数据存放在系统 Provider,不受影响;\n'
      printf '         时钟闹钟、计算器历史、录音机设置会丢失。\n'
      printf '      命令(请自行确认后执行):\n'
      printf '        adb uninstall %s\n' "$pkg"
      printf '      或者直接使用  bash scripts/uninstall_all.sh --keep-data\n'
      ;;
    INSTALL_FAILED_CONFLICTING_PROVIDER)
      err "$app_id: INSTALL_FAILED_CONFLICTING_PROVIDER —— ContentProvider authority 冲突。"
      printf '      原因:authority 在整个系统内必须唯一;设备上已有另一个应用声明了同一 authority\n'
      printf '            (常见于同源应用的另一个包名版本仍在使用相同的 authority)。\n'
      printf '      处理:确认是否重复安装了同一应用的另一份构建;必要时卸载冲突的一方\n'
      printf '            (请自行判断,卸载会丢数据)。\n'
      printf '      排查:\n'
      printf '        adb shell dumpsys package %s | grep -i provider\n' "$pkg"
      ;;
    INSTALL_FAILED_DUPLICATE_PERMISSION)
      err "$app_id: INSTALL_FAILED_DUPLICATE_PERMISSION —— 重复声明了设备上已有的同名权限。"
      printf '      原因:权限名全局唯一,设备上已有应用定义了同名权限(通常是同源应用)。\n'
      printf '      处理:确认是否重复安装同一应用的另一份构建;卸载多余的那一份后再试。\n'
      ;;
    INSTALL_FAILED_VERSION_DOWNGRADE)
      err "$app_id: INSTALL_FAILED_VERSION_DOWNGRADE —— 设备上已安装的 versionCode 更高。"
      printf '      处理:使用更新的 APK;或确认后允许降级(-- 不建议,可能丢数据)。\n'
      ;;
    INSTALL_FAILED_ALREADY_EXISTS)
      err "$app_id: INSTALL_FAILED_ALREADY_EXISTS —— 已存在同包名应用(未使用覆盖安装)。"
      printf '      处理:本脚本使用 -r 覆盖;若仍出现,请确认设备上是否为不同的包名/签名。\n'
      ;;
    INSTALL_PARSE_FAILED*)
      err "$app_id: $code —— APK 解析失败(文件损坏或不是有效 APK)。"
      printf '      处理:重新下载该 Release 资产并核对 sha256(apps.yaml 中已记录)。\n'
      ;;
    INSTALL_FAILED_INSUFFICIENT_STORAGE)
      err "$app_id: INSTALL_FAILED_INSUFFICIENT_STORAGE —— 设备空间不足。"
      ;;
    INSTALL_FAILED_VERIFICATION_FAILURE)
      err "$app_id: INSTALL_FAILED_VERIFICATION_FAILURE —— 系统校验(如安装器校验)拒绝。"
      printf '      处理:检查 ROM 的「安装未知来源应用 / 校验」相关设置后重试。\n'
      ;;
    '')
      err "$app_id: adb install 失败(未能识别错误码)。原始输出如下:"
      printf '%s\n' "$out" | sed 's/^/        /'
      ;;
    *)
      err "$app_id: adb install 失败,错误码 $code。原始输出如下:"
      printf '%s\n' "$out" | sed 's/^/        /'
      ;;
  esac
  printf '\n'
}

# -----------------------------------------------------------------------------
# 3) 逐个安装(只执行 adb install -r)
# -----------------------------------------------------------------------------
printf '%s=== GKUI-Pack:adb 免 root 批量安装(主推方案)===%s\n' "$C_BLD" "$C_RST"
info "APK 目录: $APK_DIR"
[ "$DRY_RUN" = 1 ] && info "模式: --dry-run(不实际安装)"
printf '\n'

SUCCESS=0
FAILED=0
FAILED_LIST=""

while IFS=$'\t' read -r APP_ID _APP_NAME APP_PKG _STOCK_PKG APP_REPO _APP_UP _APP_LIC \
        _APP_SRC APP_TAG APP_ASSET APP_SHA _APP_SIGNER _APP_IVC _APP_AS _APP_MODE \
        _APP_CONF _APP_ENABLED; do
  [ -n "$APP_ID" ] || continue
  printf '%s--- %s (%s) ---%s\n' "$C_BLD" "$APP_ID" "$APP_PKG" "$C_RST"

  asset="$APK_DIR/$APP_ASSET"
  if [ ! -f "$asset" ]; then
    err "缺少 APK: $asset"
    printf '      请先从 %s 的 Release %s 下载资产 %s:\n' "$APP_REPO" "$APP_TAG" "$APP_ASSET"
    printf '        gh release download %s -R %s -p %s -D %s\n' "$APP_TAG" "$APP_REPO" "$APP_ASSET" "$APK_DIR"
    FAILED=$((FAILED + 1)); FAILED_LIST="$FAILED_LIST $APP_ID(缺少 APK)"
    continue
  fi

  if [ "$SKIP_SHA" = 1 ]; then
    warn "已跳过 sha256 校验(--skip-sha-check)"
  else
    actual="$(sha256_of "$asset")"
    expected="$(printf '%s' "$APP_SHA" | tr -d ':\ ' | tr '[:upper:]' '[:lower:]')"
    if [ "$actual" != "$expected" ]; then
      err "$APP_ID: 资产 sha256 不匹配,拒绝安装"
      printf '      期望(apps.yaml): %s\n      实际(本地文件): %s\n' "$expected" "$actual"
      FAILED=$((FAILED + 1)); FAILED_LIST="$FAILED_LIST $APP_ID(sha256 不匹配)"
      continue
    fi
    info "sha256 校验通过(${actual:0:16}…)"
  fi

  # zip 包装的资产:解压取其中唯一的 APK(资产级 sha256 已在上面校验过)
  apk="$asset"
  case "$APP_ASSET" in
    *.zip)
      mkdir -p "$WORK/unzip/$APP_ID"
      unzip -qq -o "$asset" -d "$WORK/unzip/$APP_ID" || { err "$APP_ID: 解压失败"; FAILED=$((FAILED + 1)); FAILED_LIST="$FAILED_LIST $APP_ID(解压失败)"; continue; }
      found="$(find "$WORK/unzip/$APP_ID" -type f -name '*.apk' | sort)"
      cnt="$(printf '%s' "$found" | grep -c 'apk$' || true)"
      if [ "$cnt" -ne 1 ]; then
        err "$APP_ID: 压缩包内 .apk 数量为 $cnt,无法自动判定(禁止猜测),跳过"
        FAILED=$((FAILED + 1)); FAILED_LIST="$FAILED_LIST $APP_ID(压缩包内容不唯一)"
        continue
      fi
      apk="$found"
      info "从 zip 资产中取出: $(basename "$apk")"
      ;;
  esac

  if [ "$DRY_RUN" = 1 ]; then
    printf '      [dry-run] adb %sinstall -r %s   (包名 %s)\n' \
      "$([ -n "$SERIAL" ] && printf -- '-s %s ' "$SERIAL")" "$apk" "$APP_PKG"
    SUCCESS=$((SUCCESS + 1))
    continue
  fi

  out="$("${ADB[@]}" install -r "$apk" 2>&1)"; rc=$?
  if [ $rc -eq 0 ] && printf '%s' "$out" | grep -q 'Success'; then
    printf '      %s✔ 安装成功%s(%s)\n' "$C_GRN" "$C_RST" "$APP_PKG"
    SUCCESS=$((SUCCESS + 1))
  else
    explain_failure "$APP_ID" "$APP_PKG" "$out"
    FAILED=$((FAILED + 1)); FAILED_LIST="$FAILED_LIST $APP_ID"
  fi
done <<EOF
$TSV
EOF

# -----------------------------------------------------------------------------
# 4) 收尾:提示默认应用切换 + 只打印(不执行)破坏性命令
# -----------------------------------------------------------------------------
printf '%s=== 安装结果 ===%s\n' "$C_BLD" "$C_RST"
printf '成功: %d,失败: %d%s\n' "$SUCCESS" "$FAILED" "${FAILED_LIST:+ (失败:$FAILED_LIST)}"

if [ "$SUCCESS" -gt 0 ]; then
  printf '\n%s下一步:把默认应用切换成 GKUI 应用%s\n' "$C_BLD" "$C_RST"
  printf '  请在设备的「设置 → 应用 → 默认应用」中切换(入口名称随 ROM 版本略有差异):\n'
  printf '    * 默认「日历」→ 选择 GKUI 日历(GKUICalendar)\n'
  printf '    * 默认「图库 / 相册」→ 选择 GKUI 图库(部分 ROM 没有独立的默认图库开关,\n'
  printf '      此时在打开图片时选择「始终使用 GKUI 图库」即可)\n'
  printf '  说明:GKUI 应用与 ROM 自带应用是**两个不同的应用**(包名不同),\n'
  printf '        切换默认应用只影响「打开方式」,不会卸载或禁用自带应用。\n'
fi

printf '\n%s以下命令仅供你按需自行执行,本脚本不会代做任何破坏性操作:%s\n' "$C_YEL" "$C_RST"
printf '  卸载已安装的 GKUI 应用:\n'
printf '    数据影响:日历/图库的数据存放在系统 Provider,卸载应用不受影响;\n'
printf '              时钟闹钟、计算器历史、录音机设置会随卸载丢失。\n'
while IFS=$'\t' read -r APP_ID _APP_NAME APP_PKG _REST; do
  [ -n "$APP_ID" ] || continue
  printf '        adb uninstall %s\n' "$APP_PKG"
done <<EOF
$TSV
EOF
printf '  隐藏 ROM 自带应用(仅当你确实需要时;可随时 pm enable 恢复):\n'
while IFS=$'\t' read -r APP_ID _APP_NAME APP_PKG STOCK_PKG _REST; do
  [ -n "$APP_ID" ] || continue
  [ -n "$STOCK_PKG" ] || continue
  printf '        adb shell pm disable-user --user 0 %s\n' "$STOCK_PKG"
done <<EOF
$TSV
EOF

if [ "$FAILED" -gt 0 ]; then
  exit 1
fi
exit 0
