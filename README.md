# GKUI-Pack

把 [gx-bangsong](https://github.com/gx-bangsong) 的 LineageOS 本土化应用
(GKUI 日历 / 图库 / 计算器 / 时钟 / 录音机)打包安装到你**已经能正常运行的设备**上。

本仓库是**打包与安装工程**,不含任何 APK、不含任何上游源码:
APK 由 CI 或你本机从各应用的 GitHub Releases 下载,并逐个校验 sha256 与签名证书。

> 本轮实现验证范围仅为虚拟机环境（AndVM，Pixel 5 / OnePlus7TPro 配置）；真实设备、KernelSU/APatch、A/B 与 OTA 均未验证。clock 闹钟数据继承是预期而非验证结论。

---

## ⚠️ 先读这一节:全部 APK 都是 debug 构建

> **GKUI 系列 APK 均为 debug 构建**(包名带 `.debug` / `.dev` 后缀,
> 由 **debug keystore** 签名),不是正式发行签名。
>
> * 调试签名可能随构建环境变化。当签名与设备上已安装版本不一致时,
>   覆盖安装会失败(`INSTALL_FAILED_UPDATE_INCOMPATIBLE`),
>   此时**只能卸载重装,该 /data 副本的应用内数据会丢失**
>   —— 日历/图库的数据存放在系统 Provider,不受影响;计算器历史与录音机设置可能丢失。
>   时钟另有 PackageManager `<original-package>` 改名映射:它与 stock 时钟共享 PackageSetting,
>   预期继承 stock 闹钟数据;闹钟实际响铃行为仍需真机验证(见下文时钟根因)。
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

GKUI 应用与 ROM 自带应用是**两个不同的应用**(包名不同),切换默认应用只影响「打开方式」。
本节的免 root `adb install` 路径不会更改 stock 应用状态;systemless 模块路径的 stock 处理见下文「stock 应用处理」。

### 4. 回退

```bash
bash scripts/uninstall_all.sh              # 逐个确认后再卸载
bash scripts/uninstall_all.sh --keep-data  # 保留应用数据(仅当之后重装签名一致时有用)
```

---

## 🪟 Windows 用户:不需要 bash

本工程的 `scripts/*.sh` 与 `build.sh` 都是 bash 脚本,但**在 Windows 上你不需要它们**。
下面三条路径覆盖脚本的全部用途,只用 Windows 自带能力 + `adb` 即可。

> 前提:装 **Android Platform Tools**(官方 zip,解压即用,不需要管理员权限):
> <https://developer.android.com/tools/releases/platform-tools>
> Windows 10/11 自带 `curl.exe` 与解压能力:下载 zip 后在资源管理器里右键"全部解压缩"即可。

**⚠️ PowerShell 不会从当前目录加载命令**(会提示
`无法将"adb"项识别为 cmdlet...` + `Suggestion [3,General]`)。在 platform-tools
目录下先执行下面两条之一,之后 `adb` 就能直接用:

```powershell
$env:Path = "$($PWD.Path);$env:Path"      # 本会话有效
# 或: $adb = Join-Path $PWD 'adb.exe'     # 之后一律用 & $adb ...
```

想要一劳永逸,把 platform-tools 目录加入用户 PATH(新开的窗口才生效)。

> 注意:若 `adb` 没能调用,脚本里"未安装 / 未取到"只是**命令没找到**造成的空结果,
> **不代表设备上没装这些应用**。务必先确认 `adb devices` 能列出设备。

### ① 采集设备侧事实(代替 `probe-device.sh`)

```powershell
# 0) 让 adb 可用(在 platform-tools 目录下执行)
$env:Path = "$($PWD.Path);$env:Path"
$adb = Join-Path $PWD 'adb.exe'          # 用绝对路径,切目录也不会失效

# 1) 设备是否就绪:必须出现一行以 device 结尾
#    (unauthorized = 手机还没点"允许 USB 调试";空列表 = 线/口/驱动问题)
& $adb devices

# 2) 五个应用的已安装 versionCode(等价于 probe 里 dumpsys 那一步;含录音机)
#    先判"是否安装"(用 pm list packages,可靠),再取 versionCode;
#    这样"adb 偶发取不到"不会被误读成"设备上没装"。
$pkgs = 'ws.xsoh.etar.debug','org.lineageos.glimpse.dev','com.android.calculator2.dev','com.android.deskclock.dev','org.lineageos.recorder.dev'
foreach ($p in $pkgs) {
  $listed = (& $adb shell pm list packages $p) -join "`n"
  if (-not $listed.Contains($p)) { "{0,-30} 未安装" -f $p; continue }
  $dump = (& $adb shell dumpsys package $p 2>$null) -join "`n"
  if ($dump -match 'versionCode=(\d+)') { "{0,-30} installed_version_code = {1}" -f $p, $Matches[1] }
  else { "{0,-30} 已安装,但 dumpsys 未取到 versionCode → 请重跑这一项" -f $p }
}

