# 设备与源码权限清单说明（`device/`）

本目录为 Recorder 特权变体提供 `privapp-permissions` 生成输入。权限快照只代表 AndVM 虚拟机配置，不代表真实设备上的安装或授予结果。

## `framework-permissions.txt`（优先使用）

- 来源：AndVM 虚拟机环境中的 `GKUI-diag.txt` 第 [5] 节 `pm list permissions -f`；快照标注 Pixel 5 / redfin、LineageOS 23.2、Android 16 / SDK 36，并记录 OnePlus7TPro 配置背景及 build 属性。
- 文件头新增可追溯元数据；`--- [5] pm list permissions -f ---` 之后的权限正文保持原样，1195 条记录未改动。
- 该快照不含 `dangerous` 记录。生成器只在此已知快照场景下显式跳过缺失的 requested permission；若转储含 `dangerous` 记录，缺失的请求权限仍 fail-closed。
- 存在该文件时，`build.sh` 启用设备表严格门禁，并用它生成 Recorder 特权变体白名单。生成成功不等于真实设备已授予权限。
- 更换 ROM、Android 版本或目标环境时，应重新采集对应权限表；不得将 AndVM 快照当作真实设备数据。

## `framework-permissions.source.txt`（源码回退）

- 从 `LineageOS/android_frameworks_base` 的 `lineage-23.2` 分支、commit `f4ed08a03b518772ba77c3c0a1b4185fa1712c9b` 的 `core/res/AndroidManifest.xml` 提取。
- 重复源码声明按 protection-level token 合并；APK 自声明且位于自身包名空间内的权限排除，命名空间外的自声明权限 fail-closed。
- 仅使用源码回退表时，产物带 `recorderpriv-TEST` 标记，不能表述为设备验证。

在 AndVM 快照模式下，构建还会从源码表生成参考 XML 并逐字节比较；不一致即停止构建。该比较仅验证构建产物的一致性，不证明实际设备行为。
