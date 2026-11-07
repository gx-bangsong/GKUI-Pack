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
# 诊断报告章节:
#   [0]-[6] stock 状态、属性、10 个包的 pm path / PackageManager identity 与权限字段
#   [7] PackageManager renamed packages;[8] disabled/system 包列表
#   [9] 相关 launcher activities;[10]-[11] 模块文件树与 mount 行
#   runtime-grants.list、no-auto-grant、版本 marker 与授权结果一并记录(默认自动处理)
# =============================================================================
MODDIR="${0%/*}"
rm -f "$MODDIR/.boot_flag"

{
  printf 'last_boot_ok epoch=%s\n' "$(date +%s 2>/dev/null || echo unknown)"
} > "$MODDIR/last_boot.log" 2>/dev/null

(
  MOD_VERSION="__VERSION__"
  RECORDER_SYSTEM_SUBDIR="__RECORDER_SUBDIR__" # privapp-permissions variant
  case "$MOD_VERSION" in
    "__""VERSION__"|"") MOD_VERSION="unrendered" ;;
  esac
  case "$RECORDER_SYSTEM_SUBDIR" in
    "__""RECORDER_SUBDIR__"|"") RECORDER_SYSTEM_SUBDIR="app" ;;
  esac
  MOD_VARIANT="normal"
  [ "$RECORDER_SYSTEM_SUBDIR" = "app" ] || MOD_VARIANT="recorderpriv"

  DIAG_FILE="$MODDIR/GKUI-diag.txt"
  SDCARD_DIR="${DIAG_SDCARD_DIR:-/sdcard/Download}"
  SDCARD_FILE="$SDCARD_DIR/GKUI-diag.txt"
  BOOT_MAX="${DIAG_BOOT_MAX_WAIT:-120}"
  BOOT_INT="${DIAG_BOOT_SLEEP:-1}"
  SD_MAX="${DIAG_SDCARD_MAX_WAIT:-600}"
  SD_INT="${DIAG_SDCARD_SLEEP:-5}"
  STOCK_PACKAGES_FILE="$MODDIR/stock-packages.list"
  GKUI_PACKAGES_FILE="$MODDIR/gkui-packages.list"
  STOCK_GKUI_MAP_FILE="$MODDIR/stock-gkui-map.list"
  RUNTIME_GRANTS_FILE="$MODDIR/runtime-grants.list"
  APP_OP_MAP_FILE="$MODDIR/appop-map.txt"
  AUTO_GRANT_DISABLED_MARKER="$MODDIR/no-auto-grant"
  GRANTED_DIR="$MODDIR/granted"
  GRANT_LOG="$MODDIR/grant.log"
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

  stock_map_gkui() {
    [ -r "$STOCK_GKUI_MAP_FILE" ] || return 1
    awk -F '|' -v stock="$1" '$1 == stock { print $2; exit }' "$STOCK_GKUI_MAP_FILE" 2>/dev/null
  }

  package_path_first() {
    _path_output="$(pm path "$1" 2>/dev/null)"
    _path_value="$(printf '%s\n' "$_path_output" | sed -n '1{s/^package://;p;}')"
    [ -n "$_path_value" ] || return 1
    printf '%s' "$_path_value"
  }

  grant_log_result() {
    _grant_ts="$(date '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null)"
    [ -n "$_grant_ts" ] || _grant_ts=unknown
    _grant_stderr="$(printf '%s\n' "$5" | sed -n '1{s/[[:space:]]*$//;p;}')"
    [ -n "$_grant_stderr" ] || _grant_stderr='-'
    _grant_stderr="$(printf '%s' "$_grant_stderr" | tr '|' '/')"
    printf '%s package=%s permission=%s method=%s rc=%s stderr=%s\n' \
      "$_grant_ts" "$1" "$2" "$3" "$4" "$_grant_stderr" >> "$GRANT_LOG" 2>/dev/null
  }

  appop_for_permission() {
    [ -r "$APP_OP_MAP_FILE" ] || return 1
    awk -F '|' -v permission="$1" '$1 == permission { print $2; exit }' "$APP_OP_MAP_FILE" 2>/dev/null
  }

  run_grant_command() {
    _grant_stderr_file="$MODDIR/.grant-stderr.tmp"
    "$@" >/dev/null 2>"$_grant_stderr_file"
    grant_rc=$?
    grant_output="$(sed -n '1p' "$_grant_stderr_file" 2>/dev/null)"
    rm -f "$_grant_stderr_file" 2>/dev/null
  }

  package_version_code() {
    [ -n "$1" ] || return 1
    command -v dumpsys >/dev/null 2>&1 || return 1
    _version_code="$(dumpsys package "$1" 2>/dev/null | sed -n 's/.*versionCode=\([0-9][0-9]*\).*/\1/p' | sed -n '1p')"
    case "$_version_code" in
      ''|*[!0-9]*) return 1 ;;
    esac
    printf '%s' "$_version_code"
  }

  dump_requested_permission_sections() {
    _permission_pkg="$1"
    printf '[%s]\n' "$_permission_pkg"
    if ! command -v dumpsys >/dev/null 2>&1; then
      printf '<dumpsys unavailable>\n'
      return
    fi
    dumpsys package "$_permission_pkg" 2>/dev/null | awk '
      /^[[:space:]]*(requested|install|runtime|declared) permissions:/ {
        in_sec = 1
        base_indent = match($0, /[^[:space:]]/) - 1
        print
        next
      }
      in_sec {
        if ($0 ~ /^[[:space:]]*$/) { in_sec = 0; next }
        cur_indent = match($0, /[^[:space:]]/) - 1
        if (cur_indent <= base_indent) { in_sec = 0 }
        else { print; next }
      }
    '
  }

  self_heal_gkui_packages() {
    if [ ! -r "$GKUI_PACKAGES_FILE" ]; then
      stock_log_result '<gkui-packages.list>' read 1
      return
    fi
    _disabled_packages="$(pm list packages -d 2>/dev/null)"
    _disabled_status=$?
    if [ "$_disabled_status" -ne 0 ]; then
      stock_log_result '<disabled-packages>' self-heal-check "$_disabled_status"
      return
    fi
    while IFS= read -r gkui_pkg; do
      [ -n "$gkui_pkg" ] || continue
      if ! stock_package_valid "$gkui_pkg"; then
        stock_log_result "$gkui_pkg" self-heal-invalid-package 1
        continue
      fi
      if printf '%s\n' "$_disabled_packages" | grep -Fqx "package:$gkui_pkg"; then
        if pm enable --user 0 "$gkui_pkg" >/dev/null 2>&1; then
          heal_rc=0
        else
          heal_rc=$?
        fi
        stock_log_result "$gkui_pkg" 'SELF-HEAL GKUI-disabled' "$heal_rc"
      fi
    done < "$GKUI_PACKAGES_FILE"
  }

  self_heal_tracked_merged_stock() {
    [ -f "$STOCK_DISABLED_FILE" ] || return 0
    [ -r "$GKUI_PACKAGES_FILE" ] || return 0
    while IFS= read -r tracked_pkg; do
      [ -n "$tracked_pkg" ] || continue
      if ! stock_package_valid "$tracked_pkg"; then
        stock_log_result "$tracked_pkg" self-heal-invalid-tracked-package 1
        continue
      fi
      tracked_path="$(package_path_first "$tracked_pkg" 2>/dev/null || true)"
      [ -n "$tracked_path" ] || continue
      while IFS= read -r gkui_pkg; do
        [ -n "$gkui_pkg" ] || continue
        gkui_path="$(package_path_first "$gkui_pkg" 2>/dev/null || true)"
        [ -n "$gkui_path" ] || continue
        [ "$tracked_path" = "$gkui_path" ] || continue
        if pm enable --user 0 "$tracked_pkg" >/dev/null 2>&1; then
          heal_rc=0
        else
          heal_rc=$?
        fi
        stock_log_result "$tracked_pkg" 'SELF-HEAL merged-tracked-stock' "$heal_rc"
        if [ "$heal_rc" -eq 0 ]; then
          if stock_remove_disabled "$tracked_pkg"; then
            stock_log_result "$tracked_pkg" 'SELF-HEAL untrack-merged-stock' 0
          else
            stock_log_result "$tracked_pkg" 'SELF-HEAL untrack-merged-stock' 1
          fi
        fi
        break
      done < "$GKUI_PACKAGES_FILE"
    done < "$STOCK_DISABLED_FILE"
  }

  toggle_stock_apps() {
    if ! stock_normalize_disabled_list; then
      stock_log_result '<stock-disabled.list>' normalize 1
    fi

    # 新版模块更新后的自愈必须先于 keep-stock / stock disable。
    # 第一段修复所有本模块 GKUI 包的 disabled-user 状态;第二段清理旧版跟踪的合并 stock 别名。
    self_heal_gkui_packages
    self_heal_tracked_merged_stock

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
        if pm enable --user 0 "$stock_pkg" >/dev/null 2>&1; then
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
    if [ ! -r "$STOCK_GKUI_MAP_FILE" ]; then
      stock_log_result '<stock-gkui-map.list>' read 1
      return
    fi
    while IFS= read -r stock_pkg; do
      [ -n "$stock_pkg" ] || continue
      if ! stock_package_valid "$stock_pkg"; then
        stock_log_result "$stock_pkg" invalid-package 1
        continue
      fi
      if [ -r "$GKUI_PACKAGES_FILE" ] && grep -Fqx "$stock_pkg" "$GKUI_PACKAGES_FILE" 2>/dev/null; then
        stock_log_result "$stock_pkg" 'PROTECT-GKUI-package; skip disable' 0
        continue
      fi
      gkui_pkg="$(stock_map_gkui "$stock_pkg")"
      if [ -z "$gkui_pkg" ] || ! stock_package_valid "$gkui_pkg"; then
        stock_log_result "$stock_pkg" 'MAP-MISSING; skip disable' 0
        continue
      fi
      stock_path="$(package_path_first "$stock_pkg" 2>/dev/null || true)"
      if [ -z "$stock_path" ]; then
        stock_log_result "$stock_pkg" 'ABSENT: stock pm path empty; skip' 0
        continue
      fi
      gkui_path="$(package_path_first "$gkui_pkg" 2>/dev/null || true)"
      if [ -z "$gkui_path" ]; then
        stock_log_result "$stock_pkg" "ABSENT: GKUI $gkui_pkg pm path empty; skip" 0
        continue
      fi
      if [ "$stock_path" = "$gkui_path" ]; then
        stock_log_result "$stock_pkg" "MERGED: resolves to $gkui_pkg APK; skip disable" 0
        continue
      fi

      enabled_packages="$(pm list packages -e 2>/dev/null)"
      check_rc=$?
      if [ "$check_rc" -ne 0 ]; then
        stock_log_result "$stock_pkg" check-enabled "$check_rc"
        continue
      fi
      if printf '%s\n' "$enabled_packages" | grep -Fqx "package:$stock_pkg"; then
        stock_pm_path_output="$(pm path "$stock_pkg" 2>/dev/null)"
        stock_base_path="$(printf '%s\n' "$stock_pm_path_output" | sed -n '1{s/^package://;p;}')"
        if printf '%s\n' "$stock_base_path" | grep -Eq '^/system/(priv-)?app/GKUI'; then
          stock_log_result "$stock_pkg" 'skip-merged-gkUI' 0
          continue
        fi
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
            if pm enable --user 0 "$stock_pkg" >/dev/null 2>&1; then
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

  run_pending_runtime_grants() {
    pending_pkg="$1"
    [ -n "$pending_pkg" ] || return 0
    pending_version="$(package_version_code "$pending_pkg" 2>/dev/null || true)"
    if [ -z "$pending_version" ]; then
      while IFS='|' read -r pending_permission pending_method pending_extra; do
        [ -n "$pending_permission" ] || continue
        grant_log_result "$pending_pkg" "$pending_permission" "$pending_method" 1 'versionCode unavailable'
      done < "$PENDING_GRANTS_FILE"
      return 1
    fi

    pending_marker="$GRANTED_DIR/$pending_pkg.$pending_version"
    [ -f "$pending_marker" ] && return 0
    package_grants_ok=1
    while IFS='|' read -r pending_permission pending_method pending_extra; do
      [ -n "$pending_permission" ] || continue
      if [ -n "$pending_extra" ] || ! stock_package_valid "$pending_permission"; then
        grant_log_result "$pending_pkg" "$pending_permission" "$pending_method" 1 'invalid runtime grant row'
        package_grants_ok=0
        continue
      fi
      case "$pending_method" in
        grant)
          run_grant_command pm grant "$pending_pkg" "$pending_permission"
          ;;
        appops)
          grant_appop="$(appop_for_permission "$pending_permission" 2>/dev/null)"
          if [ -z "$grant_appop" ]; then
            grant_output='appop mapping missing'
            grant_rc=1
          else
            run_grant_command appops set "$pending_pkg" "$grant_appop" allow
          fi
          ;;
        *)
          grant_output='unsupported runtime grant method'
          grant_rc=1
          ;;
      esac
      grant_log_result "$pending_pkg" "$pending_permission" "$pending_method" "$grant_rc" "$grant_output"
      [ "$grant_rc" -eq 0 ] || package_grants_ok=0
    done < "$PENDING_GRANTS_FILE"

    if [ "$package_grants_ok" -eq 1 ]; then
      if mkdir -p "$GRANTED_DIR" 2>/dev/null \
        && printf 'versionCode=%s\ncompleted=%s\n' "$pending_version" "$(date +%s 2>/dev/null || echo unknown)" \
          > "$pending_marker.tmp" 2>/dev/null \
        && mv -f "$pending_marker.tmp" "$pending_marker" 2>/dev/null; then
        :
      else
        rm -f "$pending_marker.tmp" 2>/dev/null
        grant_log_result "$pending_pkg" - marker 1 'could not persist success marker'
      fi
    fi
    return 0
  }

  grant_runtime_permissions() {
    if [ -f "$AUTO_GRANT_DISABLED_MARKER" ]; then
      grant_log_result - - no-auto-grant 0 'opt-out marker present'
      return 0
    fi
    if [ ! -r "$RUNTIME_GRANTS_FILE" ]; then
      grant_log_result '<runtime-grants.list>' - read 1 'runtime-grants.list unavailable'
      return 1
    fi
    if ! mkdir -p "$GRANTED_DIR" 2>/dev/null; then
      grant_log_result - - marker-dir 1 'cannot create granted directory'
      return 1
    fi

    PENDING_GRANTS_FILE="$MODDIR/.runtime-grants.pending"
    : > "$PENDING_GRANTS_FILE" 2>/dev/null || {
      grant_log_result - - pending-file 1 'cannot create pending grant file'
      return 1
    }
    pending_pkg=''
    while IFS='|' read -r grant_pkg grant_permission grant_method extra; do
      [ -n "$grant_pkg" ] || continue
      if [ -n "$extra" ] || ! stock_package_valid "$grant_pkg" || ! stock_package_valid "$grant_permission"; then
        grant_log_result "$grant_pkg" "$grant_permission" invalid-entry 1 'expected package|permission|method'
        continue
      fi
      if [ -n "$pending_pkg" ] && [ "$pending_pkg" != "$grant_pkg" ]; then
        run_pending_runtime_grants "$pending_pkg"
        : > "$PENDING_GRANTS_FILE" 2>/dev/null || break
      fi
      pending_pkg="$grant_pkg"
      printf '%s|%s\n' "$grant_permission" "$grant_method" >> "$PENDING_GRANTS_FILE" 2>/dev/null
    done < "$RUNTIME_GRANTS_FILE"
    [ -z "$pending_pkg" ] || run_pending_runtime_grants "$pending_pkg"
    rm -f "$PENDING_GRANTS_FILE" 2>/dev/null
    return 0
  }

  dump_package_diagnostic() {
    _diag_pkg="$1"
    printf '\n[%s]\n' "$_diag_pkg"
    if command -v dumpsys >/dev/null 2>&1; then
      _diag_fields="$(dumpsys package "$_diag_pkg" 2>/dev/null | awk '
        /^[[:space:]]*(realName|codePath|versionCode|flags|signatures)=/ { print; found = 1 }
        /^[[:space:]]*User 0:/ { print; found = 1; in_user = 1; next }
        in_user && /installed=|hidden=|enabled=/ { print; found = 1 }
        in_user && /^[^[:space:]]/ { in_user = 0 }
        /^[[:space:]]*(requested|install|runtime|declared) permissions:/ {
          in_sec = 1
          base_indent = match($0, /[^[:space:]]/) - 1
          print
          found = 1
          next
        }
        in_sec {
          if ($0 ~ /^[[:space:]]*$/) { in_sec = 0; next }
          cur_indent = match($0, /[^[:space:]]/) - 1
          if (cur_indent <= base_indent) { in_sec = 0 }
          else { print; found = 1; next }
        }
        END { if (!found) print "<no requested package fields>" }
      ')"
      printf '%s\n' "$_diag_fields"
    else
      printf '<dumpsys unavailable>\n'
    fi
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
  # 默认启用生成的 runtime-grants.list;no-auto-grant 存在时完全跳过。
  # 授权处理在 stock 切换之后、诊断之前,失败只记日志并继续。
  grant_runtime_permissions

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
    if [ -f "$STOCK_DISABLED_FILE" ]; then
      printf 'stock-disabled.list marker: present\ncontents:\n'
      if [ -s "$STOCK_DISABLED_FILE" ]; then cat "$STOCK_DISABLED_FILE"; else printf '<empty>\n'; fi
    else
      printf 'stock-disabled.list marker: absent\n'
    fi
    if [ -f "$MODDIR/keep-stock" ]; then
      printf 'keep-stock marker: present (preserve stock)\n'
    else
      printf 'keep-stock marker: absent (disable enabled stock apps)\n'
    fi
    if [ -f "$AUTO_GRANT_DISABLED_MARKER" ]; then
      printf 'no-auto-grant marker: present (runtime grants skipped)\n'
    else
      printf 'no-auto-grant marker: absent (runtime grants default-on)\n'
    fi
    if [ -f "$MODDIR/.boot_flag" ]; then
      printf '.boot_flag marker: present\n'
    else
      printf '.boot_flag marker: absent\n'
    fi
    for list_name in gkui-packages.list stock-packages.list stock-gkui-map.list stock-merged.list runtime-grants.list; do
      printf '%s marker: ' "$list_name"
      if [ -f "$MODDIR/$list_name" ]; then printf 'present\n'; else printf 'absent\n'; fi
      printf '%s contents:\n' "$list_name"
      if [ -s "$MODDIR/$list_name" ]; then
        cat "$MODDIR/$list_name"
      else
        printf '<empty or unavailable>\n'
      fi
    done
    printf 'granted marker directory: %s\n' "$GRANTED_DIR"
    if [ -d "$GRANTED_DIR" ]; then
      marker_files="$(find "$GRANTED_DIR" -type f -print 2>/dev/null)"
      if [ -n "$marker_files" ]; then printf '%s\n' "$marker_files" | sort; else printf '<no success markers>\n'; fi
    else
      printf '<directory absent>\n'
    fi
    printf 'runtime grant marker status by package/version:\n'
    if [ -r "$RUNTIME_GRANTS_FILE" ]; then
      while IFS='|' read -r marker_pkg marker_permission marker_method marker_extra; do
        [ -n "$marker_pkg" ] || continue
        marker_version="$(package_version_code "$marker_pkg" 2>/dev/null || true)"
        if [ -n "$marker_version" ] && [ -f "$GRANTED_DIR/$marker_pkg.$marker_version" ]; then
          marker_status=present
        elif [ -n "$marker_version" ]; then
          marker_status=absent
        else
          marker_status=versionCode-unavailable
        fi
        printf 'package=%s permission=%s method=%s versionCode=%s marker=%s\n' \
          "$marker_pkg" "$marker_permission" "$marker_method" "${marker_version:-unknown}" "$marker_status"
      done < "$RUNTIME_GRANTS_FILE"
    else
      printf '<runtime-grants.list unavailable>\n'
    fi
    printf 'grant.log:\n'
    if [ -s "$GRANT_LOG" ]; then
      cat "$GRANT_LOG"
    else
      printf '<empty>\n'
    fi
    printf '\n'

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

    printf '%s\n' '--- [2] Target Packages pm path (gkui-packages.list + stock-packages.list) ---'
    if [ -r "$GKUI_PACKAGES_FILE" ]; then
      while IFS= read -r pkg; do
        [ -n "$pkg" ] || continue
        p_out=""
        if command -v pm >/dev/null 2>&1; then
          p_out="$(pm path "$pkg" 2>/dev/null)"
        fi
        printf '[%s]\n%s\n' "$pkg" "${p_out:-<not installed>}"
      done < "$GKUI_PACKAGES_FILE"
    else
      printf '<gkui-packages.list unavailable>\n'
    fi
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

    printf '%s\n' '--- [3] Requested / install / runtime / declared permission sections (GKUI + stock lists) ---'
    for package_list in "$GKUI_PACKAGES_FILE" "$STOCK_PACKAGES_FILE"; do
      if [ -r "$package_list" ]; then
        while IFS= read -r pkg; do
          [ -n "$pkg" ] || continue
          dump_requested_permission_sections "$pkg"
        done < "$package_list"
      else
        printf '%s unavailable\n' "${package_list##*/}"
      fi
    done
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

    # [6] 原有 declared permissions / signatures / versionCode 段保留并扩充:
    #     对 5 个 GKUI + stock-packages.list 中的 5 个包输出 identity、user 0 与权限字段。
    printf '%s\n' '--- [6] dumpsys package (identity / User 0 / permissions / signatures; stock list is dynamic) ---'
    if [ -r "$GKUI_PACKAGES_FILE" ]; then
      while IFS= read -r pkg; do
        [ -n "$pkg" ] || continue
        dump_package_diagnostic "$pkg"
      done < "$GKUI_PACKAGES_FILE"
    else
      printf '<gkui-packages.list unavailable>\n'
    fi
    if [ -r "$STOCK_PACKAGES_FILE" ]; then
      while IFS= read -r pkg; do
        [ -n "$pkg" ] || continue
        dump_package_diagnostic "$pkg"
      done < "$STOCK_PACKAGES_FILE"
    else
      printf '<stock-packages.list unavailable>\n'
    fi
    printf '\n'

    printf '%s\n' '--- [7] PackageManager renamed packages ---'
    if command -v dumpsys >/dev/null 2>&1; then
      dumpsys package 2>/dev/null | awk '
        /^[[:space:]]*Renamed packages:/ {
          in_renamed = 1
          found = 1
          print
          next
        }
        in_renamed {
          if ($0 ~ /^[[:space:]]*$/) { print; exit }
          if ($0 !~ /^[[:space:]]/) exit
          print
        }
        END { if (!found) print "<Renamed packages section not found>" }
      '
    else
      printf '<dumpsys unavailable>\n'
    fi
    printf '\n'

    printf '%s\n' '--- [8] Disabled and system package listings ---'
    if command -v pm >/dev/null 2>&1; then
      printf 'pm list packages -d:\n'
      pm list packages -d 2>&1
      printf 'pm list packages -s:\n'
      pm list packages -s 2>&1
    else
      printf '<pm unavailable>\n'
    fi
    printf '\n'

    printf '%s\n' '--- [9] Relevant launcher activities (package lists are dynamic) ---'
    if command -v cmd >/dev/null 2>&1; then
      launcher_out="$(cmd package query-activities --brief --user 0 \
        -a android.intent.action.MAIN -c android.intent.category.LAUNCHER 2>/dev/null)"
      for package_list in "$GKUI_PACKAGES_FILE" "$STOCK_PACKAGES_FILE"; do
        if [ -r "$package_list" ]; then
          while IFS= read -r pkg; do
            [ -n "$pkg" ] || continue
            launcher_matches="$(printf '%s\n' "$launcher_out" | grep -F "$pkg" || true)"
            if [ -n "$launcher_matches" ]; then
              printf '[%s]\n%s\n' "$pkg" "$launcher_matches"
            else
              printf '[%s] <no matching launcher activity>\n' "$pkg"
            fi
          done < "$package_list"
        fi
      done
    else
      printf '<cmd package unavailable>\n'
    fi
    printf '\n'

    printf '%s\n' '--- [10] Module mount tree ---'
    ls -laR "$MODDIR/system" 2>&1
    printf '\n'
    printf '%s\n' '--- [11] Module-related mount lines ---'
    if command -v mount >/dev/null 2>&1; then
      mount 2>/dev/null | grep -E 'GKUI-Pack|/system/|/product/' \
        || printf '<no matching mount lines>\n'
    else
      printf '<mount unavailable>\n'
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
