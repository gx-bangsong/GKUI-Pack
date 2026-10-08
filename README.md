# GKUI-Pack

把 [gx-bangsong](https://github.com/gx-bangsong) 的 LineageOS 本土化应用
(GKUI 日历 / 图库 / 计算器 / 时钟 / 录音机,共五款)打包安装到你**已经能正常运行的设备**上。

本仓库是**打包与安装工程**,不含任何 APK、不含任何上游源码:
APK 由 CI 或你本机从各应用的 GitHub Releases 下载,并逐个校验 sha256 与签名证书。

---

## ⚠️ 先读这一节:已验证的 APK 是 debug 构建

> 已实际取得并检查的 GKUI APK 为 **debug 构建**(包名带 `.debug` / `.dev` 后缀,
> 由 **debug keystore** 签名),不是正式发行签名。GKUIRecorder beta2 的 Release asset
> 元数据已登记,但 APK 本体尚未取得,其构建类型与 signer 必须等 CI 下载后实测,不能据源码推断。
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

# 4) 录音机包名已实测为 org.lineageos.recorder.dev(2026-10-08)。注意:严禁按 .dev
#    规律推断 —— 当初能填进 apps.yaml 是因为有下面的实测输出,规律本身不是证据。
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
  'GKUIRecorder-beta2.apk'         = 'f4c00ddb06145ab26fb4a4ba85f91bf866a22a33ad079044ed45da3d7f778f6f' # GitHub API asset digest; APK 本体 / signer 尚未本地实测
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
& $adb install -r .\GKUIRecorder-beta2.apk  # 仅在核对 Release asset digest 后使用;签名还需实测

# calculator 的 Release 资产是 zip 包装:先解压,再装里面的 APK
Expand-Archive -Path .\ExactCalculator-debug.apk.zip -DestinationPath .\calc -Force
$inner = Get-ChildItem .\calc -Recurse -Filter *.apk | Select-Object -First 1
& $adb install -r $inner.FullName
```

失败时的错误码含义见下面「常见错误码」表;最典型的是
`INSTALL_FAILED_UPDATE_INCOMPATIBLE`(**debug 签名不一致**)→ 必须先卸载再装,
**应用内数据会丢失**(日历/图库数据在系统 Provider 中,不受影响;时钟闹钟、计算器历史会丢)。

### ③ 出包(代替 `build.sh`)

模块 zip 由 **CI 构建**,你的电脑不需要装任何构建工具:

1. 按第 ① 步的数字填好 `apps.yaml`(网页编辑器即可)→ 提交到 `main`;
2. 仓库 → **Releases** → *Draft a new release* → *Choose a tag* → 输入 `v0.0.2`
   → *Create new tag* → *Publish release*;
3. 等 **Actions** 跑完(约 1~2 分钟),在 Release 页面下载 `GKUI-Pack-v0.0.2.zip`;
   刷入在手机上的 Magisk / KernelSU / APatch 管理器里完成,**与电脑无关**。

构建失败时:Actions 日志会指出是哪一项门禁;`PREFLIGHT-REPORT.md`(门禁报告)与
`build-manifest.txt` 会作为 artifact 上传,可下载查看实测值。

> ℹ️ `clock` 的 APK 未声明 `versionCode`(设备上那一份实测为 0)→ 按 G7 语义**放行**
> (见下文专节)。录音机已设为启用并进入五应用清单,但 APK signer 尚未由真实 APK 实测；
> 当前 `signer_sha256: TODO` 会按 C7 阻止正式构建,CI 的 collect-only 报告可用于补齐。

### 想在 Windows 上用原脚本?

两条路,任选:

* **WSL(推荐)**:管理员 PowerShell 执行 `wsl --install -d Ubuntu`,重启后
  `sudo apt install zip unzip` 即可照常 `bash scripts/install_all.sh` / `bash build.sh`;
* **Git Bash**(随 Git for Windows 安装):提供 `bash`;个别命令
  (如 `build.sh` 需要的 `zip`/`unzip`)不保证自带,缺哪个补哪个。
  ⚠️ 本工程未在 Windows 上实测过 Git Bash 的工具齐全度,以 WSL 为准。

## 🧩 次方案:systemless 模块(Magisk / KernelSU / APatch)

普通变体为 **coexist 模式**:APK 在 ZIP 中已静态放入
`system/app/<Name>/<Name>.apk`,安装时不由脚本从临时目录复制;与 ROM 自带应用**共存**,
**绝不替换、绝不修改、绝不禁用**任何自带应用。另有需明确 opt-in 的特权变体:只将
`priv_variant.app_ids` 中的应用静态放入 `system/priv-app/`,其他应用仍在 `system/app/`。
两个 ZIP 共享 `module.prop` 的 `id=gkui-pack`,设备上只能启用一个变体。

### ⚠️ 刷入前必须先做的一件事(C8)

GKUI 应用目前通常已经通过 adb 安装在 **`/data` 用户空间**;模块版与之**同包名**,
必然冲突。所以普通版 `module/customize.sh` 与特权版 `module-priv/customize.sh` 都会在安装时逐个执行 `pm path <application_id>`;特权版还会在部署前复核目标设备权限转储:

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

* 返回目标 `/system/...` 路径 → 认为模块已生效,该条目跳过;若发现同模块的另一变体落点,则清理旧路径并迁移。
* 特权版会额外读取 APK 清单 XML,对每条权限调用 `pm list permissions -f`(必要时 `-fg`)复核其保护级别仍含 `privileged`;无法解析或不匹配时在部署 APK/XML 前中止。

另外:安装环境必须有可用的 `pm`(在 recovery 下刷入会被拒绝),
此时请改用管理器在系统内安装,或直接用上面的**主方案**。

### 构建模块

```bash
bash build.sh
# → dist/GKUI-Pack-<version>.zip        普通变体(所有纳入的应用均为 system/app)
# → dist/GKUI-Pack-Priv-<version>.zip   可选特权变体;仅所有特权门禁通过后生成
# → dist/PREFLIGHT-REPORT.md            APK 七项门禁 + 特权权限交集报告
# → dist/build-manifest.txt             普通版清单/特权版状态;若生成另有 priv-build-manifest.txt
```

构建会依次执行:清单校验 → 资产 sha256 校验 → 解包 → **APK 七项门禁**
→ 将普通版 APK 静态放入 `system/app/<Name>/<Name>.apk` → (可选)按实测设备权限转储
生成特权 XML/变体 → 打包。任一选定特权 APK 缺权限定义、转储不可解析、纯 signature、
交集为空时 fail-closed,跳过 Priv ZIP,但不影响合格的普通 ZIP。录音机当前 enabled 且
`privileged_ack: true`,但 signer 指纹仍为 TODO;C7 会阻止当前正式构建,直到真实 APK
经 `apksigner` 验证并回填。设备权限转储也未采集,所以当前不能生成/发布 Priv ZIP。

### ⚠️ 特权变体(实验性、高风险)

- 特权 ZIP 只将 `priv_variant.app_ids` 里显式选中的应用放入 `/system/priv-app/`;本设计仅把 recorder 选入特权路径,另外四款仍是 `/system/app/`。
- 白名单 XML **仅**包含“APK 实际申请权限 ∩ 同一设备 dump 中 protectionLevel 含 privileged 的权限”。输入缺失/歧义、权限不在 dump、纯 signature 或空交集均失败,绝不猜测。
- 安装器在目标真机再用 `pm list permissions -f` / `-fg` 逐项复核。ROM/SDK 改变、设备 dump 不匹配、白名单分区错位都可能导致 bootloop;API 28+ 的 `ro.control_privapp_permissions=enforce` 尤其需谨慎。
- 普通版的 `privileged_ack: true` 只表示“允许作为普通 system app 入普通版”;**不**授予这些权限、不写 XML,也不会改变安装路径。
- recorder 的 beta2 Release 元数据与 asset digest 已登记在 `apps.yaml`,但 APK 本体暂未下载核验,signer 仍是 TODO;设备 `framework-permissions.txt` 也不存在,当前不生成/不发布特权版。
- 设备只安装其中一个 ZIP。切换变体时脚本清理旧录音机落点和白名单;先按 C8 处理 `/data` 副本。完整采集/安装/恢复说明见 [`module-priv/README.md`](module-priv/README.md) 与 [`device/README.md`](device/README.md)。
- `release.yml` 保持零改动;它现有的 `dist/GKUI-Pack-*.zip` glob 会在两份都生成时上传两个 ZIP。若某个 Release 确实附带 Priv ZIP,发布说明请使用 [`docs/privileged-release-notes.md`](docs/privileged-release-notes.md) 的特权风险/恢复段落;当前工作流生成的自动 notes 模板不自动内嵌此文件。

### 刷入

* **普通版(Magisk)**:Magisk 应用 → 模块 → 从本地安装,明确选择 `dist/GKUI-Pack-<version>.zip`(不要使用会同时匹配两份 ZIP 的通配符)。
* **特权版(Magisk)**:仅当本次构建确实生成 `GKUI-Pack-Priv-<version>.zip` 且你已阅读高风险恢复说明时,选择该文件;不可与普通版同时启用。
* **KernelSU / APatch**:用各自管理器安装所选的单个 ZIP。
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
| C3 | **默认走普通 `system/app`;特权版必须显式选择并通过 fail-closed 验证** | 申请平台特权权限的 APK 默认排除。`privileged_ack: true` 可明确接受其以普通 `/system/app` 纳入,但不授予权限、不生成 XML。只有 `priv_variant.app_ids` 指定的应用可进独立 `GKUI-Pack-Priv-*.zip` 的 `/system/priv-app`;白名单按“APK 实际申请 ∩ 同 ROM dump 中 protectionLevel 含 privileged”生成,缺失/歧义/纯 signature/空交集均失败,安装时再由 `pm` 复核。APK **自己声明**的 signature 权限只报告,不因此排除。 |
| C4 | **不含拨号 / 短信 / 联系人** | 它们使用 `sharedUserId="android.uid.shared"` 并依赖 platform 签名,第三方签名无法替换,任何打包尝试都必然失败。因此本仓库**不接受**这类应用,即使被要求也不做。 |
| C5 | **仓库不含 APK** | `.gitignore` 含 `*.apk`、`dist/`、`build/`、`*.keystore`;验收 `git ls-files \| grep -c '\.apk$'` 必须为 `0`;APK 由 CI 下载并校验 sha256。 |
| C6 | **签名必须匹配** | 每个 APK 的证书 SHA-256 与 `apps.yaml` 记录不一致 → 构建失败,并提示「需卸载重装,应用内数据会丢失」。 |
| C7 | **TODO 必须失败** | 任何必填字段为 `TODO` 或 `confidence: unverified` 都让构建**失败**,绝不降级为 warning。 |
| C8 | **`/data` 冲突必须中止** | 见上文「刷入前必须先做的一件事」。 |

> `enabled: false` 的条目不参与构建,其 TODO 默认不阻断(加 `--strict` 才会检查所有条目)。
> recorder 已启用、`privileged_ack: true`,且 beta2 Release 元数据已登记;但签名指纹尚未由
> APK 本体采集,因此其 `signer_sha256: TODO` / `confidence: unverified` 会按 C7 阻止当前构建。
> 这保证五应用目标明确纳入门禁,但不伪造签名或输出未经验证的 ZIP。

---

## 🔧 填值流程:`apps.yaml` 里的 TODO 怎么变成真实值

`apps.yaml` 是**全仓库唯一的事实来源**。凡是标了 `TODO` 的字段,都必须来自
**真实设备 / 真实 APK 的实测**;本工程**绝不**自动填值(自动填 = 脚本猜)。

当前状态(详见文件内注释):

| 字段 | 来源 | 采集方式 |
|---|---|---|
| `sha256` | Release 资产的 sha256 | 已按 GitHub Releases API 的 asset digest 填好(核查时间 2026-10-08);CI 每次构建都会重新下载并逐字节复算 |
| `signer_sha256` | APK 签名证书 SHA-256 | 四个已验证 APK 的值由真实 `apksigner` 实测;recorder 仍为 TODO,因本环境无法取得 beta2 APK 本体。CI 的 release collect-only 会报告 recorder 的真实值;人工核对回填前 C7 阻止出包,其余 APK 每次构建仍会按 C6 比对 |
| `installed_version_code` | 设备上已安装版本的 versionCode | ✅ **已填**(2026-10-08 真机 adb 实测:`ws.xsoh.etar.debug=51`、`org.lineageos.glimpse.dev=1`、`com.android.calculator2.dev=1`、`com.android.deskclock.dev=0`、`org.lineageos.recorder.dev=1`)。Windows 用户可用「Windows 用户」一节的 PowerShell 命令重采;设备上确实没装该包名时才写 `none`。 |

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

### 录音机(GKUIRecorder):普通版纳入已明确,签名门禁仍待真实 APK 验证

* **包名与已装版本已实测**(2026-10-08):`org.lineageos.recorder.dev`,
  `installed_version_code = 1`。源码里 `applicationIdSuffix = ".dev"` 恰与实测一致,
  但登记依据是设备输出,不是命名规律。
* **Release 已存在**:GitHub API 可查到 `beta2` tag 与资产 `GKUIRecorder-beta2.apk`;
  API 返回的 asset digest 已写入 `apps.yaml`。源代码 tag 对应 commit 也已登记。
  但本工作环境无法从 `release-assets.githubusercontent.com` 取得 APK 本体,所以
  digest 尚未本地复算,签名证书 SHA-256 尚未用 `apksigner` 测量。不得据源码或 API
  元数据猜 signer。
* 清单已设置 `name: GKUIRecorder`、`enabled: true`、`privileged_ack: true`。
  这表示最终普通 ZIP 明确包含五款应用的目标;recorder 的普通版落点为
  `system/app/GKUIRecorder/GKUIRecorder.apk`。`privileged_ack` 不授予任何权限。
* 由于 `signer_sha256: TODO` 且 `confidence: unverified`,C7 当前会阻止正式出包。
  连接可下载 GitHub Release asset 的 CI 会在 `--collect-only` 报告真实包名、versionCode、
  asset digest 与 signer;请下载报告、人工核对 APK 身份,再把实测 signer SHA-256 填入
  `apps.yaml` 并将 confidence 设为 confirmed。`build.sh` 不会自动回填或猜测。
* 上游与许可已核实:上游为 `LineageOS/android_packages_apps_Recorder`
  (GitHub API 的 parent/source 字段),许可为 **Apache-2.0**
  (仓库 `REUSE.toml` 与 `LICENSES/Apache-2.0.txt`)。
* 另一个独立门槛是特权版设备转储:真实 `device/framework-permissions.txt` 尚未采集。
  因此在设备 dump、权限交集与安装期复核都通过前,不能生成 Priv ZIP。
* 复核命令:`bash scripts/probe-device.sh --filter recorder`(列出设备上用户空间的包名;
  真机输出才是事实依据)。
---

## 🧰 命令速查

```bash
bash tests/test_build.sh              # 离线自测:假 APK + 桩 aapt/apksigner/pm/adb(不需要网络/设备/SDK)
bash build.sh --check                 # 只校验清单(字段规则 + TODO 门禁)
bash build.sh --check --strict        # 连 disabled 条目的 TODO 也算失败
bash build.sh --list                  # 打印条目摘要
bash build.sh --dump-apps-json        # 规范化 JSON(其它脚本统一从这里读清单)
bash build.sh --collect-only          # 只采集真实值,不产出模块(永远返回非零)
bash build.sh                         # 完整构建普通 ZIP;特权输入齐备且合格时另生成 Priv ZIP
bash build.sh --no-zip                # 只渲染变体,不打包(调试)
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
| G3 | 列出 `uses-permission`;申请平台签名/特权权限(`ADVISORY_LIST`)默认不适合普通模块,但 `privileged_ack: true` 可显式允许仅按普通 `system_app` 入包;另报告 APK **自己声明**的 `<permission>` protectionLevel(如 `0x12` → `signature\|system`) | 未 ACK → excluded,仅走 adb install;已 ACK → 仍无特权权限。进入特权 ZIP 还须从 APK 请求集与同设备 dump privileged 集求交,并通过安装期 `pm` 复核;缺失、纯 signature、歧义、空交集均 fail-closed |
| G4 | `apksigner verify --print-certs` 的证书 SHA-256 与 `apps.yaml` 比对 | 失败(提示数据丢失) |
| G5 | 断言 `applicationId != stock_package`(C2) | 失败 |
| G6 | 提取 `<provider>` authorities 与 `<permission>`,authority 不以 applicationId 为前缀则标红 | **仅报告,不影响退出码** |
| G7 | 比对模块内 APK 的 versionCode 与设备实测的 `installed_version_code`:**小于** → 失败(回退);**相等** → 通过但提示(两侧同一版本,刷入前须按 C8 卸载 /data 副本);`none`(实测设备上无副本)→ 通过(不存在压制);设备上已有副本但 APK 未声明 versionCode → 失败 | 见左列(压制风险本身由 C8 在刷入时强制拦截) |

G1/G3/G6 的结果写入 `PREFLIGHT-REPORT.md`(默认与 zip 同目录,或 `PREFLIGHT_REPORT=` 指定)。

### clock 的 APK 未声明 versionCode(实测已闭环)

两处实测互相印证(2026-10-08):

* CI 门禁报告:`DeskClock-debug.apk` 的 badging 是 `versionCode='' versionName=''`
  —— 该 APK **没有**声明 versionCode(LinageOS 部分应用仓库如此);
* 真机实测:设备上已安装的 `com.android.deskclock.dev` 记录的 **versionCode = 0**
  —— 与平台语义"未声明按 0 处理"完全吻合。

因此 G7 把它当**已知的 0** 参与比较(不再当成"未知"):

| 情况 | 结果 |
|---|---|
| 设备上副本也是 0(本例) | **放行**,并提示"两侧同一版本,刷入前须按 C8 先卸载 /data 副本" |
| 设备上副本更高(如 5) | **失败** —— 模块内更旧,会被压制 |
| 设备上无副本(`none`) | **放行** —— 无压制风险 |

`dist/build-manifest.txt` 里该应用的 versionCode 记为 `0(未声明)`,Release notes 里同样如此。

> ⚠️ 仍未验证:"未声明 versionCode 的 APK 装入 `/system/app` 后的真机行为"没有实测过
> (安装本身不受影响;之后若用 adb 装了更新版本,按 Android 规则 /data 版本会正常覆盖它)。
> 采集小坑:第一次采集时 adb 偶发返回空,曾被误读成"未安装";`probe-device.sh` 与 README 的
> PowerShell 片段现在都改为**先用 `pm list packages` 判是否安装**,再取 versionCode。

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
module/                   普通变体模板(仅 system/app;构建时渲染)
  module.prop  customize.sh  post-fs-data.sh  service.sh  uninstall.sh
  META-INF/com/google/android/{update-binary,updater-script}
module-priv/              特权变体模板(同 module id;含安装复核/自检/恢复文档)
  META-INF/com/google/android/{update-binary,updater-script}
scripts/generate-privapp-permissions.py  从实测权限交集生成白名单 XML
device/README.md          采集真机权限转储的步骤(转储文件目前缺失)
docs/privileged-release-notes.md  特权 ZIP 的发布说明模板
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

## 🧭 诚实边界(未验证项)

这些是**本工程确实没有能力验证**的部分,已如实标注,不假装完成:

* **未在 KernelSU / APatch 真机上验证**。三端兼容的依据是"KernelSU / APatch 遵循
  Magisk 模块约定(读取 `module.prop`、执行 `customize.sh`)"这一公开约定;
  Magisk 侧走标准 `install_module` 流程。`update-binary` 里为非 Magisk 环境提供了
  保守兜底流程(不确定就失败,绝不半成品安装),但同样未在真机验证。
* **recorder(GKUIRecorder) 的 APK 本体 / 签名尚未实测**:包名与设备 versionCode 已实测
  (`org.lineageos.recorder.dev` / 1);GitHub API 可查到 beta2 Release、asset 名和 SHA-256 digest,
  但当前环境取不到重定向后的 APK 文件,所以 `signer_sha256` 保持 TODO、`confidence`
  为 `unverified`。条目已启用并设 `privileged_ack: true`;C7 会在签名核验前阻止出包。
  上游与许可已核实为 `LineageOS/android_packages_apps_Recorder` / Apache-2.0。
* **采集过程留痕**:第一次采集 clock 时 adb 偶发返回空,一度被误读成"未安装";
  已在 apps.yaml 的注释里如实记录,采集命令也改为先用 `pm list packages` 判是否安装。
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