# 3) 若上面有"未取到",先看清楚设备上到底装了什么:
& $adb shell pm list packages | Select-String -Pattern 'etar|glimpse|calculator2|deskclock|recorder'

# 4) AndVM 虚拟机配置记录的录音机包名为 org.lineageos.recorder.dev(2026-10-08)。注意:严禁按 .dev
#    规律推断 —— 包名必须由 AndVM 虚拟机配置或 APK 实测输出支持,规律本身不是证据。
& $adb shell pm list packages -3 | Select-String recorder    # -3 = 仅用户空间安装的
```

拿到这些数字后,在 **GitHub 网页编辑器**里填进 `apps.yaml` 对应的
`installed_version_code:` 行即可(Windows 上无需任何命令行)。

> 想看更细的设备信息(签名、路径等)?那就是 `probe-device.sh` 的活;它需要 bash,
> 可用下面的"想在 Windows 上用原脚本"一节的 WSL 方案。

### ② 安装应用(代替 `install_all.sh`,即主方案)

**第一步:校验 sha256**(与 `apps.yaml` 里记录的值逐字节比对,别跳过):

```powershell
$want = @{
  'GKUICalendar-1.0.apk'          = '13be77cad54742054bc5acb0d489efb4d98e047f414e277568a87dfbdfe8046f'
  'app-debug.apk'                 = 'b5e039fb867c76d1ca17935b51186564ebcb409c50a90c2ee20a231c08e172f7'
  'ExactCalculator-debug.apk.zip' = 'dfae8f8731797a7ffe09377a8c0141579077fb389d37f730d052cc4b2e400fc0'
  'DeskClock-debug.apk'           = '206d5e9cc348622036ed6cdbfe78d8db3bae9080bfa5836de2d2af8cca34f0fa'
  'GKUIRecorder-beta2.apk'        = 'f4c00ddb06145ab26fb4a4ba85f91bf866a22a33ad079044ed45da3d7f778f6f'
}
foreach ($f in $want.Keys) {
  if (-not (Test-Path $f)) { "缺少   $f"; continue }
  $h = (Get-FileHash -Algorithm SHA256 $f).Hash.ToLower()
  if ($h -eq $want[$f]) { "OK     $f" } else { "不匹配 $f`n    期望 $($want[$f])`n    实际 $h" }
}
```

**第二步:逐个安装**(只用 `adb install -r`,不卸载、不禁用、不修改任何已有应用):

```powershell
& $adb install -r .\GKUICalendar-1.0.apk
& $adb install -r .\app-debug.apk
& $adb install -r .\DeskClock-debug.apk
& $adb install -r .\GKUIRecorder-beta2.apk

