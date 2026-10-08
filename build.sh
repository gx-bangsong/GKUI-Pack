#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
# build.sh —— GKUI-Pack 构建入口,同时也是全仓库唯一的 apps.yaml 解析入口
#
# 用法:
#   bash build.sh                    校验清单 → APK 门禁 → 渲染模块 → 打包 zip
#   bash build.sh --check            只校验清单(字段规则 + TODO 门禁)
#   bash build.sh --dump-apps-json   输出 apps.yaml 规范化 JSON(其他脚本复用)
#   bash build.sh --list             打印条目摘要(不校验,不会失败)
#   bash build.sh --no-zip           渲染模块但不打包(调试用)
#   bash build.sh --collect-only     只采集真实值(不产出模块,永远返回非零)
#                                    用途:apps.yaml 里 signer_sha256 / sha256 还是 TODO 时,
#                                    先用它在 CI/本地把"该填什么值"打印出来。
#                                    它**不会**改写 apps.yaml,也不产出任何 zip。
#
# 供其它脚本复用的机器可读输出(本仓库其它脚本一律通过这两个模式读取 apps.yaml,
# 不允许各自解析 YAML):
#   bash build.sh --emit-tsv         制表符分隔,仅 enabled 条目
#   bash build.sh --emit-tsv-all     制表符分隔,含 disabled 条目
#   字段顺序:id name application_id stock_package repo upstream license source_url
#            release_tag asset_name sha256 signer_sha256 installed_version_code
#            install_as mode confidence enabled
#
# 选项:
#   --strict       disabled 条目里的 TODO/unverified 也视为失败(字面版 C7)
#   --no-color     关闭彩色输出
#   --help
#
# 环境变量:
#   APK_DIR        APK 来源目录,默认 <repo>/dist/apks
#   DIST_DIR       产物目录,默认 <repo>/dist
#   VERSION        module.prop 的 version(默认取 git describe / 短 sha)
#   VERSION_CODE   module.prop 的 versionCode(默认按 UTC 时间生成,必须是整数)
#   AAPT / APKSIGNER   传给 scripts/preflight-apk.sh 的工具路径覆盖
#
# 退出码:0 成功 | 1 校验或门禁失败 | 2 用法/环境错误
#
# 设计要点(勿改,改了会破坏硬约束):
#   C1/C7  未知值必须是 TODO,并且在构建时**失败**,绝不降级为 warning。
#   C2     mode 只允许 coexist;绝不生成任何写入 stock 应用目录的代码路径。
#   C3     只装 system/app;检出 privileged 权限的条目**被排除出模块**,
#          在摘要与 README 中标注"仅走 adb install"(绝不生成白名单 XML)。
#   C5     构建产物只进 dist/(已被 .gitignore 忽略),仓库内不落任何 APK。
#   C8     与 /data 同包名的冲突检查由 module/customize.sh 在安装期执行。
# =============================================================================

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPS_YAML="$ROOT/apps.yaml"
APK_DIR="${APK_DIR:-$ROOT/dist/apks}"
DIST_DIR="${DIST_DIR:-$ROOT/dist}"
PREFLIGHT="$ROOT/scripts/preflight-apk.sh"

MODE="build"
STRICT=0
NO_ZIP=0
COLLECT=0

