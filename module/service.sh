#!/system/bin/sh
# =============================================================================
# service.sh —— late_start service 阶段执行(系统接近完成启动)
#
# 职责:
#   1) 清除 post-fs-data.sh 立下的 .boot_flag,表明上一次启动已顺利走到这里;
#   2) 记录最近一次成功启动的时间戳到本模块目录(仅用于排障,不触碰系统分区);
#   3) 后台子进程 ( ... ) & 自动采集诊断信息:
#      - 先写 $MODDIR/GKUI-diag.txt(不依赖 FBE 解锁)
#      - 再轮询等待 /sdcard/Download 可写(每 5 秒实际试写一次,最多 600 秒),
#        可写后复制到 /sdcard/Download/GKUI-diag.txt;若超时则在
#        $MODDIR/GKUI-diag.txt 末尾记录原因并退出。
#      - 绝不写 $MODDIR 和 /sdcard/Download/GKUI-diag.txt 以外的任何路径。
#
# 诊断报告章节(v0.0.5):
#   [1] 7 个只读属性(键名按规格逐字固定,严禁无参 getprop 全量 dump)
#   [2] 10 个包(5 GKUI + 5 stock)的 pm path
#   [3] recorder.dev 的 requested/install/runtime permissions 段
#   [4] 过滤后的 logcat(privapp|signature changed|PackageManager)
#   [5] pm list permissions -f 全量权限表(保持原样)
#   [6] 10 个包各取 dumpsys package 的 declared permissions 段与
#       signatures / versionCode 行
# =============================================================================
MODDIR="${0%/*}"
rm -f "$MODDIR/.boot_flag"

{
  printf 'last_boot_ok epoch=%s\n' "$(date +%s 2>/dev/null || echo unknown)"
} > "$MODDIR/last_boot.log" 2>/dev/null