# calculator 的 Release 资产是 zip 包装:先解压,再装里面的 APK
Expand-Archive -Path .\ExactCalculator-debug.apk.zip -DestinationPath .\calc -Force
$inner = Get-ChildItem .\calc -Recurse -Filter *.apk | Select-Object -First 1
& $adb install -r $inner.FullName
```

失败时的错误码含义见下面「常见错误码」表;最典型的是
`INSTALL_FAILED_UPDATE_INCOMPATIBLE`(**debug 签名不一致**)→ 必须先卸载再装,
该 `/data` 副本的应用内数据会丢失(日历/图库数据在系统 Provider 中,不受影响;计算器历史可能丢失)。
stock 时钟与 GKUI Clock 通过 `<original-package>` 共享 PackageSetting,闹钟数据预期由 GKUI Clock 继承；该继承并非验证结论。

### ③ 出包(代替 `build.sh`)

模块 zip 由 **CI 构建**,你的电脑不需要装任何构建工具:

1. 按第 ① 步的数字填好 `apps.yaml`(网页编辑器即可)→ 提交到 `main`;
2. 仓库 → **Releases** → *Draft a new release* → *Choose a tag* → 输入 `v0.0.2`
   → *Create new tag* → *Publish release*;
3. 等 **Actions** 跑完(约 1~2 分钟),在 Release 页面下载 `GKUI-Pack-v0.0.2.zip`;
   刷入在手机上的 Magisk / KernelSU / APatch 管理器里完成,**与电脑无关**。

构建失败时:Actions 日志会指出是哪一项门禁;`PREFLIGHT-REPORT.md`(门禁报告)与
`build-manifest.txt` 会作为 artifact 上传,可下载查看本次构建采集值。

> ℹ️ `clock` 条目的 `installed_version_code: 0` 是 AndVM 虚拟机配置记录；该值不代表真实设备。
> 若 clock APK 未声明 `versionCode`,构建按 Android 平台语义以 0 参与 G7。录音机的普通版
> `/system/app` 不会授予 `CAPTURE_AUDIO_OUTPUT`;是否通过 `recorderpriv` 变体实现通话录音尚未验证。

### 想在 Windows 上用原脚本?

两条路,任选:

* **WSL(推荐)**:管理员 PowerShell 执行 `wsl --install -d Ubuntu`,重启后
  `sudo apt install zip unzip` 即可照常 `bash scripts/install_all.sh` / `bash build.sh`;
* **Git Bash**(随 Git for Windows 安装):提供 `bash`;个别命令
  (如 `build.sh` 需要的 `zip`/`unzip`)不保证自带,缺哪个补哪个。
  ⚠️ 本工程未在 Windows 上实测过 Git Bash 的工具齐全度,以 WSL 为准。

## 🧩 次方案:systemless 模块(Magisk / KernelSU / APatch)

模块为 **coexist 模式**，不会覆盖 stock APK 或系统分区文件。普通版应用落在
`/system/app/<Name>/`；`recorderpriv` 变体只改变 Recorder 的落点并加入构建生成的
`privapp-permissions` XML。两版脚本都由 `module/` 源码在 `build.sh` 中生成，构建会检查脚本
差异仅涉及 `priv-app` / `privapp-permissions`。

### Clock 合并与恢复

clock 的故障事实来自用户提供的诊断结论：APK 声明
`<original-package android:name="com.android.deskclock"/>`；stock 名称与 GKUI 名称的首个
`pm path` 都是 `/system/app/GKUIClock/GKUIClock.apk`，PackageManager 因而以 rename/replacement
共享 PackageSetting；`/product/app/DeskClock` 因重复被跳过。这不是包名子串误匹配，也不是
GKUI Clock 未安装。旧版本没有相关 `MERGED` / `SELF-HEAL` / `ABSENT` 诊断记录。

v0.0.8 的 service 在 stock 切换前修复 disabled 的 GKUI 包和曾被跟踪的 merged stock 名称，
随后按构建生成的 `stock|gkui` 映射比较两边首个 `pm path`：相同则记录 `MERGED` 并跳过停用；
任一路径为空则记录 `ABSENT`、rc 0 跳过；仅路径不同且 stock 当前启用时才执行
`pm disable-user --user 0`。精确判断读取完整 `pm list packages -e/-d` 并匹配完整
`package:<name>` 行，不把变量包名传给 `pm list` 作为过滤参数。`keep-stock`、成功项追踪、
boot flag 清除、后台诊断和卸载恢复流程保留。

共享 PackageSetting 下 stock 闹钟数据由 GKUI Clock 继承是预期，不是已验证事实。把
`<original-package>` 替换扩展到其他四个应用不属于本次实现。

**验证范围**：已在虚拟机环境（AndVM，Pixel 5 / OnePlus7TPro 配置）验证。真实设备行为、
KernelSU/APatch、A/B、OTA 均未验证。

### ⚠️ 刷入前必须先做的一件事(C8)

GKUI 应用目前通常已经通过 adb 安装在 **`/data` 用户空间**;模块版与之**同包名**,
必然冲突。所以 `module/customize.sh` 会在安装时逐个执行 `pm path <application_id>`:

* 返回 `/data/...` → **中止整个安装**(exit 1)并打印:

  ```
  检测到 <pkg> 已安装于用户空间。请先 `pm uninstall <pkg>`
  (日历/图库数据存于系统 Provider 不受影响;计算器历史/录音机设置可能丢失),
  重启后再刷入本模块。stock 时钟闹钟数据预期由 `<original-package>` 映射继承。
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
  ⚠️ KernelSU / APatch 行为未验证(见「诚实边界」)。

