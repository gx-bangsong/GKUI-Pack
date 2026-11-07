# GKUI-Pack v0.0.6 发布说明（历史说明）

> 本文记录 v0.0.6 当时的行为设计。时钟部分已由 v0.0.8 的 `<original-package>` / 同路径诊断取代；本文旧时钟告警不应作为当前结论。所有本轮验证均限于虚拟机环境（AndVM，Pixel 5 / OnePlus7TPro 配置），真实设备、KernelSU/APatch、A/B 与 OTA 未验证。
>
> ## ⚠️ 行为变更：默认停用 stock 同类应用（可逆）
>
> v0.0.6 起，安装模块后首次开机，`service.sh` 会读取构建时由 `apps.yaml` 生成的
> `stock-packages.list`，并对其中**当前启用**的 user 0 stock 应用执行
> `pm disable-user --user 0`。stock APK 与系统分区文件不会被删除、替换或覆盖。
> 这是为回应用户反馈「安装 GKUI 后 stock 应用图标仍然可见」而作的决策变更；旧版
> 「只提供手动命令、不由模块停用 stock」规则不再适用。
>
> 安装时 10 秒内按音量下可保留 stock；安装后也可在模块目录创建 `keep-stock` 文件并
> 重启。删除此文件后重启会恢复默认停用行为。卸载时会安排下一次启动的
> `service.d` 一次性恢复脚本；模块管理器中只关闭模块开关不会恢复 stock。

## 行为与注意事项

- 只管理 `stock-disabled.list` 中由本模块成功停用的包；原本已停用且不在记录中的包
  不会被启用。PackageManager 命令结果写入模块目录 `stock-toggle.log`，诊断文件新增
  `[0] Stock app toggle state` 段。
- **时钟注意（v0.0.8 补充）**：GKUI Clock 声明 `<original-package android:name="com.android.deskclock"/>`；用户提供的诊断显示 stock 与 GKUI 名称指向同一个 `/system/app/GKUIClock/GKUIClock.apk` 并共享 PackageSetting。该同路径情况应记为 `MERGED` 并跳过停用；时钟只会有一个，这是正常的。闹钟数据继承是预期，不是已验证事实；真实响铃行为仍未验证。
- 临时切回 stock 时，不要在管理器里关闭模块开关；创建 `keep-stock` 后重启，或卸载模块
  再重启。关闭模块开关会令 `service.sh` 不再运行，stock 会保持当前停用状态。
- 本功能不执行 `pm uninstall`，不删除/覆盖 stock 应用目录，也不写入 `/data/data`。

## 双包说明

单次构建继续产出普通版与 recorderpriv 特权版，模块 `id` 均为 `gkui-pack`：

| 安装包 | Recorder 落点 | privapp 白名单 | 说明 |
|---|---|---|---|
| `GKUI-Pack-v0.0.6.zip` | `/system/app/GKUIRecorder` | 无 | 普通录音；不启用通话录音权限 |
| `GKUI-Pack-v0.0.6-recorderpriv.zip` | `/system/priv-app/GKUIRecorder` | `CAPTURE_AUDIO_OUTPUT` 一项 | 实际权限授予与通话录音未验证 |

特权版用户不要点击管理器的普通版自动更新按钮，否则会换回普通版。

## 尚未验证的项目

- 真实设备上，`pm disable-user --user 0` 对 `system_ext` / `product` 分区系统应用的实际效果；
- 卸载生成的 `/data/adb/service.d/gkui-pack-restore-stock.sh` 在 KernelSU / APatch 下是否执行；
- 管理器内安装时，`getevent` 能否在 10 秒窗口内读取到音量键；
- Magisk 下卸载后一次性恢复脚本的真实设备行为，以及 keep-stock 的重启恢复流程；
- v0.0.6 普通版与 recorderpriv 包在真机刷入后的整体行为。

## 手机端测试提醒

刷完并重启后，stock 同类应用图标可能按策略停用；GKUI Clock 与 stock Clock 共享 PackageSetting，因此时钟只会有一个，这是正常的。卸载模块后会安排恢复模块曾停用的 stock 应用；实际设备恢复情况未验证。