(
  MOD_VERSION="__VERSION__"
  MOD_VARIANT="__VARIANT__"
  case "$MOD_VERSION" in
    "__""VERSION__"|"") MOD_VERSION="unrendered" ;;
  esac
  case "$MOD_VARIANT" in
    "__""VARIANT__"|"") MOD_VARIANT="normal" ;;
  esac

  DIAG_FILE="$MODDIR/GKUI-diag.txt"
  SDCARD_DIR="${DIAG_SDCARD_DIR:-/sdcard/Download}"
  SDCARD_FILE="$SDCARD_DIR/GKUI-diag.txt"
  BOOT_MAX="${DIAG_BOOT_MAX_WAIT:-120}"
  BOOT_INT="${DIAG_BOOT_SLEEP:-1}"
  SD_MAX="${DIAG_SDCARD_MAX_WAIT:-600}"
  SD_INT="${DIAG_SDCARD_SLEEP:-5}"

  # 1) 等待 getprop sys.boot_completed 为 1(最多 120 秒)
  boot_waited=0
  boot_ok=0
  if command -v getprop >/dev/null 2>&1; then
    while [ "$boot_waited" -lt "$BOOT_MAX" ]; do
      if [ "$(getprop sys.boot_completed 2>/dev/null)" = "1" ]; then
        boot_ok=1
        break
      fi
      sleep "$BOOT_INT"
      boot_waited=$((boot_waited + BOOT_INT))
    done
    if [ "$boot_ok" -eq 0 ] && [ "$(getprop sys.boot_completed 2>/dev/null)" = "1" ]; then
      boot_ok=1
    fi
  fi

  # 2) 先写 $MODDIR/GKUI-diag.txt(不依赖 FBE 解锁)
  {
    printf '=== GKUI-Pack Diagnostic Report ===\n'
    printf 'version: %s\n' "$MOD_VERSION"
    printf 'variant: %s\n' "$MOD_VARIANT"
    printf 'timestamp_epoch: %s\n' "$(date +%s 2>/dev/null || echo unknown)"
    printf 'boot_completed: %s (waited=%ss)\n\n' "$boot_ok" "$boot_waited"

    printf '%s\n' '--- [1] Read-only System Properties (7 allowlisted keys only) ---'
    # 严禁无参 getprop 全量 dump(避免泄露序列号/IMEI)。
    # 键名逐字按诊断规格固定为以下 7 个,不得增删改(由 tests/test_build.sh 断言):
    for prop in \
      ro.lineage.version \
      ro.build.version.incremental \
      ro.build.date.utc \
      ro.build.fingerprint \
      ro.control_privapp_permissions \
      ro.build.version.sdk \
      ro.product.device; do
      val=""
      if command -v getprop >/dev/null 2>&1; then
        val="$(getprop "$prop" 2>/dev/null)"
      fi
      printf '%s: %s\n' "$prop" "${val:-<empty>}"
    done
    printf '\n'

    printf '%s\n' '--- [2] Target Packages pm path (10 apps: 5 GKUI + 5 stock) ---'
    for pkg in \
      ws.xsoh.etar.debug \
      org.lineageos.glimpse.dev \
      com.android.calculator2.dev \
      com.android.deskclock.dev \
      org.lineageos.recorder.dev \
      org.lineageos.etar \
      org.lineageos.glimpse \
      com.android.calculator2 \
      com.android.deskclock \
      org.lineageos.recorder; do
      p_out=""
      if command -v pm >/dev/null 2>&1; then
        p_out="$(pm path "$pkg" 2>/dev/null)"
      fi
      printf '[%s]\n%s\n' "$pkg" "${p_out:-<not installed>}"
    done
    printf '\n'

    printf '%s\n' '--- [3] dumpsys package org.lineageos.recorder.dev (permission sections) ---'
    if command -v dumpsys >/dev/null 2>&1; then
      dumpsys package org.lineageos.recorder.dev 2>/dev/null | awk '
        /^[[:space:]]*(requested|install|runtime) permissions:/ {
          in_sec = 1
          base_indent = match($0, /[^[:space:]]/) - 1
          print
          next
        }
        in_sec {
          if ($0 ~ /^[[:space:]]*$/) {
            in_sec = 0
            next
          }
          cur_indent = match($0, /[^[:space:]]/) - 1
          if (cur_indent <= base_indent && $0 !~ /^[[:space:]]*(requested|install|runtime) permissions:/) {
            in_sec = 0
          } else {
            print
          }
        }
      '
    else
      printf '<dumpsys unavailable>\n'
    fi
    printf '\n'

    printf '%s\n' '--- [4] logcat (privapp|signature changed|PackageManager, last 300 lines) ---'
    if command -v logcat >/dev/null 2>&1; then
      logcat -d 2>/dev/null | grep -E 'privapp|signature changed|PackageManager' | tail -n 300
    else
      printf '<logcat unavailable>\n'
    fi
    printf '\n'

    printf '%s\n' '--- [5] pm list permissions -f ---'
    if command -v pm >/dev/null 2>&1; then
      pm list permissions -f 2>/dev/null
    else
      printf '<pm unavailable>\n'
    fi
    printf '\n'

    # [6] 对 5 个 GKUI 包 + 5 个 stock 包各采集 dumpsys package 的:
    #     "declared permissions" 段落,以及 signatures / versionCode 行。
    #     只做只读 grep/awk 提取,不做任何改写;包未安装时输出 <not installed>。
    printf '%s\n' '--- [6] dumpsys package x10 (declared permissions / signatures / versionCode) ---'
    for pkg in \
      ws.xsoh.etar.debug \
      org.lineageos.glimpse.dev \
      com.android.calculator2.dev \
      com.android.deskclock.dev \
      org.lineageos.recorder.dev \
      org.lineageos.etar \
      org.lineageos.glimpse \
      com.android.calculator2 \
      com.android.deskclock \
      org.lineageos.recorder; do
      printf '[%s]\n' "$pkg"
      if command -v dumpsys >/dev/null 2>&1; then
        d_out="$(dumpsys package "$pkg" 2>/dev/null | awk '
          /^[[:space:]]*declared permissions:/ {
            in_sec = 1
            base_indent = match($0, /[^[:space:]]/) - 1
            print
            next
          }
          in_sec {
            if ($0 ~ /^[[:space:]]*$/) {
              in_sec = 0
              next
            }
            cur_indent = match($0, /[^[:space:]]/) - 1
            if (cur_indent <= base_indent) {
              in_sec = 0
            } else {
              print
              next
            }
          }
          /versionCode|signatures/ { print }
        ')"
        printf '%s\n' "${d_out:-<not installed>}"
      else
        printf '<dumpsys unavailable>\n'
      fi
    done
    printf '\n'
  } > "$DIAG_FILE" 2>/dev/null

  # 3) 轮询等待 /sdcard/Download 可写(每 5 秒实际试写一次,最多 600 秒 = 10 分钟)
  #    绝不写 $MODDIR 和 /sdcard/Download/GKUI-diag.txt 以外的任何路径
  sd_waited=0
  sd_ok=0
  if command -v getprop >/dev/null 2>&1 || [ -n "${DIAG_SDCARD_DIR:-}" ]; then
    while [ "$sd_waited" -lt "$SD_MAX" ]; do
      if [ -d "$SDCARD_DIR" ] && cp -f "$DIAG_FILE" "$SDCARD_FILE" 2>/dev/null && [ -s "$SDCARD_FILE" ]; then
        sd_ok=1
        break
      fi
      sleep "$SD_INT"
      sd_waited=$((sd_waited + SD_INT))
    done
    if [ "$sd_ok" -eq 0 ] && [ -d "$SDCARD_DIR" ] && cp -f "$DIAG_FILE" "$SDCARD_FILE" 2>/dev/null && [ -s "$SDCARD_FILE" ]; then
      sd_ok=1
    fi
  fi

  if [ "$sd_ok" -eq 1 ]; then
    printf 'sdcard_copy: ok (%s, waited=%ss)\n' "$SDCARD_FILE" "$sd_waited" >> "$DIAG_FILE" 2>/dev/null
    cp -f "$DIAG_FILE" "$SDCARD_FILE" 2>/dev/null || true
  else
    printf 'sdcard_copy: timeout_or_unwritable (waited=%ss, target=%s not writable; FBE may still be locked after %ss)\n' \
      "$sd_waited" "$SDCARD_FILE" "$SD_MAX" >> "$DIAG_FILE" 2>/dev/null
  fi
) </dev/null >/dev/null 2>&1 &
