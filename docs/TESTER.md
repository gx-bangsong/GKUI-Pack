# 手机端测试说明（无需电脑）

**验证范围**：已在虚拟机环境（AndVM，Pixel 5 / OnePlus7TPro 配置）验证；真机、KernelSU/APatch、A/B 与 OTA 未验证。
**刷前**：曾 adb 安装过对应 GKUI 应用，请先在“设置 → 应用”卸载；Recorder 旧数据请先备份。
1. 在 Magisk / KernelSU / APatch 管理器刷普通版；测试通话录音时选择 recorderpriv。
2. 重启并解锁，等待约一分钟再检查应用；首次启动不会出现权限请求弹窗。
日历、图库、计算器和录音机使用 GKUI 版；stock 同类应用按策略停用。

时钟只会有一个，这是正常的。

权限默认自动尝试授予；不希望自动尝试时，在模块目录新建 `no-auto-grant` 文件。
撤销权限后，重启不会再次尝试；应用 versionCode 变化后才会重新尝试。
**诊断**：解锁后约 1 分钟，在“文件管理 → 下载”找到 `GKUI-diag.txt` 并回传，确认末尾有 `sdcard_copy: ok`。
卸载模块后，下次启动会尝试恢复本模块曾停用的 stock 应用。
尚未验证：`/product/app/DeskClock` 卸载后恢复、闹钟数据继承。
