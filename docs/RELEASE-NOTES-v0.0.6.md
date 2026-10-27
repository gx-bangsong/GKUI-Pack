# GKUI-Pack v0.0.6 发布说明

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
- stock 时钟被停用后，原有 stock 时钟闹钟不会响；请在 GKUI 时钟中重新设置闹钟。
- 临时切回 stock 时，不要在管理器里关闭模块开关；创建 `keep-stock` 后重启，或卸载模块
  再重启。关闭模块开关会令 `service.sh` 不再运行，stock 会保持当前停用状态。
- 本功能不执行 `pm uninstall`，不删除/覆盖 stock 应用目录，也不写入 `/data/data`。

## 双包说明

单次构建继续产出普通版与 recorderpriv 特权版，模块 `id` 均为 `gkui-pack`：

| 安装包 | Recorder 落点 | privapp 白名单 | 说明 |
|---|---|---|---|
| `GKUI-Pack-v0.0.6.zip` | `/system/app/GKUIRecorder` | 无 | 普通录音；不启用通话录音权限 |
| `GKUI-Pack-v0.0.6-recorderpriv.zip` | `/system/priv-app/GKUIRecorder` | `CAPTURE_AUDIO_OUTPUT` 一项 | 通话录音功能仍待真机验证 |

特权版用户不要点击管理器的普通版自动更新按钮，否则会换回普通版。

## 尚未经真机验证的项目

- Android 16 上，`pm disable-user --user 0` 对 `system_ext` / `product` 分区系统应用的实际效果；
- 卸载生成的 `/data/adb/service.d/gkui-pack-restore-stock.sh` 在 KernelSU / APatch 下是否执行；
- 管理器内安装时，`getevent` 能否在 10 秒窗口内读取到音量键；
- Magisk 下卸载后一次性恢复脚本的完整真机行为，以及 keep-stock 的重启恢复流程；
- v0.0.6 普通版与 recorderpriv 包在真机刷入后的整体行为。

## 手机端测试提醒

刷完并重启后，原来的时钟、日历、计算器、图库、录音机图标会消失，这是正常的；如果想要回来，卸载这个模块再重启。