# ---------------------------------------------------------------------------
# 输出helpers
# ---------------------------------------------------------------------------
if [ -t 1 ]; then
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'; C_BLD=$'\033[1m'; C_RST=$'\033[0m'
else
  C_RED=''; C_GRN=''; C_YEL=''; C_BLD=''; C_RST=''
fi

log()  { printf '%s\n' "$*"; }
info() { printf '%s\n' "[信息] $*"; }
warn() { printf '%s%s%s\n' "$C_YEL" "[警告] $*" "$C_RST" >&2; }
die()  { printf '%s%s%s\n' "$C_RED" "[失败] $*" "$C_RST" >&2; exit "${2:-1}"; }

usage() {
  sed -n '3,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# ---------------------------------------------------------------------------
# apps.yaml 解析器(受限 YAML 子集,纯 stdlib,离线可用)
#
# 为什么不用 PyYAML:本工程要求"离线、零第三方依赖"就能跑通;CI 与用户机器都不
# 保证装了 PyYAML。因此这里实现一个**受限子集**解析器,只支持本清单实际用到的
# 语法:块式映射、块式序列、标量、整行注释、行尾注释。
# 不支持(遇到即报错,绝不猜测):内联集合 [] {}、多行标量 | >、锚点/别名 & *、
# 多文档 --- ...、制表符缩进、复杂键。apps.yaml 的完整 YAML 合法性由 CI 的
# yamllint 兜底。
# ---------------------------------------------------------------------------
apps_python() {
  python3 - "$APPS_YAML" "$@" <<'PYEOF'
# -*- coding: utf-8 -*-
"""apps.yaml 受限子集解析 + 规范化 + 校验(由 build.sh 内嵌调用)"""
import json
import re
import sys

FIELDS = [
    "id", "name", "application_id", "stock_package", "repo", "upstream", "license",
    "source_url", "release_tag", "asset_name", "sha256", "signer_sha256",
    "installed_version_code", "install_as", "mode", "confidence", "enabled",
]
REQUIRED = [
    "id", "name", "application_id", "stock_package", "repo", "upstream", "license",
    "release_tag", "asset_name", "sha256", "signer_sha256", "installed_version_code",
    "install_as", "mode", "confidence", "enabled",
]
# C4:严禁纳入拨号 / 短信 / 联系人类应用(系统共享 UID + platform 签名)
C4_RE = re.compile(r"(dialer|telephony|messaging|contacts)", re.I)
RE_ID = re.compile(r"^[a-z][a-z0-9_]*$")
RE_NAME = re.compile(r"^[A-Za-z][A-Za-z0-9_]*$")
RE_PKG = re.compile(r"^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+$")
RE_HEX64 = re.compile(r"^[0-9a-f]{64}$")
# 目录名卫生:这些名字不能作为模块内 app 目录名
FORBIDDEN_NAMES = {"priv-app", "priv_app", "app", "system", "build", "dist"}
ALLOWED_MODE = {"coexist"}
ALLOWED_INSTALL_AS = {"system_app"}


class YamlError(Exception):
    """受限 YAML 子集解析错误"""


def strip_comment(text):
    """去掉行尾注释(尊重引号;只在 ' #' 处截断)"""
    out = []
    in_s = in_d = False
    for i, ch in enumerate(text):
        if ch == "'" and not in_d:
            in_s = not in_s
        elif ch == '"' and not in_s:
            in_d = not in_d
        elif ch == "#" and not in_s and not in_d and (i == 0 or text[i - 1] in " \t"):
            break
        out.append(ch)
    return "".join(out).rstrip()


def to_scalar(tok, ln):
    """标量转换(token, 行号)"""
    tok = tok.strip()
    if tok == "":
        return None
    if len(tok) >= 2 and tok[0] == tok[-1] and tok[0] in ('"', "'"):
        return tok[1:-1]
    low = tok.lower()
    if low in ("null", "~"):
        return None
    if low in ("true", "false"):
        return low == "true"
    if re.fullmatch(r"-?\d+", tok):
        return int(tok)
    if tok[0] in "[{&*!|>%@`":
        raise YamlError(
            "第 %d 行:本工程只支持受限 YAML 块式子集,不支持该语法: %s" % (ln, tok)
        )
    return tok


def split_kv(text, ln):
    """按第一个 '键: 值' 拆分(尊重引号;冒号后必须紧跟空格或行尾)"""
    in_s = in_d = False
    for i, ch in enumerate(text):
        if ch == "'" and not in_d:
            in_s = not in_s
        elif ch == '"' and not in_s:
            in_d = not in_d
        elif ch == ":" and not in_s and not in_d and (i + 1 == len(text) or text[i + 1] == " "):
            return text[:i].strip(), text[i + 1:].strip()
    raise YamlError('第 %d 行:不是合法的 "键: 值" 形式: %s' % (ln, text))


def looks_kv(text):
    try:
        split_kv(text, 0)
        return True
    except YamlError:
        return False


def preprocess(text):
    """按行预处理 → [(缩进, 文本, 行号)]"""
    out = []
    for n, raw in enumerate(text.splitlines(), 1):
        lead = raw[: len(raw) - len(raw.lstrip(" \t"))]
        if "\t" in lead:
            raise YamlError("第 %d 行:缩进中不允许使用制表符(请改用空格)" % n)
        line = strip_comment(raw)
        if not line.strip():
            continue
        if line.strip() in ("---", "..."):
            if n == 1 and line.strip() == "---":
                continue
            raise YamlError("第 %d 行:不支持多文档分隔符 %s" % (n, line.strip()))
        indent = len(line) - len(line.lstrip(" "))
        out.append((indent, line.strip(), n))
    return out


def parse_seq(lines, pos, indent):
    items = []
    while pos < len(lines):
        ind, text, ln = lines[pos]
        if ind < indent:
            break
        if ind > indent:
            raise YamlError("第 %d 行:序列项缩进不一致" % ln)
        if not (text == "-" or text.startswith("- ")):
            break
        rest = text[1:].strip()
        pos += 1
        if rest == "":
            if pos < len(lines) and lines[pos][0] > indent:
                val, pos = parse_block(lines, pos, lines[pos][0])
                items.append(val)
            else:
                items.append(None)
            continue
        if not looks_kv(rest):
            items.append(to_scalar(rest, ln))
            continue
        # 序列项内部是映射:第一对键值写在同一行,后续键在更深缩进处
        item = {"__line__": ln}
        key, val = split_kv(rest, ln)
        if val == "":
            if pos < len(lines) and lines[pos][0] > indent:
                sub, pos = parse_block(lines, pos, lines[pos][0])
                item[key] = sub
            else:
                item[key] = None
        else:
            item[key] = to_scalar(val, ln)
        while pos < len(lines):
            ind2, text2, ln2 = lines[pos]
            if ind2 <= indent:
                break
            if not looks_kv(text2):
                raise YamlError("第 %d 行:此处应为 键: 值: %s" % (ln2, text2))
            key2, val2 = split_kv(text2, ln2)
            if key2 in item:
                raise YamlError("第 %d 行:重复键 %s" % (ln2, key2))
            pos += 1
            if val2 == "":
                if pos < len(lines) and lines[pos][0] > ind2:
                    sub2, pos = parse_block(lines, pos, lines[pos][0])
                    item[key2] = sub2
                else:
                    item[key2] = None
            else:
                item[key2] = to_scalar(val2, ln2)
        items.append(item)
    return items, pos


def parse_map(lines, pos, indent):
    out = {}
    while pos < len(lines):
        ind, text, ln = lines[pos]
        if ind < indent:
            break
        if ind > indent:
            raise YamlError("第 %d 行:缩进不一致" % ln)
        if text == "-" or text.startswith("- "):
            raise YamlError("第 %d 行:此处不应出现序列项" % ln)
        key, val = split_kv(text, ln)
        if key in out:
            raise YamlError("第 %d 行:重复键 %s" % (ln, key))
        pos += 1
        if val == "":
            if pos < len(lines) and lines[pos][0] > indent:
                sub, pos = parse_block(lines, pos, lines[pos][0])
                out[key] = sub
            else:
                out[key] = None
        else:
            out[key] = to_scalar(val, ln)
    return out, pos


def parse_block(lines, pos, indent):
    if pos >= len(lines):
        return None, pos
    text = lines[pos][1]
    if text == "-" or text.startswith("- "):
        return parse_seq(lines, pos, indent)
    return parse_map(lines, pos, indent)


def load_apps_yaml(path):
    with open(path, "r", encoding="utf-8") as fh:
        text = fh.read()
    lines = preprocess(text)
    if not lines:
        raise YamlError("文件为空")
    if lines[0][0] != 0:
        raise YamlError("第 %d 行:顶层内容必须顶格(缩进 0)" % lines[0][2])
    doc, pos = parse_block(lines, 0, 0)
    if pos != len(lines):
        raise YamlError("第 %d 行:解析在预期之外结束" % lines[pos][2])
    if not isinstance(doc, dict):
        raise YamlError("顶层必须是映射(键: 值)")
    return doc


def is_todo(val):
    return isinstance(val, str) and val.strip().upper().startswith("TODO")


def norm_hex(val):
    return re.sub(r"[:\s]", "", str(val)).lower()


def norm_entry(raw, idx):
    """规范化单条目:补齐字段顺序,记录 TODO / 未知字段"""
    raw = dict(raw)
    line_no = raw.pop("__line__", None)
    entry = {"_index": idx, "_line": line_no}
    unknown = []
    for key in raw:
        if key not in FIELDS:
            unknown.append(key)
    for key in FIELDS:
        entry[key] = raw.get(key)
    entry["_unknown"] = unknown
    entry["_todo_fields"] = [k for k in FIELDS if is_todo(entry.get(k))]
    if isinstance(raw.get("enabled"), bool):
        pass
    entry["_enabled"] = entry.get("enabled") is True
    return entry


def load(path):
    doc = load_apps_yaml(path)
    for key in doc:
        if key not in ("schema_version", "apps"):
            raise YamlError("顶层出现未知键: %s" % key)
    if "apps" not in doc or not isinstance(doc.get("apps"), list):
        raise YamlError("缺少顶层 apps 列表")
    entries = [norm_entry(a, i) for i, a in enumerate(doc["apps"])]
    return doc.get("schema_version"), entries


def validate(schema_version, entries, strict=False, allow_todo=False):
    """返回 (errors, warnings, skipped)

    allow_todo=True(仅 --collect-only 采集模式使用)时,把 TODO / confidence 类问题
    从"错误"降级为"警告"。**任何硬规则(C2/C3/C4/格式/重复)依然必须失败**。
    """
    errors, warnings, skipped = [], [], []
    for entry in entries:
        eid = entry.get("id") if isinstance(entry.get("id"), str) else "#%d" % (entry["_index"] + 1)
        if entry.get("_line"):
            eid = "%s(第 %d 行)" % (eid, entry["_line"])
        problems, notes = [], []

        if schema_version != 1:
            errors.append("schema_version 必须是 1,当前为 %r" % (schema_version,))

        for key in entry["_unknown"]:
            errors.append("%s: 出现未知字段 %s(可能是拼写错误)" % (eid, key))

        # --- C4:永久禁止的类别(无论 enabled 与否都不允许出现在清单里) ---
        for key in FIELDS:
            val = entry.get(key)
            if isinstance(val, str) and C4_RE.search(val):
                errors.append(
                    "%s: 字段 %s 命中 C4 禁用类别(拨号/短信/联系人类应用一律不得纳入)" % (eid, key)
                )

        # --- mode / install_as:任何条目都不许越界 ---
        mode = entry.get("mode")
        if mode not in ALLOWED_MODE:
            errors.append(
                "%s: mode=%r 非法;只允许 coexist(C2:GKUI 包名带后缀,与 stock 不构成替换关系)" % (eid, mode)
            )
        install_as = entry.get("install_as")
        if install_as not in ALLOWED_INSTALL_AS:
            errors.append(
                "%s: install_as=%r 非法;只允许 system_app(C3:禁止使用特权应用目录)" % (eid, install_as)
            )

        enabled = entry["_enabled"]
        if enabled is None or entry.get("enabled") is None:
            errors.append("%s: 缺少 enabled 字段" % eid)

        # --- 必填字段与 TODO 门禁(C1/C7) ---
        for key in REQUIRED:
            val = entry.get(key)
            if val is None:
                problems.append("缺少必填字段 %s" % key)
            elif is_todo(val):
                problems.append("%s 为 TODO(需实测/实算后填入)" % key)

        if entry.get("confidence") != "confirmed":
            problems.append("confidence=%r 不是 confirmed" % (entry.get("confidence"),))
        if entry.get("enabled") is not None and not isinstance(entry.get("enabled"), bool):
            errors.append("%s: enabled 必须是 true/false" % eid)

        # --- 字段格式 ---
        if isinstance(entry.get("id"), str) and not is_todo(entry["id"]) and not RE_ID.match(entry["id"]):
            errors.append("%s: id 只允许小写字母/数字/下划线,且以字母开头" % eid)
        name = entry.get("name")
        if isinstance(name, str) and not is_todo(name):
            if not RE_NAME.match(name):
                errors.append("%s: name=%r 非法(仅允许字母/数字/下划线,字母开头)" % (eid, name))
            elif name.lower() in FORBIDDEN_NAMES:
                errors.append("%s: name=%r 是保留名,不能作为模块内目录名" % (eid, name))
        for key in ("application_id", "stock_package"):
            val = entry.get(key)
            if isinstance(val, str) and not is_todo(val) and not RE_PKG.match(val):
                errors.append("%s: %s=%r 不是合法的包名形式" % (eid, key, val))
        # --- C2:GKUI applicationId 必须与 stock 包名不同 ---
        aid, stock = entry.get("application_id"), entry.get("stock_package")
        if isinstance(aid, str) and isinstance(stock, str) and not is_todo(aid) and not is_todo(stock):
            if aid == stock:
                errors.append(
                    "%s: application_id 与 stock_package 相同(%s);coexist 模式要求两者不同(C2)" % (eid, aid)
                )
        for key in ("sha256", "signer_sha256"):
            val = entry.get(key)
            if isinstance(val, str) and not is_todo(val) and not RE_HEX64.match(norm_hex(val)):
                errors.append("%s: %s 必须是 64 位小写 hex(当前为 %r)" % (eid, key, val))
        ivc = entry.get("installed_version_code")
        # 允许整数(设备实测的 versionCode)或字面量 none(实测:设备上未安装该包名)。
        # none 是**测量结果**,不是"未知":设备上无副本 → 不存在被 /data 压制的问题。
        if (ivc is not None and not is_todo(ivc) and not isinstance(ivc, int)
                and str(ivc).lower() != "none"):
            errors.append("%s: installed_version_code 必须是整数或 none(均为设备实测值)" % eid)
        lic = entry.get("license")
        if isinstance(lic, str) and not is_todo(lic) and lic.upper().startswith("GPL"):
            src = entry.get("source_url")
            if src is None or is_todo(src):
                problems.append("license=%s 必须提供 source_url(GPL 的对应源码链接)" % lic)

        if problems:
            if enabled and allow_todo:
                warnings.extend("%s: %s(采集模式:仅提示,不阻断)" % (eid, p) for p in problems)
            elif enabled:
                errors.extend("%s: %s" % (eid, p) for p in problems)
            else:
                reason = "条目已禁用(enabled: false),未参与构建"
                skipped.append((eid, reason, problems))
                if strict:
                    errors.extend("%s: %s(strict 模式)" % (eid, p) for p in problems)
                # 非 strict 时不逐条刷警告:完整缺口清单已在上面的 [跳过] 行里给出
        elif not enabled:
            skipped.append((eid, "条目已禁用(enabled: false),未参与构建", []))

        notes and warnings.extend(notes)
    # --- 重复检查 ---
    seen_ids, seen_names, seen_stock = {}, {}, {}
    for entry in entries:
        eid = entry.get("id")
        if isinstance(eid, str) and not is_todo(eid):
            if eid in seen_ids:
                errors.append("id 重复: %s" % eid)
            seen_ids[eid] = True
        if not entry["_enabled"]:
            continue
        name = entry.get("name")
        if isinstance(name, str) and not is_todo(name):
            if name.lower() in seen_names:
                errors.append("enabled 条目的 name 重复: %s(模块内目录会冲突)" % name)
            seen_names[name.lower()] = True
        stock = entry.get("stock_package")
        if isinstance(stock, str) and not is_todo(stock):
            if stock in seen_stock:
                errors.append(
                    "两个 enabled 条目共享同一个 stock_package(%s):同类应用重复入包" % stock
                )
            seen_stock[stock] = True
    if not any(e["_enabled"] for e in entries):
        errors.append("没有任何 enabled: true 的条目,模块无内容")
    return errors, warnings, skipped


def emit_report(schema_version, entries, errors, warnings, skipped):
    lines = []
    lines.append("apps.yaml 校验: schema_version=%r,条目 %d 条" % (schema_version, len(entries)))
    for entry in entries:
        state = "纳入构建" if entry["_enabled"] else "跳过"
        lines.append(
            "  [%s] id=%-10s name=%-16s application_id=%-28s stock=%s"
            % (state, entry.get("id"), entry.get("name"), entry.get("application_id"), entry.get("stock_package"))
        )
    for eid, reason, problems in skipped:
        detail = (";" + "、".join(problems)) if problems else ""
        lines.append("  [跳过] %s:%s%s" % (eid, reason, detail))
    for text in warnings:
        lines.append("  [警告] %s" % text)
    for text in errors:
        lines.append("  [错误] %s" % text)
    return "\n".join(lines)


def main():
    if len(sys.argv) < 2:
        sys.stderr.write("用法: build.sh --check|--dump-apps-json|--list|--emit-tsv\n")
        return 2
    path = sys.argv[1]
    flags = sys.argv[2:]
    mode = flags[0] if flags else "--validate"
    strict = "--strict" in flags
    allow_todo = "--allow-todo" in flags
    try:
        schema_version, entries = load(path)
    except YamlError as exc:
        sys.stderr.write("[失败] 解析 apps.yaml 失败: %s\n" % exc)
        return 1
    if mode == "--dump-apps-json":
        out = {"schema_version": schema_version, "apps": []}
        for entry in entries:
            clean = {k: entry.get(k) for k in FIELDS}
            clean["_line"] = entry["_line"]
            clean["_todo_fields"] = entry["_todo_fields"]
            clean["_enabled"] = entry["_enabled"]
            out["apps"].append(clean)
        json.dump(out, sys.stdout, ensure_ascii=False, indent=2)
        sys.stdout.write("\n")
        return 0
    errors, warnings, skipped = validate(schema_version, entries, strict=strict, allow_todo=allow_todo)
    if mode == "--list":
        sys.stdout.write(emit_report(schema_version, entries, [], warnings, skipped) + "\n")
        return 0
    if mode in ("--emit-tsv", "--emit-tsv-all"):
        for entry in entries:
            if not entry["_enabled"] and mode == "--emit-tsv":
                continue
            row = []
            for k in FIELDS:
                val = entry.get(k)
                if isinstance(val, bool):
                    val = "true" if val else "false"
                row.append("" if val is None else "%s" % val)
            if any("\t" in cell or "\n" in cell for cell in row):
                sys.stderr.write("[失败] %s 的字段含制表符/换行,无法传递\n" % entry.get("id"))
                return 1
            sys.stdout.write("\t".join(row) + "\n")
        return 0
    sys.stdout.write(emit_report(schema_version, entries, errors, warnings, skipped) + "\n")
    if errors:
        sys.stdout.write(
            "\n校验失败:%d 处问题。\n"
            "说明:本工程禁止编造未知值(C1/C7)。请先用 scripts/probe-device.sh 采集设备实测值、\n"
            "     用 scripts/preflight-apk.sh 采集 sha256/签名指纹,再回填 apps.yaml。\n"
            "     若某项确实无法确认,请保持 TODO 并让构建失败,不要填入猜测值。\n" % len(errors)
        )
        return 1
    sys.stdout.write("\n校验通过。\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
PYEOF
}

# ---------------------------------------------------------------------------
# 小工具
# ---------------------------------------------------------------------------
need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "缺少命令 $1,请先安装" 2
}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    die "缺少 sha256 工具(sha256sum 或 shasum)" 2
  fi
}

norm_hex() { printf '%s' "${1:-}" | tr -d ':\ ' | tr '[:upper:]' '[:lower:]'; }

# 从 preflight 的 JSON 结果里取一个顶层字段
json_get() { # $1=json文件 $2=字段名
  python3 -c '
import json, sys
try:
    with open(sys.argv[1], "r", encoding="utf-8") as fh:
        data = json.load(fh)
except Exception:
    sys.stdout.write("")
    sys.exit(0)
val = data.get(sys.argv[2], "")
if isinstance(val, bool):
    val = "true" if val else "false"
sys.stdout.write("" if val is None else str(val))
' "$1" "$2"
}

collect_values() { # $1=门禁json $2=app-id $3=包名 $4=解包后 APK sha256 $5=资产 sha256 $6=资产名
  python3 - "$1" "$2" "$3" "$4" "$5" "$6" <<'PYEOF'
# -*- coding: utf-8 -*-
"""输出一个便于人工回填的采集块(只打印,不写 apps.yaml)"""
import json
import sys

path, app_id, pkg, apk_sha, asset_sha, asset_name = sys.argv[1:7]
try:
    with open(path, "r", encoding="utf-8") as fh:
        data = json.load(fh)
except Exception:
    data = {}


def val(key):
    v = data.get(key)
    return "<未取到>" if v in (None, "") else str(v)


print("=== %s ===" % app_id)
print("  apps.yaml 当前 application_id : %s" % pkg)
print("  APK 内真实 application_id     : %s" % val("application_id"))
print("  version_code                  : %s" % val("version_code"))
print("  version_name                  : %s" % val("version_name"))
print("  signer_sha256                 : %s" % val("signer_sha256"))
print("  asset_name                    : %s" % asset_name)
print("  asset_sha256                  : %s" % asset_sha)
print("  apk_sha256(解包后待安装物)    : %s" % apk_sha)
print("  module_suitable               : %s" % ("true" if data.get("module_suitable") else "false"))
print("  preflight_result              : %s" % (data.get("result") or "unknown"))
print("")
PYEOF
}

render_placeholder() { # $1=文件 $2=占位符 $3=替换文本
  python3 - "$1" "$2" "$3" <<'PYEOF'
# -*- coding: utf-8 -*-
import sys
path, key, val = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, "r", encoding="utf-8") as fh:
    data = fh.read()
if key not in data:
    sys.stderr.write("[失败] %s 中缺少占位符 %s\n" % (path, key))
    sys.exit(1)
with open(path, "w", encoding="utf-8") as fh:
    fh.write(data.replace(key, val))
PYEOF
}

# 从 apps.yaml 条目中取单个字段(dump JSON → 取值)
entry_field() { # $1=app-id $2=字段名
  apps_python --dump-apps-json | python3 -c '
import json, sys
data = json.load(sys.stdin)
for app in data["apps"]:
    if app.get("id") == sys.argv[1]:
        val = app.get(sys.argv[2], "")
        sys.stdout.write("" if val is None else str(val))
        break
' "$1" "$2"
}

# ---------------------------------------------------------------------------
# 参数解析
# ---------------------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "${1:-}" in
    --check)          MODE=check ;;
    --dump-apps-json) MODE=dump ;;
    --emit-tsv)       MODE=tsv ;;
    --emit-tsv-all)   MODE=tsv-all ;;
    --list)           MODE=list ;;
    --no-zip)         NO_ZIP=1 ;;
    --collect-only)   MODE=collect ;;
    --strict)         STRICT=1 ;;
    --no-color)       C_RED=''; C_GRN=''; C_YEL=''; C_BLD=''; C_RST='' ;;
    -h|--help)        usage; exit 0 ;;
    *)                die "未知参数: $1(用 --help 查看用法)" 2 ;;
  esac
  shift
