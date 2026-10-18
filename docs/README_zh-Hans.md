<p align="center">
  <a href="../README.md">English</a> |
  <a href="README_zh-Hans.md">简体中文</a>
</p>

# DuoStatusRing

灵动岛一分为二时，DuoStatusRing 把状态栏里的信号、Wi‑Fi 和电池折叠成岛旁边的一个圆环；灵动岛合回一个时再展开。

![预览](./preview.gif)

## 安装

在常用的包管理器里添加 OwnGoal Studio 源：

**[apt.owngoal.dev](https://apt.owngoal.dev/)**

安装包也在 [GitHub Releases](https://github.com/owngoal-dev/DuoStatusRing/releases)，按越狱环境选择：

| 环境 | 安装包 |
| --- | --- |
| [roothide](https://github.com/roothide) | `iphoneos-arm64e` `.deb` |
| Rootless（`/var/jb`） | `iphoneos-arm64` `.deb` |

需要带灵动岛的 iPhone，iOS 16 或更高版本。开发和测试环境为 iOS 26.6.2。没有任何设置项，装上即可。想临时关闭而不卸载，在越狱环境内创建 `/var/mobile/Library/wiki.qaq.duostatusring/disabled` 再注销即可。

## 效果

- **分裂**：电池收成一个点，再从点长成环顶部的一段圆弧，弧的填充就是电量，颜色跟随系统电池（充电绿、低电量模式黄、电量低红）；信号格沿圆环落下，变成环底开口处的四个点；Wi‑Fi 移到环心。
- **合并**：圆弧缩回成点，四个点爬回成信号格，电池从点长回原样。
- **打断**保持速度：正在运动的部件带着当前速度掉头，快速连续地分裂、合并也不会跳变。
- **折叠时数据照常变化**：信号强弱变化时点和 Wi‑Fi 弧段渐变；断网时 Wi‑Fi 图标上画出一道斜杠；电量沿圆弧滑动，颜色渐变。
- **灵动岛仍是系统原生的**：只把分裂与合并的弹簧放慢到设计稿的节奏，并让时间和图标在岛宽度变化时带一点回弹地跟随。
- 主屏、锁屏和 App 内的状态栏都会折叠（它们都由 SpringBoard 绘制）。开启"减弱动态效果"时改为交叉淡入淡出。横屏和控制中心的展开状态栏保持原样。

Wi‑Fi 图标按系统图标的比例手绘，线宽与圆环一致。没有 Wi‑Fi 但有蜂窝数据时，环心显示网络类型；完全没有连接时，显示带斜杠的 Wi‑Fi。

## 原理

DuoStatusRing 只注入 SpringBoard。它跟随 System Aperture 自己发出的布局通知，在两个元素并排显示（原生 mitosis）时折叠。系统的右侧图标留在原位并被隐藏，由根据它们实时状态绘制的副本变形成圆环，所以折叠从图标所在的位置开始，也正好结束在它们将要出现的位置。每个部件都是一个闭式求解的阻尼弹簧，掉帧或延迟的帧不会让动画错位；共享的 display link 只在有东西运动时运行。

## 构建

只用 Xcode 自带工具链构建；每一步都是 `scripts/` 下的脚本，本地和 Release 工作流跑的是同一份代码。

```sh
make check      # 全部静态检查
make debs       # 两个安装包、对应的 dSYM 和 SHA256SUMS，输出到 build/pkg
```

`tests/host/run.sh` 在 Mac 上运行时间线和几何的测试。`tests/device/` 是在虚拟 iPhone 上测试用的工具：一个仅供开发的 dylib（运行时 dump、逐帧记录、SpringBoard 内录屏和模拟信号数据），不会进入安装包。

## 致谢

设计概念来自 Mobin。

## 许可证

[MIT](../LICENSE)
