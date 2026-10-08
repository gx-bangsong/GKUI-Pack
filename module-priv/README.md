# GKUI-Pack 特权变体(⚠ 有开机风险)

此 ZIP 与普通版是**同一个模块**: `module.prop` 的 id 都是 `gkui-pack`。设备上只应启用其中一个。

- 普通版 ZIP:五款应用的 APK 已静态位于 `system/app/<Name>/<Name>.apk`;安装器不从 `apks/` 临时目录复制。录音机是普通系统应用,**不会因此获得通话录音权限**。
- 特权版 ZIP:日历、图库、计算器、时钟仍静态位于 `system/app/`;本配置只把 `priv_variant.app_ids` 中的录音机放到 `system/priv-app/GKUIRecorder/GKUIRecorder.apk`,白名单 XML 静态位于同 ZIP 的 `system/etc/permissions/`。
- APK 包名、签名不变,变体切换不创建第二个 GKUI-Pack 模块。切换前仍须处理 `/data` 中同包名副本(C8)。

> ⚠ **可能卡开机。** Android 9(API 28) 及以上,若 `ro.control_privapp_permissions=enforce`,白名单漏项或 XML 没有落到对应分区都可能导致启动失败。此 ZIP 只应在拥有正确设备权限转储、且愿意承担恢复风险的设备上使用。

## 构建保护

特权版 XML 不是手写的。构建器使用：

```text
XML 权限 = APK 实际申请的权限 ∩ 设备转储中 protectionLevel 含 privileged 的权限
```

APK 申请权限从 `aapt dump badging` / preflight JSON 读取；设备侧事实来自仓库 `device/framework-permissions.txt`。任一申请权限不在转储里、权限级别无法解析、遇到纯 `signature` 权限、交集为空或 XML 少于一条，特权变体会 fail-closed 并跳过 Priv ZIP；合格的普通 ZIP 可照常生成。普通版始终只用静态 `system/app/<Name>/<Name>.apk` 布局。当前 recorder 的真实 signer 尚待采集,因此 C7 会先阻止整次正式构建；设备权限 dump 则是生成 Priv ZIP 的另一独立门槛。

安装时 `customize.sh` 会再次调用设备 `pm list permissions -f`(必要时 `-fg`)逐条核对 XML 中的权限。任意一条在当前设备不再含 `privileged` 都会在部署前中止。不要把一个 ROM 的转储拿去给另一个 ROM/SDK 构建。

## 安装前检查

1. 先备份,并确认能进入 recovery 或有可用 root shell。
2. 确认设备属性与捕获转储时一致：

   ```sh
   adb shell getprop ro.build.version.sdk
   adb shell getprop ro.build.version.release
   adb shell getprop ro.build.type
   adb shell getprop ro.control_privapp_permissions
   adb shell pm list permissions -f
   ```

3. 卸载 `/data` 中同包名应用后重启,否则 C8 会中止整个安装：

   ```sh
   adb uninstall org.lineageos.recorder.dev
   ```

   确切包名以本次 `apps.yaml` 和 APK preflight 为准。模块**不会替用户卸载**。
4. 用 Magisk / KernelSU / APatch 管理器安装 `GKUI-Pack-Priv-<版本>.zip`,不要同时启用同 id 普通版。

## 验证

```sh
adb shell pm path org.lineageos.recorder.dev
adb shell pm check-permission android.permission.CAPTURE_AUDIO_OUTPUT org.lineageos.recorder.dev 0
```

检查路径应为 `/system/priv-app/GKUIRecorder/...`。服务脚本会清除 `.boot_flag`,并把每条白名单权限的 `granted / denied / unknown` 结果写入模块目录 `last_boot.log`。成功进入桌面后仍需在录音机内实测通话录音;设备 ROM 还可能有额外限制。

## 恢复与回退

1. **自动看门狗**:若一次启动未走到 `service.sh`,下次 `post-fs-data.sh` 会写 `disable`,管理器下次启动自动跳过本模块。
2. **有管理器界面**:关闭/删除 GKUI-Pack 模块并重启。
3. **无 GUI / 卡开机**:进入 recovery 或任何可执行 shell 的环境,二选一：

   ```sh
   rm -rf /data/adb/modules/gkui-pack
   # 或只禁用本模块,下次启动后再通过管理器移除
   touch /data/adb/modules/gkui-pack/disable
   ```

   ⚠ `magisk --remove-modules` 会移除**所有**模块,只有别无他法时才使用。
4. **有 root shell**:

   ```sh
   adb shell su -c 'rm -rf /data/adb/modules/gkui-pack'
   ```

5. **回到零风险版本**:直接刷回同 id 普通版 ZIP;无需先卸载特权版模块。普通版安装脚本会清理该模块目录内旧的特权落点与白名单 XML。也可在管理器中禁用/删除后重启。

模块使用 systemless 挂载,不会写系统分区。卸载模块后 APK 与 XML 一起消失;若包名/签名没变,应用数据通常保留。若你为了满足 C8 手动卸载了 `/data` 应用,该次卸载是否保留数据由 Android/ROM 决定。

## 已知注意事项

- [BCR 上游说明](https://github.com/chenxiaolong/BCR#usage)指出,对 **BCR 本身**启用 root hiding 时可能还要手动安装 APK;KernelSU 用户需兼容的 metamodule,并避免在 app profile 中卸载模块挂载。它不是 GKUIRecorder 的验证结果,请勿照搬为保证。
- 上述是第三方上游说明,不是本仓库的真机验证结果。若设备仍不工作,先回退普通版并提供 boot log、`pm path`、`pm list permissions -f` 输出供排查。
