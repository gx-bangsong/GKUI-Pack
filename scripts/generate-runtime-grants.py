#!/usr/bin/env python3
"""Generate fail-closed runtime-grants.list from APK preflight JSON and device data."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

RE_PACKAGE = re.compile(r"^[A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z0-9_]+)+$")
RE_APPOP = re.compile(r"^[A-Z][A-Z0-9_]*$")
RE_PERMISSION_LINE = re.compile(r"^\s*[+*]?\s*permission\s*:\s*([A-Za-z][A-Za-z0-9_.]+)\s*$", re.I)
RE_LEVEL_LINE = re.compile(r"^\s*protectionLevel\s*:\s*(.*?)\s*$", re.I)


def read_json(path: Path) -> dict:
    try:
        with path.open(encoding="utf-8") as handle:
            value = json.load(handle)
    except (OSError, json.JSONDecodeError) as exc:
        raise SystemExit(f"无法读取 JSON {path}: {exc}") from exc
    if not isinstance(value, dict):
        raise SystemExit(f"JSON 顶层必须是对象: {path}")
    return value


def read_framework_levels(path: Path) -> dict[str, str]:
    if not path.is_file():
        return {}
    levels: dict[str, str] = {}
    current: str | None = None
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        match = RE_PERMISSION_LINE.match(line)
        if match:
            current = match.group(1)
            continue
        if current is None:
            continue
        match = RE_LEVEL_LINE.match(line)
        if match:
            level = match.group(1).strip().strip("\"'").lower().replace(" ", "")
            previous = levels.get(current)
            if previous is not None and previous != level:
                raise SystemExit(
                    f"{path}:{number}: {current} 出现冲突的 protectionLevel: {previous} / {level}"
                )
            levels[current] = level
            current = None
    return levels


def read_appop_map(path: Path) -> dict[str, str]:
    mapping: dict[str, str] = {}
    if not path.is_file():
        return mapping
    for number, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        fields = line.split("|")
        if len(fields) != 2 or not all(fields):
            raise SystemExit(f"{path}:{number}: 格式必须是 permission|appop")
        permission, op = fields
        if not RE_PACKAGE.fullmatch(permission) or not RE_APPOP.fullmatch(op):
            raise SystemExit(f"{path}:{number}: 非法 permission 或 appop: {line}")
        if permission in mapping:
            raise SystemExit(f"{path}:{number}: 重复的 appop 映射: {permission}")
        mapping[permission] = op
    return mapping


def read_dependencies(path: Path) -> dict[str, list[str]]:
    dependencies: dict[str, list[str]] = {}
    if not path.is_file():
        return dependencies
    for number, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        fields = line.split("|")
        if len(fields) != 2 or not all(fields):
            raise SystemExit(f"{path}:{number}: 格式必须是 dependent|prerequisite")
        dependent, prerequisite = fields
        if not RE_PACKAGE.fullmatch(dependent) or not RE_PACKAGE.fullmatch(prerequisite):
            raise SystemExit(f"{path}:{number}: 非法权限依赖: {line}")
        dependencies.setdefault(dependent, [])
        if prerequisite not in dependencies[dependent]:
            dependencies[dependent].append(prerequisite)
    return dependencies


def read_included_ids(path: Path) -> list[str]:
    ids: list[str] = []
    seen: set[str] = set()
    for number, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not raw:
            continue
        app_id = raw.split("|", 1)[0]
        if not re.fullmatch(r"[a-z][a-z0-9_]*", app_id):
            raise SystemExit(f"{path}:{number}: 非法 included app id: {app_id!r}")
        if app_id in seen:
            raise SystemExit(f"{path}:{number}: included app id 重复: {app_id}")
        seen.add(app_id)
        ids.append(app_id)
    return ids


def validate_filter(app_id: str, key: str, value: object) -> list[str] | None:
    if value is None:
        return None
    if not isinstance(value, list):
        raise SystemExit(f"{app_id}: {key} 必须是权限名字符串列表")
    result: list[str] = []
    seen: set[str] = set()
    for permission in value:
        if not isinstance(permission, str) or not RE_PACKAGE.fullmatch(permission):
            raise SystemExit(f"{app_id}: {key} 含非法权限名: {permission!r}")
        if permission in seen:
            raise SystemExit(f"{app_id}: {key} 重复声明: {permission}")
        seen.add(permission)
        result.append(permission)
    return result


def ordered_permissions(
    app_id: str,
    package: str,
    requested: list[str],
    app: dict,
    levels: dict[str, str],
    appops: dict[str, str],
    dependencies: dict[str, list[str]],
    notes: list[str],
) -> list[tuple[str, str]]:
    only = validate_filter(app_id, "runtime_permissions_only", app.get("runtime_permissions_only"))
    exclude = validate_filter(
        app_id, "runtime_permissions_exclude", app.get("runtime_permissions_exclude")
    )
    if only is not None and exclude is not None:
        raise SystemExit(
            f"{app_id}: runtime_permissions_only 与 runtime_permissions_exclude 不可同时设置"
        )

    requested_unique = list(dict.fromkeys(requested))
    requested_set = set(requested_unique)
    for field, values in (
        ("runtime_permissions_only", only),
        ("runtime_permissions_exclude", exclude),
    ):
        if values is not None:
            unknown = [permission for permission in values if permission not in requested_set]
            if unknown:
                raise SystemExit(
                    f"{app_id}: {field} 中的权限未由 APK uses-permission 请求: "
                    + ", ".join(unknown)
                )

    if only is not None:
        selected = [permission for permission in requested_unique if permission in set(only)]
    elif exclude is not None:
        excluded = set(exclude)
        selected = [permission for permission in requested_unique if permission not in excluded]
    else:
        selected = requested_unique

    rows: list[tuple[str, str]] = []
    for permission in selected:
        level = levels.get(permission)
        if level is None:
            notes.append(f"SKIP {app_id}|{permission}: device framework permission level missing")
            continue
        tokens = set(level.split("|"))
        if "dangerous" in tokens:
            rows.append((permission, "grant"))
        elif "appop" in tokens:
            if permission in appops:
                rows.append((permission, "appops"))
            else:
                notes.append(
                    f"SKIP {app_id}|{permission}: appop protectionLevel={level}, "
                    "but scripts/appop-map.txt has no mapping"
                )
        elif tokens.intersection({"normal", "signature", "privileged", "development", "internal"}):
            # Normal / signature / privileged permissions are intentionally not runtime grants.
            continue
        else:
            notes.append(
                f"SKIP {app_id}|{permission}: unsupported protectionLevel={level!r} (fail closed)"
            )

    selected_names = [permission for permission, _method in rows]
    selected_set = set(selected_names)
    remaining = list(selected_names)
    ordered: list[str] = []
    while remaining:
        ready = [
            permission
            for permission in remaining
            if not any(
                prerequisite in selected_set and prerequisite not in ordered
                for prerequisite in dependencies.get(permission, [])
            )
        ]
        if not ready:
            raise SystemExit(f"{app_id}: runtime permission dependency cycle in generated grants")
        for permission in ready:
            ordered.append(permission)
            remaining.remove(permission)

    method_by_permission = {permission: method for permission, method in rows}
    return [(permission, method_by_permission[permission]) for permission in ordered]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apps-json", type=Path, required=True)
    parser.add_argument("--included", type=Path, required=True)
    parser.add_argument("--preflight-dir", type=Path, required=True)
    parser.add_argument("--framework-permissions", type=Path, required=True)
    parser.add_argument("--appop-map", type=Path, required=True)
    parser.add_argument("--dependencies", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--report", type=Path, required=True)
    args = parser.parse_args()

    apps_data = read_json(args.apps_json)
    app_by_id = {app.get("id"): app for app in apps_data.get("apps", []) if isinstance(app, dict)}
    levels = read_framework_levels(args.framework_permissions)
    appops = read_appop_map(args.appop_map)
    dependencies = read_dependencies(args.dependencies)
    included_ids = read_included_ids(args.included)

    rows: list[str] = []
    report: list[str] = [
        "Runtime permission selection (default-on; $MODDIR/no-auto-grant disables it):",
        f"Framework permission table: {args.framework_permissions}",
        f"Mapped AppOps: {len(appops)} entries from {args.appop_map}",
        "",
    ]
    for app_id in included_ids:
        app = app_by_id.get(app_id)
        if app is None:
            raise SystemExit(f"included app id {app_id!r} is missing from apps.yaml JSON")
        package = app.get("application_id")
        if not isinstance(package, str) or not RE_PACKAGE.fullmatch(package):
            raise SystemExit(f"{app_id}: application_id is not a valid package name")
        preflight_path = args.preflight_dir / f"preflight-{app_id}.json"
        preflight = read_json(preflight_path)
        if preflight.get("application_id") != package:
            raise SystemExit(
                f"{app_id}: preflight package mismatch: {preflight.get('application_id')!r} != {package!r}"
            )
        requested = preflight.get("requested_permissions")
        if not isinstance(requested, list) or any(not isinstance(item, str) for item in requested):
            raise SystemExit(f"{app_id}: preflight requested_permissions is not a string list")
        notes: list[str] = []
        permission_methods = ordered_permissions(
            app_id, package, requested, app, levels, appops, dependencies, notes
        )
        report.append(f"[{app_id}] {package}")
        if not permission_methods:
            report.append("  (no grantable runtime permissions)")
        for permission, method in permission_methods:
            if method == "appops" and permission not in appops:
                raise SystemExit(f"{app_id}: appops row lacks a map entry: {permission}")
            rows.append(f"{package}|{permission}|{method}")
            if method == "appops":
                report.append(f"  {permission} -> appops {appops[permission]}")
            else:
                report.append(f"  {permission} -> pm grant")
        for note in notes:
            report.append(f"  {note}")
        report.append("")

    seen: set[tuple[str, str]] = set()
    for number, row in enumerate(rows, 1):
        fields = row.split("|")
        if len(fields) != 3 or not all(fields):
            raise SystemExit(f"generated runtime-grants.list:{number}: expected package|permission|method")
        package, permission, method = fields
        key = (package, permission)
        if key in seen:
            raise SystemExit(f"generated runtime-grants.list:{number}: duplicate row {row}")
        seen.add(key)
        level = levels.get(permission)
        if level is None:
            raise SystemExit(f"generated row cannot be verified against framework table: {row}")
        tokens = set(level.split("|"))
        if method == "grant":
            if "dangerous" not in tokens:
                raise SystemExit(f"fail closed: pm grant on non-dangerous {permission} (level={level})")
        elif method == "appops":
            if "dangerous" in tokens or "appop" not in tokens or permission not in appops:
                raise SystemExit(f"fail closed: unsupported appops row {row} (level={level})")
        else:
            raise SystemExit(f"fail closed: unsupported runtime grant method {method!r}")

    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text("".join(row + "\n" for row in rows), encoding="utf-8")
    args.report.write_text("\n".join(report).rstrip() + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError) as exc:
        sys.stderr.write(f"runtime grant generation failed closed: {exc}\n")
        sys.exit(1)
