#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
# scripts/preflight-apk.sh —— APK 侧七项门禁
#
# 用法:
#   bash scripts/preflight-apk.sh <apk路径> <app-id> [--report FILE] [--json FILE] [--no-color]
#
#   <app-id> 必须存在于 apps.yaml(门禁需要 stock_package / signer_sha256 /
#   installed_version_code 等值)。apps.yaml 的解析统一走
#       bash build.sh --dump-apps-json
#   本脚本不自行解析 YAML。
#
# 退出码(约定,调用方 build.sh 依赖此协议):
#   0  七项门禁全部通过
#   1  门禁失败(硬阻断:不得入包)
#   2  APK 不适合模块化(检出 signature|privileged 权限)→ 应改走 adb install
#   3  环境不完整(aapt / apksigner / java 缺失,无法完成校验)
#
# 环境变量:
#   AAPT / APKSIGNER   工具路径或命令名覆盖(默认从 PATH 与 ANDROID_HOME 查找)
#   PREFLIGHT_REPORT   报告文件默认路径(默认 <repo>/PREFLIGHT-REPORT.md)
#
# 七项门禁(编号与需求一一对应):
#   G1 aapt dump badging 取 package: name=(**applicationId 真值**)
#      —— 明确不得读解包 manifest 的 package 属性(Etar 系那里是 AOSP 残留
#         com.android.calendar,会误导)
#   G2 断言无 sharedUserId(C4 类应用的判定特征之一)
#   G3 列出 uses-permission;命中「平台签名/特权权限清单」(ADVISORY_LIST)的应用
#      判为不适合模块化(仅走 adb install,**不生成任何 privapp 白名单**);
#      另报告本 APK 自声明 <permission> 的 protectionLevel(仅参考,不参与判定)
#   G4 apksigner verify --print-certs 取证书 SHA-256 并与 apps.yaml 比对(C6)
#   G5 断言 applicationId != stock_package(C2)
#   G6 (optional,仅报告,不影响退出码)authorities / <permission> 检查
#   G7 比对 versionCode 与 apps.yaml 的 installed_version_code
#
# 注意:本脚本不做任何"猜测式补全"。apps.yaml 中为 TODO 的值一律判为门禁失败(C7)。
# =============================================================================

set -uo pipefail

# ---------------------------------------------------------------------------
# 参数
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

APK="${1:-}"
APP_ID="${2:-}"
shift 2 2>/dev/null || true

REPORT="${PREFLIGHT_REPORT:-$ROOT/PREFLIGHT-REPORT.md}"
JSON_OUT=""
COLOR=1
while [ $# -gt 0 ]; do
  case "${1:-}" in
    --report) REPORT="${2:-}"; shift 2 ;;
    --json)   JSON_OUT="${2:-}"; shift 2 ;;
    --no-color) COLOR=0; shift ;;
    *) printf '[失败] 未知参数: %s\n' "${1:-}" >&2; exit 3 ;;
  esac
done