刷入并重启后，首次开机请等待 **30–60 秒**再检查；runtime grants 不会弹出权限请求窗口。

### 开机自愈(bootloop 自救)

* `post-fs-data.sh`:每次开机在模块目录写入 `.boot_flag`;
  **如果发现该标记已存在**(说明上一次开机没跑完),就写入 `disable` 让管理器
  在下次开机时跳过本模块,从而打破 bootloop;
* `service.sh`:开机成功进入系统服务阶段后删除 `.boot_flag`,并把时间戳写入
  `last_boot.log`。

### stock 应用处理(可逆)

构建从 `apps.yaml` 生成 `gkui-packages.list`、`stock-packages.list` 和 `stock-gkui-map.list`
（每行 `stock|gkui`），并从 APK preflight 生成 `stock-merged.list`。service 先自愈被禁用的
GKUI 包和旧版本记录过的 merged stock 名称，再按 map 处理 stock：

- 两边首个 `pm path` 相同：写 `MERGED`，rc 0 跳过停用，也不加入 `stock-disabled.list`；
- 任一首个 `pm path` 为空：写 `ABSENT`，rc 0 跳过；
- 路径不同且 stock 在完整 `pm list packages -e` 输出中：执行 `pm disable-user --user 0`，只跟踪成功项；
- disabled / enabled 检查读取完整 `pm list packages -d/-e` 输出，按完整 `package:<name>` 行精确匹配，不使用变量包名过滤。

结果写入模块目录 `stock-toggle.log`，含时间、包名、动作与返回码。`keep-stock` 可保留并恢复
模块曾停用的 stock 应用；卸载时的恢复脚本排除 `stock-merged.list`。`/product/app/DeskClock`
卸载后的恢复仍未验证。

安装器会把所有 `customize.sh` 的 `ui_print` 消息追加到模块目录 `install.log`。安装器音量键读取
尚未验证；缺少可读按键时采用默认的按路径切换策略。

### 自动运行时权限(默认开启，可退出)

构建从每个实际 APK 的 `aapt dump badging` `uses-permission`、`device/framework-permissions.txt`
与 `scripts/appop-map.txt` 生成根目录 `runtime-grants.list`，格式为
`package|permission|method`。`dangerous` 生成 `grant`；非 dangerous 且 protectionLevel 含 `appop`、
并存在映射时生成 `appops`；其余权限不进入授权列表。生成清单经 fail-closed 校验；可在每个
`apps.yaml` 条目设置互斥的 `runtime_permissions_only` 或 `runtime_permissions_exclude`。

默认尝试处理清单中的所有项；在模块目录创建 `no-auto-grant` 文件可完全跳过。前置权限按依赖
顺序先处理。命令使用 `pm grant` 或 `appops set <package> <op> allow`；每次尝试记录时间、包名、
权限、方法、返回码和 stderr 首行到 `grant.log`，单项失败不阻止后续项。仅当该包的所有授权
命令成功后，写入 `granted/<package>.<versionCode>`；之后重启不重复。手动撤销权限不会触发重复
授权，APK `versionCode` 变化后会产生一次新尝试。

刷入后的首次启动请等待 **30–60 秒**；运行时权限不会弹出权限请求窗口。每个 APK 的实际授权
项目以本次构建 zip 中的 `runtime-grants.list` 为准，不从源码或旧版本推测。

---

## 🚫 本工程明确不做的事(硬约束)

