#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
# tests/test_build.sh —— 离线全流程测试
#
# 目标:在没有网络、没有设备、没有 Android SDK 的前提下,把整个工程跑通:
#   * 用**桩工具**(stub aapt / apksigner)与**假 APK**(普通文本文件)驱动
#     build.sh 与 scripts/preflight-apk.sh 的完整流程;
#   * 用**桩 pm** 驱动渲染后的 module/customize.sh,验证 C8 冲突检查;
#   * 验证 bootloop 自救(post-fs-data.sh / service.sh)的标记生命周期;
#   * 验证硬约束的验收项(仓库内无 APK、无 replace、module/ 无特权应用目录等)。
#
# 全程只在 mktemp 出来的临时目录里操作,**绝不写脏工作区**。
#
# 用法:bash tests/test_build.sh [-v]
# =============================================================================

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERBOSE=0
[ "${1:-}" = "-v" ] && VERBOSE=1

PASS=0
FAIL=0

if [ -t 1 ]; then
  C_GRN=$'\033[32m'; C_RED=$'\033[31m'; C_BLD=$'\033[1m'; C_RST=$'\033[0m'
else
  C_GRN=''; C_RED=''; C_BLD=''; C_RST=''
fi

ok()   { PASS=$((PASS + 1)); printf '  %s✔%s %s\n' "$C_GRN" "$C_RST" "$*"; }
bad()  { FAIL=$((FAIL + 1)); printf '  %s✘%s %s\n' "$C_RED" "$C_RST" "$*"; }
head1() { printf '\n%s=== %s ===%s\n' "$C_BLD" "$*" "$C_RST"; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/gkui-pack-test.XXXXXX")"
# shellcheck disable=SC2329  # 由 trap 间接调用
cleanup() {
  if [ "$VERBOSE" = 1 ]; then
    printf '\n[调试] 临时目录保留: %s\n' "$WORK"
  else
    rm -rf "$WORK"
  fi
}
trap cleanup EXIT

# -----------------------------------------------------------------------------
# 0) 准备工作区:复制被测文件(不复制 .git / dist)
# -----------------------------------------------------------------------------
mkdir -p "$WORK/repo" "$WORK/bin" "$WORK/apks"
cp "$REPO_ROOT/build.sh" "$WORK/repo/build.sh"
cp "$REPO_ROOT/apps.yaml" "$WORK/repo/apps.yaml"
cp -a "$REPO_ROOT/scripts" "$WORK/repo/scripts"
cp -a "$REPO_ROOT/module" "$WORK/repo/module"
cp -a "$REPO_ROOT/module-priv" "$WORK/repo/module-priv"
cp -a "$REPO_ROOT/device" "$WORK/repo/device"
# 默认测试工作区保持源码回退(TEST)模式:v0.0.5 入库的真机权限表只在专门的
# 设备模式测试(12d)里按需放入,避免改变既有 source/TEST 路径的断言。
rm -f "$WORK/repo/device/framework-permissions.txt"
chmod +x "$WORK/repo/scripts/"*.sh "$WORK/repo/scripts/"*.py "$WORK/repo/build.sh"

# 10 个诊断包名(5 GKUI + 5 stock),service.sh 的 [2]/[6] 两节共用
DIAG_GKUI_PKGS="ws.xsoh.etar.debug org.lineageos.glimpse.dev com.android.calculator2.dev com.android.deskclock.dev org.lineageos.recorder.dev"
DIAG_STOCK_PKGS="org.lineageos.etar org.lineageos.glimpse com.android.calculator2 com.android.deskclock org.lineageos.recorder"

# -----------------------------------------------------------------------------
# 1) 桩工具:aapt / apksigner / pm
#
# 假 APK 的文件内容约定(仅测试用):
#   第 1 行 = 包名
#   第 2 行 = versionCode
#   第 3 行 = 签名证书 SHA-256(64 位小写 hex)
#   第 4 行起 = aapt badging 的附加行(# 开头的行不输出)
#   出现整行 "#priv" 时,桩 aapt 会在 xmltree 中输出 signature|privileged 声明
# -----------------------------------------------------------------------------
cat > "$WORK/bin/aapt" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
case "${1:-}" in
  version) echo "Android Asset Packaging Tool (stub), v0.2-test"; exit 0 ;;
  dump)
    sub="${2:-}"; apk="${3:-}"
    [ -f "$apk" ] || exit 1
    if [ "$sub" = "badging" ]; then
      # 尽量贴近真实 aapt 输出:单引号 + 平台版本字段。
      # ⚠️ compileSdkVersionCodename='16' 里含小写 "name='",是历史 bug 的触发点
      #    (子串匹配会把平台代号当成包名),这里刻意保留以防回归。
      # 标记 #nover → 模拟未声明 versionCode/versionName 的 APK(真实 CI 上遇到过)。
      vc="$(sed -n '2p' "$apk")"; vn="1.0"
      if grep -q '^#nover$' "$apk"; then vc=""; vn=""; fi
      printf "package: name='%s' versionCode='%s' versionName='%s' platformBuildVersionName='16' platformBuildVersionCode='36' compileSdkVersion='36' compileSdkVersionCodename='16'\n" \
        "$(sed -n '1p' "$apk")" "$vc" "$vn"
      # 标记 #priv → 申请平台特权权限(硬判据:该应用不适合模块化)
      if grep -q '^#priv$' "$apk"; then
        printf "uses-permission: name='android.permission.WRITE_SECURE_SETTINGS'\n"
      fi
      sed -n '4,$p' "$apk" | grep -v '^#' || true
      exit 0
    fi
    if [ "$sub" = "xmltree" ]; then
      echo "E: manifest (line=1)"
      echo "  A: android:versionCode(0x0101021b)=(type 0x10)0x0"
      # 标记 #decl → 自声明一项 signature 级权限(真实 aapt 是数值形式!
      # 早期用关键字匹配的实现在这里永远命中不了,故专门覆盖)
      if grep -q '^#decl$' "$apk"; then
        pkg="$(sed -n '1p' "$apk")"
        echo "  E: permission (line=1)"
        echo "    A: android:name(0x01010003)=\"${pkg}.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION\" (Raw: \"${pkg}.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION\")"
        echo "    A: android:protectionLevel(0x01010009)=(type 0x11)0x12"
      fi
      if grep -q '^#decl-foreign$' "$apk"; then
        echo "  E: permission (line=2)"
        echo "    A: android:name(0x01010003)=\"com.other.foreign.EVIL_PERMISSION\" (Raw: \"com.other.foreign.EVIL_PERMISSION\")"
        echo "    A: android:protectionLevel(0x01010009)=(type 0x11)0x2"
      fi
      # 标记 #auth → provider authorities(类型化值 + (Raw: ...) 会各出现一次,
      # 报告必须去重,否则每条 authority 都打印两遍)
      if grep -q '^#auth$' "$apk"; then
        echo "  E: provider (line=1)"
        echo "    A: android:authorities(0x01010018)=\"com.example.stub.fileprovider\" (Raw: \"com.example.stub.fileprovider\")"
      fi
      exit 0
    fi
    ;;
esac
exit 2
STUB
chmod +x "$WORK/bin/aapt"

cat > "$WORK/bin/apksigner" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
apk=""
for a in "$@"; do
  [ -f "$a" ] && apk="$a"
done
[ -n "$apk" ] || { echo "ERROR: no input" >&2; exit 1; }
echo "Signer #1 certificate DN: CN=Android Debug, O=Android, C=US"
printf 'Signer #1 certificate SHA-256 digest: %s\n' "$(sed -n '3p' "$apk")"
exit 0
STUB
chmod +x "$WORK/bin/apksigner"

cat > "$WORK/bin/pm" <<'STUB'
#!/usr/bin/env bash
# 桩 pm:FAKE_PM_PKG + FAKE_PM_MODE(data|system|absent)控制 pm path 的输出
set -uo pipefail
case "${1:-}" in
  list) exit 0 ;;
  path)
    pkg="${2:-}"
    if [ "$pkg" = "${FAKE_PM_PKG:-}" ]; then
      case "${FAKE_PM_MODE:-absent}" in
        data)   echo "package:/data/app/~~stub==/$pkg-stub/base.apk" ;;
        system) echo "package:/system/app/$pkg/$pkg.apk" ;;
      esac
    fi
    exit 0
    ;;
esac
exit 0
STUB
chmod +x "$WORK/bin/pm"

# -----------------------------------------------------------------------------
# 2) 测试夹具:每个应用的假 APK 参数(测试自造值,不是任何设备事实)
# -----------------------------------------------------------------------------
SIGNER_CAL=1111111111111111111111111111111111111111111111111111111111111111
SIGNER_GAL=2222222222222222222222222222222222222222222222222222222222222222
SIGNER_CALC=3333333333333333333333333333333333333333333333333333333333333333
SIGNER_CLOCK=4444444444444444444444444444444444444444444444444444444444444444
SIGNER_REC=5555555555555555555555555555555555555555555555555555555555555555
# 录音机资产名以 apps.yaml 为准(不能在测试里硬编码,否则改资产名会与仓库脱节)
ASSET_REC="$(python3 - "$REPO_ROOT/apps.yaml" <<'PYY'
import re, sys
s = open(sys.argv[1], encoding='utf-8').read()
m = re.search(r'- id: recorder\b.*?\n    asset_name:\s*(\S+)', s, re.S)
print(m.group(1).strip('"') if m else '')
PYY
)"

make_fake_apk() { # $1=输出文件 $2=包名 $3=versionCode $4=签名 $5=额外行(可空) $6=是否 privileged
  {
    printf '%s\n' "$2"
    printf '%s\n' "$3"
    printf '%s\n' "$4"
    printf "uses-permission: name='android.permission.INTERNET'\n"
    printf "uses-permission: name='android.permission.RECEIVE_BOOT_COMPLETED'\n"
    if [ -n "${5:-}" ]; then printf '%s\n' "$5"; fi
    if [ "${6:-0}" = "1" ]; then printf '#priv\n'; fi
  } > "$1"
}

build_assets() { # $1=APK_DIR $2=是否让 clock 申请 privileged 权限 $3=calendar 的额外标记(可空)
  local d="$1" priv="${2:-0}" calm="${3:-}"
  rm -rf "$d"
  mkdir -p "$d"
  make_fake_apk "$d/GKUICalendar-1.0.apk" "ws.xsoh.etar.debug" "50000" "$SIGNER_CAL" "$calm" "0"
  make_fake_apk "$d/app-debug.apk" "org.lineageos.glimpse.dev" "60000" "$SIGNER_GAL" "" "0"
  # 计算器的资产是 zip 包装:内层唯一的 APK
  local tmp="$WORK/calc-src"
  mkdir -p "$tmp"
  make_fake_apk "$tmp/ExactCalculator-debug.apk" "com.android.calculator2.dev" "70000" "$SIGNER_CALC" "" "0"
  ( cd "$tmp" && zip -q "$d/ExactCalculator-debug.apk.zip" "ExactCalculator-debug.apk" )
  make_fake_apk "$d/DeskClock-debug.apk" "com.android.deskclock.dev" "80000" "$SIGNER_CLOCK" "" "$priv"
  # 录音机:模块内 versionCode 90000 > 夹具安装值 89999 → G7 放行;
  # 模拟真实 GKUIRecorder-beta3 的权限结构(含 CAPTURE_AUDIO_OUTPUT、REQUEST_INSTALL_PACKAGES 与包内自声明权限)
  make_fake_apk "$d/$ASSET_REC" "org.lineageos.recorder.dev" "90000" "$SIGNER_REC" \
"uses-permission: name='android.permission.CAPTURE_AUDIO_OUTPUT'
uses-permission: name='android.permission.REQUEST_INSTALL_PACKAGES'
uses-permission: name='org.lineageos.recorder.dev.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION'
#decl" "0"
}

# 把 workspace 里的 apps.yaml 补齐(sha256 按真实假 APK 计算,签名/版本按夹具)
patch_yaml() { # $1=workspace repo $2=APK_DIR
  python3 - "$1/apps.yaml" "$2" <<PYEOF
# -*- coding: utf-8 -*-
import hashlib, os, re, sys
path, apk_dir = sys.argv[1], sys.argv[2]
fixtures = {
    "calendar":   ("ws.xsoh.etar.debug",        "50000", "$SIGNER_CAL"),
    "gallery":    ("org.lineageos.glimpse.dev", "60000", "$SIGNER_GAL"),
    "calculator": ("com.android.calculator2.dev", "70000", "$SIGNER_CALC"),
    "clock":      ("com.android.deskclock.dev",  "80000", "$SIGNER_CLOCK"),
    "recorder":   ("org.lineageos.recorder.dev", "90000", "$SIGNER_REC"),
}
text = open(path, encoding="utf-8").read()
blocks = text.split("  - id: ")
out = [blocks[0]]
for blk in blocks[1:]:
    lines = blk.split("\n")
    app_id = lines[0].strip()
    if app_id in fixtures:
        _pkg, vc, signer = fixtures[app_id]
        # 刻意**不改写** application_id:让 preflight 的 G1 拿假 APK 里的包名与
        # apps.yaml 的真实值比对,从而顺带验证 G1 本身是否生效
        lines = [re.sub(r"^    signer_sha256: .*", "    signer_sha256: " + signer, ln) if ln.startswith("    signer_sha256: ") else ln for ln in lines]
        lines = [re.sub(r"^    confidence: .*", "    confidence: confirmed", ln) if ln.startswith("    confidence: ") else ln for ln in lines]
        lines = [re.sub(r"^    installed_version_code: .*", "    installed_version_code: " + str(int(vc) - 1), ln) if ln.startswith("    installed_version_code: ") else ln for ln in lines]
        asset = ""
        for ln in lines:
            if ln.startswith("    asset_name: "):
                asset = ln.split(": ", 1)[1].strip().strip('"')
        asset_path = os.path.join(apk_dir, asset)
        if os.path.isfile(asset_path):
            digest = hashlib.sha256(open(asset_path, "rb").read()).hexdigest()
            lines = [re.sub(r"^    sha256: .*", "    sha256: " + digest, ln) if ln.startswith("    sha256: ") else ln for ln in lines]
    out.append("  - id: " + "\n".join(lines))
open(path, "w", encoding="utf-8").write("".join(out))
print("[fixtures] apps.yaml 已按夹具补齐")
PYEOF
}

run_build() { # $1=工作区repo $2=APK_DIR $3=dist $4...=额外参数与环境(形式 VAR=VAL)
  local repo="$1" apk="$2" dist="$3"; shift 3
  ( cd "$repo" && env PATH="$WORK/bin:$PATH" APK_DIR="$apk" DIST_DIR="$dist" \
      AAPT="$WORK/bin/aapt" APKSIGNER="$WORK/bin/apksigner" VERSION="test-1" \
      VERSION_CODE=999999 "$@" bash build.sh )
}

# -----------------------------------------------------------------------------
head1 "1) 真实仓库状态:五个应用(recorder 已切至 beta3)"
# -----------------------------------------------------------------------------
pending_todos="$(python3 - "$REPO_ROOT" <<'PYP'
import json, subprocess, sys
out = subprocess.run(["bash", "build.sh", "--dump-apps-json"], cwd=sys.argv[1],
                     capture_output=True, text=True).stdout
apps = json.loads(out)["apps"]
print(sum(1 for a in apps if a.get("_enabled") and a.get("_todo_fields")))
PYP
)"
out="$(cd "$REPO_ROOT" && bash build.sh --check 2>&1)"; rc=$?
if [ "$pending_todos" -gt 0 ]; then
  if [ $rc -ne 0 ] && printf '%s' "$out" | grep -q 'signer_sha256 为 TODO'; then
    ok "真实清单处于 beta3 signer 待采集态(C7 按预期拦截 TODO,rc=$rc)"
  else
    bad "真实清单含 TODO 却未按 C7 拦截(rc=$rc)"; printf '%s\n' "$out" | tail -20
  fi
else
  if [ $rc -eq 0 ]; then ok "bash build.sh --check 通过(rc=0):启用条目已无 TODO"; else bad "字段已齐全却未通过校验(rc=$rc)"; printf '%s\n' "$out" | tail -20; fi
fi
if printf '%s' "$out" | grep -qE '(\[纳入构建\]|\[跳过\]|recorder).*'; then ok "报告里 recorder 状态被显式打印"; else bad "未打印 recorder 状态"; fi
if [ "$pending_todos" -gt 0 ]; then
  if (cd "$REPO_ROOT" && bash build.sh --check --strict >/dev/null 2>&1); then
    bad "--strict 下含 TODO 的真实清单竟通过(违反 C7)"
  else
    ok "--strict 下含 TODO 的真实清单按预期失败(C7)"
  fi
else
  if (cd "$REPO_ROOT" && bash build.sh --check --strict >/dev/null 2>&1); then
    ok "--strict 下真实清单通过(五个应用已无 TODO)"
  else
    bad "真实清单 --strict 应通过(已无 TODO)"
  fi
fi
# C7 的反向验证:启用条目里注入一个 TODO 后必须失败
# (真实仓库已填齐,所以这里显式造出 C7 场景,避免该规则失去覆盖)
cp "$REPO_ROOT/apps.yaml" "$WORK/c7-apps.yaml"
sed -i 's/^    signer_sha256: 815d90d0.*/    signer_sha256: TODO/' "$WORK/c7-apps.yaml"
cp "$WORK/c7-apps.yaml" "$WORK/repo/apps.yaml"
out="$(cd "$WORK/repo" && bash build.sh --check 2>&1)"; rc=$?
if [ $rc -ne 0 ] && printf '%s' "$out" | grep -q 'signer_sha256 为 TODO'; then
  ok "启用条目出现 TODO 时仍被 C7 挡住(反向验证)"