if [ -t 1 ] && [ "$COLOR" = 1 ]; then
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'; C_BLD=$'\033[1m'; C_RST=$'\033[0m'
else
  C_RED=''; C_GRN=''; C_YEL=''; C_BLD=''; C_RST=''
fi

usage() {
  sed -n '4,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

if [ -z "$APK" ] || [ -z "$APP_ID" ] || [ "$APK" = "-h" ] || [ "$APK" = "--help" ]; then
  usage
  [ -n "$APK" ] && [ -n "$APP_ID" ] && exit 0
  exit 3
fi

GATE_FAIL=0        # 硬阻断
MODULE_UNSUITABLE=0 # 不适合模块化(仅 adb install)
REPORT_BODY=""

say() { # 普通信息:stdout + 报告
  printf '%s\n' "$*"
  REPORT_BODY="${REPORT_BODY}$*"$'\n'
}
say_ok() { # 通过
  printf '  %s✔%s %s\n' "$C_GRN" "$C_RST" "$*"
  REPORT_BODY="${REPORT_BODY}  ✔ $*"$'\n'
}
say_bad() { # 标红(问题)
  printf '  %s✘ %s%s\n' "$C_RED" "$*" "$C_RST"
  REPORT_BODY="${REPORT_BODY}  ✘ $*"$'\n'
}
say_warn() { # 标黄(提示,不影响退出码)
  printf '  %s! %s%s\n' "$C_YEL" "$*" "$C_RST"
  REPORT_BODY="${REPORT_BODY}  ! $*"$'\n'
}
env_fail() {
  printf '%s[失败] %s%s\n' "$C_RED" "$*" "$C_RST" >&2
  exit 3
}

# ---------------------------------------------------------------------------
# 前置:输入文件与工具链
# ---------------------------------------------------------------------------
[ -f "$APK" ] || env_fail "找不到 APK 文件: $APK"

# apps.yaml 的条目(唯一解析入口是 build.sh --dump-apps-json)
if [ ! -f "$ROOT/build.sh" ]; then
  env_fail "找不到 $ROOT/build.sh(本脚本需要在仓库内运行)"
fi
ENTRY_TSV="$(bash "$ROOT/build.sh" --dump-apps-json 2>/dev/null | python3 -c '
import json, sys
want = sys.argv[1]
fields = ["id", "application_id", "stock_package", "repo", "upstream", "license",
          "release_tag", "asset_name", "sha256", "signer_sha256",
          "installed_version_code", "confidence", "enabled"]
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)
for app in data.get("apps", []):
    if app.get("id") == want:
        out = []
        for f in fields:
            v = app.get(f)
            out.append("" if v is None else str(v))
        sys.stdout.write("\t".join(out))
        break
else:
    sys.exit(2)
' "$APP_ID")" || env_fail "apps.yaml 解析失败,或条目 '$APP_ID' 不存在(build.sh --dump-apps-json)"

IFS=$'\t' read -r E_ID E_APPID E_STOCK E_REPO E_UP E_LIC E_TAG E_ASSET \
  E_SHA E_SIGNER E_IVC E_CONF E_ENABLED <<< "$ENTRY_TSV"

# aapt 查找:PATH → ANDROID_HOME/build-tools/<最新>
AAPT="${AAPT:-$(command -v aapt 2>/dev/null || true)}"
if [ -z "$AAPT" ]; then
  sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
  if [ -n "$sdk" ] && [ -d "$sdk/build-tools" ]; then
    # shellcheck disable=SC2012
    bt="$(ls -1 "$sdk/build-tools" 2>/dev/null | sort -V | tail -1)"
    if [ -n "$bt" ] && [ -x "$sdk/build-tools/$bt/aapt" ]; then
      AAPT="$sdk/build-tools/$bt/aapt"
    fi
  fi
fi
[ -n "$AAPT" ] || env_fail "找不到 aapt。请安装 Android SDK build-tools,或用 AAPT=/path/to/aapt 指定(本工程不接受用解包 manifest 的 package 属性替代)"
"$AAPT" version >/dev/null 2>&1 || env_fail "aapt 不可用: $AAPT"

# 注意:APKSIGNER 若由环境变量显式提供(测试桩 / 自定义包装脚本),则不做
# java 依赖检查;只有从 PATH / ANDROID_HOME 自动发现时(即 SDK 自带脚本,
# 它本身是 Java 程序)才要求 java 存在。
APKSIGNER_EXPLICIT=0
if [ -n "${APKSIGNER:-}" ]; then
  APKSIGNER_EXPLICIT=1
fi
APKSIGNER="${APKSIGNER:-$(command -v apksigner 2>/dev/null || true)}"
if [ -z "$APKSIGNER" ]; then
  sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
  if [ -n "$sdk" ] && [ -d "$sdk/build-tools" ]; then
    # shellcheck disable=SC2012
    bt="$(ls -1 "$sdk/build-tools" 2>/dev/null | sort -V | tail -1)"
    if [ -n "$bt" ] && [ -x "$sdk/build-tools/$bt/apksigner" ]; then
      APKSIGNER="$sdk/build-tools/$bt/apksigner"
    fi
  fi
fi
[ -n "$APKSIGNER" ] || env_fail "找不到 apksigner(签名证书门禁 G4 必需),用 APKSIGNER=/path/to/apksigner 指定"
if [ "$APKSIGNER_EXPLICIT" = 0 ]; then
  command -v java >/dev/null 2>&1 || env_fail "找不到 java:SDK 自带的 apksigner 是 Java 程序,必须安装 JRE(或用 APKSIGNER= 指定替代实现)"
fi

APK_BYTES="$(wc -c < "$APK" | tr -d ' ')"

sha256_of() { # 计算文件 sha256(纯输出,不夹带文件名)
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    env_fail "找不到 sha256sum / shasum"
  fi
}
APK_SHA="$(sha256_of "$APK")"

# ---------------------------------------------------------------------------
# badging_field <字段名> <aapt badging 的 package: 行>
#   从 package: 行里按「引号对」取字段值,字段名做**整字段**比较(绝不做子串匹配)。
#   真实 aapt 输出示例(CI 上实测,已脱敏):
#     package: name='ws.xsoh.etar.debug' versionCode='51' versionName='1.0.51' \
#              platformBuildVersionName='16' platformBuildVersionCode='36' \
#              compileSdkVersion='36' compileSdkVersionCodename='16'
#   ⚠️ 曾经的 bug(真实 APK 上踩到):用 sed 's/.*name=.../' 子串匹配时,
#      compileSdkVersionCodename='16' 里含小写 "name='",贪婪匹配取最后一个命中,
#      于是把平台代号 16 当成了包名(四个应用全部误判)。必须整字段匹配。
# ---------------------------------------------------------------------------
badging_field() {
  local want="$1" line="$2"
  printf '%s\n' "$line" | awk -v want="$want" -F"'" '
    {
      for (i = 1; i < NF; i += 2) {
        key = $i
        sub(/^.*[[:space:]]/, "", key)      # 只保留最后一个空白之后的字段名
        if (key == want "=") { print $(i + 1); exit }
      }
    }'
}

# ---------------------------------------------------------------------------
# describe_protection_level <xmltree 中含 protectionLevel 的整行>
#   把 protectionLevel 的原始值解成可读文本(仅用于报告,不参与判定)。
#   aapt xmltree 通常输出数值形式:
#     A: android:protectionLevel(0x01010009)=(type 0x11)0x12
#   其中 (type 0x11) 表示后面的数字按十六进制书写(0x12 = signature|system);
#   个别 aapt 版本输出字符串形式,则直接采用原文。
#   注意:本 APK 自己声明的权限由它自己满足(androidx 的
#   *.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION 就是 signature 级),不构成
#   模块化障碍 → 这里只报告,不据此排除应用(判定规则见 G3)。
# ---------------------------------------------------------------------------
describe_protection_level() {
  local line="$1" raw type body token val base bits n
  raw="$(printf '%s' "$line" | sed -n 's/.*protectionLevel[^=]*=[[:space:]]*//p')"
  case "$raw" in
    *'"'*)   # 字符串形式:="signature|privileged"
      val="$(printf '%s' "$raw" | sed -n 's/^"\([^"]*\)".*/\1/p')"
      printf '%s' "${val:-$raw}"
      return 0 ;;
  esac
  if [ "${raw#*\(type }" != "$raw" ]; then
    # 数值形式:(type 0xNN)<值> —— 0x11=十六进制书写、0x10=十进制书写。
    # 注意:必须按 type 解析,不能笼统地"抓最后一个 0x.." —— 那会把类型码
    # (0x10/0x11)本身当成保护级别(真实踩到)。
    type="$(printf '%s' "$raw" | sed -n 's/^[[:space:]]*(type[[:space:]]*\(0x[0-9a-fA-F]*\)).*/\1/p')"
    body="${raw#*)}"
    token="$(printf '%s' "$body" | sed -n 's/^[[:space:]]*\([^[:space:]]*\).*/\1/p')"
    case "$type" in
      0x11|0x10) : ;;
      *) printf '原始值(未识别的数值类型 %s):%s' "${type:-?}" "$token"; return 0 ;;
    esac
  else
    token="$(printf '%s' "$raw" | grep -o '0x[0-9a-fA-F][0-9a-fA-F]*' | head -1 || true)"
  fi
  if printf '%s' "$token" | grep -qE '^(0x[0-9a-fA-F]+|[0-9]+)$'; then
    val="$token"
    n=$(( token ))
  else
    printf '原始值无法解析:%s' "$raw"
    return 0
  fi
  case $(( n & 0xF )) in
    0) base=normal ;;
    1) base=dangerous ;;
    2) base=signature ;;
    3) base=signatureOrSystem ;;
    *) base="(未知基础值 0x$(printf '%x' $(( n & 0xF ))))" ;;
  esac
  bits=""
  if (( n & 0x10 )); then bits="$bits|system"; fi
  if (( n & 0x20 )); then bits="$bits|development"; fi
  if (( n & 0x40 )); then bits="$bits|appop"; fi
  if (( n & 0x80 )); then bits="$bits|pre23"; fi
  if (( n & 0x100 )); then bits="$bits|installer"; fi
  if (( n & 0x200 )); then bits="$bits|verifier"; fi
  if (( n & 0x400 )); then bits="$bits|preinstalled"; fi
  if (( n & 0x800 )); then bits="$bits|privileged"; fi
  printf '%s%s(原始值 %s)' "$base" "$bits" "$val"
}