| 编号 | 约束 | 说明 |
|---|---|---|
| C1 | **不推断包名** | known 反例:`GKUICalendar` fork 自 Etar,但它的 applicationId 是 `ws.xsoh.etar.debug`,不是 `org.lineageos.etar.debug`。凡不在事实基线中的值一律写 `TODO`,构建失败。 |
| C2 | **只做 coexist；stock 状态可逆** | `mode` 只允许 `coexist`；不改写 stock APK/分区；仅路径不同且启用的 stock 才停用。相同路径 `MERGED`、空路径 `ABSENT` 均 rc 0 跳过；先自愈 GKUI 与旧 merged 记录；精确匹配完整 `package:<name>` 行；`keep-stock` 与卸载恢复按记录工作。运行时权限默认开启，`no-auto-grant` 文件为 opt-out。禁止 `pm uninstall`、写 `/data/data`。 |
| C3 | **普通版使用 `system/app`；仅 Recorder 提供特权变体** | privileged 权限申请仍按 `privileged_ack` 显式确认；普通版 `/system/app` 不会因此获得权限。Recorder 特权变体由 `build.sh` 从 `module/` 源码生成，只替换 Recorder 落点与 `privapp-permissions` XML；构建断言脚本差异仅涉及 `priv-app` / `privapp-permissions`。为通过仓库 C3 检查，`module/` 源码不得出现字面 `priv-app`；`module-priv/` 只保留变体 `module.prop`。 |
| C4 | **不含拨号 / 短信 / 联系人** | 它们使用 `sharedUserId="android.uid.shared"` 并依赖 platform 签名,第三方签名无法替换,任何打包尝试都必然失败。因此本仓库**不接受**这类应用,即使被要求也不做。 |
| C5 | **仓库不含 APK** | `.gitignore` 含 `*.apk`、`dist/`、`build/`、`*.keystore`;验收 `git ls-files \| grep -c '\.apk$'` 必须为 `0`;APK 由 CI 下载并校验 sha256。 |
| C6 | **签名必须匹配** | 每个 APK 的证书 SHA-256 与 `apps.yaml` 记录不一致 → 构建失败,并提示「需卸载重装,应用内数据会丢失」。 |
| C7 | **TODO 必须失败** | 任何必填字段为 `TODO` 或 `confidence: unverified` 都让构建**失败**,绝不降级为 warning。 |
| C8 | **`/data` 冲突必须中止** | 见上文「刷入前必须先做的一件事」。 |

> 唯一的一处宽松处理:**`enabled: false` 的条目**里残留的 `TODO` 不会阻断构建
> —— 因为它根本不参与构建。这是为了让项目在"某个应用的事实待确认"的长期状态下
> 仍能出包(v0.0.2 之前的录音机就处于这种状态;目前五个条目全部启用,没有条目
> 用到这条宽松)。想恢复字面语义请加 `--strict`:
> `bash build.sh --check --strict` 或 `bash build.sh --strict`。

---

## 🔧 填值流程:`apps.yaml` 里的 TODO 怎么变成真实值

`apps.yaml` 是**全仓库唯一的事实来源**。凡是标了 `TODO` 的字段,都必须来自
**真实设备 / 真实 APK 的实测**;本工程**绝不**自动填值(自动填 = 脚本猜)。

当前状态(详见文件内注释):

| 字段 | 来源 | 采集方式 |
|---|---|---|
| `sha256` | Release 资产的 sha256 | 使用 GitHub Releases API 的 asset digest；CI 每次构建会重新下载并逐字节复算 |
| `signer_sha256` | APK 签名证书 SHA-256 | CI 对实际 APK 执行 `apksigner` 并与记录比对；这些是构建证书事实，不构成设备行为验证 |
| `installed_version_code` | 已记录虚拟机配置中已安装版本的 versionCode | `apps.yaml` 中现存数字是 AndVM 虚拟机配置记录；不代表真实设备。真实设备请单独采集，明确无包时才写 `none` |

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

### 录音机(GKUIRecorder)与 Recorder 变体

Recorder 的 preflight 会记录其平台特权权限申请。普通版将其作为普通 system app 放置，
`/system/app` 本身不会授予 `CAPTURE_AUDIO_OUTPUT`；需要尝试特权集成时可选择单独的
`recorderpriv` 包。此包的 `customize.sh` / `service.sh` 由 `build.sh` 从 `module/` 源码生成，
仅替换 Recorder 落点与构建生成的 `privapp-permissions` XML；脚本差异有自动校验。普通版与
Recorder 变体的 module id 相同，互刷覆盖，不会并存。

`apps.yaml` 的 `privileged_ack` 只记录已知的系统权限后果，不代表权限已授予，也不代表通话录音
已工作。`privapp-permissions` 生成成功与实际设备授予效果是两件事。

### 双包：普通版与 recorderpriv 版

| 安装包 | Recorder 落点 | 白名单 XML | 结论 |
|---|---|---|---|
| `GKUI-Pack-<ver>.zip` | `/system/app/GKUIRecorder` | 无 | 普通版不授予特权权限 |
| `GKUI-Pack-<ver>-recorderpriv.zip` | `/system/priv-app/GKUIRecorder` | 构建生成 | 真正设备上的授予与通话录音效果未验证 |

