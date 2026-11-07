# AGENTS.md — 本仓库的 agent / 贡献者工作守则

> 面向以 agent 模式或人工方式修改本仓库的所有人。
> **本文件的规则优先于任何"看起来更合理"的直觉。**
>
> 本轮验证口径只限虚拟机环境（AndVM，Pixel 5 / OnePlus7TPro 配置）；真实设备、KernelSU/APatch、A/B 与 OTA 均未验证。真实设备、`pm grant` / AppOps 与数据继承不得写成已验证。

## 0. 这个仓库是什么

`GKUI-Pack` 是一个**打包与安装工程**,把 gx-bangsong 的 LineageOS 本土化应用
装到已运行的设备上,有两种途径:

1. **主方案(默认推荐)**:`scripts/install_all.sh` —— 通过 `adb install` 免 root 批量安装。
2. **次方案**:`build.sh` 生成 systemless 模块 zip(Magisk / KernelSU / APatch),`mode` **恒为 coexist**。

本仓库**不含任何 APK**,APK 由 CI 从 GitHub Releases 下载并校验 sha256。

## 1. 事实基线:禁止推断

`apps.yaml` 中的 `application_id` / `stock_package` 等值**只能来自事实基线**
(设备实测或已验证的仓库元数据),**不得**从仓库名、上游项目、命名后缀规律推断。

已确立的反例,必须记住:

> `GKUICalendar` fork 自 `LineageOS/android_packages_apps_Etar`,
> 但其 applicationId 是 **`ws.xsoh.etar.debug`**,而不是 `org.lineageos.etar.debug`。
> 规律不成立。

因此:

- 不在事实基线中的值一律写 `TODO`,**绝不允许**填写占位/猜测值
  (不得编造 sha256、版本号、包名、路径、仓库名、commit)。
- 任何 `TODO` 或 `confidence: unverified` 都会让 `build.sh` **`exit 1`**。
  这是**有意设计**,不是 bug;不要"顺手填上"以让构建通过。
- 录音机(GKUIRecorder)条目的 `application_id = org.lineageos.recorder.dev` 与
  `installed_version_code` 的范围必须按 `apps.yaml` 注释说明；本轮文档只将设备侧观察表述为
  AndVM 虚拟机配置，不可据此宣称真实设备已验证。签名摘要应来自 CI 对实际 APK 的
  `apksigner` 采集，Release 字段来自 GitHub Releases API；不能从包名后缀规律推断。

## 2. 硬约束(违反任一 = 失败)

| 编号 | 约束 | 在代码中的落点 |
|---|---|---|
| C1 | 禁止推断 applicationId;未知值 `TODO` + 构建失败 | `build.sh` 字段校验 |
| C2 | `mode` 恒为 `coexist`,禁止 `replace`、Magisk `REPLACE`、`.replace`，不改写 stock APK/分区。只对映射中路径不同且当前启用的 user 0 stock 执行 `pm disable-user`；同路径 `MERGED`、空路径 `ABSENT` 均 rc 0 跳过；GKUI disabled 与旧 tracked merged 状态先 `SELF-HEAL`。读取完整 `pm list packages -e/-d` 并匹配完整 `package:<name>` 行，禁止变量包名过滤。`keep-stock`、成功记录和卸载恢复保持可逆。Runtime grants 默认开启；`$MODDIR/no-auto-grant` 存在时完全跳过。不得 `pm uninstall`、不得写 `/data/data`。 | `build.sh`、`module/customize.sh`、`module/service.sh`、`module/uninstall.sh` |
| C3 | 普通版落在 `/system/app/<Name>/`。仅 Recorder 提供特权变体；privileged 权限申请仍走 `privileged_ack` 显式确认。`build.sh` 从 `module/` 源码生成两种脚本，只替换 Recorder 落点与生成的 `privapp-permissions` XML，并验证变体脚本差异行仅含 `priv-app` / `privapp-permissions`。为满足 `.github/workflows/ci.yml`，`module/` 下任何文件不得出现字面 `priv-app`；`module-priv/` 仅保留 module.prop 模板。普通版 `/system/app` 不因此获得特权权限。 | `preflight-apk.sh`、`build.sh`、`module/customize.sh` |
| C4 | 严禁纳入拨号 / 短信 / 联系人(`sharedUserId="android.uid.shared"` + platform 签名,第三方签名无法替换) | `apps.yaml` 字段校验 + CI 检查 |
| C5 | 仓库不得提交任何 `.apk` | `.gitignore`、`tests/test_build.sh` |
| C6 | 记录 APK 签名证书 SHA-256;证书与 `apps.yaml` 不一致时 CI fail 并提示卸载重装会丢数据 | `preflight-apk.sh`、`release.yml` |
| C7 | 不确定的值写 `TODO` 并让构建失败 | `build.sh` |
| C8 | 同包名已存在于 `/data` 时必须**中止安装**(提示用户自行 `pm uninstall`),模块**不得**代为卸载 | `module/customize.sh` |