else
  bad "启用条目的 TODO 未被挡住(rc=$rc)"
fi
if (cd "$WORK/repo" && bash build.sh --check --strict >/dev/null 2>&1); then
  bad "--strict 下含 TODO 的清单竟通过(违反字面版 C7)"
else
  ok "--strict 下含 TODO 的清单会失败(字面版 C7)"
fi
cp "$REPO_ROOT/apps.yaml" "$WORK/repo/apps.yaml"

# 1b) --collect-only:引导填值模式(采集真实值,不产出模块,始终返回非零)
mkdir -p "$WORK/collect-repo"
cp -a "$WORK/repo/." "$WORK/collect-repo/"
cp "$REPO_ROOT/apps.yaml" "$WORK/collect-repo/apps.yaml"
# 真实清单已填齐;为了覆盖"清单里还有 TODO 时 collect 仍能采集"这条路径,
# 这里人为把 calendar 的签名证书改回 TODO(--collect-only 本就是为填值而存在)
sed -i 's/^    signer_sha256: 815d90d0.*/    signer_sha256: TODO/' "$WORK/collect-repo/apps.yaml"
if (cd "$WORK/collect-repo" && bash build.sh --check >/dev/null 2>&1); then
  bad "collect 夹具:含 TODO 却通过了普通校验(C7 失效)"
else
  ok "collect 夹具仍含 TODO(普通校验如 C7 所述失败)"
fi
build_assets "$WORK/collect-apks" 0
out="$( cd "$WORK/collect-repo" && env PATH="$WORK/bin:$PATH" APK_DIR="$WORK/collect-apks" \
        DIST_DIR="$WORK/collect-dist" AAPT="$WORK/bin/aapt" APKSIGNER="$WORK/bin/apksigner" \
        bash build.sh --collect-only 2>&1 )"; rc=$?
if [ $rc -ne 0 ]; then ok "--collect-only 始终返回非零(不假装构建成功)"; else bad "--collect-only 竟然返回 0"; fi
if [ -f "$WORK/collect-dist/collected-values.txt" ] && grep -q "$SIGNER_CAL" "$WORK/collect-dist/collected-values.txt"; then
  ok "--collect-only 采集到真实签名证书摘要"
else
  bad "--collect-only 未采集到签名摘要"
fi
if grep -q 'version_code.*50000' "$WORK/collect-dist/collected-values.txt" 2>/dev/null; then
  ok "--collect-only 采集到 versionCode"
else
  bad "--collect-only 未采集到 versionCode"
fi
if [ -z "$(find "$WORK/collect-dist" -name '*.zip' 2>/dev/null)" ]; then
  ok "--collect-only 不产出模块 zip"
else
  bad "--collect-only 竟然产出了模块 zip"
fi
# 注意:夹具是"人为留了 TODO 的副本",因此要与**采集前的快照**比较,而不是与仓库原始文件比较
cp "$WORK/collect-repo/apps.yaml" "$WORK/collect-apps.yaml.before"
out="$( cd "$WORK/collect-repo" && env PATH="$WORK/bin:$PATH" APK_DIR="$WORK/collect-apks" \
        DIST_DIR="$WORK/collect-dist" AAPT="$WORK/bin/aapt" APKSIGNER="$WORK/bin/apksigner" \
        bash build.sh --collect-only 2>&1 )"; rc=$?
if diff -q "$WORK/collect-apps.yaml.before" "$WORK/collect-repo/apps.yaml" >/dev/null 2>&1; then
  ok "--collect-only 未改写 apps.yaml"
else
  bad "--collect-only 改写了 apps.yaml"
fi
if printf '%s' "$out" | grep -q '可回填到 apps.yaml 的片段'; then
  ok "--collect-only 打印可回填片段(仍需人工核对)"
else
  bad "--collect-only 未打印回填片段"
fi

# -----------------------------------------------------------------------------
head1 "2) 桩环境:补齐夹具后应能通过校验"
# -----------------------------------------------------------------------------
build_assets "$WORK/apks" 0
patch_yaml "$WORK/repo" "$WORK/apks"
out="$(cd "$WORK/repo" && bash build.sh --check 2>&1)"; rc=$?
if [ $rc -eq 0 ]; then ok "补齐后 --check 通过"; else bad "补齐后 --check 仍失败"; printf '%s\n' "$out" | tail -20; fi
if (cd "$WORK/repo" && bash build.sh --check 2>&1 | grep -qE '\[纳入构建\].*recorder'); then
  ok "补齐夹具后 recorder 已被纳入构建"
else
  bad "recorder 未被纳入构建"
fi

# -----------------------------------------------------------------------------
head1 "3) 资产 sha256 不匹配必须失败(C5)"
# -----------------------------------------------------------------------------
cp "$WORK/apks/GKUICalendar-1.0.apk" "$WORK/apks/GKUICalendar-1.0.apk.bak"
printf 'tampered\n' >> "$WORK/apks/GKUICalendar-1.0.apk"
out="$(run_build "$WORK/repo" "$WORK/apks" "$WORK/dist-tamper" 2>&1)"; rc=$?
if [ $rc -ne 0 ] && printf '%s' "$out" | grep -q 'sha256 不匹配'; then
  ok "资产被篡改时构建失败并说明原因"
else
  bad "资产被篡改却未失败(rc=$rc)"
fi
mv "$WORK/apks/GKUICalendar-1.0.apk.bak" "$WORK/apks/GKUICalendar-1.0.apk"

# -----------------------------------------------------------------------------
head1 "4) 完整构建:生成模块 zip 并检查其内容"
# -----------------------------------------------------------------------------
out="$(run_build "$WORK/repo" "$WORK/apks" "$WORK/dist" 2>&1)"; rc=$?
ZIP="$WORK/dist/GKUI-Pack-test-1.zip"
ZIP_PRIV_TEST="$WORK/dist/GKUI-Pack-test-1-recorderpriv-TEST.zip"
if [ $rc -eq 0 ] && [ -f "$ZIP" ]; then ok "构建成功并生成 $(basename "$ZIP")"; else bad "构建失败(rc=$rc)"; printf '%s\n' "$out" | tail -30; fi
if [ -f "$ZIP_PRIV_TEST" ]; then
  ok "单次构建同时生成特权测试包 GKUI-Pack-test-1-recorderpriv-TEST.zip"
else
  bad "未生成 GKUI-Pack-test-1-recorderpriv-TEST.zip"
fi
if printf '%s' "$out" | grep -A1 '被跳过的条目(未参与构建):' | grep -q '  (无)'; then
  ok "无跳过条目时打印 '  (无)'"
else
  bad "无跳过条目时未打印 '  (无)'"
fi
if [ -f "$ZIP" ]; then
  listing="$(unzip -l "$ZIP" | awk '{print $4}')"
  for need in module.prop customize.sh post-fs-data.sh service.sh uninstall.sh \
              META-INF/com/google/android/update-binary META-INF/com/google/android/updater-script; do
    if printf '%s\n' "$listing" | grep -q "^$need\$"; then ok "zip 内含 $need"; else bad "zip 缺少 $need"; fi
  done
  for name in GKUICalendar GKUIPhotos GKUICalculator GKUIClock GKUIRecorder; do
    if printf '%s\n' "$listing" | grep -q "^apks/$name.apk\$"; then ok "zip 内含 apks/$name.apk"; else bad "zip 缺少 apks/$name.apk"; fi
  done
  # 渲染检查:不得残留占位符
  if unzip -p "$ZIP" customize.sh | grep -q '__APP_ENTRIES__'; then
    bad "customize.sh 未渲染(仍含占位符)"
  else
    ok "customize.sh 已渲染"
  fi
  if unzip -p "$ZIP" customize.sh | grep -q 'ws.xsoh.etar.debug|GKUICalendar|'; then
    ok "customize.sh 的清单包含 application_id|目录名|sha256"
  else
    bad "customize.sh 清单格式不符合预期"
  fi
  if unzip -p "$ZIP" module.prop | grep -q 'versionCode=999999'; then ok "module.prop 已渲染 VERSION_CODE"; else bad "module.prop 未渲染"; fi
  # 硬约束:module 内不得出现特权应用目录字样、不得有 replace 语义
  if unzip -l "$ZIP" | grep -q 'priv-app'; then bad "zip 内出现特权应用目录字样"; else ok "zip 内无特权应用目录字样(C3)"; fi
  if unzip -p "$ZIP" customize.sh | grep -qiE 'REPLACE|\.replace'; then bad "customize.sh 出现替换语义(C2)"; else ok "customize.sh 无替换语义(C2)"; fi
  # 构建清单
  if [ -f "$WORK/dist/build-manifest.txt" ]; then
    ok "生成 dist/build-manifest.txt"
    if grep -q '^included' "$WORK/dist/build-manifest.txt"; then ok "清单记录了 included 条目"; else bad "清单缺少 included 记录"; fi
  else
    bad "缺少 build-manifest.txt"
  fi
  if [ -f "$WORK/dist/PREFLIGHT-REPORT.md" ] && grep -q 'G1' "$WORK/dist/PREFLIGHT-REPORT.md"; then
    ok "生成 PREFLIGHT-REPORT.md 且含门禁结果"
  else
    bad "缺少 PREFLIGHT-REPORT.md"
  fi
fi

# -----------------------------------------------------------------------------
head1 "5) 签名证书不一致必须失败(C6)"
# -----------------------------------------------------------------------------
sed -i.bak 's/    signer_sha256: 1111111111111111111111111111111111111111111111111111111111111111/    signer_sha256: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/' "$WORK/repo/apps.yaml"
out="$(run_build "$WORK/repo" "$WORK/apks" "$WORK/dist-signer" 2>&1)"; rc=$?
if [ $rc -ne 0 ] && printf '%s' "$out" | grep -q '签名证书与 apps.yaml 不一致'; then
  ok "证书不一致时构建失败"
  if printf '%s' "$out" | grep -q '数据会丢失'; then ok "提示了卸载重装会丢数据"; else bad "缺少数据丢失提示"; fi
else
  bad "证书不一致却未失败(rc=$rc)"
fi
mv "$WORK/repo/apps.yaml.bak" "$WORK/repo/apps.yaml"

# -----------------------------------------------------------------------------
head1 "6) versionCode 不高于已安装版本必须失败(G7)"
# -----------------------------------------------------------------------------
sed -i.bak 's/^    installed_version_code: 49999$/    installed_version_code: 999999/' "$WORK/repo/apps.yaml"
out="$(run_build "$WORK/repo" "$WORK/apks" "$WORK/dist-vc" 2>&1)"; rc=$?
if [ $rc -ne 0 ] && printf '%s' "$out" | grep -q '压制'; then
  ok "versionCode 过小时构建失败并提示会被压制"
else
  bad "versionCode 过小却未失败(rc=$rc)"
fi
mv "$WORK/repo/apps.yaml.bak" "$WORK/repo/apps.yaml"

# 6.2 相等:两侧是同一版本的构建(C8 会在刷入时要求先卸载 /data 副本)→ 应通过,但必须提示
sed -i.bak 's/^    installed_version_code: 49999$/    installed_version_code: 50000/' "$WORK/repo/apps.yaml"
out="$(run_build "$WORK/repo" "$WORK/apks" "$WORK/dist-vc-eq" 2>&1)"; rc=$?
if [ $rc -eq 0 ]; then ok "versionCode 与设备已装版本相同时构建通过(不再无条件阻断)"; else bad "相等却失败(rc=$rc)"; printf '%s\n' "$out" | tail -12; fi
if printf '%s' "$out" | grep -q '同一版本'; then ok "相等时给出提示(同一版本构建)"; else bad "缺少相等说明"; fi
if printf '%s' "$out" | grep -q 'C8'; then ok "相等时提示 C8(刷入前须卸载 /data 副本)"; else bad "缺少 C8 提示"; fi
mv "$WORK/repo/apps.yaml.bak" "$WORK/repo/apps.yaml"

# 6.3 none:实测设备上未安装该包名 → 不存在被压制的问题 → 应通过
sed -i.bak 's/^    installed_version_code: 49999$/    installed_version_code: none/' "$WORK/repo/apps.yaml"
out="$(run_build "$WORK/repo" "$WORK/apks" "$WORK/dist-vc-none" 2>&1)"; rc=$?
if [ $rc -eq 0 ]; then ok "installed_version_code=none(实测未安装)时构建通过"; else bad "none 却失败(rc=$rc)"; printf '%s\n' "$out" | tail -12; fi
if printf '%s' "$out" | grep -q '无该包名副本'; then ok "明确说明设备上没有该包名的副本"; else bad "缺少 none 的说明文案"; fi
mv "$WORK/repo/apps.yaml.bak" "$WORK/repo/apps.yaml"

# -----------------------------------------------------------------------------
head1 "7) 特权权限硬判据:申请者被排除出模块,其余照常出包(C3)"
# -----------------------------------------------------------------------------
# clock 申请平台特权权限(WRITE_SECURE_SETTINGS)→ 硬排除;
# calendar 只是"自声明"一项 signature 级权限(androidx 常见做法)+ 有 authorities →
# 必须**不**被排除,且 authoritiy 在报告里只出现一次(去重)。
build_assets "$WORK/apks-priv" 1 '#decl
#auth'
patch_yaml "$WORK/repo" "$WORK/apks-priv"
out="$(run_build "$WORK/repo" "$WORK/apks-priv" "$WORK/dist-priv" 2>&1)"; rc=$?
ZIP_PRIV="$WORK/dist-priv/GKUI-Pack-test-1.zip"
if [ $rc -eq 0 ] && [ -f "$ZIP_PRIV" ]; then ok "存在 privileged 应用时构建仍成功(该应用被排除)"; else bad "构建失败(rc=$rc)"; printf '%s\n' "$out" | tail -20; fi
if printf '%s' "$out" | grep -q '不适合模块化'; then ok "明确提示该应用不适合模块化,仅走 adb install"; else bad "缺少不适合模块化的提示"; fi
if [ -f "$ZIP_PRIV" ]; then
  if unzip -l "$ZIP_PRIV" | grep -q 'apks/GKUIClock.apk'; then bad "被排除的应用仍进了模块"; else ok "被排除的应用未进入模块"; fi
  if unzip -l "$ZIP_PRIV" | grep -q 'apks/GKUICalendar.apk'; then ok "其余应用仍正常入包"; else bad "其余应用未入包"; fi
  if grep -q '^excluded.*clock' "$WORK/dist-priv/build-manifest.txt" 2>/dev/null; then ok "build-manifest.txt 标记了 excluded"; else bad "清单未标记 excluded"; fi
fi
# 触发原因必须可核:报告要列出具体权限
if printf '%s' "$out" | grep -q 'WRITE_SECURE_SETTINGS'; then ok "报告列出触发的特权权限(证据可核)"; else bad "报告未列出触发原因"; fi
# 回归:真实 aapt 行里的平台代号(compileSdkVersionCodename='16')绝不能被当成包名
if printf '%s' "$out" | grep -q 'name=16'; then bad "G1 把平台代号当成了包名(子串匹配回归)"; else ok "G1 未把平台代号(16)误当成包名"; fi
if printf '%s' "$out" | grep -q 'name=ws.xsoh.etar.debug'; then ok "G1 从真实形态的 badging 行取到正确包名"; else bad "G1 未取到正确包名"; fi
# 仅报告:自声明权限用数值形式表示,需解码后打印(原始值 + 解码)
if printf '%s' "$out" | grep -q 'signature|system'; then ok "自声明权限 protectionLevel 已解码(0x12 → signature|system)"; else bad "缺少 protectionLevel 解码"; fi
if printf '%s' "$out" | grep -q '未检出 signature|privileged 权限声明'; then bad "仍输出误导性的『未检出 signature 声明』"; else ok "不再输出误导性的『未检出声明』结论"; fi
# 去重:类型化值与 (Raw: ...) 各出现一次,报告里必须只留一条
auth_n="$(printf '%s' "$out" | grep -c 'com.example.stub.fileprovider' || true)"
if [ "$auth_n" -eq 1 ]; then ok "authorities 已去重(只出现 1 次)"; else bad "authority 重复出现 ${auth_n} 次"; fi

# 7b) C3 显式确认制:**同一特权夹具**,给 clock 写上 privileged_ack: true →
#     以普通系统应用纳入 system/app,且报告 / 清单 / 构建摘要逐条标注;
#     calendar 同样写 ack 但它并未申请特权权限 → 不产生任何标注(ack 不是"豁免",只是确认)。
set_ack() { # $1=workspace repo $2=app id $3=privileged_ack 值 $4=privileged_note(可空)
  python3 - "$1/apps.yaml" "$2" "$3" "${4:-}" <<'PYEOF2'
import sys
path, app_id, ack, note = sys.argv[1:5]
text = open(path, encoding="utf-8").read()
blocks = text.split("  - id: ")
out = [blocks[0]]
for blk in blocks[1:]:
    lines = blk.split("\n")
    if lines[0].strip() == app_id:
        new = []
        for ln in lines:
            new.append(ln)
            if ln.startswith("    install_as: "):
                new.append("    privileged_ack: " + ack)
                if note:
                    new.append('    privileged_note: "' + note + '"')
        lines = new
    out.append("  - id: " + "\n".join(lines))
open(path, "w", encoding="utf-8").write("".join(out))
PYEOF2
}
ACK_NOTE='通话录音不会生效,需 priv 变体(分支 recorder-priv)'
cp "$WORK/repo/apps.yaml" "$WORK/apps.yaml.noack"
set_ack "$WORK/repo" clock true "$ACK_NOTE"
set_ack "$WORK/repo" calendar true
out="$(cd "$WORK/repo" && bash build.sh --check 2>&1)"; rc=$?
if [ $rc -eq 0 ] && printf '%s' "$out" | grep -q 'id=clock.*privileged_ack=true'; then
  ok "privileged_ack: true 能通过清单校验,且在 --check 输出里显式标出"
