# GKUI-Pack

把 [gx-bangsong](https://github.com/gx-bangsong) 的 LineageOS 本土化应用
(GKUI 日历 / 图库 / 计算器 / 时钟)打包安装到你**已经能正常运行的设备**上。

本仓库是**打包与安装工程**,不含任何 APK、不含任何上游源码:
APK 由 CI 或你本机从各应用的 GitHub Releases 下载,并逐个校验 sha256 与签名证书。

---

## ⚠️ 先读这一节:全部 APK 都是 debug 构建

> **GKUI 系列 APK 均为 debug 构建**(包名带 `.debug` / `.dev` 后缀,
> 由 **debug keystore** 签名),不是正式发行签名。
>
> * 调试签名可能随构建环境变化。当签名与设备上已安装版本不一致时,
>   覆盖安装会失败(`INSTALL_FAILED_UPDATE_INCOMPATIBLE`),
>   此时**只能卸载重装,应用内数据会丢失**
>   —— 日历/图库的数据存放在系统 Provider,不受影响;
>   **时钟闹钟、计算器历史、录音机设置会丢失**。
> * 本工程的 CI 会把每个 APK 的**签名证书 SHA-256** 与 `apps.yaml` 中记录的值比对,
>   不一致即**构建失败**并提示上述后果(C6)。
> * 请**不要**把本工程产物用于任何正式分发场景。

---

## 🚀 主方案(默认推荐):adb 免 root 安装

**不需要 root、不需要解锁、不动系统分区、失败可回退。** 绝大多数情况下用这个就够了。

### 1. 准备 APK

把每个应用 Release 中的资产下载到同一个目录(默认 `dist/apks/`;文件名必须与
`apps.yaml` 里的 `asset_name` 完全一致):

```bash
# 以日历为例(其余应用见 apps.yaml 的 repo / release_tag / asset_name 字段)
mkdir -p dist/apks
gh release download 1.0 -R gx-bangsong/GKUICalendar -p GKUICalendar-1.0.apk -D dist/apks
```

> 不确定该下哪个资产?执行 `bash build.sh --list` 看清单;
> 缺哪个文件时,`install_all.sh` 会直接把该执行的 `gh release download` 命令打印给你。

### 2. 一键安装

```bash
bash scripts/install_all.sh            # 需要 adb 已连接并已授权
bash scripts/install_all.sh --dry-run  # 先看看会做什么(不实际安装)
bash scripts/install_all.sh -s <序列号>  # 连接了多台设备时指定
```

`install_all.sh` 做的事:

* 检测 adb 与设备;没有设备/未授权/多设备时**友好退出,不做任何修改**;
* 对每个应用先校验资产 sha256(zip 包装的资产会自动解包取其中唯一的 APK);
* 只执行 `adb install -r <apk>`;
* 失败时把错误码翻译成人话(见下文「常见错误码」);
* **不卸载、不禁用、不修改任何已有应用**,破坏性命令只以建议形式打印。

### 3. 切换默认应用

安装完成后,到设备的 **设置 → 应用 → 默认应用** 中切换
(入口名称随 ROM 版本略有差异):

* 默认「日历」→ 选 GKUI 日历;
* 默认「图库 / 相册」→ 选 GKUI 图库(部分 ROM 没有独立的默认图库开关,
  此时打开图片时选「始终使用 GKUI 图库」即可)。

GKUI 应用与 ROM 自带应用是**两个不同的应用**(包名不同),
切换默认应用只影响「打开方式」,不会卸载或禁用自带应用。

### 4. 回退

```bash
bash scripts/uninstall_all.sh              # 逐个确认后再卸载
bash scripts/uninstall_all.sh --keep-data  # 保留应用数据(仅当之后重装签名一致时有用)
```

---

## 🧩 次方案:systemless 模块(Magisk / KernelSU / APatch)

模块为 **coexist 模式**:APK 挂载到 `/system/app/<Name>/`,与 ROM 自带应用**共存**,
**绝不替换、绝不修改、绝不禁用**任何自带应用。

### ⚠️ 刷入前必须先做的一件事(C8)

GKUI 应用目前通常已经通过 adb 安装在 **`/data` 用户空间**;模块版与之**同包名**,
必然冲突。所以 `module/customize.sh` 会在安装时逐个执行 `pm path <application_id>`:

* 返回 `/data/...` → **中止整个安装**(exit 1)并打印:

  ```
  检测到 <pkg> 已安装于用户空间。请先 `pm uninstall <pkg>`
  (日历/图库数据存于系统 Provider 不受影响,时钟闹钟/计算器历史/录音机设置会丢失),
  重启后再刷入本模块。
  ```

  **模块不会替你执行卸载** —— 卸载必须由你显式执行:

  ```bash
  bash scripts/uninstall_all.sh --yes     # 或用 adb uninstall <application_id>
  ```

* 返回 `/system/...` → 认为模块已生效,该条目跳过。

另外:安装环境必须有可用的 `pm`(在 recovery 下刷入会被拒绝),
此时请改用管理器在系统内安装,或直接用上面的**主方案**。

### 构建模块

```bash
bash build.sh
# → dist/GKUI-Pack-<version>.zip        模块包(刷入用)
# → dist/PREFLIGHT-REPORT.md            APK 七项门禁报告
# → dist/build-manifest.txt             本次构建的每个 APK 的实际 sha256 / 签名 / versionCode
```

构建会依次执行:清单校验 → 资产 sha256 校验 → 解包 → **APK 七项门禁**
→ 渲染模块 → 打包。任何一项不满足都会失败(见「硬约束」)。

### 刷入

* **Magisk**:Magisk 应用 → 模块 → 从本地安装,选择 `dist/GKUI-Pack-*.zip`。
* **KernelSU / APatch**:用各自管理器安装同一个 zip。
  ⚠️ **本工程未在 KernelSU / APatch 真机上验证**(见「诚实边界」)。

### 开机自愈(bootloop 自救)

* `post-fs-data.sh`:每次开机在模块目录写入 `.boot_flag`;
  **如果发现该标记已存在**(说明上一次开机没跑完),就写入 `disable` 让管理器
  在下次开机时跳过本模块,从而打破 bootloop;
* `service.sh`:开机成功进入系统服务阶段后删除 `.boot_flag`,并把时间戳写入
  `last_boot.log`。

### 隐藏 ROM 自带应用(可选,需你自己执行)

本模块**不会**替你做这件事。如果你确实想隐藏自带应用:

```bash
adb shell pm disable-user --user 0 <stock_package>
# 恢复:adb shell pm enable <stock_package>
```

---

## 🚫 本工程明确不做的事(硬约束)

| 编号 | 约束 | 说明 |
|---|---|---|
| C1 | **不推断包名** | known 反例:`GKUICalendar` fork 自 Etar,但它的 applicationId 是 `ws.xsoh.etar.debug`,不是 `org.lineageos.etar.debug`。凡不在事实基线中的值一律写 `TODO`,构建失败。 |
| C2 | **只做 coexist** | `mode` 只允许 `coexist`;不生成任何写入 stock 应用目录的代码;不使用 Magisk 的 `REPLACE` 变量或 `.replace` 文件。 |
| C3 | **只装 `system/app`** | 带后缀的新包名不在 ROM 的 privapp 白名单里,放进特权应用目录并申请 `signature\|privileged` 权限会导致 zygote 抛白名单错误 → bootloop。门禁若检出某 APK 申请此类权限,**不生成白名单 XML**,而是**把它排除出模块**,并在此标注「该应用仅走 adb install」。 |
| C4 | **不含拨号 / 短信 / 联系人** | 它们使用 `sharedUserId="android.uid.shared"` 并依赖 platform 签名,第三方签名无法替换,任何打包尝试都必然失败。因此本仓库**不接受**这类应用,即使被要求也不做。 |
| C5 | **仓库不含 APK** | `.gitignore` 含 `*.apk`、`dist/`、`build/`、`*.keystore`;验收 `git ls-files \| grep -c '\.apk$'` 必须为 `0`;APK 由 CI 下载并校验 sha256。 |
| C6 | **签名必须匹配** | 每个 APK 的证书 SHA-256 与 `apps.yaml` 记录不一致 → 构建失败,并提示「需卸载重装,应用内数据会丢失」。 |
| C7 | **TODO 必须失败** | 任何必填字段为 `TODO` 或 `confidence: unverified` 都让构建**失败**,绝不降级为 warning。 |
| C8 | **`/data` 冲突必须中止** | 见上文「刷入前必须先做的一件事」。 |

> 唯一的一处宽松处理:**`enabled: false` 的条目**(目前只有录音机)里残留的
> `TODO` 不会阻断构建 —— 因为它根本不参与构建。这是为了让项目在"录音机包名
> 待确认"的长期状态下仍能出包。想恢复字面语义请加 `--strict`:
> `bash build.sh --check --strict` 或 `bash build.sh --strict`。

---

## 🔧 填值流程:`apps.yaml` 里的 TODO 怎么变成真实值

`apps.yaml` 是**全仓库唯一的事实来源**。凡是标了 `TODO` 的字段,都必须来自
**真实设备 / 真实 APK 的实测**;本工程**绝不**自动填值(自动填 = 脚本猜)。

当前状态(详见文件内注释):

| 字段 | 来源 | 采集方式 |
|---|---|---|
| `sha256` | Release 资产的 sha256 | 已按 GitHub Releases API 的 asset digest 填好(核查时间 2026-10-08);CI 每次构建都会重新下载并逐字节复算 |
| `signer_sha256` | APK 签名证书 SHA-256 | **TODO** — 用 `--collect-only`(本地或 CI artifact)采集 |
| `installed_version_code` | 设备上已安装版本的 versionCode | **TODO** — 用 `scripts/probe-device.sh` 采集 |

### 设备侧:`scripts/probe-device.sh`(只读)

```bash
bash scripts/probe-device.sh                       # 打印报告
bash scripts/probe-device.sh --filter recorder     # 定位录音机等未确认的包名
bash scripts/probe-device.sh --yaml-snippet --out report.md
```

它只做只读操作(`pm list packages` / `pm path` / `dumpsys package` /
`adb pull` 到本地临时目录),**不会修改设备,也不会改 `apps.yaml`**。

### APK 侧:`build.sh --collect-only`(只采集,永不产出模块)

```bash
bash build.sh --collect-only     # 打印每个 APK 的真实 applicationId / versionCode /
                                 # 签名证书 SHA-256 / 资产 sha256,并写入
                                 # dist/collected-values.txt 与 dist/PREFLIGHT-REPORT.md
```

* 该模式**不产出任何模块 zip**、**不改写 `apps.yaml`**,并且**永远返回非零**
  (C7:清单里还有 TODO 时不许假装构建成功);
* 它只是把「该填什么」照实打印出来,由你人工核对后填进 `apps.yaml`;
* CI 的 tag 构建(`release.yml`)会自动跑一遍这个步骤,并把报告作为 artifact
  上传 —— 于是你可以:打 tag → 下载 artifact → 回填 `apps.yaml` → 重新打 tag。

### 录音机(GKUIRecorder)为什么是 `enabled: false`

* `application_id` 处于 `UNVERIFIED` 状态,**严禁**按 `.dev` 规律填写(C1);
* 仓库 `gx-bangsong/GKUIRecorder` 确实存在(描述:"基于LineageOS录音机,添加打点功能"),
  但**没有任何 Release、也没有任何 Tag**,因此没有可下载、可校验的资产;
* 上游与许可同样尚未确认。
* 待确认方式:`bash scripts/probe-device.sh --filter recorder` 可列出设备上
  用户空间安装的包名 —— 那里的结果才是**证据**,规律不是。

---

## 🧰 命令速查

```bash
bash tests/test_build.sh              # 离线自测:假 APK + 桩 aapt/apksigner/pm/adb(不需要网络/设备/SDK)
bash build.sh --check                 # 只校验清单(字段规则 + TODO 门禁)
bash build.sh --check --strict        # 连 disabled 条目的 TODO 也算失败
bash build.sh --list                  # 打印条目摘要
bash build.sh --dump-apps-json        # 规范化 JSON(其它脚本统一从这里读清单)
bash build.sh --collect-only          # 只采集真实值,不产出模块(永远返回非零)
bash build.sh                         # 完整构建模块 zip
bash build.sh --no-zip                # 只渲染模块,不打包(调试)
bash scripts/preflight-apk.sh <apk> <app-id>   # 单个 APK 的七项门禁
bash scripts/install_all.sh           # 【主方案】adb 免 root 批量安装
bash scripts/uninstall_all.sh         # 逐个确认卸载
bash scripts/probe-device.sh          # 只读采集设备事实
```

### APK 七项门禁(`scripts/preflight-apk.sh`)

| 门禁 | 内容 | 不通过时 |
|---|---|---|
| G1 | `aapt dump badging` 取 `package: name=`(**不读解包 manifest 的 package 属性** —— Etar 系那里是 AOSP 残留 `com.android.calendar`,会误导) | 失败 |
| G2 | 断言无 `sharedUserId` | 失败 |
| G3 | 列出 `uses-permission`,标出 signature / privileged 级 | 命中「已声明的 signature\|privileged 权限」→ 该应用**不适合模块化**,仅走 adb install |
| G4 | `apksigner verify --print-certs` 的证书 SHA-256 与 `apps.yaml` 比对 | 失败(提示数据丢失) |
| G5 | 断言 `applicationId != stock_package`(C2) | 失败 |
| G6 | 提取 `<provider>` authorities 与 `<permission>`,authority 不以 applicationId 为前缀则标红 | **仅报告,不影响退出码** |
| G7 | 模块内 APK 的 versionCode 必须 **大于** `installed_version_code` | 失败("将被 /data 版本压制,刷入无效") |

G1/G3/G6 的结果写入 `PREFLIGHT-REPORT.md`(默认与 zip 同目录,或 `PREFLIGHT_REPORT=` 指定)。

---

## 📁 目录结构

```
apps.yaml                 唯一事实来源(包名 / 版本 / sha256 / 签名指纹)
build.sh                  构建入口,也是全仓库唯一的 apps.yaml 解析入口
scripts/
  install_all.sh          【主方案】adb 免 root 批量安装
  uninstall_all.sh        逐个确认卸载
  probe-device.sh         只读采集设备事实(用于回填 TODO)
  preflight-apk.sh        APK 七项门禁
module/                   systemless 模块源码(构建时被 build.sh 渲染进 zip)
  module.prop  customize.sh  post-fs-data.sh  service.sh  uninstall.sh
  META-INF/com/google/android/{update-binary,updater-script}
tests/test_build.sh       离线全流程测试(桩工具 + 假 APK)
.github/workflows/        ci.yml(push/PR,离线)/ release.yml(tag v*,下载 APK 出包)
AGENTS.md                 agent / 贡献者工作守则(硬约束与踩坑清单)
NOTICE.md                 上游 → fork → 本仓库 的归属与许可链条
```

---

## ❓ 常见错误码

| 错误码 | 含义与处理 |
|---|---|
| `INSTALL_FAILED_UPDATE_INCOMPATIBLE` | 已安装版本与本次 APK 签名不一致(debug 签名变更的典型表现)。**只能卸载重装**,数据会丢失(日历/图库数据在系统 Provider,不受影响)。 |
| `INSTALL_FAILED_CONFLICTING_PROVIDER` | ContentProvider authority 冲突(authority 全局唯一)。检查是否重复安装了同源应用的另一份构建。 |
| `INSTALL_FAILED_DUPLICATE_PERMISSION` | 重复声明了设备上已有的同名权限。通常是同源应用的另一个包名版本已安装。 |
| `INSTALL_FAILED_VERSION_DOWNGRADE` | 设备上已安装的 versionCode 更高。请使用更新的 APK。 |
| `INSTALL_PARSE_FAILED_*` | APK 损坏或不是有效 APK。重新下载并核对 `apps.yaml` 里记录的 sha256。 |
| 模块刷入被中止:`检测到 <pkg> 已安装于用户空间` | 见上文 C8:先 `pm uninstall <pkg>`,重启后再刷。 |

---

## 🧭 诚实边界(未验证项)

这些是**本工程确实没有能力验证**的部分,已如实标注,不假装完成:

* **未在 KernelSU / APatch 真机上验证**。三端兼容的依据是"KernelSU / APatch 遵循
  Magisk 模块约定(读取 `module.prop`、执行 `customize.sh`)"这一公开约定;
  Magisk 侧走标准 `install_module` 流程。`update-binary` 里为非 Magisk 环境提供了
  保守兜底流程(不确定就失败,绝不半成品安装),但同样未在真机验证。
* **recorder(GKUIRecorder)的 `application_id`、上游、许可均未确认**,
  条目保持 `confidence: unverified` + `enabled: false`。
* **`signer_sha256` 与 `installed_version_code` 目前是 `TODO`**:
  前者需要真实 APK(CI/本地即可采集),后者需要真实设备(`probe-device.sh`)。
  在这种状态下 `build.sh` 会按 C7 **拒绝构建**。
* 各应用的**权限与 provider authorities 实际内容**由 CI 的 preflight 在真实 APK 上判定,
  本仓库内无法预先断言。
* 模块的**体积、开机耗时、实际挂载效果**等真机行为未经测量。

---

## 📜 许可、归属与免责声明

* 本仓库整体以 **GPL-3.0** 分发(见 [`LICENSE`](LICENSE)):
  GKUICalendar 继承 Etar 的 GPL-3.0,其余应用为 Apache-2.0
  (Apache-2.0 与 GPL-3.0 单向兼容,可并入 GPL-3.0 整体分发)。
* 逐应用的上游 → fork → 本仓库链条、tag / commit 与许可:见 [`NOTICE.md`](NOTICE.md)。
* 本仓库**不是官方项目**,与 gx-bangsong、LineageOS 及任何 ROM / Magisk /
  KernelSU / APatch 项目**无隶属关系**,也未获其背书。
* 本仓库**不重新分发 APK**,也不包含上游源码;构建时由 CI 从各应用 Release
  直接下载并校验 sha256。
* 刷机、安装系统应用、切换默认应用均有风险(可能无法开机、可能丢数据),
  **请自行评估并承担后果**。
