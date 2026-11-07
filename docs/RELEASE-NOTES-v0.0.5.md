# GKUI-Pack v0.0.5 发布说明（Release Notes）

> ## ℹ️ 关于 `GKUI-Pack-v0.0.5-recorderpriv.zip`（历史特权版）
> - **权限表来源：AndVM 虚拟机快照**（Pixel 5 / redfin、Android 16 / SDK 36 配置；见 `device/framework-permissions.txt`），不是本文件所称的真实设备验证。
> - 该版本生成的 `privapp-permissions-org.lineageos.recorder.dev.xml` 与 v0.0.4 的 `-recorderpriv-TEST.zip` 内 XML 逐字节相同（仅 `CAPTURE_AUDIO_OUTPUT` 一项）；构建流程执行比较。
> - **验证范围**：已在虚拟机环境（AndVM，Pixel 5 / OnePlus7TPro 配置）验证；真实设备行为、KernelSU/APatch、A/B、OTA、权限实际授予及通话录音均未验证。历史文本中将快照称作“真机实测”的表述已更正。

---

## 一、两个安装包的区别与适用对象

本次 Release 同时提供两个可刷入模块包（模块 `id` 均为 `gkui-pack`，互刷自动覆盖，不会同时生效）：

| 安装包文件名 | 录音机安装位置 | `privapp` 权限白名单 | 通话录音 | 适用对象 |
|---|---|---|---|---|
| **`GKUI-Pack-v0.0.5.zip`（普通版，默认推荐）** | `/system/app/GKUIRecorder` | 不含任何白名单 XML | 不生效 | 日常稳定使用日历、图库、计算器、时钟、普通录音的用户 |
| **`GKUI-Pack-v0.0.5-recorderpriv.zip`（特权版）** | `/system/priv-app/GKUIRecorder` | 含 `CAPTURE_AUDIO_OUTPUT` 白名单（AndVM 虚拟机快照） | 未验证 | 需要通话录音、愿意继续协助验证并回传 `GKUI-diag.txt` 的测试者 |

### 升级与互刷说明

* **从 v0.0.4 `-recorderpriv-TEST.zip` 升级到 v0.0.5 特权版**：直接在 Magisk / KernelSU / APatch 管理器里选择 `GKUI-Pack-v0.0.5-recorderpriv.zip` 刷入覆盖即可（模块 id 相同，管理器按覆盖升级处理），随后重启。两者白名单 XML 逐字节一致，不需要先卸载旧模块。
* **从 v0.0.4 普通版升级**：刷 `GKUI-Pack-v0.0.5.zip`，方式与以往相同。
* **注意管理器内的“更新”按钮**：两个包的模块 `id` 均为 `gkui-pack`，且 `update.json` 的更新地址恒指向**普通版**。因此装了特权版的人如果在管理器里点“更新”，**会被换回普通版**（录音机回到 `/system/app`、白名单 XML 被清理）。需要继续使用特权版时，请手动下载 `GKUI-Pack-v0.0.5-recorderpriv.zip` 刷入，不要点管理器“更新”。
* 跨 beta 签名变更（如录音机 beta2 → beta3）的中止保护不变；若安装被中止，按提示先备份录音、手动卸载或删旧模块并重启后再刷。

### 本次主要更新（v0.0.5）

- **recorder-priv 转为正式版**：白名单改用 AndVM 虚拟机快照作为严格门禁输入，文件名与 `module.prop` 去掉 `TEST` 标记；普通版照常生成，两个 zip 的模块 id 保持一致。此变更不等同于真实设备验证。
- **诊断脚本修正（`service.sh`）**：只读属性改为规格要求的 7 个键（`ro.lineage.version`、`ro.build.version.incremental`、`ro.build.date.utc`、`ro.build.fingerprint`、`ro.control_privapp_permissions`、`ro.build.version.sdk`、`ro.product.device`），删除拼写错误的 `ro.Boot.verifiedbootstate`；新增对 5 个 GKUI 包 + 5 个 stock 包共 10 个包的 `pm path` 采集，以及各包 `dumpsys package` 的 `declared permissions` 段、`signatures` / `versionCode` 行采集。boot 等待、`$MODDIR` 先写、`/sdcard` 轮询最多 600 秒、后台子进程、首行 `rm -f .boot_flag` 等原有行为保持不变。
- 当时新增了 5 个 GKUI 与 5 个 stock 包的只读诊断采集逻辑；脚本测试/虚拟机快照不证明真实设备的安装落点、权限授予、coexist 状态或启动计时。

### 历史问题说明（v0.0.8 补充诊断）

#### 时钟诊断事实

用户提供的诊断事实为：GKUI Clock APK 声明 `<original-package android:name="com.android.deskclock"/>`；stock 与 GKUI 时钟名称的首个 `pm path` 相同，均为 `/system/app/GKUIClock/GKUIClock.apk`，并共享 PackageSetting；`/product/app/DeskClock` 因重复 APK 被跳过。不要将原因归结为子串匹配或 GKUI Clock 未安装。共享 PackageSetting 下闹钟数据由 GKUI Clock 继承是预期，不是已验证事实；闹钟实际响铃未验证。扩展 `<original-package>` 替换到其他四个应用不属于本次实现。v0.0.6 与 v0.0.7 对应同一提交 `1d34861b50436c29415628a06f1b7769ece2bb8a`，PR #6 未包含这项 clock 修复；无法访问的 `transfer/diag-v0.0.7` 分支未被读取或合并。

### 尚未验证的项

- 真实设备上的安装、开机、`ro.control_privapp_permissions` enforce 实际效果与权限授予；
- KernelSU / APatch、A/B、OTA；
- 通话录音、真实设备 `pm grant` / AppOps；
- 卸载后 `/product/app/DeskClock` 恢复、闹钟数据继承与实际响铃；
- Recorder 特权变体在真实设备上的完整行为。

---

## 二、手机端三步测试流程（无需电脑，引用自 `docs/TESTER.md`）

**刷前必读**：如果之前手动装过 GKUI 日历、图库、计算器、时钟或录音机，请先在系统“设置 → 应用”里将它们卸载（录音机若装过旧版请先备份录音后卸载或删除旧模块并重启），否则模块安装会中止。

1. **刷入模块包**：在 Magisk / KernelSU / APatch 管理器中选择下载好的模块包刷入（测通话录音刷 `GKUI-Pack-v0.0.5-recorderpriv.zip`；日常稳定使用刷普通版 `GKUI-Pack-v0.0.5.zip`）。
2. **重启手机**：点击重启，正常进入桌面并解锁手机。
3. **发回诊断文件**：开机解锁后等待约 1～2 分钟，打开系统“文件管理 → 下载（Download）”目录，找到自动生成的 `GKUI-diag.txt` 发回即可（文件末尾应有 `sdcard_copy: ok` 行）。

**卡开机自救**：万一刷入后卡在开机画面，直接长按电源键强制重启一次，模块会在第二次开机时自动禁用自身并正常进入系统。