else
  bad "privileged_ack: true 的清单校验异常(rc=$rc)"; printf '%s\n' "$out" | tail -8
fi
out="$(run_build "$WORK/repo" "$WORK/apks-priv" "$WORK/dist-ack" 2>&1)"; rc=$?
ZIP_ACK="$WORK/dist-ack/GKUI-Pack-test-1.zip"
MAN_ACK="$WORK/dist-ack/build-manifest.txt"
REP_ACK="$WORK/dist-ack/PREFLIGHT-REPORT.md"
if [ $rc -eq 0 ] && [ -f "$ZIP_ACK" ]; then ok "privileged_ack: true 时构建成功"; else bad "privileged_ack 构建失败(rc=$rc)"; printf '%s\n' "$out" | tail -20; fi
if [ -f "$ZIP_ACK" ]; then
  if unzip -l "$ZIP_ACK" | grep -q 'apks/GKUIClock.apk'; then ok "已显式确认的特权申请者以 system_app 纳入模块"; else bad "已确认的条目仍被排除"; fi
  if unzip -l "$ZIP_ACK" | grep -q 'priv-app'; then bad "ack 后 zip 内出现特权应用目录字样"; else ok "ack 后 zip 内仍无特权应用目录字样(物理底线不变)"; fi
  if unzip -l "$ZIP_ACK" | grep -qiE 'permissions/.*\.xml'; then bad "ack 后 zip 内出现权限白名单 XML"; else ok "ack 后 zip 内没有任何白名单 XML"; fi
  if unzip -p "$ZIP_ACK" customize.sh | grep -q 'com.android.deskclock.dev|GKUIClock|'; then ok "渲染清单含已确认条目(落点仍是 system/app)"; else bad "渲染清单缺少已确认条目"; fi
fi
if grep -q '^excluded' "$MAN_ACK" 2>/dev/null; then bad "ack 后清单仍有 excluded 行"; else ok "ack 后清单没有 excluded 行"; fi
clock_row="$(grep '^included	clock	' "$MAN_ACK" 2>/dev/null || true)"
case "$clock_row" in
  *WRITE_SECURE_SETTINGS*"不会被授予"*"$ACK_NOTE"*) ok "build-manifest.txt 逐条标注:权限名 + 不会被授予 + privileged_note" ;;
  *) bad "build-manifest.txt 缺少 ack 标注:$clock_row" ;;
esac
cal_row="$(grep '^included	calendar	' "$MAN_ACK" 2>/dev/null || true)"
case "$cal_row" in
  *"	-") ok "未申请特权权限的条目即使写了 ack 也不产生标注(note 列为 -)" ;;
  *) bad "calendar 行的 note 列异常:$cal_row" ;;
esac
if printf '%s' "$out" | grep -q '\[privileged_ack\].*WRITE_SECURE_SETTINGS.*'"$ACK_NOTE"; then ok "构建摘要逐条标注(权限名 + note)"; else bad "构建摘要缺少 ack 标注"; fi
if printf '%s' "$out" | grep -q '并不会授予 signature|privileged 权限'; then ok "构建摘要说明 /system/app 不会授予特权权限"; else bad "构建摘要缺少『不会授予』说明"; fi
if printf '%s' "$out" | grep -q '已排除出本模块'; then bad "ack 后仍打印了排除提示"; else ok "ack 后不再打印排除提示"; fi
if grep -q '结论: privileged_acknowledged' "$REP_ACK" 2>/dev/null && grep -q '标注: 该 APK 申请特权权限 android.permission.WRITE_SECURE_SETTINGS' "$REP_ACK" 2>/dev/null; then
  ok "PREFLIGHT-REPORT.md 标注结论 privileged_acknowledged + 权限名"
else
  bad "PREFLIGHT-REPORT.md 缺少 ack 标注"
fi
if grep -q "privileged_note):$ACK_NOTE" "$REP_ACK" 2>/dev/null; then ok "PREFLIGHT-REPORT.md 带上了 privileged_note"; else bad "PREFLIGHT-REPORT.md 缺少 privileged_note"; fi
if grep -q '不进 priv-app、不生成任何 privapp 白名单 XML' "$REP_ACK" 2>/dev/null; then ok "PREFLIGHT-REPORT.md 重申物理底线"; else bad "PREFLIGHT-REPORT.md 缺少物理底线说明"; fi

# 7c) privileged_ack: false 必须与缺省完全一致(排除)—— fail-safe
cp "$WORK/apps.yaml.noack" "$WORK/repo/apps.yaml"
set_ack "$WORK/repo" clock false
out="$(run_build "$WORK/repo" "$WORK/apks-priv" "$WORK/dist-ackfalse" 2>&1)"; rc=$?
if [ $rc -eq 0 ] && ! unzip -l "$WORK/dist-ackfalse/GKUI-Pack-test-1.zip" 2>/dev/null | grep -q 'apks/GKUIClock.apk'; then
  ok "privileged_ack: false 与缺省一致:仍被排除"
else
  bad "privileged_ack: false 的行为异常(rc=$rc)"
fi
if grep -q '^excluded	clock	.*WRITE_SECURE_SETTINGS' "$WORK/dist-ackfalse/build-manifest.txt" 2>/dev/null; then ok "excluded 行写明了触发的特权权限"; else bad "excluded 行缺少权限名"; fi
if printf '%s' "$out" | grep -q 'privileged_ack: true'; then ok "排除提示告诉用户显式确认的写法"; else bad "排除提示未说明 privileged_ack"; fi

# 7d) 非法取值:privileged_ack 只能是 true/false;privileged_note 不能脱离 ack: true 单独出现
cp "$WORK/apps.yaml.noack" "$WORK/repo/apps.yaml"
set_ack "$WORK/repo" clock yes
out="$(cd "$WORK/repo" && bash build.sh --check 2>&1)"; rc=$?
if [ $rc -ne 0 ] && printf '%s' "$out" | grep -q 'privileged_ack=.* 非法'; then ok "privileged_ack: yes(非布尔)被拒绝"; else bad "非法 privileged_ack 未被拒绝(rc=$rc)"; fi
cp "$WORK/apps.yaml.noack" "$WORK/repo/apps.yaml"
set_ack "$WORK/repo" clock false "$ACK_NOTE"
out="$(cd "$WORK/repo" && bash build.sh --check 2>&1)"; rc=$?
if [ $rc -ne 0 ] && printf '%s' "$out" | grep -q 'privileged_note 只能与 privileged_ack: true'; then ok "privileged_note 脱离 ack: true 时被拒绝"; else bad "孤立的 privileged_note 未被拒绝(rc=$rc)"; fi
cp "$WORK/apps.yaml.noack" "$WORK/repo/apps.yaml"

# -----------------------------------------------------------------------------
head1 "8) C8:/data 冲突检查(渲染后的 customize.sh + 桩 pm)"
# -----------------------------------------------------------------------------
stage_module() { # $1=目标目录:从构建产物准备一个"已安装模块"的等价目录
  local d="$1" name
  rm -rf "$d"
  mkdir -p "$d/apks"
  cp -a "$WORK/repo/module/." "$d/"
  unzip -p "$ZIP" customize.sh > "$d/customize.sh"
  for name in GKUICalendar GKUIPhotos GKUICalculator GKUIClock GKUIRecorder; do
    unzip -p "$ZIP" "apks/$name.apk" > "$d/apks/$name.apk"
  done
}

if [ -f "$ZIP" ]; then
  # 8.1 冲突:/data 中已安装 → 必须中止,且不得自行卸载
  MODTEST="$WORK/modtest"
  stage_module "$MODTEST"
  out="$( env PATH="$WORK/bin:$PATH" MODPATH="$MODTEST" FAKE_PM_PKG="ws.xsoh.etar.debug" \
          FAKE_PM_MODE="data" sh "$MODTEST/customize.sh" 2>&1 )"; rc=$?
  if [ $rc -ne 0 ]; then ok "同包名存在于 /data 时安装中止(rc=$rc)"; else bad "同包名冲突却未中止"; fi
  case "$out" in
    *"已安装于用户空间"*) ok "打印了规定的冲突提示" ;;
    *) bad "缺少冲突提示文案" ;;
  esac
  case "$out" in
    *"pm uninstall"*) ok "提示用户自行 pm uninstall" ;;
    *) bad "未提示用户自行卸载" ;;
  esac
  case "$out" in
    *"本模块不会替你执行卸载"*) ok "明确声明模块不会代为卸载" ;;
    *) bad "未声明不代为卸载" ;;
  esac
  if [ -d "$MODTEST/system" ]; then bad "中止安装后仍写入了 system/ 目录"; else ok "中止安装后未留下任何挂载内容"; fi

  # 8.2 已由系统分区提供 → 该条目跳过,其余继续
  MODSYS="$WORK/modsys"
  stage_module "$MODSYS"
  out="$( env PATH="$WORK/bin:$PATH" MODPATH="$MODSYS" FAKE_PM_PKG="ws.xsoh.etar.debug" \
          FAKE_PM_MODE="system" sh "$MODSYS/customize.sh" 2>&1 )"; rc=$?
  if [ $rc -eq 0 ] && printf '%s' "$out" | grep -q '模块已生效'; then
    ok "/system 已有同包名时跳过该条目并继续安装"
  else
    bad "系统分区已存在时的处理不符合预期(rc=$rc)"
  fi
  if [ -f "$MODSYS/system/app/GKUICalendar/GKUICalendar.apk" ]; then
    bad "已由系统分区提供的条目仍被重复挂载"
  else
    ok "已由系统分区提供的条目未被重复挂载"
  fi
  if [ -f "$MODSYS/system/app/GKUIPhotos/GKUIPhotos.apk" ]; then
    ok "其余条目正常挂载"
  else
    bad "其余条目未挂载"
  fi

  # 8.3 正常路径:全部未安装 → 落盘到 system/app/<Name>/ 并设置权限
  MODOK="$WORK/modok"
  stage_module "$MODOK"
  out="$( env PATH="$WORK/bin:$PATH" MODPATH="$MODOK" FAKE_PM_PKG="__none__" \
          FAKE_PM_MODE="absent" sh "$MODOK/customize.sh" 2>&1 )"; rc=$?
  if [ $rc -eq 0 ]; then ok "无冲突时安装成功"; else bad "无冲突却安装失败(rc=$rc)"; printf '%s\n' "$out" | tail -20; fi
  for name in GKUICalendar GKUIPhotos GKUICalculator GKUIClock GKUIRecorder; do
    f="$MODOK/system/app/$name/$name.apk"
    if [ -f "$f" ]; then ok "已安装到 system/app/$name/$name.apk"; else bad "缺少 $f"; fi
  done
  if [ ! -d "$MODOK/apks" ]; then ok "安装后清理了 apks/ 临时目录"; else bad "apks/ 未被清理"; fi
  if command -v stat >/dev/null 2>&1; then
    dmode="$(stat -c '%a' "$MODOK/system/app/GKUICalendar" 2>/dev/null)"
    fmode="$(stat -c '%a' "$MODOK/system/app/GKUICalendar/GKUICalendar.apk" 2>/dev/null)"
    if [ "$dmode" = "755" ] && [ "$fmode" = "644" ]; then ok "目录/文件权限为 755/644"; else bad "权限不符(目录=$dmode 文件=$fmode)"; fi
  fi

  # 8.4 完整性校验:篡改 APK 后必须中止
  MODBAD="$WORK/modbad"
  stage_module "$MODBAD"
  printf 'x' >> "$MODBAD/apks/GKUICalendar.apk"
  out="$( env PATH="$WORK/bin:$PATH" MODPATH="$MODBAD" FAKE_PM_PKG="__none__" \
          FAKE_PM_MODE="absent" sh "$MODBAD/customize.sh" 2>&1 )"; rc=$?
  if [ $rc -ne 0 ] && printf '%s' "$out" | grep -q '完整性校验失败'; then
    ok "APK 完整性校验失败时中止安装"
  else
    bad "APK 被篡改却未中止(rc=$rc)"
  fi

  # 8.6 C3 兜底:模块目录里若有特权变体(recorder-priv,同一模块 id)的残留落点
  #     (特权应用目录 / privapp 白名单 XML),普通版安装时必须清掉,只留 system/app
  MODRES="$WORK/modres"
  stage_module "$MODRES"
  mkdir -p "$MODRES/system/priv-app/GKUIRecorder" "$MODRES/system/etc/permissions"
  printf 'stale\n' > "$MODRES/system/priv-app/GKUIRecorder/GKUIRecorder.apk"
  printf '<permissions/>\n' > "$MODRES/system/etc/permissions/privapp-permissions-gkui-recorder.xml"
  out="$( env PATH="$WORK/bin:$PATH" MODPATH="$MODRES" FAKE_PM_PKG="__none__" \
          FAKE_PM_MODE="absent" sh "$MODRES/customize.sh" 2>&1 )"; rc=$?
  if [ $rc -eq 0 ]; then ok "存在特权残留时安装仍成功"; else bad "存在残留时安装失败(rc=$rc)"; printf '%s\n' "$out" | tail -12; fi
  if [ ! -e "$MODRES/system/priv-app" ] && [ ! -e "$MODRES/system/etc" ]; then
    ok "清除了特权应用目录与白名单 XML 残留"
  else
    bad "特权残留未被清除"
  fi
  system_children="$(find "$MODRES/system" -mindepth 1 -maxdepth 1 -print 2>/dev/null | sed 's|.*/||' | tr '\n' ' ')"
  if [ "$system_children" = "app " ]; then ok "清理后 system/ 下只剩 app/"; else bad "system/ 下仍有其它落点: $system_children"; fi
  if printf '%s' "$out" | grep -q '\[清理\] 移除非 system/app 的残留落点'; then ok "清理动作有明确提示"; else bad "缺少清理提示"; fi
  if [ -f "$MODRES/system/app/GKUICalendar/GKUICalendar.apk" ]; then ok "清理不影响正常挂载"; else bad "清理后应用未挂载"; fi

  # 8.5 未渲染的 customize.sh(仓库原始版)必须拒绝安装
  out="$( env PATH="$WORK/bin:$PATH" MODPATH="$WORK/emptymod" sh "$REPO_ROOT/module/customize.sh" 2>&1 )"; rc=$?
  if [ $rc -ne 0 ] && printf '%s' "$out" | grep -q '未渲染'; then
    ok "未渲染的模块(直接打包 module/)拒绝安装并说明原因"
  else
    bad "未渲染的模块未拒绝安装(rc=$rc)"
  fi

  # 8.7 C8:已安装 APK 字节与目标 sha256 一致时可正常接管
  MODADOPT="$WORK/modadopt"
  stage_module "$MODADOPT"
  REC_TARGET_SHA="$(sha256sum "$MODADOPT/apks/GKUIRecorder.apk" | awk '{print $1}')"
  out="$( env PATH="$WORK/bin:$PATH" MODPATH="$MODADOPT" \
          FAKE_PM_PKG="org.lineageos.recorder.dev" FAKE_PM_MODE="data" \
          FAKE_PM_SHA256="$REC_TARGET_SHA" sh "$MODADOPT/customize.sh" 2>&1 )"; rc=$?
  if [ $rc -eq 0 ] && printf '%s' "$out" | grep -q '\[接管\].*org.lineageos.recorder.dev'; then
    ok "C8:已安装 APK 字节与目标 sha256 一致时正常接管(rc=0)"
  else
    bad "C8:字节与目标 sha256 一致却未能正常接管(rc=$rc)"; printf '%s\n' "$out" | tail -15
  fi
  if [ -f "$MODADOPT/system/app/GKUIRecorder/GKUIRecorder.apk" ]; then
    ok "C8:接管后 GKUIRecorder.apk 正常落盘"
  else
    bad "C8:接管后缺少 GKUIRecorder.apk"
  fi

  # 8.8 C8:检测到 beta2 → beta3 签名变更时整包中止并给出三步指引(备份 → 手动卸载或删旧模块 → 重启)
  MODSIG="$WORK/modsig"
  stage_module "$MODSIG"
  out="$( env PATH="$WORK/bin:$PATH" MODPATH="$MODSIG" \
          FAKE_PM_PKG="org.lineageos.recorder.dev" FAKE_PM_MODE="data" \
          FAKE_PM_SHA256="f4c00ddb06145ab26fb4a4ba85f91bf866a22a33ad079044ed45da3d7f778f6f" \
          sh "$MODSIG/customize.sh" 2>&1 )"; rc=$?
  if [ $rc -ne 0 ] && printf '%s' "$out" | grep -q 'beta2 → beta3'; then
    ok "C8:检测到 beta2 → beta3 签名变更时整包中止(rc=$rc)"
  else
    bad "C8:beta2 → beta3 签名变更未中止或缺少版本标记(rc=$rc)"; printf '%s\n' "$out" | tail -15
  fi
  if printf '%s' "$out" | grep -q '备份' && printf '%s' "$out" | grep -q '手动卸载或删旧模块' && printf '%s' "$out" | grep -q '重启'; then
    ok "C8:签名断裂提示含完整三步指引(备份 → 手动卸载或删旧模块 → 重启)"
  else
    bad "C8:签名断裂提示缺少三步指引"
  fi
  if printf '%s' "$out" | grep -q '严禁自动卸载或写 /data'; then
    ok "C8:明确声明严禁自动卸载或写 /data"
  else
    bad "C8:未声明严禁自动卸载或写 /data"
  fi
  if [ ! -d "$MODSIG/system" ]; then
    ok "C8:签名变更中止后未留下任何 system/ 挂载内容"
  else
    bad "C8:签名变更中止后仍残留 system/ 目录"
  fi
