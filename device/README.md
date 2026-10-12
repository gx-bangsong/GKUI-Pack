# 设备与源码权限清单说明（`device/`）

本目录用于为 `recorder-priv` 特权变体提供 `privapp-permissions` 白名单生成的权限定义输入：

1. **`device/framework-permissions.txt`（优先，真机实测）**
   - 由目标设备通过 `pm list permissions -f`（或模块自带 `service.sh` 输出的 `GKUI-diag.txt`）采集得到；
   - 文件开头必须包含 `# Device:`、`# SDK:`、`# Captured:` 元数据头；
   - 存在该文件时，`build.sh` 启用严格门禁（冲突保护级别一律 fail-closed），产出的特权包为正式文件名 `GKUI-Pack-<ver>-recorderpriv.zip`（不带 `-TEST`）。

2. **`device/framework-permissions.source.txt`（回退，LineageOS 源码提取）**
   - 当仓库中缺少 `device/framework-permissions.txt` 时，`build.sh` 自动回退使用本文件生成特权白名单；
   - 真实提取自 `LineageOS/android_frameworks_base`（分支 `lineage-23.2`，commit `f4ed08a03b518772ba77c3c0a1b4185fa1712c9b`）的 `core/res/AndroidManifest.xml`，共 1,079 条 `<permission>` 声明、1,059 个唯一权限名；
   - 遵循“宁可多写不能少写”原则：Recorder 申请的、源码里 `protectionLevel` 含 `privileged` 的权限全部写入 XML；APK 自声明且在自身包名命名空间（`org.lineageos.recorder.dev.*`）内的权限自动排除，包名命名空间外的自声明权限 fail-closed；
   - 使用源码推导白名单时，产物强制标记为 `TEST`：
     - 文件名：`GKUI-Pack-<ver>-recorderpriv-TEST.zip`
     - `module.prop` 的 `description` 注明：`白名单来源：源码推导，未经设备验证`
     - `PREFLIGHT-REPORT.md` 开头注明来源与风险提示。
