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
chmod +x "$WORK/repo/scripts/"*.sh "$WORK/repo/build.sh"

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
        echo "  E: permission (line=1)"
        echo "    A: android:name(0x01010003)=\"com.example.stub.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION\" (Raw: \"com.example.stub.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION\")"
        echo "    A: android:protectionLevel(0x01010009)=(type 0x11)0x12"
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
    "clock":      ("com.android.deskclock.dev", "80000", "$SIGNER_CLOCK"),
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
head1 "1) 真实仓库状态:四个应用字段已齐全;recorder 已实测回填但仍留 TODO(禁用)"
# -----------------------------------------------------------------------------
out="$(cd "$REPO_ROOT" && bash build.sh --check 2>&1)"; rc=$?
if [ $rc -eq 0 ]; then ok "bash build.sh --check 通过(rc=0):启用条目已无 TODO"; else bad "字段已齐全却未通过校验(rc=$rc)"; printf '%s\n' "$out" | tail -20; fi
if printf '%s' "$out" | grep -q '\[跳过\].*recorder'; then ok "报告里 recorder 仍被显式跳过并打印"; else bad "未打印 recorder 跳过信息"; fi
if (cd "$REPO_ROOT" && bash build.sh --check --strict >/dev/null 2>&1); then
  bad "--strict 下 disabled 条目的 TODO 仍通过(违反字面版 C7)"
else
  ok "--strict 下 disabled 条目的 TODO 仍会失败(字面版 C7)"
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
if (cd "$WORK/repo" && bash build.sh --check 2>&1 | grep -q 'recorder'); then
  ok "disabled 的 recorder 条目被显式跳过并打印"
else
  bad "未打印 recorder 跳过信息"
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
if [ $rc -eq 0 ] && [ -f "$ZIP" ]; then ok "构建成功并生成 $(basename "$ZIP")"; else bad "构建失败(rc=$rc)"; printf '%s\n' "$out" | tail -30; fi
if [ -f "$ZIP" ]; then
  listing="$(unzip -l "$ZIP" | awk '{print $4}')"
  for need in module.prop customize.sh post-fs-data.sh service.sh uninstall.sh \
              META-INF/com/google/android/update-binary META-INF/com/google/android/updater-script; do
    if printf '%s\n' "$listing" | grep -q "^$need\$"; then ok "zip 内含 $need"; else bad "zip 缺少 $need"; fi
  done
  for name in GKUICalendar GKUIPhotos GKUICalculator GKUIClock; do
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

# -----------------------------------------------------------------------------
head1 "8) C8:/data 冲突检查(渲染后的 customize.sh + 桩 pm)"
# -----------------------------------------------------------------------------
stage_module() { # $1=目标目录:从构建产物准备一个"已安装模块"的等价目录
  local d="$1" name
  rm -rf "$d"
  mkdir -p "$d/apks"
  cp -a "$WORK/repo/module/." "$d/"
  unzip -p "$ZIP" customize.sh > "$d/customize.sh"
  for name in GKUICalendar GKUIPhotos GKUICalculator GKUIClock; do
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
  for name in GKUICalendar GKUIPhotos GKUICalculator GKUIClock; do
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

  # 8.5 未渲染的 customize.sh(仓库原始版)必须拒绝安装
  out="$( env PATH="$WORK/bin:$PATH" MODPATH="$WORK/emptymod" sh "$REPO_ROOT/module/customize.sh" 2>&1 )"; rc=$?
  if [ $rc -ne 0 ] && printf '%s' "$out" | grep -q '未渲染'; then
    ok "未渲染的模块(直接打包 module/)拒绝安装并说明原因"
  else
    bad "未渲染的模块未拒绝安装(rc=$rc)"
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
for pkg in ws.xsoh.etar.debug org.lineageos.glimpse.dev com.android.calculator2.dev com.android.deskclock.dev; do
  if printf '%s' "$out" | grep -q "$pkg"; then ok "dry-run 覆盖 $pkg"; else bad "dry-run 未覆盖 $pkg"; fi
done

# 10.2 install_all:正常路径
out="$(ADB_STUB_MODE=ok ia 2>&1)"; rc=$?
if [ $rc -eq 0 ] && printf '%s' "$out" | grep -q '成功: 4'; then
  ok "install_all 正常路径:4 个应用全部成功"
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
if [ $rc -eq 2 ] && printf '%s' "$out" | grep -q '多台设备'; then ok "多设备时要求 -s 指定"; else bad "多设备处理异常(rc=$rc)"; fi
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
if [ $rc -eq 0 ] && printf '%s' "$out" | grep -q '成功: 4'; then ok "uninstall_all --yes 正常卸载 4 项"; else bad "uninstall_all 异常(rc=$rc)"; fi
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
        ok = (app["confidence"] == "unverified" and app["_enabled"] is False
              and app["application_id"] == "org.lineageos.recorder.dev"
              and app["application_id"] != app["stock_package"]
              and str(app["installed_version_code"]) == "1"
              and bool(app["_todo_fields"]))
        sys.exit(0 if ok else 1)
sys.exit(1)
PYEOF
then ok "recorder:实测包名与 versionCode 已回填,且仍 unverified + disabled + 留有 TODO"; else bad "recorder 条目不符合要求"; fi
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
