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
- 录音机(GKUIRecorder)条目的 `application_id` **必须保持 `TODO`**,
  它的仓库描述虽然写着"基于 LineageOS 录音机",但这**不构成**包名证据。

## 2. 硬约束(违反任一 = 失败)

| 编号 | 约束 | 在代码中的落点 |
|---|---|---|
| C1 | 禁止推断 applicationId;未知值 `TODO` + 构建失败 | `build.sh` 字段校验 |
| C2 | `mode` 恒为 `coexist`,**严禁** `replace`;禁止任何写 stock 目录的路径;禁止 Magisk `REPLACE` / `.replace` | `build.sh`、`module/customize.sh` |
| C3 | 一律装到 `/system/app/<Name>/`,**严禁 `priv-app`**;检出 privileged 权限则**不入模块**,README 标注"仅走 adb install" | `preflight-apk.sh`、`build.sh` |
| C4 | 严禁纳入拨号 / 短信 / 联系人(`sharedUserId="android.uid.shared"` + platform 签名,第三方签名无法替换) | `apps.yaml` 字段校验 + CI 检查 |
| C5 | 仓库不得提交任何 `.apk` | `.gitignore`、`tests/test_build.sh` |
| C6 | 记录 APK 签名证书 SHA-256;证书与 `apps.yaml` 不一致时 CI fail 并提示卸载重装会丢数据 | `preflight-apk.sh`、`release.yml` |
| C7 | 不确定的值写 `TODO` 并让构建失败 | `build.sh` |
| C8 | 同包名已存在于 `/data` 时必须**中止安装**(提示用户自行 `pm uninstall`),模块**不得**代为卸载 | `module/customize.sh` |

唯一一处对 C7 的宽松处理:**`enabled: false` 的条目**里残留的 `TODO` 不阻断构建
(它不参与构建)。这样录音机在"包名待确认"的长期状态下不会卡死整个项目。
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

## 6. 两个容易踩的坑

- **不要读解包 manifest 的 `package` 属性当 applicationId**。
  Etar 系那里是 AOSP 历史残留 `com.android.calendar`,会误导。
  必须用 `aapt dump badging` 的 `package: name=`(已编译进 APK 的真值)。
- **不要把带后缀的新包名放进 `priv-app`**。
  它不在 ROM 自带的 `privapp-permissions` 白名单里,
  一旦申请 `signature|privileged` 权限就会让 zygote 抛
  `Signature|privileged permissions not in privapp-permissions whitelist` → bootloop。
  检出此情况**不要生成白名单 XML**,而是**不入模块**并提示仅走 adb 安装。

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