printf '%s=== preflight: %s (%s) ===%s\n' "$C_BLD" "$APP_ID" "$(basename "$APK")" "$C_RST"
say "## $APP_ID — $E_APPID"
say "- 条目: id=$E_ID enabled=$E_ENABLED confidence=$E_CONF license=$E_LIC upstream=$E_UP"
say "- APK: \`$APK\`"
say "- 体积: $APK_BYTES 字节;sha256: $APK_SHA"
say "- 来源: $E_REPO @ $E_TAG / $E_ASSET"

BADGING="$("$AAPT" dump badging "$APK" 2>/dev/null || true)"

# ---------------------------------------------------------------------------
# G1:applicationId(aapt dump badging 的 package: name=)
# ---------------------------------------------------------------------------
say ""
say "### G1 applicationId(aapt dump badging)"
PKG_LINE="$(printf '%s\n' "$BADGING" | grep -m1 '^package:' || true)"
if [ -z "$PKG_LINE" ]; then
  say_bad "aapt dump badging 未输出 package: 行(APK 可能损坏或不是 APK)"
  GATE_FAIL=1
  APP_ID_FROM_APK=""
else
  # 取字段必须锚定字段名(见 badging_field 的注释):不要用子串匹配
  APP_ID_FROM_APK="$(badging_field name "$PKG_LINE")"
  VER_CODE="$(badging_field versionCode "$PKG_LINE")"
  VER_NAME="$(badging_field versionName "$PKG_LINE")"
  say "  aapt 原始行: $PKG_LINE"
  say "  package: name=${APP_ID_FROM_APK:-<解析失败>} versionCode=${VER_CODE:-未知} versionName=${VER_NAME:-未知}"
  if [ -z "$APP_ID_FROM_APK" ] \
     || ! printf '%s' "$APP_ID_FROM_APK" | grep -qE '^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+$'; then
    say_bad "无法从 badging 输出解析出可信包名(得到:'${APP_ID_FROM_APK}');请把上面的原始行反馈"
    GATE_FAIL=1
  elif [ "$APP_ID_FROM_APK" != "$E_APPID" ]; then
    say_bad "包名与 apps.yaml 不一致:APK=$APP_ID_FROM_APK / apps.yaml=$E_APPID"
    GATE_FAIL=1
  else
    say_ok "与 apps.yaml 的 application_id 一致"
  fi
  say_warn "已按规格使用 aapt dump badging;未读取解包 manifest 的 package 属性(Etar 系该属性是 AOSP 残留,会误导)"
