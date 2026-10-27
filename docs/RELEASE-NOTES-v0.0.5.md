# GKUI-Pack v0.0.5 发布说明（Release Notes）

> ## ℹ️ 关于 `GKUI-Pack-v0.0.5-recorderpriv.zip`（特权版，已去掉 TEST 标记）
> - **白名单来源：Pixel 5 / Android 16 设备权限表**（真机 `pm list permissions -f` 实测，见仓库 `device/framework-permissions.txt`），不再是 v0.0.4 的源码推导。
> - 本包生成的 `privapp-permissions-org.lineageos.recorder.dev.xml` 与 v0.0.4 的 `-recorderpriv-TEST.zip` 内 XML **逐字节相同**（仅 `CAPTURE_AUDIO_OUTPUT` 一项），构建时会自动逐字节比对，不一致即中止构建。
> - **验证口径（如实标注）**：已在 Pixel 5 / Android 16 验证开机与 `CAPTURE_AUDIO_OUTPUT` 授予；**通话录音功能本身尚未验证**；白名单 enforce 校验状态待 v0.0.5 诊断确认（v0.0.4 诊断漏采 `ro.control_privapp_permissions`）。

---

## 一、两个安装包的区别与适用对象

本次 Release 同时提供两个可刷入模块包（模块 `id` 均为 `gkui-pack`，互刷自动覆盖，不会同时生效）：

| 安装包文件名 | 录音机安装位置 | `privapp` 权限白名单 | 通话录音 | 适用对象 |
|---|---|---|---|---|
| **`GKUI-Pack-v0.0.5.zip`（普通版，默认推荐）** | `/system/app/GKUIRecorder` | 不含任何白名单 XML | 不生效 | 日常稳定使用日历、图库、计算器、时钟、普通录音的用户 |
| **`GKUI-Pack-v0.0.5-recorderpriv.zip`（特权版）** | `/system/priv-app/GKUIRecorder` | 含 `CAPTURE_AUDIO_OUTPUT` 白名单（Pixel 5 / Android 16 设备权限表） | 待真机验证 | 需要通话录音、愿意继续协助验证并回传 `GKUI-diag.txt` 的测试者 |

### 升级与互刷说明

* **从 v0.0.4 `-recorderpriv-TEST.zip` 升级到 v0.0.5 特权版**：直接在 Magisk / KernelSU / APatch 管理器里选择 `GKUI-Pack-v0.0.5-recorderpriv.zip` 刷入覆盖即可（模块 id 相同，管理器按覆盖升级处理），随后重启。两者白名单 XML 逐字节一致，不需要先卸载旧模块。
* **从 v0.0.4 普通版升级**：刷 `GKUI-Pack-v0.0.5.zip`，方式与以往相同。
* **注意管理器内的“更新”按钮**：两个包的模块 `id` 均为 `gkui-pack`，且 `update.json` 的更新地址恒指向**普通版**。因此装了特权版的人如果在管理器里点“更新”，**会被换回普通版**（录音机回到 `/system/app`、白名单 XML 被清理）。需要继续使用特权版时，请手动下载 `GKUI-Pack-v0.0.5-recorderpriv.zip` 刷入，不要点管理器“更新”。
* 跨 beta 签名变更（如录音机 beta2 → beta3）的中止保护不变；若安装被中止，按提示先备份录音、手动卸载或删旧模块并重启后再刷。

### 本次主要更新（v0.0.5）

- **recorder-priv 转为正式版**：白名单改用 Pixel 5 / Android 16 真机权限表严格门禁，文件名与 `module.prop` 去掉 `TEST` 标记；普通版照常生成，两个 zip 的模块 id 保持一致。
- **诊断脚本修正（`service.sh`）**：只读属性改为规格要求的 7 个键（`ro.lineage.version`、`ro.build.version.incremental`、`ro.build.date.utc`、`ro.build.fingerprint`、`ro.control_privapp_permissions`、`ro.build.version.sdk`、`ro.product.device`），删除拼写错误的 `ro.Boot.verifiedbootstate`；新增对 5 个 GKUI 包 + 5 个 stock 包共 10 个包的 `pm path` 采集，以及各包 `dumpsys package` 的 `declared permissions` 段、`signatures` / `versionCode` 行采集。boot 等待、`$MODDIR` 先写、`/sdcard` 轮询最多 600 秒、后台子进程、首行 `rm -f .boot_flag` 等原有行为保持不变。
- v0.0.4 真机诊断确认：5 个 GKUI 应用落点正确（Recorder 在 `priv-app`，其余在 `app`）；`CAPTURE_AUDIO_OUTPUT` 已授予；5 个 stock 包仍在设备上，coexist 模式真机确认；开机诊断在 `boot_completed` 后 59 秒跑完，`/sdcard` 复制 `waited=0s`。

### 已知异常（本轮只采集更多信息，不修复）

设备权限表中 `com.android.deskclock.dev.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION` 的归属包显示为 stock 时钟 `com.android.deskclock`（其余四个 GKUI 应用的同名权限均归属自身），且表中不存在 `com.android.deskclock.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION`。原因未知，暂无功能影响证据；v0.0.5 诊断已增加 10 包采集以便继续排查。

### 尚未经真机验证的项

- 白名单 enforce 校验状态（`ro.control_privapp_permissions`，待 v0.0.5 诊断回传）；
- 通话录音的实际效果；
- KernelSU / APatch 环境（目前仅 Magisk 流程有真机依据）；
- 时钟权限归属异常的原因；
- v0.0.5 正式特权包在真机上的刷入行为（本轮只在 CI 用真实 APK 构建过）。

---

## 二、手机端三步测试流程（无需电脑，引用自 `docs/TESTER.md`）

**刷前必读**：如果之前手动装过 GKUI 日历、图库、计算器、时钟或录音机，请先在系统“设置 → 应用”里将它们卸载（录音机若装过旧版请先备份录音后卸载或删除旧模块并重启），否则模块安装会中止。

1. **刷入模块包**：在 Magisk / KernelSU / APatch 管理器中选择下载好的模块包刷入（测通话录音刷 `GKUI-Pack-v0.0.5-recorderpriv.zip`；日常稳定使用刷普通版 `GKUI-Pack-v0.0.5.zip`）。
2. **重启手机**：点击重启，正常进入桌面并解锁手机。
3. **发回诊断文件**：开机解锁后等待约 1～2 分钟，打开系统“文件管理 → 下载（Download）”目录，找到自动生成的 `GKUI-diag.txt` 发回即可（文件末尾应有 `sdcard_copy: ok` 行）。

**卡开机自救**：万一刷入后卡在开机画面，直接长按电源键强制重启一次，模块会在第二次开机时自动禁用自身并正常进入系统。
