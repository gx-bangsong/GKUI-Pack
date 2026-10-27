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
#      - 诊断报告仅写入模块目录和 /sdcard/Download/GKUI-diag.txt;stock 状态清单与日志
#        也保存在模块目录。
#
# 诊断报告章节(v0.0.6):
#   [0] stock 状态日志、成功停用清单与 keep-stock 标记状态
#   [1] 7 个只读属性(键名按规格逐字固定,严禁无参 getprop 全量 dump)
#   [2] 5 个 GKUI 包 + stock-packages.list 中包名的 pm path
#   [3] recorder.dev 的 requested/install/runtime permissions 段
#   [4] 过滤后的 logcat(privapp|signature changed|PackageManager)
#   [5] pm list permissions -f 全量权限表(保持原样)
#   [6] 同一组包各取 dumpsys package 的 declared permissions 段与
#       signatures / versionCode 行;stock 包名只从 stock-packages.list 读取
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
  STOCK_PACKAGES_FILE="$MODDIR/stock-packages.list"
  STOCK_DISABLED_FILE="$MODDIR/stock-disabled.list"
  STOCK_TOGGLE_LOG="$MODDIR/stock-toggle.log"

  stock_log_result() {
    _stock_ts="$(date '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null)"
    [ -n "$_stock_ts" ] || _stock_ts=unknown
    printf '%s package=%s action=%s rc=%s\n' \
      "$_stock_ts" "$1" "$2" "$3" >> "$STOCK_TOGGLE_LOG" 2>/dev/null
  }

  stock_package_valid() {
    case "$1" in
      ''|*[!A-Za-z0-9_.]*) return 1 ;;
    esac
    case "$1" in
      [A-Za-z]*.*) : ;;
      *) return 1 ;;
    esac
    case "$1" in
      .*|*..*|*.) return 1 ;;
    esac
    return 0
  }

  stock_list_contains() {
    [ -f "$STOCK_DISABLED_FILE" ] || return 1
    grep -Fqx "$1" "$STOCK_DISABLED_FILE" 2>/dev/null
  }

  stock_normalize_disabled_list() {
    [ -f "$STOCK_DISABLED_FILE" ] || return 0
    _stock_tmp="$MODDIR/.stock-disabled.list.tmp"
    if awk 'NF && !seen[$0]++ { print }' "$STOCK_DISABLED_FILE" > "$_stock_tmp" 2>/dev/null \
      && mv -f "$_stock_tmp" "$STOCK_DISABLED_FILE" 2>/dev/null; then
      return 0
    fi
    rm -f "$_stock_tmp" 2>/dev/null
    return 1
  }

  stock_add_disabled() {
    _stock_pkg="$1"
    stock_normalize_disabled_list || return 1
    if stock_list_contains "$_stock_pkg"; then
      return 0
    fi
    printf '%s\n' "$_stock_pkg" >> "$STOCK_DISABLED_FILE" 2>/dev/null
  }

  stock_remove_disabled() {
    _stock_pkg="$1"
    [ -f "$STOCK_DISABLED_FILE" ] || return 0
    _stock_tmp="$MODDIR/.stock-disabled.list.tmp"
    if ! awk -v pkg="$_stock_pkg" '$0 != pkg && NF { print }' \
      "$STOCK_DISABLED_FILE" > "$_stock_tmp" 2>/dev/null; then
      rm -f "$_stock_tmp" 2>/dev/null
      return 1
    fi
    if [ -s "$_stock_tmp" ]; then
      mv -f "$_stock_tmp" "$STOCK_DISABLED_FILE" 2>/dev/null
    else
      rm -f "$_stock_tmp" "$STOCK_DISABLED_FILE" 2>/dev/null
    fi
  }

  toggle_stock_apps() {
    if ! stock_normalize_disabled_list; then
      stock_log_result '<stock-disabled.list>' normalize 1
    fi

    if [ -f "$MODDIR/keep-stock" ]; then
      if [ ! -f "$STOCK_DISABLED_FILE" ]; then
        stock_log_result '<stock-disabled.list>' read 0
        return
      fi
      while IFS= read -r stock_pkg; do
        [ -n "$stock_pkg" ] || continue
        if ! stock_package_valid "$stock_pkg"; then
          stock_log_result "$stock_pkg" invalid-package 1
          continue
        fi
        if pm enable "$stock_pkg" >/dev/null 2>&1; then
          stock_rc=0
        else
          stock_rc=$?
        fi
        stock_log_result "$stock_pkg" enable "$stock_rc"
        if [ "$stock_rc" -eq 0 ]; then
          if stock_remove_disabled "$stock_pkg"; then
            stock_log_result "$stock_pkg" untrack-disabled 0
          else
            stock_log_result "$stock_pkg" untrack-disabled 1
          fi
        fi
      done < "$STOCK_DISABLED_FILE"
      return
    fi

    if [ ! -r "$STOCK_PACKAGES_FILE" ]; then
      stock_log_result '<stock-packages.list>' read 1
      return
    fi
    while IFS= read -r stock_pkg; do
      [ -n "$stock_pkg" ] || continue
      if ! stock_package_valid "$stock_pkg"; then
        stock_log_result "$stock_pkg" invalid-package 1
        continue
      fi
      enabled_packages="$(pm list packages -e 2>/dev/null)"
      check_rc=$?
      if [ "$check_rc" -ne 0 ]; then
        stock_log_result "$stock_pkg" check-enabled "$check_rc"
        continue
      fi
      if printf '%s\n' "$enabled_packages" | grep -Fqx "package:$stock_pkg"; then
        stock_log_result "$stock_pkg" check-enabled 0
        if pm disable-user --user 0 "$stock_pkg" >/dev/null 2>&1; then
          stock_rc=0
        else
          stock_rc=$?
        fi
        stock_log_result "$stock_pkg" disable-user "$stock_rc"
        if [ "$stock_rc" -eq 0 ]; then
          if stock_add_disabled "$stock_pkg"; then
            stock_log_result "$stock_pkg" track-disabled 0
          else
            stock_log_result "$stock_pkg" track-disabled 1
            if pm enable "$stock_pkg" >/dev/null 2>&1; then
              rollback_rc=0
            else
              rollback_rc=$?
            fi
            stock_log_result "$stock_pkg" rollback-enable "$rollback_rc"
          fi
        fi
      elif stock_list_contains "$stock_pkg"; then
        stock_log_result "$stock_pkg" already-disabled-tracked 0
      else
        stock_log_result "$stock_pkg" preserve-user-disabled 0
      fi
    done < "$STOCK_PACKAGES_FILE"
  }

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

  # 在现有 boot_completed 等待之后、诊断之前处理 stock 启用状态。
  # 任意单项失败只写日志,不退出 late_start 子进程。
  toggle_stock_apps

  # 2) 先写 $MODDIR/GKUI-diag.txt(不依赖 FBE 解锁)
  {
    printf '=== GKUI-Pack Diagnostic Report ===\n'
    printf 'version: %s\n' "$MOD_VERSION"
    printf 'variant: %s\n' "$MOD_VARIANT"
    printf 'timestamp_epoch: %s\n' "$(date +%s 2>/dev/null || echo unknown)"
    printf 'boot_completed: %s (waited=%ss)\n\n' "$boot_ok" "$boot_waited"

    printf '%s\n' '--- [0] Stock app toggle state ---'
    printf 'stock-toggle.log:\n'
    if [ -s "$STOCK_TOGGLE_LOG" ]; then
      cat "$STOCK_TOGGLE_LOG"
    else
      printf '<empty>\n'
    fi
    printf 'stock-disabled.list:\n'
    if [ -s "$STOCK_DISABLED_FILE" ]; then
      cat "$STOCK_DISABLED_FILE"
    else
      printf '<empty>\n'
    fi
    if [ -f "$MODDIR/keep-stock" ]; then
      printf 'keep-stock: present (preserve stock)\n\n'
    else
      printf 'keep-stock: absent (disable enabled stock apps)\n\n'
    fi

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

    printf '%s\n' '--- [2] Target Packages pm path (5 GKUI + stock-packages.list) ---'
    for pkg in \
      ws.xsoh.etar.debug \
      org.lineageos.glimpse.dev \
      com.android.calculator2.dev \
      com.android.deskclock.dev \
      org.lineageos.recorder.dev; do
      p_out=""
      if command -v pm >/dev/null 2>&1; then
        p_out="$(pm path "$pkg" 2>/dev/null)"
      fi
      printf '[%s]\n%s\n' "$pkg" "${p_out:-<not installed>}"
    done
    if [ -r "$STOCK_PACKAGES_FILE" ]; then
      while IFS= read -r pkg; do
        [ -n "$pkg" ] || continue
        p_out=""
        if command -v pm >/dev/null 2>&1; then
          p_out="$(pm path "$pkg" 2>/dev/null)"
        fi
        printf '[%s]\n%s\n' "$pkg" "${p_out:-<not installed>}"
      done < "$STOCK_PACKAGES_FILE"
    else
      printf '<stock-packages.list unavailable>\n'
    fi
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

    # [6] 对 5 个 GKUI 包 + stock-packages.list 中的包采集 dumpsys package:
    #     取 "declared permissions" 段落,以及 signatures / versionCode 行。
    #     只做只读 grep/awk 提取,不做任何改写;包未安装时输出 <not installed>。
    printf '%s\n' '--- [6] dumpsys package (declared permissions / signatures / versionCode; stock list is dynamic) ---'
    for pkg in \
      ws.xsoh.etar.debug \
      org.lineageos.glimpse.dev \
      com.android.calculator2.dev \
      com.android.deskclock.dev \
      org.lineageos.recorder.dev; do
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
    if [ -r "$STOCK_PACKAGES_FILE" ]; then
      while IFS= read -r pkg; do
        [ -n "$pkg" ] || continue
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
      done < "$STOCK_PACKAGES_FILE"
    else
      printf '<stock-packages.list unavailable>\n'
    fi
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
