# GKUI-Pack Privileged ZIP — Release notes template

> 仅当同一 Release 附件中实际存在 `GKUI-Pack-Priv-<版本>.zip` 时使用此说明。当前仓库还没有真机权限转储,不要把该模板当成已发布/已验证特权包。

## ⚠️ 特权变体:可能导致无法开机

`GKUI-Pack-Priv-<版本>.zip` 与普通版共享模块 ID `gkui-pack`,设备上只能启用其中一个。普通版五款 APK 均静态位于 `system/app/<Name>/<Name>.apk`;特权版只将 `priv_variant.app_ids` 中明确指定的 recorder 放入 `system/priv-app/GKUIRecorder/GKUIRecorder.apk`,日历、图库、计算器和时钟仍在 `system/app/`。APK 安装时不会由脚本从临时目录复制。白名单 XML 与 APK 一起静态位于 systemless ZIP 的 `system/etc/permissions/`。

白名单仅由 **APK 实际申请的权限 ∩ 同一设备转储中 protectionLevel 含 `privileged` 的权限** 自动生成。安装器会用目标设备 `pm list permissions -f` / `-fg` 再次核验;任何 mismatch 都会在部署前中止。该特权变体只适用于采集权限转储所对应的 ROM/SDK,换 ROM 或升级系统后必须重新测量、构建与验证。

### 安装前必须

- 备份数据,确认能进入 recovery 或取得 root shell。
- 按 [device/README.md](../device/README.md) 检查设备/ROM/SDK。
- 若同包名应用仍在 `/data`,先自行 `adb uninstall <application_id>`,再重启并刷入;模块不会替你卸载(C8)。
- 只安装一个同 ID 变体。普通版为 `GKUI-Pack-<版本>.zip`,特权版为 `GKUI-Pack-Priv-<版本>.zip`。

### 恢复

1. 开机看门狗若发现前次启动未到 `service.sh`,下次启动会写入 `disable` 自动停用模块。
2. 可从 Magisk / KernelSU / APatch 管理器关闭/移除 `gkui-pack`。
3. 若设备无法进入系统,进入 recovery/root shell 后执行 `rm -rf /data/adb/modules/gkui-pack`;若只想暂时停用可执行 `touch /data/adb/modules/gkui-pack/disable`。
4. 或刷回同 id 普通版 ZIP。不要轻率运行 `magisk --remove-modules`,它会移除所有模块。

特权功能必须在目标设备实测;安装成功不等于 ROM 一定允许该功能。上游应用/ROM 可能另有权限或录音限制。更多说明见 `module-priv/README.md`。