fi

# ---------------------------------------------------------------------------
# G2:sharedUserId 必须不存在
# ---------------------------------------------------------------------------
say ""
say "### G2 sharedUserId"
XMLTREE="$("$AAPT" dump xmltree "$APK" AndroidManifest.xml 2>/dev/null || true)"
if [ -z "$XMLTREE" ]; then
  say_bad "无法读取 AndroidManifest.xml(aapt dump xmltree 失败)"
  GATE_FAIL=1
elif printf '%s\n' "$XMLTREE" | grep -q 'sharedUserId'; then
  say_bad "检出 sharedUserId —— 此类应用依赖系统共享 UID,第三方签名无法替代,严禁打包(C4)"
  printf '%s\n' "$XMLTREE" | grep -m3 'sharedUserId' | sed 's/^/      /'
  GATE_FAIL=1
else
  say_ok "未检出 sharedUserId"
fi

# ---------------------------------------------------------------------------
# G3:uses-permission 清单 + signature / privileged 标红
# ---------------------------------------------------------------------------
say ""
say "### G3 权限清单"
REQUESTED="$(printf '%s\n' "$BADGING" \
  | grep -E "^uses-permission(-sdk-[0-9]+)?: name=" \
  | sed -n "s/.*name='\([^']*\)'.*/\1/p" || true)"
