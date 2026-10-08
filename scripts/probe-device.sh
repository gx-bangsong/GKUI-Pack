#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
# scripts/probe-device.sh —— 只读采集设备事实,用于人工回填 apps.yaml 的 TODO
#
# 本脚本的定位:
#   apps.yaml 里凡是标了 TODO 的设备侧字段(installed_version_code、
#   signer_sha256 等),都必须来自**真实设备/真实 APK 的实测**。
#   本脚本把这些实测值采集出来给你看,但**绝不自动改写 apps.yaml** ——
#   自动写值等于把"实测"变成"脚本猜",那是本工程明令禁止的(C1/C7)。
#
# 只做只读操作:
#   adb shell pm list packages / pm path / dumpsys package
#   adb pull <设备上的 APK> → 本地临时目录(仅用于算 sha256 与签名证书)
#   **不会** push / install / uninstall / disable / rm 任何设备上的内容。
#   临时目录在退出时会被删除;仓库内不会落下任何 .apk。
#
# 用法:
#   bash scripts/probe-device.sh [选项]
#
# 选项:
#   -s, --device ID     指定设备序列号
#   --out FILE          同时把报告写入文件(默认只打印)
#   --filter PATTERN    只显示包名包含该字符串的用户空间应用(用于定位录音机等未确认项)
#   --yaml-snippet      额外打印可直接粘贴到 apps.yaml 的片段(仅打印,不写入)
#   --no-color
#   -h, --help
#
# 退出码:0 成功 | 2 环境/设备问题 | 3 用法错误
# =============================================================================

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERIAL=""
OUT_FILE=""
FILTER=""
YAML_SNIPPET=0

if [ -t 1 ]; then
  C_RED=$'\033[31m'; C_YEL=$'\033[33m'; C_BLD=$'\033[1m'; C_RST=$'\033[0m'
else
  C_RED=''; C_YEL=''; C_BLD=''; C_RST=''
fi

err() { printf '%s%s%s\n' "$C_RED" "[失败] $*" "$C_RST" >&2; }
usage() { sed -n '3,29p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "${1:-}" in
    -s|--device) SERIAL="${2:-}"; shift 2 ;;
    --out) OUT_FILE="${2:-}"; shift 2 ;;
    --filter) FILTER="${2:-}"; shift 2 ;;
    --yaml-snippet) YAML_SNIPPET=1; shift ;;
    --no-color) C_RED=''; C_YEL=''; C_BLD=''; C_RST=''; shift ;;
    -h|--help) usage; exit 0 ;;
    *) err "未知参数: $1"; usage; exit 3 ;;
  esac
done

command -v adb >/dev/null 2>&1 || { err "找不到 adb 命令"; exit 2; }
command -v python3 >/dev/null 2>&1 || { err "找不到 python3(解析 apps.yaml 需要)"; exit 2; }

ADB=(adb)
[ -n "$SERIAL" ] && ADB=(adb -s "$SERIAL")

devices="$(adb devices 2>/dev/null | awk 'NR>1 && $2=="device" {print $1}')"
count="$(printf '%s' "$devices" | grep -c . || true)"
if [ "$count" -eq 0 ]; then
  err "没有检测到已授权的设备(本脚本只读,未做任何修改)。"
  printf '请检查 USB 调试授权后,用  adb devices  确认状态为 device。\n' >&2
  exit 2
fi
if [ "$count" -gt 1 ] && [ -z "$SERIAL" ]; then
  err "检测到多台设备,请用 -s <序列号> 指定:"
  printf '%s\n' "$devices" | sed 's/^/      /' >&2
  exit 2
fi
if [ -n "$SERIAL" ]; then
  DEVICE="$SERIAL"
else
  DEVICE="$(printf '%s' "$devices" | head -1)"
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/gkui-probe.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  else printf 'unknown'
  fi
}

APKSIGNER="${APKSIGNER:-$(command -v apksigner 2>/dev/null || true)}"
if [ -z "$APKSIGNER" ]; then
  sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
  if [ -n "$sdk" ] && [ -d "$sdk/build-tools" ]; then
    # shellcheck disable=SC2012
    bt="$(ls -1 "$sdk/build-tools" 2>/dev/null | sort -V | tail -1)"
    [ -n "$bt" ] && [ -x "$sdk/build-tools/$bt/apksigner" ] && APKSIGNER="$sdk/build-tools/$bt/apksigner"
  fi
fi

