# AGENTS.md — 本仓库的 agent / 贡献者工作守则

> 面向以 agent 模式或人工方式修改本仓库的所有人。
> **本文件的规则优先于任何"看起来更合理"的直觉。**

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
- 录音机(GKUIRecorder)条目的 `application_id = org.lineageos.recorder.dev` 来自
  2026-10-08 的真机实测(`pm list packages -3` + `dumpsys package`),**不是**从仓库描述
  "基于 LineageOS 录音机"或源码里的 `applicationIdSuffix` 推出来的 —— 那些**不构成**包名
  证据,只是事后恰好一致。同理,它的 `signer_sha256` 来自 CI 在真实 APK 上的 `apksigner`
  采集(临时 tag `v0.0.3-collect`),Release 字段来自 GitHub Releases API 原样抄录。

## 2. 硬约束(违反任一 = 失败)

| 编号 | 约束 | 在代码中的落点 |
|---|---|---|
| C1 | 禁止推断 applicationId;未知值 `TODO` + 构建失败 | `build.sh` 字段校验 |
| C2 | `mode` 恒为 `coexist`,**严禁** `replace`;禁止任何写 stock 目录的路径;禁止 Magisk `REPLACE` / `.replace` | `build.sh`、`module/customize.sh` |
| C3 | 一律装到 `/system/app/<Name>/`,**严禁 `priv-app`**、严禁生成任何白名单 XML(物理底线);检出 privileged 权限申请时按**显式确认制**处理:条目未写 `privileged_ack` → **不入模块**(fail-safe,README 标注"仅走 adb install");条目写明 `privileged_ack: true` → 以 `system_app` 纳入,但报告 / 清单 / 构建摘要必须**逐条标注**申请了哪些特权权限、这些权限不会被授予、后果(`privileged_note`)。`customize.sh` 还会清掉模块目录 `system/` 下除 `app/` 以外的任何落点(从 `recorder-priv` 变体刷回时不留残留) | `preflight-apk.sh`、`build.sh`、`module/customize.sh` |
| C4 | 严禁纳入拨号 / 短信 / 联系人(`sharedUserId="android.uid.shared"` + platform 签名,第三方签名无法替换) | `apps.yaml` 字段校验 + CI 检查 |
| C5 | 仓库不得提交任何 `.apk` | `.gitignore`、`tests/test_build.sh` |
| C6 | 记录 APK 签名证书 SHA-256;证书与 `apps.yaml` 不一致时 CI fail 并提示卸载重装会丢数据 | `preflight-apk.sh`、`release.yml` |
| C7 | 不确定的值写 `TODO` 并让构建失败 | `build.sh` |
| C8 | 同包名已存在于 `/data` 时必须**中止安装**(提示用户自行 `pm uninstall`),模块**不得**代为卸载 | `module/customize.sh` |

唯一一处对 C7 的宽松处理:**`enabled: false` 的条目**里残留的 `TODO` 不阻断构建
(它不参与构建)。这样某个应用在"事实待确认"的长期状态下不会卡死整个项目
(v0.0.2 之前的录音机即如此;v0.0.3 起五个条目全部启用,当前没有条目用到这条宽松)。
需要字面语义时用 `--strict`。

## 3. 目录地图