唯一一处对 C7 的宽松处理:**`enabled: false` 的条目**里残留的 `TODO` 不阻断构建
(它不参与构建)。这样某个应用在"事实待确认"的长期状态下不会卡死整个项目
(v0.0.2 之前的录音机即如此;v0.0.3 起五个条目全部启用,当前没有条目用到这条宽松)。
需要字面语义时用 `--strict`。

### v0.0.8 stock、Clock merge 与 runtime grants

`build.sh` 从 `apps.yaml` 生成 `gkui-packages.list`、`stock-packages.list` 与
`stock-gkui-map.list`，映射行格式为 `stock|gkui`；preflight 派生 `stock-merged.list` 与
`merge_with_stock`。构建必须拒绝任一 `stock_package` 与任何 `application_id` 相同。

Clock 根因只采用用户提供的事实：APK 声明
`<original-package android:name="com.android.deskclock"/>`；stock 与 GKUI 名称的首个 `pm path`
相同，均为 `/system/app/GKUIClock/GKUIClock.apk`，共享 PackageSetting；
`/product/app/DeskClock` 被跳过为重复 APK。不要归因于子串匹配或 GKUI Clock 未安装。
用户报告 v0.0.7 没有 `Renamed packages:` 段、没有 `MERGED` / `SELF-HEAL` / `ABSENT` 日志，且
stock-toggle 日志与 v0.0.6 相同。仓库审计显示 v0.0.6/v0.0.7 都指向
`1d34861b50436c29415628a06f1b7769ece2bb8a`，PR #6“feat: 自动停用 stock 同类应用（可逆）”
未含 `<original-package>` 修复；查询列表中没有后续 PR。`transfer/diag-v0.0.7` 不可访问，
不要宣称读过、合并或复制它。

两种变体的 service 都先自愈 disabled GKUI 包与旧版 tracked merged stock，再执行正常切换。
按每个 `stock|gkui` pair 比较首个 `pm path`：相同写 `MERGED`、rc 0 跳过且不跟踪；任一空值写
`ABSENT`、rc 0 跳过；不同才检查 stock 状态。所有 `pm list packages -e/-d` 都读取完整输出，
对完整 `package:<name>` 行做精确匹配，绝不传变量包名作为过滤参数；禁止停用 GKUI 包。
`stock-toggle.log` 保留 timestamp/package/action/rc。`keep-stock`、boot flag 清除、后台诊断、成功项
记录与 service.d 卸载恢复必须保留；卸载恢复排除 merged stock。

闹钟数据由共享 PackageSetting 继承只是预期，不是已验证事实。其他四个应用的
`<original-package>` 替换不在本轮实现。

#### Runtime grants

默认开启。`$MODDIR/no-auto-grant` 存在时跳过全部授权。Build 对每个通过 preflight 的 APK，按
实际 `aapt dump badging` `uses-permission`、`device/framework-permissions.txt`、
`scripts/appop-map.txt` 派生 `runtime-grants.list` (`pkg|perm|method`)：`dangerous` → `grant`；
非 dangerous 且标记 `appop`、并有映射 → `appops`；其余不生成授权行。生成清单必须 fail-closed
校验。`runtime_permissions_only` 与 `runtime_permissions_exclude` 是互斥的 per-app 过滤器，
列表权限必须确实由 APK 请求。不要改动人类来源的 `apps.yaml` 字段，也不得编造 APK 权限数据。

