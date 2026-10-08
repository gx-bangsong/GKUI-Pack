#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
# scripts/uninstall_all.sh —— 通过 adb 卸载 GKUI 应用(逐个确认)
#
# 用途:
#   1) 日常回退:把通过 adb install 装的 GKUI 应用卸掉;
#   2) 刷 systemless 模块前的**前置操作**(硬约束 C8):模块与 /data 中的同包名
#      应用会冲突,必须先卸载用户空间的那一份。
#
# 用法:
#   bash scripts/uninstall_all.sh [选项]
#
# 选项:
#   -s, --device ID   指定设备序列号(连接多台设备时必须指定)
#   --yes             不逐个询问(脚本化场景;默认逐个确认)
#   --keep-data       使用 `adb uninstall -k` 保留应用数据(仅当新版本签名一致时有用)
#   --dry-run         只打印将要执行的命令
#   --no-color
#   -h, --help
#
# 退出码:0 全部成功 | 1 存在失败 | 2 环境/用法问题 | 3 用法错误
#
# 行为边界(硬性):
#   * 只卸载 apps.yaml 中 enabled 的 GKUI 包(即用户在 /data 里装的那一份);
#   * **绝不**触碰 ROM 自带应用:既不卸载也不 enable/disable;
#     若你此前自行禁用过自带应用,恢复命令会以提示形式打印。
# =============================================================================

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERIAL=""
ASSUME_YES=0
KEEP_DATA=0
DRY_RUN=0

if [ -t 1 ]; then
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'; C_BLD=$'\033[1m'; C_RST=$'\033[0m'
else
  C_RED=''; C_GRN=''; C_YEL=''; C_BLD=''; C_RST=''
fi

info() { printf '%s\n' "[信息] $*"; }
warn() { printf '%s%s%s\n' "$C_YEL" "[警告] $*" "$C_RST" >&2; }
err()  { printf '%s%s%s\n' "$C_RED" "[失败] $*" "$C_RST" >&2; }
usage() { sed -n '3,29p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "${1:-}" in
    -s|--device) SERIAL="${2:-}"; shift 2 ;;
    --yes|-y) ASSUME_YES=1; shift ;;
    --keep-data) KEEP_DATA=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --no-color) C_RED=''; C_GRN=''; C_YEL=''; C_BLD=''; C_RST=''; shift ;;
    -h|--help) usage; exit 0 ;;
    *) err "未知参数: $1"; usage; exit 3 ;;
  esac
done

if ! command -v adb >/dev/null 2>&1; then
  err "找不到 adb 命令,无法卸载。"
  exit 2
fi
ADB=(adb)
[ -n "$SERIAL" ] && ADB=(adb -s "$SERIAL")

if [ "$DRY_RUN" = 0 ]; then
  devices="$(adb devices 2>/dev/null | awk 'NR>1 && $2=="device" {print $1}')"
  count="$(printf '%s' "$devices" | grep -c . || true)"
  if [ "$count" -eq 0 ]; then
    err "没有检测到已授权的设备,已安全退出(未做任何修改)。"
    printf '请检查 USB 调试授权后用  adb devices  确认状态为 device。\n' >&2
    exit 2
  fi
  if [ "$count" -gt 1 ] && [ -z "$SERIAL" ]; then
    err "检测到多台设备,请用 -s <序列号> 指定:"
    printf '%s\n' "$devices" | sed 's/^/      /' >&2
    exit 2
  fi
fi

TSV="$(bash "$ROOT/build.sh" --emit-tsv)" || { err "读取 apps.yaml 失败"; exit 2; }
[ -n "$TSV" ] || { err "apps.yaml 中没有 enabled 条目"; exit 2; }

printf '%s=== 卸载通过 adb 安装的 GKUI 应用 ===%s\n' "$C_BLD" "$C_RST"
printf '说明:本脚本只卸载 GKUI 应用(带 .debug/.dev 后缀的包名),\n'
printf '      不会动 ROM 自带应用。\n\n'
warn "卸载会删除这些应用的数据:时钟闹钟、计算器历史、录音机设置。"
info "日历与图库的数据存放在系统 Provider 中,卸载应用不受影响。"
if [ "$KEEP_DATA" = 1 ]; then
  info "已启用 --keep-data:将使用 adb uninstall -k(仅当之后重装的签名一致时数据才有用)"