done

case "$MODE" in
  dump) apps_python --dump-apps-json; exit $? ;;
  tsv) apps_python --emit-tsv; exit $? ;;
  tsv-all) apps_python --emit-tsv-all; exit $? ;;
  list) apps_python --list; exit $? ;;
  check) STRICT_FLAG=(); [ "$STRICT" = 1 ] && STRICT_FLAG=(--strict); apps_python --validate "${STRICT_FLAG[@]}"; exit $? ;;
esac

# ---------------------------------------------------------------------------
# 构建主流程
# ---------------------------------------------------------------------------
need_cmd python3
need_cmd zip
need_cmd unzip

printf '%s=== GKUI-Pack 构建 ===%s\n' "$C_BLD" "$C_RST"
[ -f "$APPS_YAML" ] || die "找不到 $APPS_YAML"

STRICT_FLAG=()
[ "$STRICT" = 1 ] && STRICT_FLAG=(--strict)
if [ "$MODE" = collect ]; then
  COLLECT=1
  STRICT_FLAG+=(--allow-todo)
  printf '%s%s%s\n' "$C_YEL" \
    "注意:当前是 --collect-only 只采集模式:只打印真实值,不产出模块 zip,最终一定返回非零。" "$C_RST"
fi
# 1) 清单校验(任何 TODO/规则违例都会在这里失败 C1/C2/C3/C7)
apps_python --validate "${STRICT_FLAG[@]}"

