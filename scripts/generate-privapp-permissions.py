#!/usr/bin/env python3
# =============================================================================
# Generate a fail-closed privapp-permissions XML from measured inputs.
#
# Inputs are deliberately runtime data, not guessed constants:
#   * requested_permissions in each preflight JSON (from aapt dump badging)
#   * protectionLevel in the captured `pm list permissions -f` dump
#
# The output contains exactly the intersection of the two sets where the device
# reports the `privileged` protection flag. A missing permission, an unparseable
# dump, or a signature-only permission is a hard error and leaves no XML behind.
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
HEADER_KEYS = ("device", "sdk", "captured")

# `pm list permissions -f` output has varied slightly across Android releases.
# Accept the documented `permission:...` form and the verbose `Permission [...]
# (...)` form, but never infer a protection level from a different permission.
PERMISSION_START_PATTERNS = (
    re.compile(r"^\s*[+*]?\s*permission\s*[:=]\s*([A-Za-z][A-Za-z0-9_.]+)", re.I),
    re.compile(r"^\s*[+*]?\s*Permission\s+\[([A-Za-z][A-Za-z0-9_.]+)\]", re.I),
)
PROTECTION_LEVEL = re.compile(r"\bprotectionLevel\s*[:=]\s*([^\s,;]+)", re.I)


class InputError(Exception):
    """A measured input is missing, incomplete, or inconsistent."""


def parse_dump(path: Path) -> tuple[dict[str, str], set[str], list[str]]:
    try:
        text = path.read_text(encoding="utf-8-sig")
    except OSError as exc:
        raise InputError(f"无法读取设备权限转储 {path}: {exc}") from exc

    if not text.strip():
        raise InputError(f"设备权限转储为空: {path}")

    metadata: dict[str, str] = {}
    for line in text.splitlines():
        if not line.lstrip().startswith("#"):
            continue
        header = line.lstrip()[1:].strip()
        if ":" not in header:
            continue
        key, value = header.split(":", 1)
        key = key.strip().lower()
        if key in HEADER_KEYS and value.strip():
            metadata[key] = value.strip()
    missing_headers = [key for key in HEADER_KEYS if key not in metadata]
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
            # A record without a level makes this permission ambiguous even if a
            # duplicate record happens to carry one; fail if an APK requests it.
            incomplete.add(current)
        elif current in levels and levels[current] != current_level:
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
                errors.append(f"转储包含格式异常的权限名: {current!r}")
                current = None
                continue

        if current is not None:
            level_match = PROTECTION_LEVEL.search(line)
            if level_match:
                level = level_match.group(1).strip().strip("'\"")
                # Normalize whitespace around the `|` separators but retain the
                # original semantic tokens for strict classification below.
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
            "无法从设备转储解析任何 permission/protectionLevel 记录;"
            "请确认使用 `adb shell pm list permissions -f` 采集"
        )
    return levels, incomplete, errors


def load_requested(app_json: Path) -> tuple[str, str, list[str]]:
    try:
        data = json.loads(app_json.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise InputError(f"无法读取 preflight JSON {app_json}: {exc}") from exc

    app_id = data.get("app_id")
    package = data.get("application_id")
    permissions = data.get("requested_permissions")
    if not isinstance(app_id, str) or not app_id:
        raise InputError(f"preflight JSON 缺少 app_id: {app_json}")
    if not isinstance(package, str) or not PERMISSION_NAME.fullmatch(package):
        raise InputError(f"preflight JSON 缺少合法 application_id: {app_json}")
    if not isinstance(permissions, list) or any(not isinstance(p, str) for p in permissions):
        raise InputError(f"preflight JSON 缺少 requested_permissions 数组: {app_json}")
    normalized = sorted(set(permissions))
    for permission in normalized:
        if not PERMISSION_NAME.fullmatch(permission):
            raise InputError(f"{app_id}: APK 权限名格式非法: {permission!r}")
    return app_id, package, normalized


def generate(dump: Path, app_jsons: list[Path], output: Path) -> list[str]:
    output.unlink(missing_ok=True)
    levels, incomplete, parse_errors = parse_dump(dump)
    if parse_errors:
        raise InputError("设备权限转储不完整:\n  - " + "\n  - ".join(parse_errors))

    apps: list[tuple[str, str, list[str]]] = []
    seen_packages: set[str] = set()
    errors: list[str] = []
    report: list[str] = []
    entries: dict[str, set[str]] = {}

    for app_json in app_jsons:
        app_id, package, requested = load_requested(app_json)
        if package in seen_packages:
            raise InputError(f"priv_variant 中 application_id 重复: {package}")
        seen_packages.add(package)
        apps.append((app_id, package, requested))
        report.append(f"包 {app_id} ({package}) 请求权限 {len(requested)} 项:")
        for permission in requested:
            if permission not in levels:
                errors.append(f"{app_id}: {permission} 未出现在设备权限转储中(拒绝猜测)")
                continue
            if permission in incomplete:
                errors.append(f"{app_id}: {permission} 的 protectionLevel 缺失/不明确(拒绝猜测)")
                continue
            tokens = {part for part in levels[permission].split("|") if part}
            if "privileged" in tokens:
                entries.setdefault(package, set()).add(permission)
                report.append(f"  + {permission} [{levels[permission]}] → 写入白名单")
            elif "signature" in tokens:
                errors.append(
                    f"{app_id}: {permission} 是纯 signature 权限("
                    f"{levels[permission]});privapp 白名单不能授予它"
                )
            else:
                report.append(f"  - {permission} [{levels[permission]}] → 非 privileged,不写入")

    for app_id, package, _requested in apps:
        if not entries.get(package):
            errors.append(
                f"{app_id}: APK 申请集与设备 privileged 集没有交集;拒绝将该应用放入 priv-app"
            )

    if errors:
        raise InputError("白名单 fail-closed 校验失败:\n  - " + "\n  - ".join(errors))

    total = sum(len(perms) for perms in entries.values())
    if total < 1:
        raise InputError(
            "APK 实际申请集与设备 privileged 权限集的交集为空;拒绝生成空白白名单 XML"
        )

    xml_lines = [
        "<?xml version=\"1.0\" encoding=\"utf-8\"?>",
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
    parser.add_argument("--dump", required=True, type=Path, help="measured `pm list permissions -f` output")
    parser.add_argument("--app-json", action="append", required=True, type=Path,
                        help="preflight JSON for one app in priv_variant.app_ids (repeatable)")
    parser.add_argument("--out", required=True, type=Path, help="generated static XML path")
    args = parser.parse_args()

    try:
        report = generate(args.dump, args.app_json, args.out)
    except InputError as exc:
        args.out.unlink(missing_ok=True)
        print(f"[失败] {exc}", file=sys.stderr)
        return 1

    print("\n".join(report))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
