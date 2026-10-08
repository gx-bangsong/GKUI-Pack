# GKUI-Pack

把 gx-bangsong 的 LineageOS 本土化应用(日历 / 图库 / 计算器 / 时钟)打包安装到**已运行的设备**上。

> **本文件的完整版在仓库收尾提交中给出(含构建流程、填值流程、模块用法、
> 风险与免责声明)。** 此处先给出最关键的三条。

## ⚠️ 重要:全部 APK 均为 debug 构建

GKUI 系列 APK 都是 **debug 构建**(`applicationIdSuffix` 为 `.debug` / `.dev`,
由 **debug keystore** 签名),而非正式发行签名。因此:

- 调试签名可能随构建环境变化 → 版本间**更新安装可能失败**
  (`INSTALL_FAILED_UPDATE_INCOMPATIBLE`),此时**只能卸载重装**,
  **应用内数据会丢失**。
- 本工程的 CI 会比对每个 APK 的**签名证书 SHA-256** 与 `apps.yaml` 中记录值,
  不一致即 **fail**,并提示上述后果。
- 请勿把本工程产物用于任何正式分发场景。

## 推荐用法(主方案):adb 免 root 安装

```bash
bash scripts/install_all.sh          # 需要 adb 已连接设备;不要 root
```

`adb install` 方式**不需要 root、不需要解锁、不修改系统分区**,
是最安全、最容易回退的方式。安装完成后按提示在
**设置 → 默认应用** 中切换默认日历 / 图库即可。

## 次方案:systemless 模块(Magisk / KernelSU / APatch)

```bash
bash build.sh                        # 生成 dist/*.zip
```

模块为 **coexist 模式**(与 stock 应用共存,**绝不替换** stock 应用),
APK 一律安装在 `/system/app/<Name>/`。**使用前请阅读完整 README 的
「模块前置条件」——模块与设备 `/data` 中已安装的同包名应用会冲突,必须先卸载。**

---

完整文档、免责声明与许可说明见 [`README.md`](README.md)(收尾提交)、
[`NOTICE.md`](NOTICE.md)、[`AGENTS.md`](AGENTS.md)。
