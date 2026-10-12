# GKUI-Pack v0.0.4 发布说明（Release Notes）

> ## ⚠️ 【重要警告】关于 `GKUI-Pack-v0.0.4-recorderpriv-TEST.zip`
> - **`-recorderpriv-TEST.zip` 为测试专用特权变体，`白名单来源：源码推导，未经设备验证`。**
> - 其内置的 `privapp-permissions-org.lineageos.recorder.dev.xml` 由 `LineageOS/android_frameworks_base`（`lineage-23.2` 分支，commit `f4ed08a03b518772ba77c3c0a1b4185fa1712c9b`）的 `core/res/AndroidManifest.xml` 静态推导生成，**尚未经目标设备 `pm list permissions -f` 实测校验**。
> - 若目标 ROM 对特权权限的 `protectionLevel` 定义与上游源码不一致，Android `PackageManager` 可能会在启动时拒绝开机（本模块内置 `post-fs-data.sh` / `service.sh` 启动标记自救，若卡开机强制重启一次会自动禁用模块恢复）。
> - 收集到测试设备发回的 `GKUI-diag.txt`（内含完整 `pm list permissions -f`）并放入仓库 `device/framework-permissions.txt` 后，后续版本将切回设备实测严格门禁并移除 `-TEST` 标记。

---

## 一、两个安装包的区别与适用对象

本次 Release 同时提供两个可刷入模块包（模块 `id` 均为 `gkui-pack`，互刷会自动覆盖，不会同时生效）：

| 安装包文件名 | 录音机安装位置 | `privapp` 权限白名单 | 通话录音 | 适用对象 |
|---|---|---|---|---|
| **`GKUI-Pack-v0.0.4.zip`（普通版，默认推荐）** | `/system/app/GKUIRecorder` | 不含任何白名单 XML | 不生效 | 日常稳定使用日历、图库、计算器、时钟、普通录音的用户 |
| **`GKUI-Pack-v0.0.4-recorderpriv-TEST.zip`（TEST 特权版）** | `/system/priv-app/GKUIRecorder` | 含 `CAPTURE_AUDIO_OUTPUT` 白名单（源码推导，未经设备验证） | 待真机验证 | 愿意协助测试录音机特权挂载与通话录音、并把 `GKUI-diag.txt` 发回的测试者 |

> **提示（关于管理器内“更新”）**：两个包的模块 `id` 均为 `gkui-pack`，且 `update.json` 的更新地址指向普通版。**装了 TEST 版的人，以后在 Magisk / KernelSU / APatch 管理器里直接点“更新”会自动换回普通版**（如需继续使用特权版，请手动下载对应特权包刷入）。

### 本次主要更新（v0.0.4）
- **GKUIRecorder 默认版本升至 `beta3`**：保留 `beta2` 作为已登记前驱；由于 `beta2 → beta3` 签名证书变更，模块刷入时（C8）若检测到旧签名副本会中止安装并提示先备份录音、手动卸载或删旧模块并重启。若已安装 APK 字节与目标 `sha256` 一致，则支持直接接管。
- **开机后台自动诊断（`service.sh`）**：两个包均会在开机完成后自动在后台生成只读诊断报告 `$MODDIR/GKUI-diag.txt`，并在手机解锁后自动复制到 `/sdcard/Download/GKUI-diag.txt`，全程无需连接电脑或使用 ADB。

---

## 二、手机端三步测试流程（无需电脑，引用自 `docs/TESTER.md`）

**刷前必读**：如果之前手动装过 GKUI 日历、图库、计算器、时钟或录音机，请先在系统“设置 → 应用”里将它们卸载（录音机若装过旧版请先备份录音后卸载或删除旧模块并重启），否则模块安装会中止。

1. **刷入模块包**：在 Magisk / KernelSU / APatch 管理器中选择下载好的模块包刷入（测通话录音刷带 `-recorderpriv-TEST` 的测试包；日常稳定使用刷普通版）。
2. **重启手机**：点击重启，正常进入桌面并解锁手机。
3. **发回诊断文件**：开机解锁后等待约 1～2 分钟，打开系统“文件管理 → 下载（Download）”目录，找到自动生成的 `GKUI-diag.txt` 发回即可。

**卡开机自救**：万一刷入后卡在开机画面，直接长按电源键强制重启一次，模块会在第二次开机时自动禁用自身并正常进入系统。