`device/framework-permissions.txt` 的记录来自 AndVM 虚拟机权限快照，头部包含所提供的构建元数据，
权限数据部分未改动。验证范围：已在虚拟机环境（AndVM，Pixel 5 / OnePlus7TPro 配置）验证；
真实设备、KernelSU/APatch、A/B、OTA 与实际通话录音均未验证。更换 ROM 或 Android 大版本时，
应重新检查权限表，不得把 AndVM 结果当成真实设备结论。`update.json` 指向普通版；需要特权版时
须手动选择对应包。

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
| G1 | `aapt dump badging` 取 `package: name=`(**不读解包 manifest 的 package 属性** —— Etar 系那里是 AOSP 残留 `com.android.calendar`,会误导);取值按**整字段**匹配 —— 真实 badging 行里有 `compileSdkVersionCodename='16'`,它含小写 `name='`,子串匹配会把平台代号当成包名(本工程实际踩过,已加回归测试) | 失败 |
| G2 | 断言无 `sharedUserId` | 失败 |
| G3 | 列出 `uses-permission`;申请**平台签名/特权权限清单**(`ADVISORY_LIST`)则记为"申请了特权权限"(退出码 2,命中的权限写入 JSON 的 `privileged_permissions`);另把本 APK **自己声明**的 `<permission>` 的 `protectionLevel` 解码后一并报告(如 `0x12` → `signature\|system`) | 申请命中 → 条目未写 `privileged_ack: true` 时该应用**不适合模块化**,仅走 adb install(排除出模块);写了 `privileged_ack: true` 时结论为 `privileged_acknowledged`:以 `system_app` 纳入并逐条标注"这些权限不会被授予"。两种情况都**绝不生成白名单 XML**;自声明权限**不影响**判定(androidx 的 `*.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION` 就是 signature 级,属正常做法) |
| G4 | `apksigner verify --print-certs` 的证书 SHA-256 与 `apps.yaml` 比对 | 失败(提示数据丢失) |
| G5 | 确认 `applicationId != stock_package`;同时提取 `<original-package>` 并派生 `merge_with_stock` | 直接包名相同则失败;若 original package 命中 stock,报告为 MERGED/replacement 并跳过 stock disable |
| G6 | 提取 `<provider>` authorities 与 `<permission>`,authority 不以 applicationId 为前缀则标红 | **仅报告,不影响退出码** |
| G7 | 比对模块内 APK 的 versionCode 与登记虚拟机配置的 `installed_version_code`:**小于** → 失败(回退);**相等** → 通过但提示(两侧同一版本,刷入前须按 C8 卸载 /data 副本);`none`(该配置已明确记录无副本)→ 通过(不存在压制);配置中已有副本但 APK 未声明 versionCode → 失败 | 见左列(压制风险本身由 C8 在刷入时强制拦截) |

G1/G3/G6 的结果写入 `PREFLIGHT-REPORT.md`(默认与 zip 同目录,或 `PREFLIGHT_REPORT=` 指定)。
`PREFLIGHT-REPORT.md` 与 `build-manifest.txt` 现包含 original packages、sharedUserId、provider
authorities、自声明 `<permission>` 与派生的 `merge_with_stock`。

### Clock 根因与版本审计

以下是用户提供的 AndVM 诊断事实，不是本轮在真实设备上的验证：GKUI Clock APK 声明
`<original-package android:name="com.android.deskclock"/>`；stock 名称与 GKUI 名称的首个
`pm path` 都是 `/system/app/GKUIClock/GKUIClock.apk`，PackageManager 因此将二者作为改名/替换
共享 PackageSetting；`/product/app/DeskClock` 因重复 APK 被跳过。故障不是子串匹配误停，也不是
GKUI Clock 未安装。

提供的 v0.0.7 记录没有 `Renamed packages:` 诊断段，也没有 `MERGED` / `SELF-HEAL` / `ABSENT`
日志；stock-toggle 记录与 v0.0.6 相同。仓库审计结论：v0.0.6 与 v0.0.7 同为
`1d34861b50436c29415628a06f1b7769ece2bb8a`；PR #6 “feat: 自动停用 stock 同类应用（可逆）”
没有包含 `<original-package>` 时钟修复，查询到的 PR 列表中也没有后续修复 PR。原始诊断分支
不可访问，因此没有声称读取或合并它。