Prerequisite grants 必须排在 dependent 前。Service 使用 `pm grant` 或
`appops set <package> <mapped-op> allow`，逐项记录 timestamp/package/permission/method/rc/stderr
首行；失败后继续。仅当某包所有行成功后写 `granted/<pkg>.<versionCode>`；成功后不重复，撤销后重启
也不自动重授，APK versionCode 变化产生一次新尝试。权限、package 名不能硬编码在 `service.sh`。

构建报告、ZIP 要列出实际生成的权限；实际五个 APK 的 grant 清单只能从此次构建产物读取，不能猜测。
`device/framework-permissions.txt` 只在头部补充提供的 AndVM 元数据，`--- [5]` 后权限正文必须
逐字节不变。

本轮验证范围：已在虚拟机环境（AndVM，Pixel 5 / OnePlus7TPro 配置）验证。真实设备、KernelSU/APatch、
A/B、OTA、真实设备 `pm grant` / AppOps、`/product/app/DeskClock` 卸载恢复、闹钟数据继承均未验证。

## 3. 目录地图

```
apps.yaml                     唯一事实来源(包名/版本/sha256/签名指纹)
build.sh                      构建入口;也是全仓库唯一的 apps.yaml 解析器
                              (--dump-apps-json 输出规范化 JSON)
scripts/install_all.sh        【主推】adb 免 root 批量安装
scripts/uninstall_all.sh      adb 卸载(逐个确认)
scripts/probe-device.sh       只读采集设备事实(用于回填 apps.yaml 的 TODO)
scripts/preflight-apk.sh      七项门禁(APK 侧;可校验单个 APK 或整个 APK_DIR)
module/                       唯一模块脚本源码;源码不得出现字面 priv-app
module-priv/                   仅特权变体 module.prop 模板;不维护重复脚本
scripts/appop-map.txt          permission 到 AppOps 映射
scripts/runtime-permission-dependencies.txt  runtime grant 前置依赖顺序
tests/test_build.sh           离线全流程测试:桩 aapt/apksigner + 假 APK
.github/workflows/ci.yml      push/PR:shellcheck + yamllint + 离线测试
.github/workflows/release.yml tag v*:下载 APK → 校验 → preflight → 构建 zip
```

## 4. 常用命令

```bash
bash tests/test_build.sh              # 离线自测(不需要网络、设备、Android SDK)
bash build.sh --check                 # 只做字段与门禁校验,不出包
bash build.sh --check --strict        # 连 disabled 条目的 TODO 也算失败(字面版 C7)
bash build.sh --dump-apps-json        # 查看 apps.yaml 规范化后的 JSON
bash build.sh --collect-only          # 只采集真实值(不产出模块,永远非零)
bash scripts/preflight-apk.sh <apk> <id>   # 单文件门禁(七项)
bash scripts/install_all.sh --dry-run      # 【主方案】演练(只打印,不装)
bash scripts/uninstall_all.sh --dry-run
bash scripts/probe-device.sh          # 只读采集设备事实
```

注意:**其它脚本一律通过 `bash build.sh --emit-tsv` / `--dump-apps-json` 读取
apps.yaml**,不要在别处再写一个 YAML 解析器(那会变成两套事实来源)。

## 5. 添加一个新应用的标准流程

1. 从**设备实测**取 `application_id`(可行时用 `scripts/probe-device.sh`)——
   **不要**照抄上游包名,也不要读解包 manifest 的 `package` 属性。
2. 在 `apps.yaml` 补条目:`application_id`、`stock_package`、`repo`、`upstream`、
   `license`、`release_tag`、`asset_name`;其余未知字段写 `TODO`。