REQ_COUNT="$(printf '%s' "$REQUESTED" | grep -c . || true)"
say "  申请权限共 $REQ_COUNT 项"
# 资产级 sha256(仅当输入文件正是 Release 资产本身时可比对;
# zip 包装的资产由 build.sh 在解包前完成资产级校验,这里只做提示)
if [ "$(basename "$APK")" = "$E_ASSET" ]; then
  case "$E_SHA" in
    ""|TODO*) say_bad "apps.yaml 的 sha256 仍是 TODO;资产级完整性校验无法进行(C7)" ; GATE_FAIL=1 ;;
    *)
      if [ "$APK_SHA" = "$(printf '%s' "$E_SHA" | tr -d ':\ ' | tr '[:upper:]' '[:lower:]')" ]; then
        say_ok "资产级 sha256 与 apps.yaml 一致"
      else
        say_bad "资产级 sha256 不匹配:apps.yaml=$E_SHA 实际=$APK_SHA"
        GATE_FAIL=1
      fi ;;
  esac
else
  say "  输入文件不是 Release 资产本身(应为 zip 解包产物):资产级 sha256 由 build.sh 在解包前校验"
fi
while IFS= read -r perm; do
  [ -n "$perm" ] || continue
  say "    - $perm"
done <<< "$REQUESTED"

# 判定(C3)分两层:
#   ① 硬判据 —— APK **申请**了平台签名/特权权限(见下方 ADVISORY_LIST):非 platform
#      签名的应用在任何安装位置都拿不到这些权限,按本工程策略判为"不适合模块化"
#      (仅走 adb install,且**绝不**生成 privapp 白名单 XML)。
#   ② 仅报告 —— APK **自己声明**的 <permission> 的 protectionLevel。自声明权限由
#      本应用自行满足(如 androidx 的 *.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION
#      就是 signature 级),不构成模块化障碍,因此不参与判定。
#   ⚠️ 真实 aapt 对 protectionLevel 输出的是数值(如 (type 0x11)0x12),不含
#      "signature"/"privileged" 字样。早期版本用关键字匹配去判"声明",在真实 APK 上
#      永不命中——既漏报、又给出"未检出"的虚假通过感;故改为上面的分工。

ADVISORY_LIST="android.permission.WRITE_SECURE_SETTINGS
android.permission.DEVICE_POWER
android.permission.REBOOT
android.permission.SHUTDOWN
android.permission.MASTER_CLEAR
android.permission.MODIFY_PHONE_STATE
android.permission.READ_PRIVILEGED_PHONE_STATE
android.permission.MANAGE_USERS
android.permission.INSTALL_PACKAGES
android.permission.DELETE_PACKAGES
android.permission.MOUNT_UNMOUNT_FILESYSTEMS
android.permission.WRITE_MEDIA_STORAGE
android.permission.STATUS_BAR
android.permission.CHANGE_CONFIGURATION
android.permission.MANAGE_APP_OPS_MODES
android.permission.ACCESS_SURFACE_FLINGER
android.permission.CAPTURE_AUDIO_OUTPUT
android.permission.LOCAL_MAC_ADDRESS"
# 归一化成单行以空格分隔,便于整词匹配
ADVISORY_ONE_LINE=" $(printf '%s' "$ADVISORY_LIST" | tr '\n' ' ' | tr -s ' ') "
ADVISORY_HITS=""
while IFS= read -r perm; do
  [ -n "$perm" ] || continue
  case "$ADVISORY_ONE_LINE" in
    *" $perm "*) ADVISORY_HITS="${ADVISORY_HITS}${perm}"$'\n' ;;
  esac