TSV="$(bash "$ROOT/build.sh" --emit-tsv-all)" || { err "读取 apps.yaml 失败"; exit 2; }

R=""
r() { R="${R}$*"$'\n'; printf '%s\n' "$*"; }
rh() { R="${R}$*"$'\n'; printf '\n%s%s%s\n' "$C_BLD" "$*" "$C_RST"; }

rh "=== GKUI-Pack 设备事实采集(只读) ==="
r "设备: $DEVICE"
r "时间: $(date '+%Y-%m-%d %H:%M:%S%z')"
r "工具: adb=$(adb version 2>/dev/null | head -1) apksigner=${APKSIGNER:-<未找到>}"
r ""
r "本报告只包含**读操作**的结果;脚本不会修改设备,也不会改写 apps.yaml。"
r "请人工核对后再把值填进 apps.yaml 对应的 TODO。"

# -----------------------------------------------------------------------------
# 1) 已确认条目:设备侧实测值
# -----------------------------------------------------------------------------
rh "--- 1) apps.yaml 中已确认的包名(设备实测) ---"
while IFS=$'\t' read -r APP_ID APP_NAME APP_PKG STOCK_PKG APP_REPO _UP _LIC _SRC _TAG _ASSET _SHA APP_SIGNER APP_IVC _AS _MODE _CONF APP_ENABLED; do
  [ -n "$APP_ID" ] || continue
  r ""
  r "## $APP_ID (enabled=$APP_ENABLED, 来源 $APP_REPO)"

  case "$APP_PKG" in
    ''|TODO*)
      r "  application_id: TODO —— **不得按规律推断**(C1)。"
      r "  请在下方的用户空间应用列表里找到它,核对后再回填。"
      ;;
    *)
      r "  application_id: $APP_PKG"
      paths="$("${ADB[@]}" shell pm path "$APP_PKG" 2>/dev/null | tr -d '\r')"
      if [ -z "$paths" ]; then
        r "  installed: 否(设备上未安装该包名)"
        r "  installed_version_code: none   # 设备上未安装该包名,可直接回填(见 apps.yaml 字段说明)"
      else
        r "  installed: 是"
        printf '%s\n' "$paths" | sed 's/^package:/  path: /' | while IFS= read -r line; do r "$line"; done
        dump="$("${ADB[@]}" shell dumpsys package "$APP_PKG" 2>/dev/null | tr -d '\r')"
        vc="$(printf '%s\n' "$dump" | sed -n 's/.*versionCode=\([0-9][0-9]*\).*/\1/p' | head -1)"
        vn="$(printf '%s\n' "$dump" | sed -n 's/.*versionName=\([^ ]*\).*/\1/p' | head -1)"
        r "  dumpsys package $APP_PKG | grep versionCode → ${vc:-<未取到>}"
        r "  versionName: ${vn:-<未取到>}"
        r "  installed_version_code: ${vc:-TODO}"
        r "  apps.yaml 当前记录: ${APP_IVC}"
        base="$(printf '%s\n' "$paths" | sed -n 's/^package:\(.*\)$/\1/p' | grep 'base\.apk$' | head -1)"
        [ -n "$base" ] || base="$(printf '%s\n' "$paths" | sed -n 's/^package:\(.*\)$/\1/p' | head -1)"
        local_file="$WORK/$APP_ID-device.apk"
        if [ -n "$base" ] && "${ADB[@]}" pull "$base" "$local_file" >/dev/null 2>&1; then
          r "  APK(设备上那一份)sha256: $(sha256_of "$local_file")"
          if [ -n "$APKSIGNER" ]; then
            sig="$("$APKSIGNER" verify --print-certs "$local_file" 2>/dev/null \
              | sed -n 's/.*certificate SHA-256 digest: *//Ip' | head -1 | tr -d ':\r ' | tr '[:upper:]' '[:lower:]')"
            r "  signer_sha256(设备上那一份): ${sig:-<未取到>}"
          else
            r "  signer_sha256: <需要 apksigner:安装 Android build-tools,或设置 APKSIGNER=路径>"
          fi
          rm -f "$local_file"
        fi
        r "  apps.yaml 当前记录 signer_sha256: $APP_SIGNER"
        r "  注意:上面是**设备上正在运行的那一份**APK 的签名。"
        r "        apps.yaml 的 signer_sha256 应当记录**你要发布/安装的那份 APK**的签名,"
        r "        两者可能不同(不同构建的 debug keystore 不同),务必用构建时下载到的 APK 复核。"
      fi
      ;;
  esac

  if [ -n "$STOCK_PKG" ] && [ "$STOCK_PKG" != "TODO" ]; then
    spaths="$("${ADB[@]}" shell pm path "$STOCK_PKG" 2>/dev/null | tr -d '\r')"
    if [ -z "$spaths" ]; then
      r "  stock($STOCK_PKG): 设备上未安装(与 coexist 无冲突)"
    else
      r "  stock($STOCK_PKG) 路径: $(printf '%s' "$spaths" | sed 's/package://' | paste -sd' ' -)"
    fi
  fi
