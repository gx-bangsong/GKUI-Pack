# 设备与源码权限清单说明（`device/`）

本目录用于为 `recorder-priv` 特权变体提供 `privapp-permissions` 白名单生成的权限定义输入：

1. **`device/framework-permissions.txt`（优先，真机实测，v0.0.5 起已入库）**
   - 采集自 **Pixel 5 / LineageOS / Android 16（SDK 36，build id `BP4A.251205.006`）**，
     采集时间 epoch `1793032493`，采集方式为 v0.0.4 `priv-TEST` 模块 `service.sh`
     生成的 `GKUI-diag.txt` 第 [5] 节（`pm list permissions -f`），原样保存，
     未做任何修改、补全、去重或重排（1195 条 permission 记录，权限名全部唯一）；
   - 文件开头的 `#` 注释头注明设备、SDK、build、采集时间与方式，以及因 v0.0.4
     诊断脚本缺陷未采集到的 4 个属性；读取脚本跳过注释头，只解析数据行；
   - 实测属性：该设备的 `pm list permissions -f` 输出**不含任何 dangerous 运行时权限**
     （转储内 dangerous 记录数为 0）。`generate-privapp-permissions.py` 在 device
     模式下据此把"APK 请求但转储未列出"的权限显式跳过（运行时权限本就不属于
     privapp 白名单范围）；一旦转储本身含有 dangerous 记录，缺失即按未知处理、
     仍然 fail-closed；
   - 存在该文件时，`build.sh` 启用严格门禁（冲突保护级别一律 fail-closed），
     产出的特权包为正式文件名 `GKUI-Pack-<ver>-recorderpriv.zip`（不带 `-TEST`），
     白名单来源标注为"Pixel 5 / Android 16 设备权限表"；
   - **换设备或换 Android 大版本时，必须重新采集权限表**（用模块自带诊断生成的
     `GKUI-diag.txt` 第 [5] 节替换本文件），不得跨设备复用。

2. **`device/framework-permissions.source.txt`（回退，LineageOS 源码提取）**
   - 当仓库中缺少 `device/framework-permissions.txt` 时，`build.sh` 自动回退使用本文件生成特权白名单；
   - 真实提取自 `LineageOS/android_frameworks_base`（分支 `lineage-23.2`，commit `f4ed08a03b518772ba77c3c0a1b4185fa1712c9b`）的 `core/res/AndroidManifest.xml`，共 1,079 条 `<permission>` 声明、1,059 个唯一权限名；
   - 遵循“宁可多写不能少写”原则：Recorder 申请的、源码里 `protectionLevel` 含 `privileged` 的权限全部写入 XML；APK 自声明且在自身包名命名空间（`org.lineageos.recorder.dev.*`）内的权限自动排除，包名命名空间外的自声明权限 fail-closed；
   - 使用源码推导白名单时，产物强制标记为 `TEST`：
     - 文件名：`GKUI-Pack-<ver>-recorderpriv-TEST.zip`
     - `module.prop` 的 `description` 注明：`白名单来源：源码推导，未经设备验证`
     - `PREFLIGHT-REPORT.md` 开头注明来源与风险提示。

> v0.0.5 构建时，`build.sh` 还会用同一份 preflight 结果分别从设备表与源码表各生成
> 一份 XML 并逐字节比对：不一致即停止构建并报告差异，保证正式包 XML 与 v0.0.4
> `priv-TEST` 包内 XML 逐字节相同（仅 `CAPTURE_AUDIO_OUTPUT` 一项）。