# 2) 版本信息
if [ -z "${VERSION:-}" ]; then
  VERSION="$(git -C "$ROOT" describe --tags --always --dirty 2>/dev/null || true)"
  [ -n "$VERSION" ] || VERSION="unreleased"
fi
VERSION_CODE="${VERSION_CODE:-$(date -u +%y%m%d%H)}"
case "$VERSION_CODE" in
  ''|*[!0-9]*) die "VERSION_CODE 必须是整数(module.prop 要求),当前为 '$VERSION_CODE'" 2 ;;
esac

WORK="$(mktemp -d "${TMPDIR:-/tmp}/gkui-pack.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

REPORT="$DIST_DIR/PREFLIGHT-REPORT.md"
mkdir -p "$DIST_DIR" "$APK_DIR"
{
  printf '# PREFLIGHT-REPORT — GKUI-Pack APK 门禁报告\n\n'
  printf -- '- 生成者: scripts/preflight-apk.sh(由 build.sh 调用)\n'
  printf -- '- 生成时间(UTC): %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  printf -- '- 模块版本: %s (versionCode %s)\n' "$VERSION" "$VERSION_CODE"
  printf -- '- APK 来源目录: %s\n\n' "$APK_DIR"
} > "$REPORT"

COLLECT_VALUES="$DIST_DIR/collected-values.txt"
COLLECT_TSV="$WORK/collected.tsv"
: > "$COLLECT_TSV"
if [ "$COLLECT" = 1 ]; then
  {
    printf '# GKUI-Pack 值采集报告(--collect-only)
'
    printf '# 生成时间(UTC): %s
' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf '# 用途:apps.yaml 中 signer_sha256 / sha256 等 TODO 字段的真实取值。
'
    printf '# 注意:本文件只是"值",不会自动写入 apps.yaml —— 请人工核对后填写。

'
  } > "$COLLECT_VALUES"
