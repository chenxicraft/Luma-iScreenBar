# Luma

**Light, beautifully controlled.**

简体中文 · [English](README.en.md)

用于 BenQ iScreenBar 挂灯的非官方 macOS 菜单栏控制应用。通过 USB HID 本地控制，无需登录账户。

## 相比原版的主要改进

- **更易用的界面**：重新设计控制面板与设置页面，适配 macOS 液态玻璃风格。常用模式、亮度和色温调节更直观；支持自定义场景名称、图标与灯光参数，修改即时保存。
- **更简洁的菜单栏常驻方式**：使用独立设计的单色菜单栏图标，应用不在 Dock 显示图标，通过菜单栏即可打开控制面板和设置。
- **可自定义的调光快捷键**：默认使用 `Fn + F1 / F2` 调暗、调亮，也可在设置中更换组合键。支持按住连续调光，无需反复按键。快捷键修改需点击保存。
- **更灵活的空闲熄灯策略**：保留硬件入离席侦测，新增独立的键鼠空闲熄灯辅助策略，提供 **5 秒至 30 分钟**多个档位，恢复操作后自动恢复灯光。该策略不改变硬件人体侦测的时间设置。

## 核心功能

- 灯光开关、亮度、色温、自动调光、视频模式。
- 场景新增、复制、删除与实时保存。
- App 启动或切换时应用绑定场景。
- 硬件入离席侦测：3 / 5 / 10 分钟，低 / 中 / 高灵敏度。
- Mac 睡眠关灯、唤醒开灯、相机视频模式及 Night Shift 联动。

## 安装

从 [Releases](https://github.com/chenxicraft/Luma/releases/latest) 下载 DMG 或 ZIP。将 `Luma.app` 移入 Applications 后启动。请先退出原版 iScreenBar，避免两个应用同时控制挂灯。

分享版要求 **macOS 14 或更新版本**，包含 Apple Silicon 和 Intel 架构。Intel 与旧版 macOS 尚未经实机验证。macOS 26 及以上使用液态玻璃，旧系统使用兼容材质。

当前采用 ad-hoc 签名，未经过 Apple 公证。首次打开可能被系统拦截；确认来源后，可在「系统设置 → 隐私与安全性」查看是否提供「仍要打开」。无需关闭系统安全机制。参见 [Apple 官方说明](https://support.apple.com/102445)。

## 兼容性与限制

- 当前仅匹配 USB VID/PID `04A5:2501`，不保证所有 ScreenBar 型号或硬件批次兼容。
- 键鼠空闲不等于人已离席，阅读和观看视频时也可能触发空闲熄灯。
- 未解锁低于硬件下限的亮度；完全熄灯使用独立电源控制。
- Night Shift 依赖非公开系统接口，系统更新可能影响兼容性。
- 相机、睡眠与唤醒联动仍需在更多设备和实际场景中验证。
- 不包含固件升级、软件自动更新或日志上报。

## 从源码构建

需要 macOS 和 Xcode 命令行工具。

```sh
./source/build.command             # 当前机器架构，最低 macOS 12
./source/build.command --universal # 分享版双架构，最低 macOS 14
```

生成的 `Luma.app` 位于仓库根目录。构建采用本地 ad-hoc 签名。

隔离测试（使用模拟设备，不控制真实挂灯）：

```sh
./Luma.app/Contents/MacOS/Luma --selftest
./Luma.app/Contents/MacOS/Luma --ui-test
```

## 隐私

预设和 App 绑定保存在当前用户的本机偏好设置中，不包含在安装包里。应用未集成日志上报或使用数据上传。相机联动读取使用状态，不采集或录制画面。

本项目与 BenQ 无隶属关系，iScreenBar 名称归其权利人所有。


Designed by Chenxi.