fi
printf '\n'

if [ "$ASSUME_YES" = 0 ] && [ "$DRY_RUN" = 0 ] && [ ! -t 0 ]; then
  err "当前不是交互式终端:为避免误删,请显式加 --yes 或在终端里运行。"
  exit 2
fi

SUCCESS=0
FAILED=0
SKIPPED=0

while IFS=$'\t' read -r APP_ID _APP_NAME APP_PKG _STOCK_PKG _APP_REPO _APP_UP _APP_LIC \
        _APP_SRC _APP_TAG _APP_ASSET _APP_SHA _APP_SIGNER _APP_IVC _APP_AS _APP_MODE \
        _APP_CONF _APP_ENABLED; do
  [ -n "$APP_ID" ] || continue
  printf '%s--- %s (%s) ---%s\n' "$C_BLD" "$APP_ID" "$APP_PKG" "$C_RST"

  if [ "$DRY_RUN" = 1 ]; then
    printf '      [dry-run] adb %suninstall %s %s\n' \
      "$([ -n "$SERIAL" ] && printf -- '-s %s ' "$SERIAL")" "$([ "$KEEP_DATA" = 1 ] && printf -- '-k ')" "$APP_PKG"
    continue
  fi

  if [ "$ASSUME_YES" = 0 ]; then
    printf '      卸载 %s 及其数据?[y/N] ' "$APP_PKG"
    read -r answer || answer=""
    case "$answer" in
      y|Y|yes|YES) : ;;
      *) printf '      已跳过\n'; SKIPPED=$((SKIPPED + 1)); continue ;;
    esac
  fi

  if [ "$KEEP_DATA" = 1 ]; then
    out="$("${ADB[@]}" uninstall -k "$APP_PKG" 2>&1)"; rc=$?
  else
    out="$("${ADB[@]}" uninstall "$APP_PKG" 2>&1)"; rc=$?
  fi

  if [ $rc -eq 0 ] && printf '%s' "$out" | grep -q 'Success'; then
    printf '      %s✔ 已卸载%s(%s)\n' "$C_GRN" "$C_RST" "$APP_PKG"
    SUCCESS=$((SUCCESS + 1))
  elif printf '%s' "$out" | grep -qi 'not installed'; then
    printf '      未安装,跳过(%s)\n' "$APP_PKG"
    SKIPPED=$((SKIPPED + 1))
  else
    err "$APP_ID 卸载失败,原始输出:"
    printf '%s\n' "$out" | sed 's/^/        /'
    printf '      提示:若失败原因是「DELETE_FAILED_DEVICE_POLICY_MANAGER」或设备管理员,\n'
    printf '            请先在系统设置中撤销该应用的管理员权限。\n'
    FAILED=$((FAILED + 1))
  fi
done <<EOF
$TSV
EOF

printf '\n%s=== 结果 ===%s\n' "$C_BLD" "$C_RST"
printf '成功: %d,跳过: %d,失败: %d\n' "$SUCCESS" "$SKIPPED" "$FAILED"

printf '\n%s以下命令仅供你自行执行(本脚本不会代做):%s\n' "$C_YEL" "$C_RST"
printf '  若你曾自行禁用过 ROM 自带应用,需要自行恢复:\n'
while IFS=$'\t' read -r APP_ID _APP_NAME APP_PKG STOCK_PKG _REST; do
  [ -n "$APP_ID" ] || continue
  [ -n "$STOCK_PKG" ] || continue
  printf '        adb shell pm enable %s\n' "$STOCK_PKG"
done <<EOF
$TSV
EOF
printf '  卸载后如需重新安装,见 README 的「主方案:adb 免 root 安装」。\n'

[ "$FAILED" -gt 0 ] && exit 1
exit 0