fi

apps_python --emit-tsv > "$WORK/enabled.tsv"
: > "$WORK/included.txt"
: > "$WORK/excluded.txt"

# 3) 逐个 enabled 条目:取资产 → 校验 sha256 → 解包 → 门禁 → 决定是否入模块
while IFS=$'\t' read -r APP_ID APP_NAME APP_PKG STOCK_PKG APP_REPO APP_UP APP_LIC \
        APP_SRC APP_TAG APP_ASSET APP_SHA APP_SIGNER APP_IVC APP_AS APP_MODE \
        APP_CONF APP_ENABLED; do
  [ -n "$APP_ID" ] || continue
  log ""
  printf '%s--- %s (%s) ---%s\n' "$C_BLD" "$APP_ID" "$APP_PKG" "$C_RST"
  info "mode=$APP_MODE install_as=$APP_AS confidence=$APP_CONF enabled=$APP_ENABLED"
  info "上游=$APP_UP 许可=$APP_LIC"
  info "来源=$APP_REPO @ $APP_TAG / $APP_ASSET"
  info "对应源码=$APP_SRC"
  info "apps.yaml 记录:签名证书=$APP_SIGNER 已安装 versionCode=$APP_IVC"

  asset_path="$APK_DIR/$APP_ASSET"
  if [ ! -f "$asset_path" ]; then
    die "缺少 Release 资产: $asset_path
      请先从 $APP_REPO 的 Release '$APP_TAG' 下载 asset '$APP_ASSET' 到该目录。
      提示:CI(release.yml)会自动下载;本地可用
            gh release download $APP_TAG -R $APP_REPO -p $APP_ASSET -D $APK_DIR"
  fi

  # 3.1 资产 sha256 校验(C5:APK 由 CI 下载并校验 sha256)
  actual_asset_sha="$(sha256_of "$asset_path")"
  if [ "$COLLECT" = 1 ]; then
    info "采集模式:实际资产 sha256 = $actual_asset_sha(apps.yaml 记录: $APP_SHA)"
  elif [ "$actual_asset_sha" != "$(norm_hex "$APP_SHA")" ]; then
    die "资产 sha256 不匹配: $asset_path
      期望(apps.yaml): $(norm_hex "$APP_SHA")
      实际(本地文件): $actual_asset_sha
      拒绝继续:可能是资产被替换、下载不完整,或 apps.yaml 尚未更新到该版本。"
  else
    info "资产 sha256 校验通过: ${actual_asset_sha:0:16}…"
  fi

  # 3.2 必要时解包(zip 包装的资产),取其中唯一的 APK
  mkdir -p "$WORK/apks"
  staged="$WORK/apks/$APP_NAME.apk"
  case "$APP_ASSET" in
    *.zip)
      info "资产是 zip 包装,解压取 APK"
      mkdir -p "$WORK/unzip/$APP_ID"
      unzip -qq -o "$asset_path" -d "$WORK/unzip/$APP_ID" || die "解压失败: $asset_path"
      found="$(find "$WORK/unzip/$APP_ID" -type f -name '*.apk' | sort)"
      count="$(printf '%s' "$found" | grep -c 'apk$' || true)"
      if [ "$count" -eq 0 ]; then
        die "压缩包内没有 .apk: $asset_path"
      elif [ "$count" -gt 1 ]; then
        die "压缩包内有多个 .apk,无法自动判定该用哪个(禁止猜测):