3. 让 `bash build.sh --check` 失败;按提示补齐(GPL 应用必须填 `source_url`)。
4. 新签名 `signer_sha256` 只能来自真实 APK 的
   `apksigner verify --print-certs`(本仓库禁止手写)。
5. 若该应用的 `stock_package` 与已有启用条目重复,`build.sh` 会拒绝(防同类应用重复入包)。

## 6. 已经踩过的坑(会持续追加)

- **不要读解包 manifest 的 `package` 属性当 applicationId**。
  Etar 系那里是 AOSP 历史残留 `com.android.calendar`,会误导。
  必须用 `aapt dump badging` 的 `package: name=`(已编译进 APK 的真值)。
- **任意应用不得随意进入 `priv-app` 或生成白名单 XML**。
  带后缀的新包名不在 ROM 的特权白名单里，未经完整权限表验证就可能导致 PackageManager/zygote
  异常。通用 C3 处理仍是：未写 `privileged_ack` → 排除；写 `privileged_ack: true` → 普通版纳入
  `system/app` 并逐项标注权限不会被授予。唯一的 Recorder 特权变体由 `build.sh` 从 `module/`
  源码生成，并按对应 `device/framework-permissions.txt` 生成 `privapp-permissions` XML；构建
  校验脚本差异只包含 Recorder 落点与 XML。除该特定路径外，不扩展 privileged 例外。
- **解析 `aapt dump badging` 必须按字段名整体匹配,绝不能做子串匹配**。
  真实输出形如:

  ```
  package: name='ws.xsoh.etar.debug' versionCode='51' versionName='1.0.51' platformBuildVersionName='16' platformBuildVersionCode='36' compileSdkVersion='36' compileSdkVersionCodename='16'
  ```

  其中 `compileSdkVersionCodename='16'` 含**小写** `name='`。曾经的写法
  `sed "s/.*name='\([^']*\)'.*/\1/p"` 贪婪匹配到最后一个 `name='`,于是把平台代号
  `16` 当成了包名 —— 四个应用全部误判(CI 报告里 `package: name=16` 即此bug)。
  一律走 `scripts/preflight-apk.sh` 里的 `badging_field`(按引号对整字段取值),
  并在 `tests/test_build.sh` 里保留了带该字段的回归夹具。
- **`aapt xmltree` 的 `protectionLevel` 是数值形式**(如 `(type 0x11)0x12`),
  不含 `signature`/`privileged` 字样;用关键字匹配去判"声明"会永远命中不了,
  既漏报又给出"未检出"的虚假通过感。判定改为:**申请**命中平台特权权限清单 →
  不适合模块化;**声明**只报告(用 `describe_protection_level` 解码)。
- **xmltree 里同一条 authority 会出现两次**(类型化值 + `(Raw: ...)` 原值),
  报告输出前必须去重,否则每条都打印两遍。
- **G7 不能写成"模块内 versionCode 必须严格大于已安装版本"**。
  现行语义为：小于 → 失败；相等 → 通过并提示先按 C8 处理 `/data` 副本；
  `installed_version_code: none` → 仅在明确检查无该包时通过。README/apps.yaml 中已有的数字
  只代表 AndVM 虚拟机配置，不得称为真实设备测量。
- **`installed_version_code` 的合法值是整数或 `none`**；`none` 表示采集时明确检查无该包，
  不是未知或 adb 空输出。
- **APK 未声明 versionCode ≠ 未知**：Android 平台按 0 处理，`build.sh` 将有效值记作
  `0(未声明)` 并由 preflight 与记录值比较；不据此推断真实设备安装行为。
- **Clock 根因只使用已明确提供的事实**：`<original-package>`、相同首个 `pm path`、共享
  PackageSetting 与 `/product/app/DeskClock` duplicate skip。不要添加 UID、额外日志或数据迁移
  断言；数据继承只能写作预期。

