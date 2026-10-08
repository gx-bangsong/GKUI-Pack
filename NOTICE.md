# NOTICE — 来源、归属与许可

本文件逐应用说明 **上游项目 → gx-bangsong fork → 本打包仓库** 的链条、
对应的 tag / commit,以及各自的许可协议。本仓库只包含**打包与安装工程**
(脚本、模块模板、CI 配置、文档),**不包含任何 APK、也不包含任何上游源代码**。

---

## 1. 本仓库自身许可

本仓库整体以 **GPL-3.0**(见 [`LICENSE`](LICENSE))分发。

理由:纳入打包的 GKUICalendar 继承自 Etar(上游 **GPL-3.0**,强 copyleft),
其余应用为 **Apache-2.0**。Apache-2.0 与 GPL-3.0 单向兼容
(可将 Apache-2.0 作品并入 GPL-3.0 作品并整体按 GPL-3.0 分发),
因此取 GPL-3.0 作为本仓库许可即可覆盖全部纳入应用。

## 2. 逐应用归属链条

> 说明:下表 `commit` 列为 **GitHub Releases 中对应 tag 经 GitHub API 解析出的提交**
> (解析时间见各条),用于满足 GPL 的"对应源码"提供义务。
> 上游仓库许可以本工程「事实基线」(设备实测/人工确认)为准;
> 部分上游仓库在 GitHub API 上**未声明** SPDX 许可(见备注),不影响其实际许可文本。

### 2.1 GKUICalendar(日历)

| 环节 | 位置 | 许可 |
|---|---|---|
| 上游 | `LineageOS/android_packages_apps_Etar` | GPL-3.0 |
| fork | `gx-bangsong/GKUICalendar` @ tag `1.0` | GPL-3.0 |
| 对应源码 commit | `edf951d41909d274474bfde6700bae591608f924` | — |
| 本仓库 | `apps.yaml` → `id: calendar` | GPL-3.0 覆盖 |

- 对应源码链接:<https://github.com/gx-bangsong/GKUICalendar/commit/edf951d41909d274474bfde6700bae591608f924>
- 备注:该 fork 仓库内同时存在 `LICENSE` 与 `LICENSE.apache2`,
  其中 GPL-3.0 继承自 Etar。

### 2.2 GKUIPhotos(图库)

| 环节 | 位置 | 许可 |
|---|---|---|
| 上游 | `LineageOS/android_packages_apps_Glimpse` | Apache-2.0 |
| fork | `gx-bangsong/GKUIPhotos` @ tag `beta2` | Apache-2.0 |
| 对应源码 commit | `5158d5813c4b152ac70ee92fc823736e65da9e30` | — |
| 本仓库 | `apps.yaml` → `id: gallery` | Apache-2.0(并入 GPL-3.0 分发) |

- 对应源码链接:<https://github.com/gx-bangsong/GKUIPhotos/commit/5158d5813c4b152ac70ee92fc823736e65da9e30>
- 备注:上游仓库在 GitHub API 上未声明 SPDX 许可标识;许可取值来自本工程事实基线。
- 备注:该 fork 当前**仅有 prerelease**(`beta1`、`beta2`),无正式 release。

### 2.3 GKUICalculator(计算器)

| 环节 | 位置 | 许可 |
|---|---|---|
| 上游 | `LineageOS/android_packages_apps_ExactCalculator` | Apache-2.0 |
| fork | `gx-bangsong/GKUICalculator` @ tag `v1.0.1` | Apache-2.0 |
| 对应源码 commit | `3819af269e0a866fc61046787a0f09f44753cfb0` | — |
| 本仓库 | `apps.yaml` → `id: calculator` | Apache-2.0(并入 GPL-3.0 分发) |

- 对应源码链接:<https://github.com/gx-bangsong/GKUICalculator/commit/3819af269e0a866fc61046787a0f09f44753cfb0>
- 备注:上游仓库在 GitHub API 上未声明 SPDX 许可标识;许可取值来自本工程事实基线。
- 备注:该 fork 的 Release 资产是 **zip 包装**(`ExactCalculator-debug.apk.zip`),
  需解压后取其中 APK,见 `scripts/preflight-apk.sh` 与 `release.yml`。

### 2.4 GKUIClock(时钟)

| 环节 | 位置 | 许可 |
|---|---|---|
| 上游 | `LineageOS/android_packages_apps_DeskClock` | Apache-2.0 |
| fork | `gx-bangsong/android_packages_apps_DeskClock` @ tag `v1.0.1` | Apache-2.0 |
| 对应源码 commit | `e7fd65ec8f5fb1496ee7ac85e70327f97689380c` | — |
| 本仓库 | `apps.yaml` → `id: clock` | Apache-2.0(并入 GPL-3.0 分发) |

- 对应源码链接:<https://github.com/gx-bangsong/android_packages_apps_DeskClock/commit/e7fd65ec8f5fb1496ee7ac85e70327f97689380c>
- 备注:上游仓库在 GitHub API 上未声明 SPDX 许可标识;许可取值来自本工程事实基线。

### 2.5 GKUIRecorder(录音机)—— **未纳入构建**

| 环节 | 位置 | 许可 |
|---|---|---|
| 上游 | `LineageOS/android_packages_apps_Recorder`(由 GitHub API 的 `parent` / `source` 字段核实) | Apache-2.0 |
| fork | `gx-bangsong/GKUIRecorder`(仓库描述:"基于LineageOS录音机,添加打点功能") | Apache-2.0(仓库内 `REUSE.toml` + `LICENSES/Apache-2.0.txt`;GitHub API 的 license 字段"无法识别",故以仓库内 REUSE 元数据为准) |
| 本仓库 | `apps.yaml` → `id: recorder`,`confidence: unverified`,`enabled: false` | — |

- 该条目**被 `build.sh` 拒绝入包**:`application_id` 为 `TODO`,
  且 `confidence: unverified`。本仓库**不猜测**其包名(见硬约束 C1)——
  源码里的 `applicationId = org.lineageos.recorder` 与 `applicationIdSuffix = ".dev"`
  只是源码意图,不是已构建 APK 的事实。
- 该 fork 仓库当前**没有任何 Release、也没有任何 Tag**,
  因此不存在可供下载校验的资产。
- upstream / license 的核实时间:2026-10-08。

---

## 3. 免责声明

- 本仓库是**第三方(非官方)打包工程**,**不隶属** gx-bangsong、LineageOS、
  或任何 Android ROM / Magisk / KernelSU / APatch 项目,亦未获其背书。
- 本仓库不重新分发 APK;构建时由 CI 从上述 Release 直接下载并校验 sha256,
  最终产物由**使用者自行构建/承担**。
- 所有上游应用的知识产权归其各自作者所有,并按其各自许可分发。
- 刷机、安装系统应用、切换默认应用均有风险(可能无法开机、数据丢失),
  **后果自负**。详见 [`README.md`](README.md) 的风险说明。