$(printf '%s\n' "$found")"
      fi
      cp "$found" "$staged"
      ;;
    *.apk)
      cp "$asset_path" "$staged"
      ;;
    *)
      die "asset_name 既不是 .apk 也不是 .zip,无法处理: $APP_ASSET" 2
      ;;
  esac
  staged_sha="$(sha256_of "$staged")"
  staged_size="$(wc -c < "$staged" | tr -d ' ')"
  info "待安装 APK: $(basename "$staged")  sha256=${staged_sha:0:16}…  ${staged_size} 字节"

  # 3.3 APK 门禁(七项)
  pf_json="$WORK/preflight-$APP_ID.json"
  rc=0
  bash "$PREFLIGHT" "$staged" "$APP_ID" --report "$REPORT" --json "$pf_json" || rc=$?

  if [ "$COLLECT" = 1 ]; then
    [ "$rc" = 3 ] && die "APK 门禁环境不完整(aapt/apksigner 缺失),无法采集 $APP_ID 的值" 2
    # 采集模式:门禁失败也要把"该填什么值"记录下来,便于回填 apps.yaml
    collect_values "$pf_json" "$APP_ID" "$APP_PKG" "$staged_sha" "$actual_asset_sha" "$APP_ASSET" >> "$COLLECT_VALUES"
    printf '%s\t%s\t%s\t%s\t%s\n' \
      "$APP_ID" "$actual_asset_sha" "$staged_sha" \
      "$(json_get "$pf_json" signer_sha256)" "$(json_get "$pf_json" version_code)" >> "$COLLECT_TSV"
    printf '%s[采集] %s:%s\n' "$C_YEL" "$APP_ID" "$C_RST"
    while IFS=$'\t' read -r k v; do
      [ -n "$k" ] && printf '        %-24s %s\n' "$k" "$v"
    done < <(python3 - "$pf_json" <<'PYC'
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    sys.exit(0)
for k in ("application_id", "version_code", "version_name", "signer_sha256", "module_suitable", "result"):
    v = d.get(k, "")
    if isinstance(v, bool):
        v = "true" if v else "false"
    if v != "":
        print("%s\t%s" % (k, v))
PYC
)
    rm -f "$staged"
    continue
  fi

  case "$rc" in
    0) : ;;
    2)
      # C3:检出 privileged 权限 → 不入模块,仅提示走 adb install
      warn "$APP_ID 检出 signature|privileged 权限,不适合模块化;已排除出本模块,仅可走 adb install"
      printf '%s|%s|%s|%s\n' "$APP_ID" "$APP_NAME" "$APP_PKG" "privileged 权限" >> "$WORK/excluded.txt"
      rm -f "$staged"
      continue
      ;;
    3) die "APK 门禁环境不完整(aapt/apksigner 缺失),无法校验 $APP_ID" 2 ;;
    *) die "APK 门禁失败: $APP_ID(详见 $REPORT)" ;;
  esac

  [ -f "$pf_json" ] || die "APK 门禁未产出结果文件: $pf_json(门禁脚本异常)"
  vc="$(json_get "$pf_json" version_code)"
  signer="$(json_get "$pf_json" signer_sha256)"
  if [ -z "$vc" ]; then
    # 未声明 versionCode 的 APK(LineageOS 部分仓库如此):平台按 0 处理,且设备上
    # 那一份的实测值也是 0(2026-10-08 真机证实)。到这里说明 preflight 的 G7 已经
    # 用"有效 versionCode = 0"比较并通过(要么设备上无副本,要么两侧同为 0),
    # 因此这里只做记录,不再拦截。
    vc="0(未声明)"
    warn "$APP_ID 的 APK 未声明 versionCode → 按平台语义记为 0(未声明)"
  fi
  [ -n "$signer" ] || die "APK 门禁结果缺少签名摘要: $pf_json"
  printf '%s|%s|%s|%s|%s|%s|%s|%s\n' \
    "$APP_ID" "$APP_NAME" "$APP_PKG" "$STOCK_PKG" "$vc" "$signer" "$staged_sha" "$APP_ASSET" \
    >> "$WORK/included.txt"