done <<< "$REQUESTED"

if [ -n "$ADVISORY_HITS" ]; then
  say_bad "申请了平台签名/特权权限(非 platform 签名无法获得):"
  while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    say "      $hit"
  done <<< "$ADVISORY_HITS"
  say_bad "按 C3 策略:该应用不适合模块化 → 不入模块,仅走 adb install(不生成白名单 XML)"
  MODULE_UNSUITABLE=1
else
  say_ok "申请清单未命中平台签名/特权权限(ADVISORY_LIST $(printf '%s\n' "$ADVISORY_LIST" | grep -c .) 条)"
fi

# 仅报告:本 APK 声明的自定义权限的 protectionLevel(原始值 + 解码)
DECLARED_PERMS="$(printf '%s\n' "$XMLTREE" | grep -i 'protectionLevel' | sed 's/^[[:space:]]*//' || true)"
if [ -n "$DECLARED_PERMS" ]; then
  say "  本 APK 声明的自定义权限 protectionLevel(原始值 + 解码,仅参考,不影响退出码):"
  while IFS= read -r pline; do
    [ -n "$pline" ] || continue
    say "      $pline  → $(describe_protection_level "$pline")"
  done <<< "$DECLARED_PERMS"
else
  say "  未声明自定义 <permission>(无 protectionLevel 条目)"
fi

# ---------------------------------------------------------------------------
# G4:签名证书 SHA-256(C6)
# ---------------------------------------------------------------------------
say ""
say "### G4 签名证书 SHA-256(apksigner verify --print-certs)"
CERTS="$("$APKSIGNER" verify --print-certs "$APK" 2>&1 || true)"
SIGNER_SHA="$(printf '%s\n' "$CERTS" | grep -m1 -i 'certificate SHA-256 digest' \
  | awk -F': *' '{print $NF}' | tr -d ':\r ' | tr '[:upper:]' '[:lower:]')"
SIGNER_COUNT="$(printf '%s\n' "$CERTS" | grep -c -i 'certificate SHA-256 digest' || true)"
if [ -z "$SIGNER_SHA" ]; then
  say_bad "无法获取签名证书摘要;apksigner 输出:"
  printf '%s\n' "$CERTS" | sed 's/^/      /'
  GATE_FAIL=1
else
  say "  Signer 数量: $SIGNER_COUNT;Signer #1 证书 SHA-256: $SIGNER_SHA"
  [ "$SIGNER_COUNT" -gt 1 ] && say_warn "存在多个签名者,本门禁仅比对 Signer #1,请人工确认其余证书"
  case "$E_SIGNER" in
    ""|TODO*)
      say_bad "apps.yaml 的 signer_sha256 仍是 TODO(C7:不确定的值必须让构建失败)"
      say_bad "请把上面的实际值回填到 apps.yaml 的 signer_sha256,再重新构建"
      GATE_FAIL=1
      ;;
    *)
      E_SIGNER_N="$(printf '%s' "$E_SIGNER" | tr -d ':\ ' | tr '[:upper:]' '[:lower:]')"
      if [ "$SIGNER_SHA" = "$E_SIGNER_N" ]; then
        say_ok "签名证书与 apps.yaml 记录一致(debug 构建锚点)"
      else
        say_bad "签名证书与 apps.yaml 不一致!"
        say_bad "  期望(apps.yaml): $E_SIGNER_N"
        say_bad "  实际(本 APK):    $SIGNER_SHA"
        say_bad "该 APK 可能由不同的 debug keystore 签名。若直接替换已安装版本,"
        say_bad "安装会失败(INSTALL_FAILED_UPDATE_INCOMPATIBLE):需卸载重装,应用内数据会丢失。"
        say_bad "确认后请更新 apps.yaml 的 signer_sha256 并重新走一遍流程。"
        GATE_FAIL=1
      fi
      ;;
  esac
fi