else
  bad "第 4 步未产出 zip,跳过 C8 测试"
fi

# -----------------------------------------------------------------------------
head1 "9) bootloop 自救:标记生命周期"
# -----------------------------------------------------------------------------
BOOT="$WORK/boot"
mkdir -p "$BOOT"
cp "$REPO_ROOT/module/post-fs-data.sh" "$REPO_ROOT/module/service.sh" "$BOOT/"
sh "$BOOT/post-fs-data.sh" >/dev/null 2>&1
if [ -f "$BOOT/.boot_flag" ]; then ok "首次 post-fs-data 创建 .boot_flag"; else bad "未创建 .boot_flag"; fi
if [ -f "$BOOT/disable" ]; then bad "首次就写了 disable(会误禁用模块)"; else ok "首次未写 disable"; fi
sh "$BOOT/post-fs-data.sh" >/dev/null 2>&1
if [ -f "$BOOT/disable" ]; then ok "第二次 post-fs-data 写出 disable(打破 bootloop)"; else bad "未写 disable"; fi
sh "$BOOT/service.sh" >/dev/null 2>&1
if [ ! -f "$BOOT/.boot_flag" ]; then ok "service.sh 清除了 .boot_flag"; else bad "service.sh 未清除 .boot_flag"; fi
if [ -f "$BOOT/last_boot.log" ] && grep -q 'epoch=' "$BOOT/last_boot.log"; then
  ok "service.sh 写入 last_boot.log 时间戳"
else
  bad "last_boot.log 缺失或格式不符"
fi

# -----------------------------------------------------------------------------
head1 "10) adb 侧脚本:install_all / uninstall_all / probe-device(桩 adb)"
# -----------------------------------------------------------------------------
cat > "$WORK/bin/adb" <<'STUB'
#!/usr/bin/env bash
# 桩 adb:用 ADB_STUB_MODE 控制安装结果与设备状态(仅供离线测试)
set -uo pipefail
MODE="${ADB_STUB_MODE:-ok}"
case "${1:-}" in
  version) echo "Android Debug Bridge version 1.0.41 (stub)"; exit 0 ;;
  devices)
    case "$MODE" in
      nodevice) printf 'List of devices attached\n\n'; exit 0 ;;
      unauth)   printf 'List of devices attached\nSTUB\tunauthorized\n'; exit 0 ;;
      twodev)   printf 'List of devices attached\nDEV1\tdevice\nDEV2\tdevice\n'; exit 0 ;;
    esac
    printf 'List of devices attached\nSTUBDEVICE\tdevice\n'; exit 0 ;;
esac
if [ "${1:-}" = "-s" ]; then shift 2; fi
case "${1:-}" in
  install)
    case "$MODE" in
      ok) echo "Success"; exit 0 ;;
      update) echo "Failure [INSTALL_FAILED_UPDATE_INCOMPATIBLE: Package signatures do not match previously installed version; ignoring!]"; exit 1 ;;
      provider) echo "Failure [INSTALL_FAILED_CONFLICTING_PROVIDER: Can't install because provider name com.example.calendar is already used by other]"; exit 1 ;;
      perm) echo "Failure [INSTALL_FAILED_DUPLICATE_PERMISSION: attempting to redeclare permission foo already owned by bar]"; exit 1 ;;
      *) echo "Failure [INSTALL_FAILED_UNKNOWN_STUB]"; exit 1 ;;
    esac ;;
  uninstall) echo "Success"; exit 0 ;;
  pull)
    dest="${@: -1}"
    printf 'stub-apk-content' > "$dest" 2>/dev/null || true
    echo "1 file pulled."
    exit 0 ;;
  shell)
    shift
    case "${1:-}" in
      pm)
        shift
        sub="${1:-}"; [ $# -gt 0 ] && shift
        case "$sub" in
          list)
            [ "${1:-}" = "packages" ] && shift
            case "${1:-}" in
              -3) printf 'package:ws.xsoh.etar.debug\npackage:com.example.stubrecorder\n' ;;
              -d) printf 'package:org.lineageos.recorder\n' ;;
            esac ;;
          path)
            case "${1:-}" in
              ws.xsoh.etar.debug) echo "package:/data/app/~~x==/ws.xsoh.etar.debug-y/base.apk" ;;
              org.lineageos.etar) echo "package:/system/app/Etar/Etar.apk" ;;
              com.android.deskclock) echo "package:/system/app/DeskClock/DeskClock.apk" ;;
            esac ;;
        esac
        exit 0 ;;
      dumpsys)
        shift
        [ "${1:-}" = "package" ] && shift
        case "${1:-}" in
          ws.xsoh.etar.debug) printf '    versionCode=50000 minSdk=21 targetSdk=34\n    versionName=1.0\n' ;;
        esac
        exit 0 ;;
    esac
    exit 0 ;;
esac
exit 0
STUB
chmod +x "$WORK/bin/adb"

# 重新准备一致的资产与清单(前面小节改动过工作区状态)
build_assets "$WORK/apks" 0
patch_yaml "$WORK/repo" "$WORK/apks"

# 注意:helper 的第一批参数是**环境变量赋值**(如 ADB_STUB_MODE=ok),
# 其余参数原样传给对应脚本。
ia() { ( cd "$WORK/repo" && env PATH="$WORK/bin:$PATH" APK_DIR="$WORK/apks" bash scripts/install_all.sh "$@" ); }
ua() { ( cd "$WORK/repo" && env PATH="$WORK/bin:$PATH" bash scripts/uninstall_all.sh "$@" ); }
pb() { ( cd "$WORK/repo" && env PATH="$WORK/bin:$PATH" bash scripts/probe-device.sh "$@" ); }

# 10.1 install_all:dry-run
out="$(ADB_STUB_MODE=ok ia --dry-run 2>&1)"; rc=$?
if [ $rc -eq 0 ] && printf '%s' "$out" | grep -q '\[dry-run\] adb install -r'; then
  ok "install_all --dry-run 只打印命令"
else
  bad "install_all --dry-run 异常(rc=$rc)"
fi
for pkg in ws.xsoh.etar.debug org.lineageos.glimpse.dev com.android.calculator2.dev com.android.deskclock.dev org.lineageos.recorder.dev; do
  if printf '%s' "$out" | grep -q "$pkg"; then ok "dry-run 覆盖 $pkg"; else bad "dry-run 未覆盖 $pkg"; fi
done

# 10.2 install_all:正常路径
out="$(ADB_STUB_MODE=ok ia 2>&1)"; rc=$?
if [ $rc -eq 0 ] && printf '%s' "$out" | grep -q '成功: 5'; then
  ok "install_all 正常路径:5 个应用全部成功"
else
  bad "install_all 正常路径异常(rc=$rc)"; printf '%s\n' "$out" | tail -12
fi
if printf '%s' "$out" | grep -q '默认应用'; then ok "安装后提示切换默认日历/图库"; else bad "缺少默认应用切换提示"; fi
if printf '%s' "$out" | grep -q 'adb uninstall' && printf '%s' "$out" | grep -q 'disable-user'; then
  ok "破坏性操作只打印建议命令(adb uninstall / disable-user)"
else
  bad "缺少建议命令清单"
fi
if printf '%s' "$out" | grep -q '计算器历史'; then ok "打印了数据丢失范围说明"; else bad "缺少数据丢失说明"; fi

# 10.3 install_all:错误码人话解释(三个必需覆盖项)
out="$(ADB_STUB_MODE=update ia 2>&1)"; rc=$?
if [ $rc -ne 0 ] && printf '%s' "$out" | grep -q 'INSTALL_FAILED_UPDATE_INCOMPATIBLE' \
   && printf '%s' "$out" | grep -q '数据会丢失'; then
  ok "UPDATE_INCOMPATIBLE → 人话解释 + 数据丢失警告"
else
  bad "UPDATE_INCOMPATIBLE 解释缺失(rc=$rc)"
fi
if printf '%s' "$out" | grep -q 'adb uninstall ws.xsoh.etar.debug'; then ok "给出卸载命令建议(不代执行)"; else bad "未给出卸载建议"; fi
out="$(ADB_STUB_MODE=provider ia 2>&1)"; rc=$?
if [ $rc -ne 0 ] && printf '%s' "$out" | grep -q 'INSTALL_FAILED_CONFLICTING_PROVIDER' \
   && printf '%s' "$out" | grep -q 'authority'; then
  ok "CONFLICTING_PROVIDER → 人话解释"
else
  bad "CONFLICTING_PROVIDER 解释缺失(rc=$rc)"
fi
out="$(ADB_STUB_MODE=perm ia 2>&1)"; rc=$?
if [ $rc -ne 0 ] && printf '%s' "$out" | grep -q 'INSTALL_FAILED_DUPLICATE_PERMISSION' \
   && printf '%s' "$out" | grep -q '权限'; then
  ok "DUPLICATE_PERMISSION → 人话解释"
else
  bad "DUPLICATE_PERMISSION 解释缺失(rc=$rc)"
fi

# 10.4 install_all:无设备 / 缺 APK
out="$(ADB_STUB_MODE=nodevice ia 2>&1)"; rc=$?
if [ $rc -eq 2 ] && printf '%s' "$out" | grep -q '没有检测到已授权的设备'; then
  ok "无设备时友好退出(rc=2,不做任何修改)"
else
  bad "无设备处理异常(rc=$rc)"
fi
out="$(ADB_STUB_MODE=twodev ia 2>&1)"; rc=$?
if [ $rc -eq 2 ] && printf '%s' "$out" | grep -q '多台设备'; then ok "多设备时要求 -s 指定"; else bad "多设备处理异常(rc=$rc)" ; fi
mkdir -p "$WORK/noapk"
out="$( cd "$WORK/repo" && env PATH="$WORK/bin:$PATH" APK_DIR="$WORK/noapk" bash scripts/install_all.sh 2>&1 )"; rc=$?
if [ $rc -ne 0 ] && printf '%s' "$out" | grep -q 'gh release download'; then
  ok "缺 APK 时打印具体的下载命令"
else
  bad "缺 APK 处理异常(rc=$rc)"
fi

# 10.5 uninstall_all
out="$(ADB_STUB_MODE=ok ua 2>&1)"; rc=$?
if [ $rc -eq 2 ] && printf '%s' "$out" | grep -q '交互式终端'; then
  ok "uninstall_all 在非交互环境拒绝执行(防误删),需显式 --yes"
else
  bad "uninstall_all 非交互未拒绝(rc=$rc)"
fi
out="$(ADB_STUB_MODE=ok ua --yes --dry-run 2>&1)"
if printf '%s' "$out" | grep -q 'adb uninstall'; then ok "uninstall_all --dry-run 打印卸载命令"; else bad "uninstall_all dry-run 异常"; fi
out="$(ADB_STUB_MODE=ok ua --yes 2>&1)"; rc=$?
if [ $rc -eq 0 ] && printf '%s' "$out" | grep -q '成功: 5'; then ok "uninstall_all --yes 正常卸载 5 项"; else bad "uninstall_all 异常(rc=$rc)"; fi
if printf '%s' "$out" | grep -q 'pm enable org.lineageos.etar'; then ok "提示用户自行 pm enable 恢复自带应用"; else bad "缺少 pm enable 提示"; fi
if printf '%s' "$out" | grep -q 'adb uninstall com.android.deskclock.dev'; then bad "打印了错误的自带应用卸载命令"; else ok "未给出卸载自带应用的命令"; fi

# 10.6 probe-device:只读、不改 apps.yaml、不落 APK
cp "$WORK/repo/apps.yaml" "$WORK/apps.yaml.before-probe"
out="$(ADB_STUB_MODE=ok pb --yaml-snippet --filter stubrecorder 2>&1)"; rc=$?
if [ $rc -eq 0 ]; then ok "probe-device 正常退出"; else bad "probe-device 失败(rc=$rc)"; fi
if printf '%s' "$out" | grep -q 'versionCode → 50000'; then ok "probe 采集到设备实测 versionCode(按规格用 dumpsys)"; else bad "probe 未取到 versionCode"; fi
if printf '%s' "$out" | grep -q 'com.example.stubrecorder'; then
  ok "probe 能列出用户空间包(用于实测未确认的包名,禁止按规律推断)"
else
  bad "probe 未列出用户空间包"
fi
if printf '%s' "$out" | grep -q 'signer_sha256(设备上那一份)'; then
  ok "probe 输出了设备侧 APK 的签名信息行(apksigner 可用时)"
else
  bad "probe 未输出签名信息行"
fi
out2="$(ADB_STUB_MODE=ok APKSIGNER=/nonexistent-apksigner pb 2>&1)"; rc2=$?
if [ $rc2 -eq 0 ] && printf '%s' "$out2" | grep -q '<未取到>'; then
  ok "apksigner 不可用时优雅降级(只缺该项,不报错)"
else
  bad "apksigner 缺失时未优雅降级(rc=$rc2)"
fi
# 未安装的包名必须给出可回填的 none,而不是占位符(否则用户照抄会撞上校验)
out3="$(ADB_STUB_MODE=ok pb --yaml-snippet 2>&1)"
if printf '%s' "$out3" | grep -q 'installed_version_code: none'; then
  ok "probe 对未安装/取不到 versionCode 的包给出 none(可直接回填)"
else
  bad "probe 未给出 none 形式的结果"
fi
if printf '%s' "$out3" | grep -q '未安装,无法取得\|<不适用'; then
  bad "probe 仍输出不可回填的占位符"
else
  ok "probe 不再输出不可回填的占位符"
fi
if diff -q "$WORK/apps.yaml.before-probe" "$WORK/repo/apps.yaml" >/dev/null 2>&1; then
  ok "probe 未改写 apps.yaml(禁止自动填值)"
else
  bad "probe 改写了 apps.yaml"
fi
if [ -z "$(find "$WORK/repo" -name '*.apk' 2>/dev/null)" ]; then ok "probe 未在仓库内落下 APK"; else bad "probe 在仓库内留下了 APK"; fi

# -----------------------------------------------------------------------------
head1 "11) 硬约束验收项(在真实仓库上检查)"
# -----------------------------------------------------------------------------
count_apk="$(cd "$REPO_ROOT" && git ls-files 2>/dev/null | grep -c '\.apk$' || true)"
if [ "$count_apk" = "0" ]; then ok "git ls-files | grep -c '.apk\$' == 0(C5)"; else bad "仓库跟踪了 $count_apk 个 .apk(C5 违规)"; fi
if grep -rn "mode: replace" "$REPO_ROOT/apps.yaml" >/dev/null 2>&1; then bad "apps.yaml 出现 mode: replace(C2)"; else ok "apps.yaml 无 mode: replace"; fi
if grep -rn "priv-app" "$REPO_ROOT/module/" >/dev/null 2>&1; then bad "module/ 出现特权应用目录字样(C3)"; else ok "module/ 无 priv-app 字样"; fi
if grep -rniE "dialer|telephony|messaging|contacts" "$REPO_ROOT/apps.yaml" >/dev/null 2>&1; then
  bad "apps.yaml 命中 C4 禁用类别"
else
  ok "apps.yaml 未命中 C4 禁用类别"
fi
if python3 - "$REPO_ROOT" <<'PYEOF'
# -*- coding: utf-8 -*-
import json, subprocess, sys
out = subprocess.run(["bash", "build.sh", "--dump-apps-json"], cwd=sys.argv[1],
                     capture_output=True, text=True).stdout
data = json.loads(out)
for app in data["apps"]:
    if app["id"] == "recorder":
        # 设计要点:断言写成**不变量**(未证实 → 必须 unverified/禁用/不得指向官方包名/
        # 仍留 TODO),而不是"application_id 必须以 TODO 开头"。后者每回填一个实测字段
        # 就要连 CI 工作流一起改,而工作流只能由用户经网页编辑器落地 —— 徒增耦合。
        signer_ok = (
            app["signer_sha256"] == "10fd149d021f5fc263f6e6dcb580a3e7e60822d48b1c0f63751e8945b5a60c25"
            and app["confidence"] == "confirmed"
        )
        ok = (app["application_id"] == "org.lineageos.recorder.dev"
              and app["application_id"] != app["stock_package"]
              and str(app["installed_version_code"]) == "1"
              and app["release_tag"] == "beta3"
              and app["asset_name"] == "GKUIRecorder-beta3.apk"
              and app["sha256"] == "fe261923f73d07c7e0b3e238231d89553a772b64571df9db1d61e7bb8c72ec4f"
              and app["previous_release_tag"] == "beta2"
              and app["previous_sha256"] == "f4c00ddb06145ab26fb4a4ba85f91bf866a22a33ad079044ed45da3d7f778f6f"
              and app["previous_signer_sha256"] == "7cd26af2112c234f9bbfe2b21e3651c4e51a5d4c4de34b462c86bacd881e0985"
              and app["_enabled"] is True
              and signer_ok)
        sys.exit(0 if ok else 1)