done < "$WORK/enabled.tsv"

if [ "$COLLECT" = 1 ]; then
  printf '\n%s=== 只采集模式结果(未产出模块 zip)===%s\n' "$C_BLD" "$C_RST"
  printf '真实值报告: %s\n' "$COLLECT_VALUES"
  printf '门禁报告  : %s\n' "$REPORT"
  printf '\n%s可回填到 apps.yaml 的片段(请人工核对;installed_version_code 是设备事实,\n用 bash scripts/probe-device.sh 采集):%s\n' "$C_BLD" "$C_RST"
  python3 - "$COLLECT_TSV" <<'PYEOF'
# -*- coding: utf-8 -*-
"""把采集到的值排版成 apps.yaml 片段(仅打印)"""
import sys

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    rows = [ln.rstrip("\n").split("\t") for ln in fh if ln.strip()]
for row in rows:
    while len(row) < 5:
        row.append("")
    app_id, asset_sha, apk_sha, signer, vc = row[:5]
    print("  # %s" % app_id)
    print("      sha256: %s          # 资产 %s 的 sha256" % (asset_sha, app_id))
    if asset_sha != apk_sha:
        print("      # 注意:该资产是 zip 包装,解包后 APK 的 sha256 = %s" % apk_sha)
    print("      signer_sha256: %s" % (signer or "<未取到>"))
    print("      # version_code(该 APK)= %s;installed_version_code 请在设备上实测" % (vc or "<未取到>"))
    print("")
PYEOF
  printf '%s重要:%s本模式**不产出任何模块 zip**,且退出码为 1(C7:apps.yaml 仍有 TODO 时不许假装构建成功)。\n' "$C_YEL" "$C_RST"
  printf '请把上面的值填入 apps.yaml(并删除对应的 TODO 注释),然后执行:\n'
  printf '    bash build.sh --check\n'
  exit 1
fi

included_count="$(grep -c . "$WORK/included.txt" || true)"
excluded_count="$(grep -c . "$WORK/excluded.txt" || true)"
[ "$included_count" -gt 0 ] || die "没有任何条目通过门禁,模块为空,已中止"

