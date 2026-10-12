#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# =============================================================================
# scripts/generate-privapp-permissions.py
#
# Generate a static Android privapp-permissions XML from measured or
# source-extracted framework permission inputs and APK preflight JSON.
#
# Rules:
#   1) Extract requested_permissions (from aapt dump badging) and
#      declared_permissions (from aapt dump xmltree) via preflight JSON.
#   2) Permissions declared by the APK itself within its own package namespace
#      (<application_id>.*) do not need to appear in the framework list and are
#      never written to the XML.
#   3) Permissions declared by the APK outside its own package namespace
#      fail-closed immediately.
#   4) Composite protection levels such as `signature|appop` are NOT misjudged
#      as pure `signature`; pure `signature` (tokens == {"signature"}) still
#      fails-closed; only permissions whose protectionLevel contains
#      `privileged` are written to the XML.
#   5) When `device/framework-permissions.txt` is used (`--mode device`),
#      conflicting duplicate records in the dump fail-closed.
#      When `device/framework-permissions.source.txt` is used (`--mode source`),
#      duplicate `<permission>` declarations in AOSP/LineageOS manifest union
#      their protectionLevel tokens ("宁可多写不能少写": any declaration with
#      `privileged` is included).
# =============================================================================

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import tempfile
from pathlib import Path
from xml.sax.saxutils import quoteattr

PERMISSION_NAME = re.compile(r"^[A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z0-9_]+)+$")
DEVICE_HEADER_KEYS = ("device", "sdk", "captured")
SOURCE_HEADER_KEYS = ("source-repo", "source-commit", "source-path")

PERMISSION_START_PATTERNS = (
    re.compile(r"^\s*[+*]?\s*permission\s*[:=]\s*([A-Za-z][A-Za-z0-9_.]+)", re.I),
    re.compile(r"^\s*[+*]?\s*Permission\s+\[([A-Za-z][A-Za-z0-9_.]+)\]", re.I),
)
PROTECTION_LEVEL = re.compile(r"\bprotectionLevel\s*[:=]\s*([^\s,;]+)", re.I)


class InputError(Exception):
    """A permission input is missing, incomplete, or inconsistent."""


def detect_mode(path: Path, requested_mode: str, metadata: dict[str, str]) -> str:
    if requested_mode in ("device", "source"):
        return requested_mode
    if path.name.endswith(".source.txt") or metadata.get("source-type"):
        return "source"
    return "device"


def parse_dump(
    path: Path, requested_mode: str = "auto"
) -> tuple[str, dict[str, str], set[str], list[str]]:
    try:
        text = path.read_text(encoding="utf-8-sig")
    except OSError as exc:
        raise InputError(f"无法读取权限列表文件 {path}: {exc}") from exc

    if not text.strip():
        raise InputError(f"权限列表文件为空: {path}")

    metadata: dict[str, str] = {}
    for line in text.splitlines():
        if not line.lstrip().startswith("#"):
            continue
        header = line.lstrip()[1:].strip()
        if ":" not in header:
            continue
        key, value = header.split(":", 1)
        key = key.strip().lower()
        if value.strip():
            metadata[key] = value.strip()

    mode = detect_mode(path, requested_mode, metadata)
    if mode == "source":
        has_source_hdr = all(k in metadata for k in SOURCE_HEADER_KEYS)
        has_device_hdr = all(k in metadata for k in DEVICE_HEADER_KEYS)
        if not (has_source_hdr or has_device_hdr):
            missing = [k for k in SOURCE_HEADER_KEYS if k not in metadata]
            raise InputError(
                f"源码权限列表缺少可追溯头信息({', '.join(missing)});"
                "请在文件开头注明 Source-Repo / Source-Commit / Source-Path"
            )
    else:
        missing_headers = [key for key in DEVICE_HEADER_KEYS if key not in metadata]
        if missing_headers:
            expected = ", ".join(missing_headers)
            raise InputError(
                f"权限转储缺少可追溯头信息({expected});请在文件开头注明 Device / SDK / Captured"
            )

    levels: dict[str, str] = {}
    incomplete: set[str] = set()
    errors: list[str] = []
    current: str | None = None
    current_level: str | None = None

    def finish_record() -> None:
        nonlocal current, current_level
        if current is None:
            return
        if current_level is None:
            incomplete.add(current)
        elif current in levels and levels[current] != current_level:
            if mode == "source":
                # Source manifest may have feature-flagged duplicate <permission> tags;
                # union tokens so any declaration carrying `privileged` is retained.
                merged = list(
                    dict.fromkeys(
                        [t for t in levels[current].split("|") if t]
                        + [t for t in current_level.split("|") if t]
                    )
                )
                levels[current] = "|".join(merged)
            else:
                errors.append(
                    f"{current}: 转储中出现冲突的 protectionLevel: "
                    f"{levels[current]!r} 与 {current_level!r}"
                )
        else:
            levels[current] = current_level
        current = None
        current_level = None

    for line in text.splitlines():
        found = None
        for pattern in PERMISSION_START_PATTERNS:
            match = pattern.search(line)
            if match:
                found = match.group(1)
                break
        if found is not None:
            finish_record()
            current = found
            if not PERMISSION_NAME.fullmatch(current):
                errors.append(f"权限列表包含格式异常的权限名: {current!r}")
                current = None
                continue

        if current is not None:
            level_match = PROTECTION_LEVEL.search(line)
            if level_match:
                level = level_match.group(1).strip().strip("'\"")
                level = re.sub(r"\s*\|\s*", "|", level).lower()
                if current_level is not None and current_level != level:
                    errors.append(
                        f"{current}: protectionLevel 在同一条记录中重复且冲突"
                    )
                else:
                    current_level = level

    finish_record()

    if not levels:
        raise InputError(
            "无法从权限列表解析任何 permission/protectionLevel 记录;"
            "请确认使用 `adb shell pm list permissions -f` 或源码提取格式"
        )
    return mode, levels, incomplete, errors