sys.exit(1)
PYEOF
then ok "recorder:已切到 beta3 并保留 beta2 前驱(包名/versionCode/哈希/signer 已核实)"; else bad "recorder 条目不符合要求"; fi
if grep -q '^\*.apk$' "$REPO_ROOT/.gitignore" && grep -q '^dist/$' "$REPO_ROOT/.gitignore" \
   && grep -q '^build/$' "$REPO_ROOT/.gitignore" && grep -q '^\*.keystore$' "$REPO_ROOT/.gitignore"; then
  ok ".gitignore 含 *.apk / dist/ / build/ / *.keystore"
else
  bad ".gitignore 缺少必需条目"
fi
if grep -q '^\*.apk$' "$REPO_ROOT/.gitignore" && [ "$count_apk" = "0" ]; then ok "仓库内不存在被跟踪的 APK"; fi

# -----------------------------------------------------------------------------
head1 "12) APK 未声明 versionCode:必须明确失败并解释(G7)"
# -----------------------------------------------------------------------------
# 真实 CI 上遇到过:LineageOS 的 DeskClock APK 的 badging 行为
#   package: name='com.android.deskclock.dev' versionCode='' versionName=''
# 平台语义:未声明 → 按 0 处理(设备上那一份的实测值也确实记录了 0,见 apps.yaml)。
# 因此 G7 的行为是:
#   * 设备上有副本且副本版本更高 → 失败(模块内更旧,会被压制);
#   * 设备上副本也是 0 → 相等 → 放行(刷入前按 C8 先卸载副本);
#   * 设备上无副本(none)→ 放行;
#   * 报告里必须写明"未在 manifest 里声明 versionCode",而不是留空白。
build_assets "$WORK/apks-nover" 0
printf '#nover\n' >> "$WORK/apks-nover/DeskClock-debug.apk"
patch_yaml "$WORK/repo" "$WORK/apks-nover"
out="$(run_build "$WORK/repo" "$WORK/apks-nover" "$WORK/dist-nover" 2>&1)"; rc=$?
if [ $rc -ne 0 ]; then ok "未声明 versionCode 的 APK 让构建失败(rc=$rc)"; else bad "缺少 versionCode 却构建成功"; fi
if printf '%s' "$out" | grep -q '未在 manifest 里声明 versionCode'; then ok "失败原因解释清楚(指明 APK 未声明 versionCode)"; else bad "失败原因不明确"; fi
if printf '%s' "$out" | grep -q 'versionCode: 未知'; then ok "报告里以『未知』表示而不是空白"; else bad "报告里未标明 versionCode 未知"; fi
# 12.1 设备上已有副本、且副本版本更高(79999)→ 模块内(未声明→0)更旧 → 必须失败
#      (12.1 的三条断言见上)

# 12.2a 真实 clock 情形:APK 未声明 versionCode,设备上那一份实测为 0
#       → 按平台语义"未声明=0",两侧相等 → 放行,并说明原因
sed -i.bak 's/^    installed_version_code: 79999$/    installed_version_code: 0/' "$WORK/repo/apps.yaml"
out="$(run_build "$WORK/repo" "$WORK/apks-nover" "$WORK/dist-nover0" 2>&1)"; rc=$?
if [ $rc -eq 0 ]; then ok "未声明 versionCode 且设备上为 0 → 相等放行(真实 clock 情形)"; else bad "该情形失败(rc=$rc)"; printf '%s\n' "$out" | tail -12; fi
if printf '%s' "$out" | grep -q '平台按 0 处理'; then ok "明确说明未声明按平台语义记 0"; else bad "缺少未声明→0 的说明"; fi
if grep -q '0(未声明)' "$WORK/dist-nover0/build-manifest.txt" 2>/dev/null; then ok "构建清单里记为该 APK 未声明"; else bad "清单未记录未声明"; fi
mv "$WORK/repo/apps.yaml.bak" "$WORK/repo/apps.yaml"

# 12.2b 但若设备上**没有**该包名的副本(实测 none)——没有压制风险 → 也应放行
sed -i.bak 's/^    installed_version_code: 79999$/    installed_version_code: none/' "$WORK/repo/apps.yaml"
out="$(run_build "$WORK/repo" "$WORK/apks-nover" "$WORK/dist-nover2" 2>&1)"; rc=$?
if [ $rc -eq 0 ]; then ok "设备上无副本 + APK 未声明 versionCode → 放行(无压制风险)"; else bad "该情形仍失败(rc=$rc)"; printf '%s\n' "$out" | tail -12; fi
if printf '%s' "$out" | grep -q '不会被压制'; then ok "说明了为何放行(不会被压制)"; else bad "缺少放行理由"; fi
mv "$WORK/repo/apps.yaml.bak" "$WORK/repo/apps.yaml"

# -----------------------------------------------------------------------------
head1 "12b) 路线 B:源码框架权限表与 privapp 白名单生成(generate-privapp-permissions.py)"
# -----------------------------------------------------------------------------
SRC_DUMP="$REPO_ROOT/device/framework-permissions.source.txt"
if [ -f "$SRC_DUMP" ]; then
  ok "device/framework-permissions.source.txt 存在"
else
  bad "缺少 device/framework-permissions.source.txt"
fi
if grep -q '^# Source-Repo: LineageOS/android_frameworks_base$' "$SRC_DUMP" \
   && grep -q '^# Source-Branch-Or-Tag: lineage-23.2$' "$SRC_DUMP" \
   && grep -q '^# Source-Commit: f4ed08a03b518772ba77c3c0a1b4185fa1712c9b$' "$SRC_DUMP"; then
  ok "framework-permissions.source.txt 含完整源码可追溯头信息"
else
  bad "framework-permissions.source.txt 缺少源码可追溯头信息"
fi
decl_count="$(grep -c '^+ permission:' "$SRC_DUMP" || true)"
uniq_count="$(grep '^+ permission:' "$SRC_DUMP" | sort -u | wc -l | tr -d ' ')"
if [ "$decl_count" -eq 1079 ] && [ "$uniq_count" -eq 1059 ]; then
  ok "framework-permissions.source.txt 含 1079 条声明与 1059 个唯一权限名"
else
  bad "framework-permissions.source.txt 声明/唯一权限数不符(实际=$decl_count/$uniq_count,期望=1079/1059)"
fi
if awk '/^\+ permission:android\.permission\.CAPTURE_AUDIO_OUTPUT$/{getline; if ($0 ~ /protectionLevel:signature\|privileged\|role/) ok=1} END{exit(ok?0:1)}' "$SRC_DUMP"; then
  ok "CAPTURE_AUDIO_OUTPUT 的 protectionLevel 为 signature|privileged|role"
else
  bad "CAPTURE_AUDIO_OUTPUT 的 protectionLevel 不符合预期"
fi

# 构造 Recorder 真实权限形态的 preflight JSON:
# - CAPTURE_AUDIO_OUTPUT (signature|privileged|role) → 应写入 XML
# - REQUEST_INSTALL_PACKAGES (signature|appop) → 复合级别不含 privileged,不误判为纯 signature,不写入
# - RECORD_AUDIO (dangerous|instant) → 不写入
# - org.lineageos.recorder.dev.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION (APK 自声明且在自身包名命名空间内) → 自动排除,不要求出现在框架权限表中
cat > "$WORK/rec-pf-ok.json" <<'EOF'
{
  "app_id": "recorder",
  "application_id": "org.lineageos.recorder.dev",
  "requested_permissions": [
    "android.permission.CAPTURE_AUDIO_OUTPUT",
    "android.permission.RECORD_AUDIO",
    "android.permission.REQUEST_INSTALL_PACKAGES",
    "org.lineageos.recorder.dev.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION"
  ],
  "declared_permissions": [
    "org.lineageos.recorder.dev.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION"
  ]
}
EOF
out="$(python3 "$REPO_ROOT/scripts/generate-privapp-permissions.py" \
  --dump "$SRC_DUMP" --app-json "$WORK/rec-pf-ok.json" --out "$WORK/privapp-ok.xml" 2>&1)"; rc=$?
if [ $rc -eq 0 ] && [ -f "$WORK/privapp-ok.xml" ]; then
  ok "generate-privapp-permissions.py:自声明包内权限 + signature|appop + CAPTURE_AUDIO_OUTPUT 成功生成 XML"
else
  bad "generate-privapp-permissions.py 正常用例失败(rc=$rc)"; printf '%s\n' "$out"
fi
if grep -q '<permission name="android.permission.CAPTURE_AUDIO_OUTPUT" />' "$WORK/privapp-ok.xml" \
   && ! grep -q 'REQUEST_INSTALL_PACKAGES' "$WORK/privapp-ok.xml" \
   && ! grep -q 'DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION' "$WORK/privapp-ok.xml" \
   && ! grep -q 'RECORD_AUDIO' "$WORK/privapp-ok.xml"; then
  ok "生成的白名单 XML 仅含含 privileged 的 CAPTURE_AUDIO_OUTPUT(排除自声明权限与 signature|appop)"
else
  bad "生成的白名单 XML 内容不符合预期"; cat "$WORK/privapp-ok.xml"
fi

# 包名命名空间外的自声明权限必须 fail-closed
cat > "$WORK/rec-pf-foreign.json" <<'EOF'
{
  "app_id": "recorder",
  "application_id": "org.lineageos.recorder.dev",
  "requested_permissions": [
    "android.permission.CAPTURE_AUDIO_OUTPUT",
    "com.other.pkg.CUSTOM_PERM"
  ],
  "declared_permissions": [
    "com.other.pkg.CUSTOM_PERM"
  ]
}
EOF
out="$(python3 "$REPO_ROOT/scripts/generate-privapp-permissions.py" \
  --dump "$SRC_DUMP" --app-json "$WORK/rec-pf-foreign.json" --out "$WORK/privapp-foreign.xml" 2>&1)"; rc=$?
if [ $rc -ne 0 ] && [ ! -f "$WORK/privapp-foreign.xml" ] && printf '%s' "$out" | grep -q 'fail-closed'; then
  ok "包名命名空间外的自声明权限触发 fail-closed 且不产出 XML"
else
  bad "跨包名自声明权限未被 fail-closed 拦截(rc=$rc)"; printf '%s\n' "$out"
fi

# 纯 signature 权限必须 fail-closed
cat > "$WORK/rec-pf-puresig.json" <<'EOF'
{
  "app_id": "recorder",
  "application_id": "org.lineageos.recorder.dev",
  "requested_permissions": [
    "android.permission.CAPTURE_AUDIO_OUTPUT",
    "android.permission.CONFIRM_FULL_BACKUP"
  ],
  "declared_permissions": []
}
EOF
out="$(python3 "$REPO_ROOT/scripts/generate-privapp-permissions.py" \
  --dump "$SRC_DUMP" --app-json "$WORK/rec-pf-puresig.json" --out "$WORK/privapp-puresig.xml" 2>&1)"; rc=$?
if [ $rc -ne 0 ] && [ ! -f "$WORK/privapp-puresig.xml" ] && printf '%s' "$out" | grep -q '纯 signature 权限'; then
  ok "纯 signature 权限仍触发 fail-closed"
else
  bad "纯 signature 权限未被拦截(rc=$rc)"; printf '%s\n' "$out"
fi

# -----------------------------------------------------------------------------
head1 "12c) v0.0.4:双包输出、TEST 标记、update.json 排序、service.sh 诊断与文档检查"
# -----------------------------------------------------------------------------
if [ -f "$ZIP" ] && [ -f "$ZIP_PRIV_TEST" ]; then
  # 两个包的 module.prop 均在根目录且 id 均为 gkui-pack
  id_norm="$(unzip -p "$ZIP" module.prop | grep '^id=' | head -1)"
  id_priv="$(unzip -p "$ZIP_PRIV_TEST" module.prop | grep '^id=' | head -1)"
  if [ "$id_norm" = "id=gkui-pack" ] && [ "$id_priv" = "id=gkui-pack" ]; then
    ok "普通版与 TEST 版 module.prop 均位于根目录且 id=gkui-pack 一致"
  else
    bad "module.prop id 不一致(norm=$id_norm, priv=$id_priv)"
  fi
  # TEST 标记检查:1) 文件名含 -recorderpriv-TEST.zip; 2) module.prop description; 3) PREFLIGHT-REPORT.md 开头; 4) RELEASE-NOTES-v0.0.4.md
  if unzip -p "$ZIP_PRIV_TEST" module.prop | grep -q '^description=.*白名单来源：源码推导，未经设备验证'; then
    ok "TEST 版 module.prop description 注明『白名单来源：源码推导，未经设备验证』"
  else
    bad "TEST 版 module.prop 缺少源码推导说明"
  fi
  if head -n 10 "$WORK/dist/PREFLIGHT-REPORT.md" | grep -q '白名单来源：源码推导，未经设备验证'; then
    ok "PREFLIGHT-REPORT.md 开头注明源码推导来源与风险"
  else
    bad "PREFLIGHT-REPORT.md 开头缺少 TEST 警告"
  fi
  if [ -f "$REPO_ROOT/docs/RELEASE-NOTES-v0.0.4.md" ] \
     && grep -q '白名单来源：源码推导，未经设备验证' "$REPO_ROOT/docs/RELEASE-NOTES-v0.0.4.md" \
     && grep -q '切回普通版' "$REPO_ROOT/docs/RELEASE-NOTES-v0.0.4.md"; then
    ok "docs/RELEASE-NOTES-v0.0.4.md 历史保留:含 TEST 警告与管理器点击更新切回普通版说明"
  else
    bad "docs/RELEASE-NOTES-v0.0.4.md 缺失或缺少 TEST 警告/更新切回说明"
  fi
  if [ -f "$REPO_ROOT/docs/RELEASE-NOTES-v0.0.5.md" ] \
     && grep -q 'GKUI-Pack-v0.0.5-recorderpriv.zip' "$REPO_ROOT/docs/RELEASE-NOTES-v0.0.5.md" \
     && grep -q 'GKUI-Pack-v0.0.5.zip' "$REPO_ROOT/docs/RELEASE-NOTES-v0.0.5.md" \
     && grep -q '白名单来源：Pixel 5 / Android 16 设备权限表' "$REPO_ROOT/docs/RELEASE-NOTES-v0.0.5.md" \
     && grep -q "已在 Pixel 5 / Android 16 验证开机与 \`CAPTURE_AUDIO_OUTPUT\` 授予" "$REPO_ROOT/docs/RELEASE-NOTES-v0.0.5.md" \
     && grep -q '通话录音功能本身尚未验证' "$REPO_ROOT/docs/RELEASE-NOTES-v0.0.5.md" \
     && grep -q 'enforce 校验状态待 v0.0.5 诊断确认' "$REPO_ROOT/docs/RELEASE-NOTES-v0.0.5.md" \
     && grep -q '直接在 Magisk / KernelSU / APatch 管理器里选择' "$REPO_ROOT/docs/RELEASE-NOTES-v0.0.5.md" \
     && grep -q '会被换回普通版' "$REPO_ROOT/docs/RELEASE-NOTES-v0.0.5.md"; then
    ok "docs/RELEASE-NOTES-v0.0.5.md 含双包说明/TEST→正式升级方法/更新换回普通版/验证口径"
  else
    bad "docs/RELEASE-NOTES-v0.0.5.md 缺失或内容不完整"
  fi
  if grep -q "BOOT_MAX=\"\${DIAG_BOOT_MAX_WAIT:-120}\"" "$REPO_ROOT/module/service.sh"; then
    ok "module/service.sh 的 boot_completed 等待上限为 120 秒"
  else
    bad "module/service.sh 的 boot_completed 等待上限不为 120 秒"
  fi
  # update.json 与 release.yml 的 sorted(glob.glob("dist/GKUI-Pack-*.zip"))[-1] 必须指向普通版
  if [ -f "$WORK/dist/update.json" ] && grep -q '"zipUrl": ".*/GKUI-Pack-test-1\.zip"' "$WORK/dist/update.json"; then
    ok "dist/update.json 的 zipUrl 指向普通版 GKUI-Pack-test-1.zip"
  else
    bad "dist/update.json 缺失或未指向普通版"
  fi
   picked_zip="$(python3 - "$WORK/dist" <<'PYS'