```
apps.yaml                     唯一事实来源(包名/版本/sha256/签名指纹)
build.sh                      构建入口;也是全仓库唯一的 apps.yaml 解析器
                              (--dump-apps-json 输出规范化 JSON)
scripts/install_all.sh        【主推】adb 免 root 批量安装
scripts/uninstall_all.sh      adb 卸载(逐个确认)
scripts/probe-device.sh       只读采集设备事实(用于回填 apps.yaml 的 TODO)
scripts/preflight-apk.sh      七项门禁(APK 侧;可校验单个 APK 或整个 APK_DIR)
module/                       systemless 模块源码(构建时被渲染进 zip)
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
- **不要把带后缀的新包名放进 `priv-app`**。
  它不在 ROM 自带的 `privapp-permissions` 白名单里,
  一旦申请 `signature|privileged` 权限就会让 zygote 抛
  `Signature|privileged permissions not in privapp-permissions whitelist` → bootloop。
  检出此情况**不要生成白名单 XML**:缺省**不入模块**并提示仅走 adb 安装;只有条目显式写
  `privileged_ack: true` 才以**普通系统应用**纳入,且必须逐条标注"这些权限不会被授予"
  (`/system/app` 只是"系统应用"标记,**不会授予** `CAPTURE_AUDIO_OUTPUT` 之类的特权权限)。
  不要为了让某个应用"功能完整"而放宽这条 —— 需要特权的功能属于 priv 变体(`recorder-priv`
  分支)/ ROM 侧集成,超出本模块范围。
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
- **G7 不能写成"模块内 versionCode 必须严格大于设备已装版本"**。
  2026-10-08 真机实测:三个已安装应用与模块内 APK 的 versionCode **恰好相同**
  (51/1/1),旧规则会让构建永远无法通过 —— 而它想防的"压制"其实由 C8 在刷入时
  强制拦截(检出 /data 副本即中止)。现行语义:小于 → 失败(回退);
  相等 → 通过并提示(先卸载 /data 副本);`installed_version_code: none`
  (实测设备无副本)→ 通过;设备上有副本但 APK 未声明 versionCode → 失败。
- **`installed_version_code` 的合法值是"整数 或 none"**,`none` 表示"实测设备上没有
  该包名的副本"(是测量结果,不是未知)。
- **APK 未声明 versionCode ≠ 未知**:Android 平台按 0 处理,设备上那一份的实测值也确实是 0
  (clock 已验证)。所以 G7 用"有效 versionCode = 0"照常比较,不要再写"未知就拦"的特例;
  `build.sh` 对该情形记为 `0(未声明)` 并放行(preflight 已负责比较)。
- **判断"设备上是否安装"要用 `pm list packages`,不要用 dumpsys 是否取到 versionCode**:
  adb 偶发返回空,会被误读成"未安装"(clock 上真实踩过,一度把 IVC 记成 none)。

- **门禁断言不要绑死在某个具体字段上**。曾有验收写成"recorder 的 `application_id`
  必须以 `TODO` 开头",结果每回填一个实测值都要求同步改 CI 工作流 —— 而工作流只有
  用户能推(路径 B),耦合纯属自找。正确写法是断言**不变量**:未证实 → 必须
  `confidence: unverified`、必须禁用、`application_id != stock_package`、且
  `_todo_fields` 非空(`build.sh --dump-apps-json` 已提供该字段)。这样回填实测值
  不再需要碰工作流。
- **versionName ≠ versionCode**。用户说"版本号是 1.1"时,1.1 只可能是 versionName;
  versionCode 是整数(该例实测为 1)。`apps.yaml` 的 `installed_version_code`
  只登记整数,永远不要把小数值当 versionCode 写进去。
- **`pm list packages <关键词>` 是子串过滤,不是精确匹配**:用 `Contains()` 判定
  "是否存在"时,理论上可能被相似包名误命中(录音机这次同时拿到了 `versionCode=1`,
  误命中概率极低)。要更严格可再用 `pm path <完整包名>` 复核一次。

- **`set -o pipefail` + `grep -q` = 假失败**:`grep -q` 一命中就退出并关闭管道,
  上游还在写(如 `git log`)就会吃到 SIGPIPE,管道整体返回 **141** —— 于是"找到了"
  被当成"没找到"。本工程的脚本里已经踩过一次(重建脚本的幂等守卫失效)。
  写法:先把输出重定向到变量或文件,再 `grep -q`;或在该管道后加 `|| true`。
  (仓库现有的 `printf '%s' "$out" | grep -q ...` 属于小输出、进 64KB 管道缓冲区即写完,
  暂时安全;但输出一旦变大就会变成随机失败。)

## 7. 值的来源纪律

`apps.yaml` 中已经填好的值**只能**来自可复核的来源,并且必须在 PR / 提交信息里说明出处:

* 包名 / `stock_package`:设备实测(事实基线)或 `probe-device.sh` 的输出;
* `release_tag` / `asset_name` / `sha256`:对应仓库的 Release 元数据
  (`gh api repos/<owner>/<repo>/releases`;`sha256` 取自 asset 的 `digest` 字段);
* `source_url`(GPL 必需):Release tag 经 API 解析出的 commit 链接;
* `signer_sha256` / `installed_version_code`:**TODO**,必须由真实 APK 与真实设备采集
  (`--collect-only` / `probe-device.sh`),**任何人都不许手写**。

## 8. 提交前自检

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