v0.0.8 在两种变体里都比较 map pair 的首个 `pm path`，相同写 `MERGED` 并跳过；为空写
`ABSENT`、rc 0 跳过；旧版本跟踪到的合并 stock 名称与被禁用的 GKUI 包先自愈。闹钟数据由共享
PackageSetting 继承是预期，不是验证结论。其他四个应用的 `<original-package>` 替换未实现。

### clock 的 APK 未声明 versionCode

clock 当前配置记录的 `installed_version_code: 0` 适用于所登记的 AndVM 虚拟机配置，不推断真实
设备。若 APK 未声明 `versionCode`，构建按平台语义以 0 参与 G7：已记录配置为 0 时通过，较高
时失败；`none` 仅代表已明确记录无该包副本。实际设备仍需单独测量；这与 `<original-package>`
合并根因无关。


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
module/                   systemless 模块源码(普通版,构建时被 build.sh 渲染进 zip)
  module.prop  customize.sh  post-fs-data.sh  service.sh  uninstall.sh
  META-INF/com/google/android/{update-binary,updater-script}
module-priv/              recorderpriv module.prop 模板;脚本不在此处复制维护
build.sh                   从 module/ 源码生成两种 Recorder 脚本变体并校验差异
device/                   framework-permissions.txt(AndVM 虚拟机快照) 与源码回退表
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

## ⚙️ 仓库设置(首次启用 CI 时)

工作流里**只使用 GitHub 官方 action**,并已固定到完整 commit SHA
(`actions/checkout@11d5960a…`、`actions/upload-artifact@ea165f8d…`)。
据此建议(仓库 → Settings → Actions → General):

| 设置项 | 建议值 | 原因 |
|---|---|---|
| Actions permissions | **Allow gx-bangsong, and select non-gx-bangsong, actions and reusable workflows** → 勾选 *Allow actions created by GitHub*,并加入 `actions/*` | 本工程只用 GitHub 官方 action;若选「Allow gx-bangsong actions」,连 `actions/checkout` 都会被挡掉,CI 根本无法运行 |
| Require actions to be pinned to a full-length commit SHA | **勾选** | 工作流中的 action 已固定到完整 SHA,打开后照常运行,同时可挡住被投毒的 tag(升级 action 时需连同 SHA 一起更新) |
| Workflow permissions | **Read repository contents and packages permissions**(只读) | 工作流已按需自带 `permissions:` —— CI 只读;Release 需要 `contents: write` 才能创建 Release,已在 `release.yml` 顶部声明 |
| Allow GitHub Actions to create and approve pull requests | **不勾选** | 本工程不需要——Release 只创建 Release 与上传附件 |
| Approval for running fork pull request workflows | **Require approval for all external contributors** | CI 会执行 PR 里的脚本,最稳妥是人工批准后再跑(本仓库的 CI 不接触任何密钥) |
| Check/artifact/log retention | 90 天(上限) | `PREFLIGHT-REPORT.md` artifact 是回填 `apps.yaml` 的主要数据来源,留存越久越稳 |

> 若仓库未启用 Actions 或不允许上述 action,`ci.yml` / `release.yml` 不会运行——
> 这**不影响**主方案:`scripts/install_all.sh` 与本地 `bash build.sh` 都是纯本地路径。

## 🧭 验证范围与未验证事项

本轮验证范围为虚拟机环境（AndVM，Pixel 5 / OnePlus7TPro 配置）。不将这些结果表述为真实设备
验证；v0.0.8 代码和测试夹具也不证明真实设备行为。

以下仍未验证：

- 真实设备上的模块安装、启动、应用行为与 stock 状态切换；
- KernelSU / APatch、A/B、OTA；
- 卸载后 `/product/app/DeskClock` 在 rename 历史保留时的恢复；
- stock 闹钟数据是否由 GKUI Clock 继承、闹钟实际响铃；
- 真实设备的 `pm grant` 与 `appops set` 效果，以及撤销后的状态；
- 管理器安装时的音量键输入、service.d 恢复脚本在各管理器下的执行；
- Recorder 特权变体中的实际权限授予与通话录音功能。

Clock 根因所述的 `<original-package>`、相同 `pm path`、共享 PackageSetting 与
`/product/app/DeskClock` duplicate skip 是用户提供的诊断事实；数据继承仅为预期。
`<original-package>` 替换扩展到其他四个应用不属于本次实现。APK 权限与 provider authorities
以本次实际构建生成的 preflight 报告和 `runtime-grants.list` 为准；不得预先猜测权限清单。

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