import glob, os, sys
zips = sorted(glob.glob(os.path.join(sys.argv[1], "GKUI-Pack-*.zip")))
print(os.path.basename(zips[-1]) if zips else "")
PYS
)"
  if [ "$picked_zip" = "GKUI-Pack-test-1.zip" ]; then
    ok "release.yml sorted(glob.glob('dist/GKUI-Pack-*.zip'))[-1] 选中普通版而非 -TEST.zip"
  else
    bad "sorted(...)[-1] 选中了错误的包: $picked_zip"
  fi

  # 执行 TEST 版的 customize.sh:Recorder 进 system/priv-app/GKUIRecorder,其余进 system/app,并写入白名单 XML
  MODPRIV="$WORK/modpriv"
  rm -rf "$MODPRIV"
  mkdir -p "$MODPRIV"
  unzip -q "$ZIP_PRIV_TEST" -d "$MODPRIV"
  # 模拟从普通版切到 TEST 版时目录中残留 system/app/GKUIRecorder,确认清理步骤会将其清除且不误删 priv-app 与 etc/permissions
  mkdir -p "$MODPRIV/system/app/GKUIRecorder"
  printf 'stale-normal\n' > "$MODPRIV/system/app/GKUIRecorder/GKUIRecorder.apk"
  out="$( env PATH="$WORK/bin:$PATH" MODPATH="$MODPRIV" FAKE_PM_PKG="__none__" \
          FAKE_PM_MODE="absent" sh "$MODPRIV/customize.sh" 2>&1 )"; rc=$?
  if [ $rc -eq 0 ] \
     && [ -f "$MODPRIV/system/priv-app/GKUIRecorder/GKUIRecorder.apk" ] \
     && [ ! -e "$MODPRIV/system/app/GKUIRecorder" ] \
     && [ -f "$MODPRIV/system/app/GKUICalendar/GKUICalendar.apk" ] \
     && [ -f "$MODPRIV/system/etc/permissions/privapp-permissions-org.lineageos.recorder.dev.xml" ]; then
    ok "TEST 版 customize.sh 将 GKUIRecorder 装入 system/priv-app 并写入 privapp 白名单 XML"
  else
    bad "TEST 版 customize.sh 落盘结果不符(rc=$rc)"; printf '%s\n' "$out" | tail -15
  fi
  if [ -f "$MODPRIV/system/priv-app/GKUIRecorder/GKUIRecorder.apk" ]; then
    ok "TEST 版 customize.sh 执行后存在 \$MODPATH/system/priv-app/GKUIRecorder/GKUIRecorder.apk"
  else
    bad "TEST 版 customize.sh 执行后缺少 \$MODPATH/system/priv-app/GKUIRecorder/GKUIRecorder.apk"
  fi
  if [ -f "$MODPRIV/system/etc/permissions/privapp-permissions-org.lineageos.recorder.dev.xml" ]; then
    ok "TEST 版 customize.sh 执行后存在 \$MODPATH/system/etc/permissions/privapp-permissions-org.lineageos.recorder.dev.xml"
  else
    bad "TEST 版 customize.sh 执行后缺少 \$MODPATH/system/etc/permissions/privapp-permissions-org.lineageos.recorder.dev.xml"
  fi
  if [ ! -e "$MODPRIV/system/app/GKUIRecorder" ]; then
    ok "TEST 版 customize.sh 执行后 \$MODPATH/system/app/GKUIRecorder 不存在(防止同一个包装两份)"
  else
    bad "TEST 版 customize.sh 执行后仍残留 \$MODPATH/system/app/GKUIRecorder"
  fi
fi

# 当存在 device/framework-permissions.txt 时,保持非 TEST 严格门禁(产出 -recorderpriv.zip)
patch_yaml "$WORK/repo" "$WORK/apks"
cp "$REPO_ROOT/device/framework-permissions.source.txt" "$WORK/repo/device/framework-permissions.txt"
out="$(run_build "$WORK/repo" "$WORK/apks" "$WORK/dist-strictpriv" 2>&1)"; rc=$?
rm -f "$WORK/repo/device/framework-permissions.txt"
if [ $rc -ne 0 ]; then
  ok "存在 device/framework-permissions.txt 时启用严格门禁(重复冲突记录按预期 fail-closed)"
else
  bad "存在 device/framework-permissions.txt 时未启用严格门禁"
fi
# 放入无重复冲突的设备实测转储 → 产出非 TEST 的 GKUI-Pack-test-1-recorderpriv.zip
python3 - "$REPO_ROOT/device/framework-permissions.source.txt" "$WORK/repo/device/framework-permissions.txt" <<'PYDEDUP'
import sys
src, dst = sys.argv[1], sys.argv[2]
lines = open(src, encoding="utf-8").read().splitlines()
out = ["# Device: StubDevice", "# SDK: 36", "# Captured: 2026-10-12", "All Permissions:"]
seen = set()
i = 0
while i < len(lines):
    if lines[i].startswith("+ permission:"):
        perm = lines[i].split(":", 1)[1].strip()
        lvl = lines[i + 1] if i + 1 < len(lines) else "  protectionLevel:normal"
        if perm not in seen:
            seen.add(perm)
            out.append(lines[i])
            out.append(lvl)
        i += 2
    else:
        i += 1
open(dst, "w", encoding="utf-8").write("\n".join(out) + "\n")
PYDEDUP
out="$(run_build "$WORK/repo" "$WORK/apks" "$WORK/dist-strict-ok" 2>&1)"; rc=$?
rm -f "$WORK/repo/device/framework-permissions.txt"
if [ $rc -eq 0 ] && [ -f "$WORK/dist-strict-ok/GKUI-Pack-test-1-recorderpriv.zip" ] \
   && [ ! -f "$WORK/dist-strict-ok/GKUI-Pack-test-1-recorderpriv-TEST.zip" ]; then
  ok "存在合法 device/framework-permissions.txt 时产出正式名 GKUI-Pack-test-1-recorderpriv.zip(无 -TEST)"
else
  bad "存在合法 device/framework-permissions.txt 时产物异常(rc=$rc)"
fi

# -----------------------------------------------------------------------------
head1 "12d) v0.0.5: 真机权限表入库、设备模式正式包、XML 逐字节一致、严格门禁停止条件"
# -----------------------------------------------------------------------------
REAL_DUMP="$REPO_ROOT/device/framework-permissions.txt"
SPEC_PROPS="ro.lineage.version ro.build.version.incremental ro.build.date.utc ro.build.fingerprint ro.control_privapp_permissions ro.build.version.sdk ro.product.device"

# 12d.1 service.sh 静态断言:7 个规格键逐字出现,ro.Boot 永不出现
keys_ok=1
for k in $SPEC_PROPS; do
  grep -qF "$k" "$REPO_ROOT/module/service.sh" || keys_ok=0
done
if [ "$keys_ok" -eq 1 ] && ! grep -q 'ro.Boot' "$REPO_ROOT/module/service.sh"; then
  ok "service.sh 逐字包含规格 7 个属性键,且不包含 ro.Boot"
else
  bad "service.sh 属性键不符合规格(keys_ok=$keys_ok)"
fi
# GKUI 包名保留在诊断脚本;stock 包名只允许来自构建生成的 stock-packages.list。
pkgs_ok=1
for pkg in $DIAG_GKUI_PKGS; do
  grep -qF "$pkg" "$REPO_ROOT/module/service.sh" || pkgs_ok=0
done
for pkg in $DIAG_STOCK_PKGS; do
  if awk -v p="$pkg" '$1 == p { found=1 } END { exit found ? 0 : 1 }' "$REPO_ROOT/module/service.sh" \
     || awk -v p="$pkg" '$1 == p { found=1 } END { exit found ? 0 : 1 }' "$REPO_ROOT/module/uninstall.sh"; then
    pkgs_ok=0
  fi
done
if [ "$pkgs_ok" -eq 1 ] \
   && grep -qF 'stock-packages.list' "$REPO_ROOT/module/service.sh" \
   && grep -qF 'stock-disabled.list' "$REPO_ROOT/module/uninstall.sh"; then
  ok "service.sh 的 stock 包名仅从 stock-packages.list 读取;卸载从运行时清单恢复"
else
  bad "service.sh/uninstall.sh stock 包名来源错误或发生硬编码"
fi
if [ -f "$ZIP" ] && [ -f "$ZIP_PRIV_TEST" ]; then
  expected_stock_list="$(printf '%s\n' "$DIAG_STOCK_PKGS" | tr ' ' '\n')"
  normal_stock_list="$(unzip -p "$ZIP" stock-packages.list)"
  priv_stock_list="$(unzip -p "$ZIP_PRIV_TEST" stock-packages.list)"
  if [ "$normal_stock_list" = "$expected_stock_list" ] \
     && [ "$priv_stock_list" = "$expected_stock_list" ]; then
    ok "普通版与 recorderpriv 包根目录均含按 enabled stock_package 生成的 stock-packages.list"
  else
    bad "双包 stock-packages.list 内容不正确"
  fi
fi
# 既有保护性行为不得改动
if grep -q "rm -f \"\$MODDIR/.boot_flag\"" "$REPO_ROOT/module/service.sh" \
   && grep -q 'DIAG_SDCARD_MAX_WAIT:-600' "$REPO_ROOT/module/service.sh" \
   && grep -q "BOOT_MAX=\"\${DIAG_BOOT_MAX_WAIT:-120}\"" "$REPO_ROOT/module/service.sh"; then
  ok "service.sh 保留首行 rm .boot_flag / 600 秒 sdcard 轮询 / 120 秒 boot 等待"
else
  bad "service.sh 既有诊断保护逻辑被改动"
fi

# 12d.2 真机权限表文件本身:头注释、记录数、关键级别、时钟异常、零 dangerous
if [ -f "$REAL_DUMP" ]; then ok "device/framework-permissions.txt 已入库"; else bad "缺少 device/framework-permissions.txt"; fi
if grep -q '^# Device: Pixel 5' "$REAL_DUMP" \
   && grep -q '^# SDK: 36' "$REAL_DUMP" \
   && grep -q 'BP4A.251205.006' "$REAL_DUMP" \
   && grep -q 'epoch 1793032493' "$REAL_DUMP" \
   && grep -q 'v0.0.4 priv-TEST 模块 service.sh 诊断' "$REAL_DUMP"; then
  ok "设备权限表头注释含设备/SDK/build/epoch/采集方式"
else
  bad "设备权限表头注释不完整"
fi
if grep -q 'ro.control_privapp_permissions' "$REAL_DUMP" \
   && grep -q 'ro.lineage.version' "$REAL_DUMP" \
   && grep -q 'ro.build.version.incremental' "$REAL_DUMP" \
   && grep -q 'ro.build.date.utc' "$REAL_DUMP"; then
  ok "设备权限表头注释注明 4 个未采集属性及原因"
else
  bad "设备权限表未注明未采集属性"
fi
if [ "$(grep -c '^+ permission:' "$REAL_DUMP" || true)" -eq 1195 ]; then
  ok "设备权限表原样保存 1195 条 permission 记录"
else
  bad "设备权限表记录数异常: $(grep -c '^+ permission:' "$REAL_DUMP" || true)"
fi
if ! grep -q 'protectionLevel:.*dangerous' "$REAL_DUMP"; then
  ok "设备权限表不含 dangerous 级权限(pm list permissions 实测行为)"
else
  bad "设备权限表出现 dangerous 记录,跳过规则前提变化"
fi
if awk '/^\+ permission:android\.permission\.CAPTURE_AUDIO_OUTPUT$/{f=1; next} f && /^  protectionLevel:/{if ($0 == "  protectionLevel:signature|privileged|role") ok=1; f=0} END{exit ok?0:1}' "$REAL_DUMP" \
   && awk '/^\+ permission:android\.permission\.REQUEST_INSTALL_PACKAGES$/{f=1; next} f && /^  protectionLevel:/{if ($0 == "  protectionLevel:signature|appop") ok=1; f=0} END{exit ok?0:1}' "$REAL_DUMP"; then
  ok "CAPTURE_AUDIO_OUTPUT=signature|privileged|role、REQUEST_INSTALL_PACKAGES=signature|appop 与诊断一致"
else
  bad "关键权限 protectionLevel 与真机诊断不符"
fi
if [ "$(awk '/^\+ permission:com.android.deskclock.dev.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION$/{getline; print}' "$REAL_DUMP")" = "  package:com.android.deskclock" ] \
   && ! grep -q '^+ permission:com.android.deskclock.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION$' "$REAL_DUMP"; then
  ok "时钟权限归属异常原样保留(归属 stock 时钟,且无 stock 同名权限)"
else
  bad "时钟权限归属异常未原样保留(严禁修改数据)"
fi
if grep -q '^--- \[5\] pm list permissions -f ---$' "$REAL_DUMP"; then
  ok "设备权限表数据区以诊断第 [5] 节标题起始(原样保存)"
else
  bad "设备权限表缺少第 [5] 节标题"
fi

# 12d.3 生成器:真机表 + Recorder 真实权限形态 → 仅 CAPTURE_AUDIO_OUTPUT 入 XML,
#       缺失的 dangerous 运行时权限显式跳过而非 fail-closed
out="$(python3 "$REPO_ROOT/scripts/generate-privapp-permissions.py" \
  --dump "$REAL_DUMP" --mode device --app-json "$WORK/rec-pf-ok.json" \
  --out "$WORK/real-device.xml" 2>&1)"; rc=$?
if [ $rc -eq 0 ] && [ -f "$WORK/real-device.xml" ]; then
  ok "生成器接受真机权限表(缺失的 dangerous 运行时权限按实测规则跳过)"
else
  bad "生成器无法处理真机权限表(rc=$rc)"; printf '%s\n' "$out"
fi
if [ -f "$WORK/real-device.xml" ] \
   && [ "$(grep -c '<permission name=' "$WORK/real-device.xml")" -eq 1 ] \
   && grep -q '<permission name="android.permission.CAPTURE_AUDIO_OUTPUT" />' "$WORK/real-device.xml"; then
  ok "真机表生成的 XML 仅含 CAPTURE_AUDIO_OUTPUT 一项"
else
  bad "真机表 XML 内容异常"; cat "$WORK/real-device.xml" 2>/dev/null
fi
# 反向:转储若含 dangerous 记录却缺请求权限,仍须 fail-closed
cat > "$WORK/neg-dump.txt" <<'EOF'
# Device: Neg
# SDK: 36
# Captured: stub
All Permissions:
+ permission:android.permission.CAPTURE_AUDIO_OUTPUT
  protectionLevel:signature|privileged|role
+ permission:android.permission.RECORD_AUDIO
  protectionLevel:dangerous|instant
EOF
cat > "$WORK/neg-pf.json" <<'EOF'
{"app_id":"recorder","application_id":"org.lineageos.recorder.dev",
 "requested_permissions":["android.permission.CAPTURE_AUDIO_OUTPUT","android.permission.POST_NOTIFICATIONS"],
 "declared_permissions":[]}
EOF
if ! python3 "$REPO_ROOT/scripts/generate-privapp-permissions.py" \
      --dump "$WORK/neg-dump.txt" --mode device --app-json "$WORK/neg-pf.json" \
      --out "$WORK/neg-out.xml" >/dev/null 2>&1 && [ ! -f "$WORK/neg-out.xml" ]; then
  ok "含 dangerous 的转储缺失请求权限时仍 fail-closed(跳过规则不被滥用)"
else
  bad "fail-closed 在含 dangerous 转储上失效"
fi

# 12d.4 设备模式完整构建:产出无 TEST 的正式特权包,来源标注正确,双包模块 id 一致
build_assets "$WORK/apks" 0
patch_yaml "$WORK/repo" "$WORK/apks"
cp "$REAL_DUMP" "$WORK/repo/device/framework-permissions.txt"
out="$(run_build "$WORK/repo" "$WORK/apks" "$WORK/dist-device" 2>&1)"; rc=$?
ZIP_NORM_DEV="$WORK/dist-device/GKUI-Pack-test-1.zip"
ZIP_PRIV_DEV="$WORK/dist-device/GKUI-Pack-test-1-recorderpriv.zip"
ZIP_TEST_DEV="$WORK/dist-device/GKUI-Pack-test-1-recorderpriv-TEST.zip"
if [ $rc -eq 0 ] && [ -f "$ZIP_PRIV_DEV" ] && [ ! -f "$ZIP_TEST_DEV" ] && [ -f "$ZIP_NORM_DEV" ]; then
  ok "设备权限表模式产出 GKUI-Pack-test-1-recorderpriv.zip(无 TEST),普通版同时产出"
else
  bad "设备模式构建异常(rc=$rc)"; printf '%s\n' "$out" | tail -25
fi
if printf '%s' "$out" | grep -q '白名单来源：设备权限表（Pixel 5 / Android 16 实测，严格门禁）' \
   && printf '%s' "$out" | grep -q '设备表 XML 与 v0.0.4 TEST 版逐字节一致'; then
  ok "构建日志明确打印白名单来源=设备权限表与 XML 逐字节一致结论"
else
  bad "构建日志缺少白名单来源/逐字节一致标注"
fi
if unzip -p "$ZIP_PRIV_DEV" module.prop | grep -q '^description=.*白名单来源：Pixel 5 / Android 16 设备权限表'; then
  ok "正式特权包 module.prop description 注明设备权限表来源且无 TEST 标记"
else
  bad "正式特权包 module.prop 来源标注错误"
fi
if unzip -p "$ZIP_PRIV_DEV" module.prop | grep -E '^(name|description)=' | grep -q 'TEST'; then
  bad "正式特权包 module.prop 的 name/description 仍含 TEST 字样"
else
  ok "正式特权包 module.prop 的 name/description 不含 TEST(version=test-1 仅为测试版本号)"
fi
if [ "$(unzip -p "$ZIP_NORM_DEV" module.prop | grep '^id=')" = "id=gkui-pack" ] \
   && [ "$(unzip -p "$ZIP_PRIV_DEV" module.prop | grep '^id=')" = "id=gkui-pack" ]; then
  ok "两个 zip 的模块 id 保持一致(gkui-pack)"
else
  bad "双包模块 id 不一致"
fi
if head -n 12 "$WORK/dist-device/PREFLIGHT-REPORT.md" | grep -q '特权变体白名单来源：设备权限表（Pixel 5 / Android 16 实测严格门禁）' \
   && grep -q '已在 Pixel 5 / Android 16 验证开机与 CAPTURE_AUDIO_OUTPUT 授予' "$WORK/dist-device/PREFLIGHT-REPORT.md" \
   && grep -q '通话录音功能本身尚未验证' "$WORK/dist-device/PREFLIGHT-REPORT.md" \
   && grep -q 'enforce 校验状态待 v0.0.5 诊断确认' "$WORK/dist-device/PREFLIGHT-REPORT.md"; then
  ok "PREFLIGHT-REPORT.md 标注设备权限表来源与准确验证口径(不写白名单已验证正确)"
