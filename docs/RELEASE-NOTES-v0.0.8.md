# GKUI-Pack v0.0.8 发布说明

## 时钟恢复与 stock 合并识别

GKUI Clock 的 APK 声明 `<original-package android:name="com.android.deskclock"/>`；用户提供的诊断事实是 stock 与 GKUI 时钟名称的首个 `pm path` 相同，均解析到 `/system/app/GKUIClock/GKUIClock.apk`，并共享 PackageSetting。故障不是包名子串误匹配，也不是 GKUI Clock 未安装；`/product/app/DeskClock` 被 PackageManager 作为重复 APK 跳过。

开机 service 先自愈已禁用的 GKUI 包及旧版本跟踪的合并 stock 名称，再处理 stock 切换。`MERGED` 表示首个路径相同并跳过停用，`ABSENT` 表示任一首个路径为空、以 rc 0 跳过；GKUI 包不会被 stock 流程停用。匹配 `pm list packages -e/-d` 时使用完整 `package:<name>` 行，不将变量包名作为过滤参数。`keep-stock`、成功停用记录、启动标记清除、后台诊断与卸载恢复机制保留。

共享 PackageSetting 下原有闹钟数据由 GKUI Clock 继承是预期，不是已验证结论。把 `<original-package>` 替换扩展到其他四个应用不在本次实现范围内。

## 默认运行时权限尝试

运行时权限默认启用；模块目录存在 `no-auto-grant` 文件时完全跳过。构建从实际 APK 的 `aapt dump badging` `uses-permission`、`device/framework-permissions.txt` 和 `scripts/appop-map.txt` 生成 `runtime-grants.list`，每行是 `package|permission|method`：`dangerous` 使用 `grant`；非 `dangerous` 且标记为 `appop`、并存在映射的权限使用 `appops`；其他等级不生成授权行，生成清单再经 fail-closed 校验。每应用可用互斥的 `runtime_permissions_only` / `runtime_permissions_exclude` 过滤。

Service 按依赖顺序运行 `pm grant` 或 `appops set … allow`；逐项记录时间、包名、权限、方法、返回码及 stderr 首行，失败不阻断其他条目。只有该包该 `versionCode` 的全部授权命令成功后才写 `granted/<package>.<versionCode>`，后续启动不重复；撤销后重启不会自动重新授予，APK `versionCode` 改变后可产生一次新尝试。安装后首次启动请等 30–60 秒；不会弹出权限请求窗口。精确权限列表必须从本次构建生成的 `runtime-grants.list` 原样抄入 PR 描述，不能从源码或旧版本猜测。

## Recorder 变体与诊断

普通版与 `recorderpriv` 变体的脚本都由 `module/` 源码在 `build.sh` 中生成；特权变体只改 Recorder 落点与生成的 `privapp-permissions` XML。构建比较两版脚本差异，改动行必须仅涉及 `priv-app` / `privapp-permissions`。每个 ZIP 都验证包含 GKUI、stock、stock-to-GKUI 映射、merged 状态及 runtime grants 清单。安装器全部 `ui_print` 输出追加写入 `install.log`。

`GKUI-diag.txt` 保留旧章节，并增加 renamed packages、五个 GKUI 与五个 stock 包的路径/身份/用户/运行时/声明权限、disabled/system 包与 launcher 结果、模块树、权限 marker/log、stock 清单和 marker 状态。

## 验证与未验证事项

已在虚拟机环境（AndVM，Pixel 5 / OnePlus7TPro 配置）验证。真实设备行为、KernelSU/APatch、A/B、OTA、卸载后 `/product/app/DeskClock` 恢复、闹钟数据继承、真实设备上的 `pm grant` 与 AppOps 效果仍未验证；这些不得表述为已验证。