- **门禁断言不要绑死在某个具体字段上**。曾有验收写成"recorder 的 `application_id`
  必须以 `TODO` 开头",结果每回填一个实测值都要求同步改 CI 工作流 —— 而工作流只有
  用户能推(路径 B),耦合纯属自找。正确写法是断言**不变量**:未证实 → 必须
  `confidence: unverified`、必须禁用、`application_id != stock_package`、且
  `_todo_fields` 非空(`build.sh --dump-apps-json` 已提供该字段)。这样回填实测值
  不再需要碰工作流。
- **versionName ≠ versionCode**。用户说"版本号是 1.1"时,1.1 只可能是 versionName;
  versionCode 是整数(该例实测为 1)。`apps.yaml` 的 `installed_version_code`
  只登记整数,永远不要把小数值当 versionCode 写进去。
- **`pm list packages <关键词>` 是子串过滤,不是精确匹配**:禁止把包名变量作为过滤参数;
  读取完整 `pm list packages -e/-d` 输出后必须用 `grep -Fx 'package:<完整包名>'`。
  这项通用精确匹配要求保留,但不能拿来解释本次 clock 故障:stock-toggle 仅有一次
  对 `com.android.deskclock` 的精确 disable 命令;实际根因是 `<original-package>` rename
  令 stock / GKUI 名称共享 PackageSetting 与 APK 路径。

- **`set -o pipefail` + `grep -q` = 假失败**:`grep -q` 一命中就退出并关闭管道,
  上游还在写(如 `git log`)就会吃到 SIGPIPE,管道整体返回 **141** —— 于是"找到了"
  被当成"没找到"。本工程的脚本里已经踩过一次(重建脚本的幂等守卫失效)。
  写法:先把输出重定向到变量或文件,再 `grep -q`;或在该管道后加 `|| true`。
  (仓库现有的 `printf '%s' "$out" | grep -q ...` 属于小输出、进 64KB 管道缓冲区即写完,
  暂时安全;但输出一旦变大就会变成随机失败。)

## 7. 值的来源纪律

`apps.yaml` 中已经填好的值**只能**来自可复核的来源,并且必须在 PR / 提交信息里说明出处:

* 包名 / `stock_package`:在本仓库允许的验证范围内由 AndVM 虚拟机配置或 `probe-device.sh` 输出支持；未确认值必须为 TODO;
* `release_tag` / `asset_name` / `sha256`:对应仓库的 Release 元数据
  (`gh api repos/<owner>/<repo>/releases`;`sha256` 取自 asset 的 `digest` 字段);
* `source_url`(GPL 必需):Release tag 经 API 解析出的 commit 链接;
* `signer_sha256`:实际 APK 的 `apksigner` 输出；`installed_version_code`:明确采集的目标环境数据。
  不手写、不猜测；任何已验证表述均须限定为 AndVM 虚拟机配置，不能声称真实设备验证。

## 8. 发布 / PR 与提交前自检

PR 描述必须从最终构建 ZIP 的 `runtime-grants.list` 原样列出五个应用的权限与 method，不能手填或从 APK 源码猜；若实际 ZIP 尚未构建/访问，明确阻塞并索取产物。PR 同时列明未验证项：真实设备行为、KernelSU/APatch、A/B、OTA、卸载后 `/product/app/DeskClock` 恢复、闹钟数据继承、真实设备 `pm grant` 与 AppOps。

`docs/TESTER.md` 不超过 15 行、没有命令，并包含“时钟只会有一个，这是正常的。”及“刷后等一分钟/不会出现权限弹窗”的提醒。

```bash
git ls-files | grep -c '\.apk$'                      # 必须为 0
grep -rn "mode: replace" apps.yaml                   # 必须无结果
grep -rn "priv-app" module/                          # 必须无结果
grep -rniE "dialer|telephony|messaging|contacts" apps.yaml   # 必须无结果
bash tests/test_build.sh                             # 必须通过(含上述全部验收项的自动检查)
find . -name '*.apk' -not -path './.git/*' | wc -l   # 必须为 0(含未跟踪文件)
shellcheck -S error $(git ls-files '*.sh')           # 必须无 error
shellcheck -S error module/META-INF/com/google/android/update-binary
```