else
  bad "PREFLIGHT-REPORT.md 来源/验证口径标注缺失"
fi
if grep -q '"zipUrl": ".*/GKUI-Pack-test-1\.zip"' "$WORK/dist-device/update.json" \
   && ! grep -q 'recorderpriv' "$WORK/dist-device/update.json"; then
  ok "update.json 的 zipUrl 仍指向普通版(不含 recorderpriv)"
else
  bad "update.json 未指向普通版"
fi
if grep -q 'RELEASE-NOTES-test-1.md' "$WORK/dist-device/update.json"; then
  ok "update.json changelog 按 VERSION 派生(RELEASE-NOTES-<ver>.md)"
else
  bad "update.json changelog 派生异常"
fi
# 正式特权包内:zip 自带白名单 XML;落点逻辑经渲染后的 customize.sh 实跑验证
# (zip 内 APK 在 apks/,由 customize.sh 在安装期移动到 priv-app / app)
if unzip -l "$ZIP_PRIV_DEV" | grep -q 'system/etc/permissions/privapp-permissions-org.lineageos.recorder.dev.xml' \
   && unzip -p "$ZIP_PRIV_DEV" customize.sh | grep -Fq "[ \"\$DIR\" = \"GKUIRecorder\" ] && SUBDIR=\"priv-app\"" \
   && unzip -l "$ZIP_PRIV_DEV" | grep -q 'apks/GKUIRecorder.apk'; then
  ok "正式特权包含白名单 XML 且 customize.sh 保留 Recorder→priv-app 落点逻辑"
else
  bad "正式特权包内容异常"
fi
MODPRIV_DEV="$WORK/modpriv-device"
rm -rf "$MODPRIV_DEV"
mkdir -p "$MODPRIV_DEV"
unzip -q "$ZIP_PRIV_DEV" -d "$MODPRIV_DEV"
out="$( env PATH="$WORK/bin:$PATH" MODPATH="$MODPRIV_DEV" FAKE_PM_PKG="__none__" \
        FAKE_PM_MODE="absent" sh "$MODPRIV_DEV/customize.sh" 2>&1 )"; rc=$?
if [ $rc -eq 0 ] \
   && [ -f "$MODPRIV_DEV/system/priv-app/GKUIRecorder/GKUIRecorder.apk" ] \
   && [ ! -e "$MODPRIV_DEV/system/app/GKUIRecorder" ] \
   && [ -f "$MODPRIV_DEV/system/app/GKUICalendar/GKUICalendar.apk" ] \
   && [ -f "$MODPRIV_DEV/system/etc/permissions/privapp-permissions-org.lineageos.recorder.dev.xml" ]; then
  ok "正式特权包 customize.sh 实跑:Recorder→priv-app、其余→app、白名单 XML 落盘"
else
  bad "正式特权包 customize.sh 实跑落点异常(rc=$rc)"; printf '%s\n' "$out" | tail -15
fi

# 12d.5 XML 与 v0.0.4 TEST 版逐字节一致:同轮次源码模式构建产物 vs 设备模式产物
XML_FROM_TEST="$(unzip -p "$ZIP_PRIV_TEST" system/etc/permissions/privapp-permissions-org.lineageos.recorder.dev.xml)"
XML_FROM_DEV="$(unzip -p "$ZIP_PRIV_DEV" system/etc/permissions/privapp-permissions-org.lineageos.recorder.dev.xml)"
if [ -n "$XML_FROM_TEST" ] && [ "$XML_FROM_TEST" = "$XML_FROM_DEV" ]; then
  ok "正式包白名单 XML 与 v0.0.4 TEST 版(源码表生成)逐字节相同"
else
  bad "正式包 XML 与 TEST 版不一致"; printf '%s\n---\n%s\n' "$XML_FROM_TEST" "$XML_FROM_DEV"
fi
if [ "$(printf '%s' "$XML_FROM_DEV" | grep -c '<permission name=')" -eq 1 ] \
   && printf '%s' "$XML_FROM_DEV" | grep -q 'android.permission.CAPTURE_AUDIO_OUTPUT'; then
  ok "XML 内容只有 CAPTURE_AUDIO_OUTPUT 一项"
else
  bad "XML 不是仅含 CAPTURE_AUDIO_OUTPUT"
fi
rm -f "$WORK/repo/device/framework-permissions.txt"

# 12d.6 严格门禁停止条件:冲突记录 fail-closed;Recorder 无特权交集时拒绝出 priv 包
cp "$REAL_DUMP" "$WORK/repo/device/framework-permissions.txt"
{
  printf '+ permission:android.permission.CAPTURE_AUDIO_OUTPUT\n'
  printf '  protectionLevel:normal\n'
} >> "$WORK/repo/device/framework-permissions.txt"
out="$(run_build "$WORK/repo" "$WORK/apks" "$WORK/dist-conflict" 2>&1)"; rc=$?
if [ $rc -ne 0 ] && printf '%s' "$out" | grep -q '冲突的 protectionLevel' \
   && [ ! -f "$WORK/dist-conflict/GKUI-Pack-test-1-recorderpriv.zip" ]; then
  ok "设备表出现冲突保护级别时严格门禁 fail-closed 且不出特权包"
else
  bad "冲突记录未触发 fail-closed(rc=$rc)"
fi
rm -f "$WORK/repo/device/framework-permissions.txt"
# Recorder 被排除(设备表中 CAPTURE_AUDIO_OUTPUT 不再是 privileged)→ 构建必须中止
sed 's/^\(  protectionLevel:signature|privileged|role\)$/  protectionLevel:signature/' "$REAL_DUMP" \
  > "$WORK/repo/device/framework-permissions.txt"
out="$(run_build "$WORK/repo" "$WORK/apks" "$WORK/dist-excluded" 2>&1)"; rc=$?
if [ $rc -ne 0 ] && printf '%s' "$out" | grep -q '没有交集' \
   && [ ! -f "$WORK/dist-excluded/GKUI-Pack-test-1-recorderpriv.zip" ]; then
  ok "严格门禁下 Recorder 特权交集为空时停止构建(Recorder 被排除即停)"
else
  bad "Recorder 被排除时构建未停止(rc=$rc)"; printf '%s\n' "$out" | tail -12
fi
rm -f "$WORK/repo/device/framework-permissions.txt"

head1 "12e) v0.0.6: stock 包清单过滤空值和 '-'"
STOCK_SENTINEL_REPO="$WORK/repo-stock-sentinel"
STOCK_SENTINEL_APKS="$WORK/apks-stock-sentinel"
STOCK_SENTINEL_DIST="$WORK/dist-stock-sentinel"
cp -a "$WORK/repo" "$STOCK_SENTINEL_REPO"
build_assets "$STOCK_SENTINEL_APKS" 0
patch_yaml "$STOCK_SENTINEL_REPO" "$STOCK_SENTINEL_APKS"
python3 - "$STOCK_SENTINEL_REPO/apps.yaml" <<'PY_STOCK_SENTINEL'
import sys
p=sys.argv[1]
s=open(p, encoding="utf-8").read().splitlines()
app=None
for i,line in enumerate(s):
    if line.startswith("  - id: "):
        app=line.split(":",1)[1].strip()
    if app == "calendar" and line.startswith("    stock_package:"):
        s[i]="    stock_package: -"
    elif app == "gallery" and line.startswith("    stock_package:"):
        s[i]='    stock_package: ""'
open(p,"w",encoding="utf-8").write("\n".join(s)+"\n")
PY_STOCK_SENTINEL
out="$(cd "$STOCK_SENTINEL_REPO" && bash build.sh --check 2>&1)"; rc=$?
if [ $rc -eq 0 ]; then
  ok "apps.yaml 显式无 stock 包(空值或 '-')仍通过清单校验"
else
  bad "空值/'-' stock_package 被错误拒绝(rc=$rc)"; printf '%s\n' "$out" | tail -12
fi
out="$(run_build "$STOCK_SENTINEL_REPO" "$STOCK_SENTINEL_APKS" "$STOCK_SENTINEL_DIST" 2>&1)"; rc=$?
STOCK_SENTINEL_ZIP="$STOCK_SENTINEL_DIST/GKUI-Pack-test-1.zip"
STOCK_SENTINEL_PRIV="$STOCK_SENTINEL_DIST/GKUI-Pack-test-1-recorderpriv-TEST.zip"
expected_sentinel_list="$(printf '%s\n' com.android.calculator2 com.android.deskclock org.lineageos.recorder)"
actual_sentinel_list="$(unzip -p "$STOCK_SENTINEL_ZIP" stock-packages.list 2>/dev/null)"
if [ $rc -eq 0 ] && [ "$actual_sentinel_list" = "$expected_sentinel_list" ]; then
  ok "构建的 stock-packages.list 跳过空值/'-'并保留其他 enabled 包名"
else
  bad "stock-packages.list 空值/'-'过滤异常(rc=$rc)"; printf '%s\n' "$actual_sentinel_list"
fi
if [ -f "$STOCK_SENTINEL_PRIV" ] \
   && [ "$(unzip -p "$STOCK_SENTINEL_PRIV" stock-packages.list)" = "$expected_sentinel_list" ]; then
  ok "recorderpriv 变体也生成相同的 stock-packages.list"
else
  bad "recorderpriv stock-packages.list 与普通版不一致"
fi

# service.sh 后台诊断测试(桩 getprop / dumpsys / logcat / pm)
DIAG_TEST="$WORK/diag-test"
mkdir -p "$DIAG_TEST/mod" "$DIAG_TEST/bin" "$DIAG_TEST/sdcard-dl"
cp "$WORK/dist/GKUI-Pack-test-1-recorderpriv-TEST.zip" "$DIAG_TEST/" 2>/dev/null || true
unzip -p "$ZIP_PRIV_TEST" service.sh > "$DIAG_TEST/mod/service.sh"
unzip -p "$ZIP_PRIV_TEST" stock-packages.list > "$DIAG_TEST/mod/stock-packages.list"
chmod +x "$DIAG_TEST/mod/service.sh"
touch "$DIAG_TEST/mod/.boot_flag"
cat > "$DIAG_TEST/bin/getprop" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
  "") echo "[ro.serialno]: [LEAKED_SERIAL_12345]"; echo "[ril.gsm.imei]: [LEAKED_IMEI_99999]" ;;
  sys.boot_completed) echo "1" ;;
  ro.lineage.version) echo "23.2-stub" ;;
  ro.build.version.incremental) echo "stub-incremental" ;;
  ro.build.date.utc) echo "1793032493" ;;
  ro.build.fingerprint) echo "google/redfin/redfin:16/BP4A.251205.006/stub:userdebug/release-keys" ;;
  ro.control_privapp_permissions) echo "enforce" ;;
  ro.build.version.sdk) echo "36" ;;
  ro.product.device) echo "redfinstub" ;;
  *) echo "" ;;
esac
STUB
cat > "$DIAG_TEST/bin/pm" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
  list)
    printf '+ permission:android.permission.CAPTURE_AUDIO_OUTPUT\n  protectionLevel:signature|privileged|role\n'
    ;;
  path)
    echo "package:/system/stub/${2}.apk"
    ;;
esac
STUB
cat > "$DIAG_TEST/bin/dumpsys" <<'STUB'
#!/usr/bin/env bash
cat <<EOF
Packages:
  Package [${2:-org.lineageos.recorder.dev}] (12345):
    versionCode=90000 targetSdk=36
    signatures=PackageSignatures{stub-signature}
    requested permissions:
      android.permission.CAPTURE_AUDIO_OUTPUT
      android.permission.RECORD_AUDIO
    install permissions:
      android.permission.CAPTURE_AUDIO_OUTPUT: granted=true
    runtime permissions:
      android.permission.RECORD_AUDIO: granted=true, flags=[ USER_SENSITIVE_WHEN_GRANTED ]
    declared permissions:
      ${2:-org.lineageos.recorder.dev}.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION: prot=signature, INSTALLED
    other section:
      should_not_appear
EOF
STUB
cat > "$DIAG_TEST/bin/logcat" <<'STUB'
#!/usr/bin/env bash
echo "10-12 08:00:00.000  1000  1000 I PackageManager: privapp permissions ok for org.lineageos.recorder.dev"
echo "10-12 08:00:01.000  1000  1000 D UnrelatedTag: should be filtered out"
STUB
chmod +x "$DIAG_TEST/bin/getprop" "$DIAG_TEST/bin/pm" "$DIAG_TEST/bin/dumpsys" "$DIAG_TEST/bin/logcat"

env PATH="$DIAG_TEST/bin:$PATH" \
    DIAG_SDCARD_DIR="$DIAG_TEST/sdcard-dl" \
    DIAG_BOOT_MAX_WAIT=2 DIAG_BOOT_SLEEP=1 \
    DIAG_SDCARD_MAX_WAIT=2 DIAG_SDCARD_SLEEP=1 \
    sh "$DIAG_TEST/mod/service.sh"
if [ ! -f "$DIAG_TEST/mod/.boot_flag" ]; then
  ok "service.sh 立即清除 .boot_flag(不阻塞启动)"
else
  bad "service.sh 未清除 .boot_flag"
fi
# 等待后台诊断子进程完成(最多 3 秒)
for _i in 1 2 3 4 5 6; do
  [ -s "$DIAG_TEST/sdcard-dl/GKUI-diag.txt" ] && break
  sleep 0.5
done
if [ -s "$DIAG_TEST/mod/GKUI-diag.txt" ] && [ -s "$DIAG_TEST/sdcard-dl/GKUI-diag.txt" ]; then
  ok "service.sh 后台生成 \$MODDIR/GKUI-diag.txt 并复制到 /sdcard/Download/GKUI-diag.txt"
else
  bad "service.sh 未生成或未复制 GKUI-diag.txt"
fi
if grep -q '^variant: priv-TEST$' "$DIAG_TEST/mod/GKUI-diag.txt" \
   && grep -q 'ro.product.device: redfinstub' "$DIAG_TEST/mod/GKUI-diag.txt" \
   && grep -q 'ro.control_privapp_permissions: enforce' "$DIAG_TEST/mod/GKUI-diag.txt" \
   && grep -q 'android.permission.CAPTURE_AUDIO_OUTPUT: granted=true' "$DIAG_TEST/mod/GKUI-diag.txt" \
   && grep -q 'PackageManager: privapp permissions ok' "$DIAG_TEST/mod/GKUI-diag.txt" \
   && ! grep -q 'LEAKED_SERIAL_12345\|LEAKED_IMEI_99999\|should_not_appear\|UnrelatedTag' "$DIAG_TEST/mod/GKUI-diag.txt"; then
  ok "GKUI-diag.txt 含变体标识/7 项只读属性/权限转储/dumpsys 权限段/过滤后 logcat,且未全量泄露 getprop"
else
  bad "GKUI-diag.txt 内容不符合预期"; cat "$DIAG_TEST/mod/GKUI-diag.txt"
fi
# 章节标题必须实际落盘(回归:printf '---' 在 dash/bash 下会被当成选项而丢行)
if grep -qF -e '--- [6] dumpsys package (' "$DIAG_TEST/mod/GKUI-diag.txt" \
   && grep -qF -e '--- [1] Read-only System Properties' "$DIAG_TEST/mod/GKUI-diag.txt"; then
  ok "诊断报告 7 个章节标题全部落盘(含 stock 状态节;printf 可移植写法)"
else
  bad "诊断报告章节标题缺失"
fi
# 10 个包(5 GKUI + 5 stock)都必须出现在 [2] pm path 与 [6] dumpsys 两节
diag_missing=""
for pkg in $DIAG_GKUI_PKGS $DIAG_STOCK_PKGS; do
  n="$(grep -c "^\[$pkg\]\$" "$DIAG_TEST/mod/GKUI-diag.txt" || true)"
  [ "$n" -eq 2 ] || diag_missing="$diag_missing $pkg($n)"
done
if [ -z "$diag_missing" ]; then
  ok "[2]/[6] 两节覆盖全部 10 个包(5 GKUI + 5 stock),每包各出现 2 次"
else
  bad "10 包采集缺失:$diag_missing"
fi
if [ "$(grep -c '^package:/system/stub/' "$DIAG_TEST/mod/GKUI-diag.txt" || true)" -eq 10 ]; then
  ok "[2] 对 10 个包各执行一次 pm path(共 10 行路径)"
else
  bad "[2] pm path 采集行数不是 10"
fi
# [6] 每包都要带 declared permissions 段、signatures 与 versionCode 行
if [ "$(grep -c '^    declared permissions:$' "$DIAG_TEST/mod/GKUI-diag.txt" || true)" -eq 10 ] \
   && [ "$(grep -c 'signatures=PackageSignatures' "$DIAG_TEST/mod/GKUI-diag.txt" || true)" -eq 10 ] \
   && [ "$(grep -c 'versionCode=90000' "$DIAG_TEST/mod/GKUI-diag.txt" || true)" -eq 10 ]; then
  ok "[6] 10 包 dumpsys 的 declared permissions / signatures / versionCode 均已采集"
else
  bad "[6] dumpsys 采集不完整"
fi