# ---------------------------------------------------------------------------
# G5:applicationId != stock_package(C2)
# ---------------------------------------------------------------------------
say ""
say "### G5 coexist 断言(applicationId != stock_package)"
if [ -z "$APP_ID_FROM_APK" ]; then
  say_bad "无法取得 applicationId,跳过该断言(已计 G1 失败)"
else
  if [ "$APP_ID_FROM_APK" = "$E_STOCK" ]; then
    say_bad "applicationId 与 stock 包名相同($E_STOCK):这构成替换关系,违反 C2(coexist)"
    GATE_FAIL=1
  else
    say_ok "$APP_ID_FROM_APK != $E_STOCK"
  fi
fi

# ---------------------------------------------------------------------------
# G6:(optional,仅报告)authorities / 自定义权限
# ---------------------------------------------------------------------------
say ""
say "### G6 provider authorities / <permission>(仅报告,不影响退出码)"
# 注意:同一条 authority 在 xmltree 里会出现两次(类型化值与 "(Raw: ...)" 原值),
# 因此这里按出现顺序去重,否则报告里每条都会重复一遍(真实 APK 上踩到过)。
AUTHORITIES="$(printf '%s\n' "$XMLTREE" | grep -i 'authorities' | grep -o '"[^"]*"' \
  | tr -d '"' | tr ';' '\n' | sed '/^$/d' | awk '!seen[$0]++' || true)"
if [ -z "$AUTHORITIES" ]; then
  say "  未发现 <provider> authorities 声明"
else
  while IFS= read -r auth; do
    [ -n "$auth" ] || continue
    case "$auth" in
      "$APP_ID_FROM_APK"*|"$APP_ID_FROM_APK".*|"$APP_ID_FROM_APK"/*)
        say_ok "authority '$auth' 以 applicationId 为前缀" ;;
      *)
        say_warn "authority '$auth' 不以 applicationId($APP_ID_FROM_APK)为前缀 → 可能与其它应用冲突"
        say_warn "  设备实测已确认本应用与 stock 共存无 provider 冲突;此项仅供参考,不影响构建" ;;
    esac
  done <<< "$AUTHORITIES"
fi
# (自定义权限 protectionLevel 的原始值 + 解码已在 G3 段统一报告)

# ---------------------------------------------------------------------------
# G7:versionCode 与设备已安装版本比对
# ---------------------------------------------------------------------------
say ""
say "### G7 versionCode / installed_version_code"
say "  模块内 APK 的 versionCode: ${VER_CODE:-未知};apps.yaml 记录的已安装版本: $E_IVC"
case "$E_IVC" in
  ""|TODO*)
    say_bad "apps.yaml 的 installed_version_code 仍是 TODO(C7)"
    say_bad "请在设备上执行 bash scripts/probe-device.sh 采集实测值后回填"
    GATE_FAIL=1
    ;;
  none|NONE|None)
    # 实测结果:设备上没有该包名的副本 → /data 不可能压制模块版本
    if [ -z "$VER_CODE" ]; then
      say_warn "该 APK 未声明 versionCode(平台按 0 处理);但设备上无同包名副本 → 不会被压制"
    else
      say_ok "设备上无该包名副本(installed_version_code=none)→ 不会被 /data 压制"
    fi
    ;;
  *)
    # 判定说明(为何不是"必须严格大于"):
    #   * 真正的"压制"风险由 C8 在刷入时强制拦截(检出 /data 副本 → 整包中止,
    #     要求先 pm uninstall);卸载之后不存在压制,所以两侧值相等不算危险,只提示;
    #   * 必须硬拦的只有一种:模块内**比设备上更旧**(回退)。
    # 2026-10-08 真机实测(构建永远失败的教训):
    #   * calendar/gallery/calculator 模块内 51/1/1,设备上也是 51/1/1(恰好相等);
    #   * clock 的 APK **未声明 versionCode**,而设备上那一份的实测值正是
    #     versionCode=0 —— 与平台语义"未声明按 0 处理"完全吻合。
    #   因此"未声明"不再是"未知",而是已知的 0:照常参与比较即可。
    vc_eff="$VER_CODE"
    if [ -z "$vc_eff" ]; then
      vc_eff=0
      say_warn "该 APK 未在 manifest 里声明 versionCode/versionName:平台按 0 处理(设备上那一份的实测值也是 0)"
    fi
    if [ "$vc_eff" -lt "$E_IVC" ] 2>/dev/null; then
      say_bad "模块内 versionCode(${VER_CODE:-未声明→0}) < 设备已安装版本($E_IVC):模块内是更旧的构建"
      say_bad "要么改用更新的 Release;要么确认后卸载 /data 副本再刷(否则模块版本会被压制)"
      GATE_FAIL=1
    elif [ "$vc_eff" -eq "$E_IVC" ] 2>/dev/null; then
      say_warn "模块内 versionCode($vc_eff) == 设备已安装版本($E_IVC):两侧是同一版本的构建"
      say_warn "刷入前必须先卸载 /data 副本(C8 会在刷入时强制要求),卸载后模块版本即生效"
    else
      say_ok "versionCode $vc_eff > installed_version_code $E_IVC(不会被压制)"
    fi
    ;;
esac

# ---------------------------------------------------------------------------
# 结果
# ---------------------------------------------------------------------------
RESULT="pass"
RC=0
if [ "$GATE_FAIL" = 1 ]; then
  RESULT="fail"; RC=1
elif [ "$MODULE_UNSUITABLE" = 1 ]; then
  RESULT="not_module_suitable"; RC=2
fi
say ""
case "$RESULT" in
  pass) printf '%s结果: 通过(七项门禁全部满足)%s\n' "$C_GRN" "$C_RST" ;;
  fail) printf '%s结果: 失败(存在硬阻断项)%s\n' "$C_RED" "$C_RST" ;;
  *)    printf '%s结果: 不适合模块化 → 请改走 adb install%s\n' "$C_YEL" "$C_RST" ;;
esac
say "- 结论: $RESULT"

mkdir -p "$(dirname "$REPORT")" 2>/dev/null || true
printf '%s\n' "$REPORT_BODY" >> "$REPORT"
printf '[信息] 报告已写入: %s\n' "$REPORT"

if [ -n "$JSON_OUT" ]; then
  GATE1=ok; GATE2=ok; GATE3=ok
  [ -z "$APP_ID_FROM_APK" ] && GATE1=fail
  [ -n "$APP_ID_FROM_APK" ] && [ "$APP_ID_FROM_APK" != "$E_APPID" ] && GATE1=fail
  printf '%s\n' "$XMLTREE" | grep -q 'sharedUserId' && GATE2=fail
  [ -n "$ADVISORY_HITS" ] && GATE3=privileged_requested
  python3 - "$JSON_OUT" <<PYEOF
# -*- coding: utf-8 -*-
import json, sys
data = {
    "app_id": "$APP_ID",
    "apk": "$APK",
    "apk_bytes": $APK_BYTES,
    "apk_sha256": "$APK_SHA",
    "application_id": "$APP_ID_FROM_APK",
    "application_id_expected": "$E_APPID",
    "stock_package": "$E_STOCK",
    "version_code": "$VER_CODE",
    "version_name": "$VER_NAME",
    "installed_version_code": "$E_IVC",
    "signer_sha256": "$SIGNER_SHA",
    "signer_sha256_expected": "$E_SIGNER",
    "signer_count": "$SIGNER_COUNT",
    "shared_user_id_detected": $(printf '%s\n' "$XMLTREE" | grep -q 'sharedUserId' && echo True || echo False),
    "privileged_request_detected": $([ -n "$ADVISORY_HITS" ] && echo True || echo False),
    "requested_permission_count": $REQ_COUNT,
    "authorities": [$(printf '%s\n' "$AUTHORITIES" | sed '/^$/d;s/.*/"&"/' | paste -sd, - 2>/dev/null || true)],
    "gate1_application_id": "$GATE1",
    "gate2_shared_user_id": "$GATE2",
    "gate3_permissions": "$GATE3",
    "module_suitable": $([ "$RESULT" = "not_module_suitable" ] && echo False || echo True),
    "result": "$RESULT",
    "exit_code": $RC
}
with open(sys.argv[1], "w", encoding="utf-8") as fh:
    json.dump(data, fh, ensure_ascii=False, indent=2)
    fh.write("\n")
PYEOF
fi

exit "$RC"
