# 采集特权变体所需的设备权限转储

`framework-permissions.txt` **必须由实际目标设备采集**,并和设备/ROM/SDK 一一对应。仓库当前没有该转储;不可手工补权限、从另一台设备复制,也不可用测试夹具代替。因此 recorder APK 与权限 dump 都就绪前,仓库**不能生成正式特权 ZIP**。

## Windows PowerShell

```powershell
adb shell getprop ro.build.version.sdk
adb shell getprop ro.build.version.release
adb shell getprop ro.product.manufacturer
adb shell getprop ro.product.model
adb shell getprop ro.build.display.id
adb shell getprop ro.control_privapp_permissions
adb shell pm list permissions -f > "$env:USERPROFILE\Desktop\framework-permissions.txt"
```

若 ROM 的 `pm list permissions -f` 没有输出 `protectionLevel`,另行采集并保留原始输出供诊断：

```powershell
adb shell pm list permissions -fg > "$env:USERPROFILE\Desktop\framework-permissions-fg.txt"
```

不要把 `-fg` 输出自行整理后冒充原始 `-f` 转储。构建解析器只接受带权限名与 `protectionLevel` 的明确记录,无法解析就 fail-closed。

## Linux / macOS

```sh
adb shell getprop ro.build.version.sdk
adb shell getprop ro.build.version.release
adb shell getprop ro.product.manufacturer
adb shell getprop ro.product.model
adb shell getprop ro.build.display.id
adb shell getprop ro.control_privapp_permissions
adb shell pm list permissions -f > /tmp/framework-permissions.txt
```

将原始文件复制为本目录下 `framework-permissions.txt`,并在文件**开头**加上可复核的实测元数据(不要修改原始权限记录)：

```text
# Device: <manufacturer / model / ROM build>
# SDK: <SDK integer>; Android <release>
# Captured: YYYY-MM-DD
```

`SDK` 值必须与 `ro.build.version.sdk` 相同,日期用 UTC/本地时区请在提交说明中注明。保留转储中的全部原始输出,禁止只摘录所需权限。完成后运行：

```sh
python3 scripts/generate-privapp-permissions.py --help
bash tests/test_build.sh
```

## Fail-closed 条件

构建时权限白名单严格按下式生成：

```text
APK 实际请求权限 ∩ 设备转储中 protectionLevel 含 privileged 的权限
```

每个被选中的 APK 所申请的**每一个权限**都必须能在转储中找到唯一、可解析的保护级别。未知/冲突/格式错误权限、纯 `signature` 权限、无 `privileged` 权限、空交集、空白 XML 或缺少转储都会失败并且不生成 `GKUI-Pack-Priv-*.zip`。普通版不会因为 `privileged_ack: true` 而提升安装位置或生成白名单。

安装时特权版还会用目标设备的 `pm list permissions -f` (必要时 `-fg`)逐项复核,任意条目不再含 `privileged` 就在部署前中止。ROM、SDK、系统签名、应用或设备任何一项变化后都必须重新测量并重建。