# 当 /sdcard/Download 不可写(模拟 FBE 超时未解锁)时,在 $MODDIR/GKUI-diag.txt 末尾记录原因并退出
DIAG_TIMEOUT="$WORK/diag-timeout"
mkdir -p "$DIAG_TIMEOUT/mod"
unzip -p "$ZIP" service.sh > "$DIAG_TIMEOUT/mod/service.sh"
chmod +x "$DIAG_TIMEOUT/mod/service.sh"
env PATH="$DIAG_TEST/bin:$PATH" \
    DIAG_SDCARD_DIR="$DIAG_TIMEOUT/nonexistent-sdcard-dl" \
    DIAG_BOOT_MAX_WAIT=1 DIAG_BOOT_SLEEP=1 \
    DIAG_SDCARD_MAX_WAIT=1 DIAG_SDCARD_SLEEP=1 \
    sh "$DIAG_TIMEOUT/mod/service.sh"
for _i in 1 2 3 4 5 6; do
  grep -q 'sdcard_copy: timeout_or_unwritable' "$DIAG_TIMEOUT/mod/GKUI-diag.txt" 2>/dev/null && break
  sleep 0.5
done
if grep -q '^variant: normal$' "$DIAG_TIMEOUT/mod/GKUI-diag.txt" 2>/dev/null \
   && grep -q 'sdcard_copy: timeout_or_unwritable' "$DIAG_TIMEOUT/mod/GKUI-diag.txt" 2>/dev/null; then
  ok "service.sh 在 /sdcard/Download 超时未解锁时在 \$MODDIR/GKUI-diag.txt 末尾记录原因并退出"
else
  bad "service.sh 超时未解锁分支行为异常"
fi

head1 "12f) v0.0.6: service.sh 可逆停用 stock 的状态机"
STOCK_TOGGLE="$WORK/stock-toggle"
STOCK_TOGGLE_MOD="$STOCK_TOGGLE/mod"
STOCK_TOGGLE_BIN="$STOCK_TOGGLE/bin"
mkdir -p "$STOCK_TOGGLE_MOD" "$STOCK_TOGGLE_BIN" "$STOCK_TOGGLE/sdcard"
unzip -q "$ZIP" -d "$STOCK_TOGGLE_MOD"
cat > "$STOCK_TOGGLE_BIN/getprop" <<'STUB'
#!/bin/sh
[ "${1:-}" = sys.boot_completed ] && echo 1
exit 0
STUB
cat > "$STOCK_TOGGLE_BIN/pm" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$FAKE_PM_CALLS"
case "${1:-}" in
  list)
    if [ "${2:-}" = packages ] && [ "${3:-}" = -e ]; then
      [ "${FAKE_PM_LIST_RC:-0}" -eq 0 ] || exit "${FAKE_PM_LIST_RC:-1}"
      if [ -f "$FAKE_PM_ENABLED_FILE" ]; then
        while IFS= read -r listed_pkg; do
          [ -n "$listed_pkg" ] && printf 'package:%s\n' "$listed_pkg"
        done < "$FAKE_PM_ENABLED_FILE"
      fi
      exit 0
    fi
    if [ "${2:-}" = permissions ]; then
      printf 'Permissions:\n'
      exit 0
    fi
    exit 0
    ;;
  path)
    printf 'package:/system/stub/%s.apk\n' "${2:-}"
    exit 0
    ;;
  disable-user)
    pkg="${4:-}"
    [ "$pkg" != "${FAKE_PM_FAIL_DISABLE:-}" ] || exit 7
    awk -v p="$pkg" '$0 != p && NF { print }' "$FAKE_PM_ENABLED_FILE" > "$FAKE_PM_ENABLED_FILE.tmp"
    mv -f "$FAKE_PM_ENABLED_FILE.tmp" "$FAKE_PM_ENABLED_FILE"
    exit 0
    ;;
  enable)
    pkg="${2:-}"
    [ "$pkg" != "${FAKE_PM_FAIL_ENABLE:-}" ] || exit 9
    if ! grep -Fqx "$pkg" "$FAKE_PM_ENABLED_FILE"; then
      printf '%s\n' "$pkg" >> "$FAKE_PM_ENABLED_FILE"
    fi
    exit 0
    ;;
esac
exit 0
STUB
chmod +x "$STOCK_TOGGLE_BIN/getprop" "$STOCK_TOGGLE_BIN/pm"
printf '%s\n' org.lineageos.etar com.android.calculator2 org.lineageos.recorder > "$STOCK_TOGGLE/enabled.list"
cat > "$STOCK_TOGGLE_MOD/stock-packages.list" <<'EOF'
org.lineageos.etar
org.lineageos.etar
org.lineageos.glimpse
com.android.calculator2
com.android.deskclock
org.lineageos.recorder
EOF
run_stock_toggle_service() {
  rm -f "$STOCK_TOGGLE_MOD/GKUI-diag.txt" "$STOCK_TOGGLE/sdcard/GKUI-diag.txt"
  env PATH="$STOCK_TOGGLE_BIN:$PATH" \
      FAKE_PM_CALLS="$STOCK_TOGGLE/pm-calls" \
      FAKE_PM_ENABLED_FILE="$STOCK_TOGGLE/enabled.list" \
      FAKE_PM_FAIL_DISABLE="${1:-}" FAKE_PM_FAIL_ENABLE="${2:-}" \
      DIAG_SDCARD_DIR="$STOCK_TOGGLE/sdcard" \
      DIAG_BOOT_MAX_WAIT=2 DIAG_SDCARD_MAX_WAIT=2 DIAG_SDCARD_SLEEP=1 \
      sh "$STOCK_TOGGLE_MOD/service.sh"
  for _stock_wait in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    grep -q 'sdcard_copy: ok' "$STOCK_TOGGLE_MOD/GKUI-diag.txt" 2>/dev/null && break
    sleep 0.1
  done
}
: > "$STOCK_TOGGLE/pm-calls"
run_stock_toggle_service com.android.calculator2 ""
if grep -Fqx 'disable-user --user 0 org.lineageos.etar' "$STOCK_TOGGLE/pm-calls" \
   && grep -Fqx 'disable-user --user 0 com.android.calculator2' "$STOCK_TOGGLE/pm-calls" \
   && grep -Fqx 'disable-user --user 0 org.lineageos.recorder' "$STOCK_TOGGLE/pm-calls" \
   && ! grep -Fqx 'disable-user --user 0 org.lineageos.glimpse' "$STOCK_TOGGLE/pm-calls" \
   && ! grep -Fqx 'disable-user --user 0 com.android.deskclock' "$STOCK_TOGGLE/pm-calls"; then
  ok "无 keep-stock 时只对 pm list packages -e 中启用的 stock 调用 disable-user"
else
  bad "默认停用错误处理了已停用 stock 包"
fi
stock_after_first="$(cat "$STOCK_TOGGLE_MOD/stock-disabled.list" 2>/dev/null)"
if [ "$stock_after_first" = "org.lineageos.etar
org.lineageos.recorder" ] \
   && [ "$(grep -Fc 'package=com.android.calculator2 action=disable-user rc=7' "$STOCK_TOGGLE_MOD/stock-toggle.log" || true)" -eq 1 ] \
   && grep -q 'package=org.lineageos.glimpse action=preserve-user-disabled rc=0' "$STOCK_TOGGLE_MOD/stock-toggle.log"; then
  ok "成功停用项唯一追加;失败有 rc 记录,用户自行停用项保持不动"
else
  bad "stock-disabled.list 添加/去重或失败日志异常"; cat "$STOCK_TOGGLE_MOD/stock-disabled.list" 2>/dev/null
fi
if grep -qF -- '--- [0] Stock app toggle state ---' "$STOCK_TOGGLE_MOD/GKUI-diag.txt" \
   && grep -q 'stock-toggle.log:' "$STOCK_TOGGLE_MOD/GKUI-diag.txt" \
   && grep -q 'stock-disabled.list:' "$STOCK_TOGGLE_MOD/GKUI-diag.txt"; then
  ok "诊断文件打印 stock-toggle.log 与 stock-disabled.list"
else
  bad "stock 状态未写入诊断文件"
fi

# keep-stock 只恢复 stock-disabled.list 中记录的包;去重;失败项仍保留供下次重试。
printf '%s\n' org.lineageos.etar org.lineageos.etar org.lineageos.recorder com.android.deskclock \
  > "$STOCK_TOGGLE_MOD/stock-disabled.list"
touch "$STOCK_TOGGLE_MOD/keep-stock"
: > "$STOCK_TOGGLE/pm-calls"
run_stock_toggle_service "" com.android.deskclock
if grep -Fqx 'enable org.lineageos.etar' "$STOCK_TOGGLE/pm-calls" \
   && grep -Fqx 'enable org.lineageos.recorder' "$STOCK_TOGGLE/pm-calls" \
   && grep -Fqx 'enable com.android.deskclock' "$STOCK_TOGGLE/pm-calls" \
   && ! grep -q '^disable-user ' "$STOCK_TOGGLE/pm-calls" \
   && [ "$(cat "$STOCK_TOGGLE_MOD/stock-disabled.list")" = "com.android.deskclock" ] \
   && grep -q 'package=com.android.deskclock action=enable rc=9' "$STOCK_TOGGLE_MOD/stock-toggle.log"; then
  ok "有 keep-stock 时仅 enable 跟踪清单;成功项移除、失败项保留且去重"
else
  bad "keep-stock 恢复/移除逻辑异常"; cat "$STOCK_TOGGLE_MOD/stock-disabled.list" 2>/dev/null
fi

# 删除标记后恢复默认;已启用包被再次停用并登记,失败包仍保持唯一记录。
rm -f "$STOCK_TOGGLE_MOD/keep-stock"
: > "$STOCK_TOGGLE/pm-calls"
run_stock_toggle_service com.android.calculator2 ""
if grep -Fqx 'disable-user --user 0 org.lineageos.etar' "$STOCK_TOGGLE/pm-calls" \
   && grep -Fqx 'disable-user --user 0 org.lineageos.recorder' "$STOCK_TOGGLE/pm-calls" \
   && [ "$(awk 'NF {n++} END {print n+0}' "$STOCK_TOGGLE_MOD/stock-disabled.list")" -eq 3 ] \
   && [ "$(sort -u "$STOCK_TOGGLE_MOD/stock-disabled.list" | awk 'NF {n++} END {print n+0}')" -eq 3 ]; then
  ok "移除 keep-stock 后恢复默认停用,新增记录且 stock-disabled.list 无重复"
else
  bad "keep-stock 删除后的默认停用或去重异常"; cat "$STOCK_TOGGLE_MOD/stock-disabled.list" 2>/dev/null
fi

head1 "12g) v0.0.6: customize getevent 缺失降级、卸载 service.d 自动恢复"
NOGE_BIN="$WORK/no-getevent-bin"
mkdir -p "$NOGE_BIN"
for _cmd in chown chmod find sha256sum cp mkdir wc tr rm cat awk; do
  _cmd_path="$(command -v "$_cmd" 2>/dev/null)"
  [ -n "$_cmd_path" ] && ln -sf "$_cmd_path" "$NOGE_BIN/$_cmd"
done
cat > "$NOGE_BIN/pm" <<'STUB'
#!/bin/sh
case "${1:-}" in
  list) exit 0 ;;
  path) exit 0 ;;
esac
exit 0
STUB
chmod +x "$NOGE_BIN/pm"
for _variant in normal priv; do
  if [ "$_variant" = normal ]; then _zip="$ZIP"; else _zip="$ZIP_PRIV_TEST"; fi
  _mod="$WORK/no-getevent-$_variant"
  rm -rf "$_mod"; mkdir -p "$_mod"
  unzip -q "$_zip" -d "$_mod"
  out="$(env PATH="$NOGE_BIN" MODPATH="$_mod" /bin/sh "$_mod/customize.sh" 2>&1)"; rc=$?
  if [ $rc -eq 0 ] && [ ! -e "$_mod/keep-stock" ] \
     && printf '%s' "$out" | grep -q 'getevent 不存在' \
     && printf '%s' "$out" | grep -q '当前选择:默认停用 stock'; then
    ok "$_variant customize.sh 在 getevent 缺失时不报错且不创建 keep-stock"
  else
    bad "$_variant customize.sh 的 getevent 缺失回退异常(rc=$rc)"; printf '%s\n' "$out" | tail -10
  fi
done

UNINSTALL_TEST="$WORK/uninstall-test"
UNINSTALL_MOD="$UNINSTALL_TEST/mod"
mkdir -p "$UNINSTALL_MOD"
unzip -p "$ZIP" uninstall.sh > "$UNINSTALL_MOD/uninstall.sh"
unzip -p "$ZIP" stock-packages.list > "$UNINSTALL_MOD/stock-packages.list"
printf '%s\n%s\n' "$DIAG_STOCK_PKGS" org.lineageos.etar | tr ' ' '\n' > "$UNINSTALL_MOD/stock-disabled.list"
if ! grep -q 'pm ' "$UNINSTALL_MOD/uninstall.sh"; then
  ok "uninstall.sh 不含直接 PackageManager 调用"
else
  bad "uninstall.sh 含 pm 调用文本"
fi
sed "s|/data/adb|$UNINSTALL_TEST/data/adb|g" "$UNINSTALL_MOD/uninstall.sh" \
  > "$UNINSTALL_MOD/uninstall-test.sh"
sh -n "$UNINSTALL_MOD/uninstall-test.sh"
out="$(sh "$UNINSTALL_MOD/uninstall-test.sh" 2>&1)"; rc=$?
RESTORE_SCRIPT="$UNINSTALL_TEST/data/adb/service.d/gkui-pack-restore-stock.sh"
if [ $rc -eq 0 ] && [ -x "$RESTORE_SCRIPT" ] && sh -n "$RESTORE_SCRIPT"; then
  ok "uninstall.sh 生成可执行且 sh -n 通过的 service.d 一次性恢复脚本"
else
  bad "卸载恢复脚本生成/语法异常(rc=$rc)"; printf '%s\n' "$out"
fi
restore_names_ok=1
for pkg in $DIAG_STOCK_PKGS; do
  grep -Fqx "$pkg" "$RESTORE_SCRIPT" || restore_names_ok=0
done
if [ "$restore_names_ok" -eq 1 ]; then
  ok "service.d 恢复脚本内联 stock-disabled.list 中的全部包名(重复项去重)"
else
  bad "service.d 恢复脚本遗漏包名"
fi
: > "$STOCK_TOGGLE/enabled.list"
: > "$STOCK_TOGGLE/pm-calls"
env PATH="$STOCK_TOGGLE_BIN:$PATH" \
    FAKE_PM_CALLS="$STOCK_TOGGLE/pm-calls" \
    FAKE_PM_ENABLED_FILE="$STOCK_TOGGLE/enabled.list" \
    FAKE_PM_FAIL_ENABLE="" \
    sh "$RESTORE_SCRIPT"
restore_calls_ok=1
for pkg in $DIAG_STOCK_PKGS; do
  grep -Fqx "enable $pkg" "$STOCK_TOGGLE/pm-calls" || restore_calls_ok=0
  grep -q "package=$pkg action=enable rc=0" "$UNINSTALL_TEST/data/adb/gkui-pack-restore.log" || restore_calls_ok=0
done
if [ "$restore_calls_ok" -eq 1 ] && [ ! -e "$RESTORE_SCRIPT" ]; then
  ok "恢复脚本逐包 enable、写 /data/adb/gkui-pack-restore.log 并在执行后自删"
else
  bad "service.d 恢复脚本执行结果/日志/自删异常"
fi

# docs/TESTER.md 行数 <= 15 且不含任何命令,并含刷前卸载提醒
if [ -f "$REPO_ROOT/docs/TESTER.md" ]; then
  tester_lines="$(wc -l < "$REPO_ROOT/docs/TESTER.md" | tr -d ' ')"
  if [ "$tester_lines" -le 15 ] \
     && grep -q '设置 → 应用' "$REPO_ROOT/docs/TESTER.md" \
     && ! grep -qE 'adb |pm uninstall|sh |bash ' "$REPO_ROOT/docs/TESTER.md"; then
    ok "docs/TESTER.md 行数 <= 15(实际=${tester_lines}行)、0 条命令且含『设置 → 应用』刷前卸载提醒"
  else
    bad "docs/TESTER.md 不符合行数/0命令/卸载提醒要求(lines=$tester_lines)"
  fi
else
  bad "缺少 docs/TESTER.md"
fi

# -----------------------------------------------------------------------------
head1 "13) 测试没有写脏工作区"
# -----------------------------------------------------------------------------
if [ -d "$REPO_ROOT/.git" ]; then
  leaked=""
  for f in "$REPO_ROOT/PREFLIGHT-REPORT.md" "$REPO_ROOT/apps.json" "$REPO_ROOT/dist" "$REPO_ROOT/build"; do
    [ -e "$f" ] && leaked="$leaked $(basename "$f")"
  done
  if [ -z "$leaked" ]; then ok "测试未在仓库内留下 dist/ 报告/ 等产物"; else bad "测试在仓库内留下产物:$leaked"; fi
  apk_leak="$(find "$REPO_ROOT" -name '*.apk' -not -path '*/.git/*' 2>/dev/null | head -5)"
  if [ -z "$apk_leak" ]; then ok "仓库内不存在任何 .apk(含未跟踪文件,C5)"; else bad "仓库内出现 .apk: $apk_leak"; fi
fi

# -----------------------------------------------------------------------------
printf '\n%s=== 结果:%d 通过 / %d 失败 ===%s\n' "$C_BLD" "$PASS" "$FAIL" "$C_RST"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