# 4) 渲染模块
STAGE="$WORK/stage"
mkdir -p "$STAGE/apks"
cp -a "$ROOT/module/." "$STAGE/"

ENTRY_LINES=""
STOCK_LINES=""
while IFS='|' read -r APP_ID APP_NAME APP_PKG _STOCK_PKG _VC _SIGNER APK_SHA _ASSET; do
  [ -n "$APP_ID" ] || continue
  cp "$WORK/apks/$APP_NAME.apk" "$STAGE/apks/$APP_NAME.apk"
  ENTRY_LINES="${ENTRY_LINES}${APP_PKG}|${APP_NAME}|${APK_SHA}"$'\n'
  case "$(printf '%s\n' "$STOCK_LINES")" in
    *"$STOCK_PKG"*) : ;;
    *) STOCK_LINES="${STOCK_LINES}${STOCK_PKG}"$'\n' ;;
  esac
done < "$WORK/included.txt"
ENTRY_LINES="${ENTRY_LINES%$'\n'}"
STOCK_LINES="${STOCK_LINES%$'\n'}"

render_placeholder "$STAGE/module.prop"   '__VERSION__'      "$VERSION"
render_placeholder "$STAGE/module.prop"   '__VERSION_CODE__' "$VERSION_CODE"
render_placeholder "$STAGE/customize.sh"  '__APP_ENTRIES__'  "$ENTRY_LINES"
render_placeholder "$STAGE/uninstall.sh"  '__STOCK_PACKAGES__' "$STOCK_LINES"

leftover="$(grep -rn -I -E '__[A-Z][A-Z0-9_]+__' "$STAGE" || true)"
if [ -n "$leftover" ]; then
  die "模块内仍有未渲染的占位符,拒绝打包:
$leftover"
fi
chmod 0755 "$STAGE"/*.sh "$STAGE/META-INF/com/google/android/update-binary"

# 5) 打包
ZIP_OUT="$DIST_DIR/GKUI-Pack-$VERSION.zip"
if [ "$NO_ZIP" = 1 ]; then
  info "--no-zip:已跳过打包,渲染结果在 $STAGE"
else
  rm -f "$ZIP_OUT"
  ( cd "$STAGE" && zip -q -r9 "$ZIP_OUT" . )
  info "模块包: $ZIP_OUT ($(wc -c < "$ZIP_OUT" | tr -d ' ') 字节)"
fi

# 6) 构建清单
MANIFEST="$DIST_DIR/build-manifest.txt"
{
  printf '# GKUI-Pack 构建清单\n'
  printf '# 生成时间(UTC): %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  printf '# 模块版本: %s (versionCode %s)\n' "$VERSION" "$VERSION_CODE"
  printf '# 产物: %s\n' "$ZIP_OUT"
  printf '#\n# 说明:asset_sha256 是 Release 资产文件的 sha256(即 apps.yaml 的 sha256);\n'
  printf '#       apk_sha256 是解包后实际写入 /system/app 的 APK 的 sha256。\n'
  printf 'state\tapp_id\tapplication_id\tname\tasset_sha256\tapk_sha256\tversion_code\tsigner_sha256\n'
  while IFS='|' read -r APP_ID APP_NAME APP_PKG _STOCK_PKG VC SIGNER APK_SHA _ASSET; do
    [ -n "$APP_ID" ] || continue
    printf 'included\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$APP_ID" "$APP_PKG" "$APP_NAME" "$(entry_field "$APP_ID" sha256)" "$APK_SHA" "$VC" "$SIGNER"
  done < "$WORK/included.txt"
  while IFS='|' read -r APP_ID APP_NAME APP_PKG REASON; do
    [ -n "$APP_ID" ] || continue
    printf 'excluded\t%s\t%s\t%s\t-\t-\t-\t-\n' "$APP_ID" "$APP_PKG" "$APP_NAME"
  done < "$WORK/excluded.txt"
} > "$MANIFEST"

# 7) 摘要
log ""
printf '%s=== 构建摘要 ===%s\n' "$C_BLD" "$C_RST"
printf '纳入模块(%s 项):\n' "$included_count"
while IFS='|' read -r APP_ID APP_NAME APP_PKG _STOCK_PKG VC SIGNER APK_SHA _ASSET; do
  [ -n "$APP_ID" ] || continue
  printf '  ✔ %-12s %-28s → system/app/%s/%s.apk  versionCode=%s  签名=%s…\n' \
    "$APP_ID" "$APP_PKG" "$APP_NAME" "$APP_NAME" "$VC" "$(printf '%s' "$SIGNER" | cut -c1-16)"
done < "$WORK/included.txt"
if [ "$excluded_count" -gt 0 ]; then
  printf '%s因检出 privileged 权限被排除(仅走 adb install,见 README):%s\n' "$C_YEL" "$C_RST"
  while IFS='|' read -r APP_ID APP_NAME APP_PKG REASON; do
    [ -n "$APP_ID" ] || continue
    printf '  ✘ %-12s %-28s (%s)\n' "$APP_ID" "$APP_PKG" "$REASON"
  done < "$WORK/excluded.txt"
fi
printf '被跳过的条目(未参与构建):\n'
apps_python --list 2>/dev/null | grep -E '^  \[跳过\] [a-z][a-z0-9_]*:' | sed 's/^/  /' || true
printf '报告: %s\n' "$REPORT"
printf '清单: %s\n' "$MANIFEST"
[ "$NO_ZIP" = 1 ] || printf '模块包: %s\n' "$ZIP_OUT"
log ""
printf '%s完成。%s模块为 coexist 模式:不替换、不修改任何 stock 应用。\n' "$C_GRN" "$C_RST"
printf '提醒:模块与设备 /data 中已安装的同包名应用会冲突,刷入前请先按 README 处理(C8)。\n'