def load_app_permissions(app_json: Path) -> tuple[str, str, list[str], list[str]]:
    try:
        data = json.loads(app_json.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise InputError(f"无法读取 preflight JSON {app_json}: {exc}") from exc

    app_id = data.get("app_id")
    package = data.get("application_id")
    permissions = data.get("requested_permissions")
    declared = data.get("declared_permissions", [])
    if not isinstance(app_id, str) or not app_id:
        raise InputError(f"preflight JSON 缺少 app_id: {app_json}")
    if not isinstance(package, str) or not PERMISSION_NAME.fullmatch(package):
        raise InputError(f"preflight JSON 缺少合法 application_id: {app_json}")
    if not isinstance(permissions, list) or any(not isinstance(p, str) for p in permissions):
        raise InputError(f"preflight JSON 缺少 requested_permissions 数组: {app_json}")
    if not isinstance(declared, list) or any(not isinstance(p, str) for p in declared):
        raise InputError(f"preflight JSON 的 declared_permissions 必须是字符串数组: {app_json}")

    normalized_req = sorted(set(permissions))
    for permission in normalized_req:
        if not PERMISSION_NAME.fullmatch(permission):
            raise InputError(f"{app_id}: APK 请求权限名格式非法: {permission!r}")

    normalized_decl = sorted(set(declared))
    for permission in normalized_decl:
        if not PERMISSION_NAME.fullmatch(permission):
            raise InputError(f"{app_id}: APK 自声明权限名格式非法: {permission!r}")

    return app_id, package, normalized_req, normalized_decl


def generate(
    dump: Path, app_jsons: list[Path], output: Path, requested_mode: str = "auto"
) -> list[str]:
    output.unlink(missing_ok=True)
    mode, levels, incomplete, parse_errors = parse_dump(dump, requested_mode=requested_mode)
    if parse_errors:
        raise InputError("权限列表不完整:\n  - " + "\n  - ".join(parse_errors))

    apps: list[tuple[str, str, list[str], list[str]]] = []
    seen_packages: set[str] = set()
    errors: list[str] = []
    report: list[str] = []
    entries: dict[str, set[str]] = {}

    source_label = (
        "源码推导(未经设备验证)" if mode == "source" else "设备实测转储(strict)"
    )
    report.append(f"白名单模式: {mode} ({source_label}) — 来源文件: {dump}")

    for app_json in app_jsons:
        app_id, package, requested, declared = load_app_permissions(app_json)
        if package in seen_packages:
            raise InputError(f"priv_variant 中 application_id 重复: {package}")
        seen_packages.add(package)
        apps.append((app_id, package, requested, declared))

        own_prefix = package + "."
        own_declared: set[str] = set()
        for decl_perm in declared:
            if decl_perm.startswith(own_prefix):
                own_declared.add(decl_perm)
            else:
                errors.append(
                    f"{app_id}: APK 自声明了包名命名空间({own_prefix}*)之外的权限 "
                    f"{decl_perm}(fail-closed)"
                )

        report.append(
            f"包 {app_id} ({package}) 请求权限 {len(requested)} 项"
            f"(自声明包内权限 {len(own_declared)} 项):"
        )
        for permission in requested:
            if permission in own_declared:
                report.append(
                    f"  - {permission} [APK 自声明且在自身包名命名空间内] → 排除,不写入白名单"
                )
                continue
            if permission not in levels:
                errors.append(f"{app_id}: {permission} 未出现在权限列表中(拒绝猜测)")
                continue
            if permission in incomplete:
                errors.append(
                    f"{app_id}: {permission} 的 protectionLevel 缺失/不明确(拒绝猜测)"
                )
                continue
            tokens = {part for part in levels[permission].split("|") if part}
            if "privileged" in tokens:
                entries.setdefault(package, set()).add(permission)
                report.append(f"  + {permission} [{levels[permission]}] → 写入白名单")
            elif tokens == {"signature"}:
                errors.append(
                    f"{app_id}: {permission} 是纯 signature 权限("
                    f"{levels[permission]});privapp 白名单不能授予它"
                )
            else:
                report.append(
                    f"  - {permission} [{levels[permission]}] → 非 privileged,不写入"
                )

    for app_id, package, _requested, _declared in apps:
        if not entries.get(package):
            errors.append(
                f"{app_id}: APK 申请集与 privileged 权限集没有交集;拒绝将该应用放入 priv-app"
            )

    if errors:
        raise InputError("白名单 fail-closed 校验失败:\n  - " + "\n  - ".join(errors))

    total = sum(len(perms) for perms in entries.values())
    if total < 1:
        raise InputError(
            "APK 实际申请集与 privileged 权限集的交集为空;拒绝生成空白白名单 XML"
        )

    xml_lines = [
        '<?xml version="1.0" encoding="utf-8"?>',
        "<permissions>",
    ]
    for package in sorted(entries):
        xml_lines.append(f"    <privapp-permissions package={quoteattr(package)}>")
        for permission in sorted(entries[package]):
            xml_lines.append(f"        <permission name={quoteattr(permission)} />")
        xml_lines.append("    </privapp-permissions>")
    xml_lines.append("</permissions>")
    xml_lines.append("")

    output.parent.mkdir(parents=True, exist_ok=True)
    fd, temp_name = tempfile.mkstemp(prefix=f".{output.name}.", dir=output.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as stream:
            stream.write("\n".join(xml_lines))
        os.replace(temp_name, output)
    finally:
        try:
            os.unlink(temp_name)
        except FileNotFoundError:
            pass

    report.append(f"白名单条数: {total}")
    report.append(f"XML: {output}")
    return report


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--dump",
        required=True,
        type=Path,
        help="measured `pm list permissions -f` output or source-extracted permissions file",
    )
    parser.add_argument(
        "--mode",
        choices=("auto", "device", "source"),
        default="auto",
        help="whitelist validation mode (default: auto-detect from filename/header)",
    )
    parser.add_argument(
        "--source",
        action="store_true",
        help="shorthand for --mode source",
    )
    parser.add_argument(
        "--app-json",
        action="append",
        required=True,
        type=Path,
        help="preflight JSON for one app in priv_variant.app_ids (repeatable)",
    )
    parser.add_argument(
        "--out",
        required=True,
        type=Path,
        help="generated static XML path",
    )
    args = parser.parse_args()
    mode = "source" if args.source else args.mode

    try:
        report = generate(args.dump, args.app_json, args.out, requested_mode=mode)
    except InputError as exc:
        args.out.unlink(missing_ok=True)
        print(f"[失败] {exc}", file=sys.stderr)
        return 1

    print("\n".join(report))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