done <<EOF
$TSV
EOF

# -----------------------------------------------------------------------------
# 2) 用户空间应用列表(定位未确认包名的关键证据)
# -----------------------------------------------------------------------------
rh "--- 2) 用户空间(第三方)应用列表: pm list packages -3 ---"
r "用途:GKUI 应用安装在 /data,会出现在这个列表里。"
r "      录音机等尚未确认 application_id 的条目,请在这里**实测**而不是按规律猜。"
r ""
third="$("${ADB[@]}" shell pm list packages -3 2>/dev/null | tr -d '\r' | sed 's/^package://' | sort)"
if [ -n "$FILTER" ]; then
  third="$(printf '%s\n' "$third" | grep -i -- "$FILTER" || true)"
  r "已按 --filter '$FILTER' 过滤,匹配 $(printf '%s' "$third" | grep -c . || true) 个包。"
fi
if [ -z "$third" ]; then
  r "(无匹配或列表为空)"
else
  printf '%s\n' "$third" | while IFS= read -r pkg; do
    [ -n "$pkg" ] || continue
    vc="$("${ADB[@]}" shell dumpsys package "$pkg" 2>/dev/null | tr -d '\r' \
      | sed -n 's/.*versionCode=\([0-9][0-9]*\).*/\1/p' | head -1)"
    r "  $pkg  (versionCode=${vc:-?})"
  done
fi

rh "--- 3) 被禁用的应用列表: pm list packages -d ---"
r "用于确认你是否曾自行禁用 ROM 自带应用(恢复命令:pm enable <包名>)。"
disabled="$("${ADB[@]}" shell pm list packages -d 2>/dev/null | tr -d '\r' | sed 's/^package://' | sort)"
if [ -z "$disabled" ]; then
  r "  (没有被禁用的应用)"
else
  printf '%s\n' "$disabled" | sed 's/^/  /' | while IFS= read -r line; do r "$line"; done
fi

# -----------------------------------------------------------------------------
# 4) 可回填片段
# -----------------------------------------------------------------------------
if [ "$YAML_SNIPPET" = 1 ]; then
  rh "--- 4) 可粘贴片段(请核对后自行填入 apps.yaml) ---"
  r "# 注意:这只是把上面采集到的值排版出来,不代表它是正确值;"
  r "#       尤其 signer_sha256 应当来自**你要安装的那份 APK**,而不是设备上那一份。"
  while IFS=$'\t' read -r APP_ID APP_NAME APP_PKG _STOCK _REPO _UP _LIC _SRC _TAG _ASSET _SHA _SIGNER APP_IVC _AS _MODE _CONF APP_ENABLED; do
    [ -n "$APP_ID" ] || continue
    case "$APP_PKG" in ''|TODO*) continue ;; esac
    vc="$("${ADB[@]}" shell dumpsys package "$APP_PKG" 2>/dev/null | tr -d '\r' \
      | sed -n 's/.*versionCode=\([0-9][0-9]*\).*/\1/p' | head -1)"
    r ""
    r "  # $APP_ID —— $APP_NAME($APP_PKG)"
    if [ -n "$vc" ]; then
      r "      installed_version_code: $vc"
    else
      r "      installed_version_code: none   # dumpsys 未取到 → 设备上未安装该包名"
    fi
    r "      signer_sha256: <用构建时下载到的 APK 执行 apksigner verify --print-certs 取得>"
  done <<EOF
$TSV
EOF
fi

printf '\n%s提醒:%s本次采集没有修改任何设备内容,也没有改写 apps.yaml。\n' "$C_YEL" "$C_RST"
printf '      请把确认过的实测值填入 apps.yaml,然后执行  bash build.sh --check 。\n'

if [ -n "$OUT_FILE" ]; then
  printf '%s\n' "$R" > "$OUT_FILE"
  printf '[信息] 报告已写入: %s\n' "$OUT_FILE"
fi
exit 0
