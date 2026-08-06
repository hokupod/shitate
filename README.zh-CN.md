[English](README.md) | [日本語](README.ja.md) | [简体中文](README.zh-CN.md)

# Shi-tate

**在声音进入通话之前，先把它精心调校。**

Shi-tate（Shitate / 仕立て）是面向macOS的开源VST3音频输入效果宿主。
它让一个物理麦克风通道经过个人效果链处理，再通过BlackHole 2ch以立体声
dual mono形式传送给通话应用。

日语“仕立て”表示针对特定的人或目的进行剪裁和调校。Shi-tate让你在麦克风
信号进入通话前按自己的需要进行处理。

## 状态

> [!WARNING]
> **Pre-alpha — 尚不可用。** 当前没有可安装的应用，也没有通过验证的音频路径。
> `0.1.0-dev`仍在实现中。

在相应的自动与手动验证证据发布之前，请勿在通话、录音或生产工作流中依赖它。

## v0.1范围

- Apple Silicon（`arm64`）和macOS 14或更高版本。
- 选择一个物理麦克风通道并转换为立体声dual mono。
- 串联处理最多八个由用户提供的arm64 VST3 Audio Effect。
- 仅以48 kHz输出到单独安装的BlackHole 2ch。
- 每个VST3 bundle使用独立Helper process进行隔离扫描。
- 保存的设备、格式或插件无效时，以静音方式fail closed。
- dirty shutdown后，在加载任何VST3之前进入safe mode。
- 设置与plugin state仅保存在本地，绝不保存音频。

## 非目标

v0.1不包含自定义虚拟driver、BlackHole/VST3再分发、Intel/Windows/Linux、
AU/CLAP/VST2、resampling、sidechain、instrument、monitoring、recording、
telemetry、updater或runtime plugin isolation。

## 架构

```text
物理麦克风
  → Shi-tate（串联VST3 Audio Effects）
  → BlackHole 2ch
  → Zoom / Slack / Google Meet / Discord
```

SwiftUI负责产品UI和本地状态。轻量Objective-C++ bridge隔离C++20/JUCE音频
核心。主target名为`Shitate`，发布的应用名为`Shi-tate.app`。

请参阅[规范详细设计](docs/design.md)。

## 环境要求

- Apple Silicon Mac
- macOS 14+
- Xcode 26.6 / Swift 6.3
- 支持flake的Nix 2.34+，或等效的CMake 3.31+工具环境
- 从官方项目单独安装的BlackHole 2ch
- 用户提供的兼容arm64或Universal VST3 Audio Effect

JUCE固定在commit
`f8f8864172464b9adf9eba6101e1f784838d1597`。

## 构建与测试

以下是计划中的统一接口，但在**build foundation完成前不可用**：

```bash
nix develop
./scripts/bootstrap.sh
./scripts/configure.sh dev
./scripts/build.sh dev
./scripts/test.sh dev
./scripts/check-format.sh
./scripts/check-docs.sh
```

目前没有证据证明应用可以构建、启动、路由音频或托管第三方插件。

## 隐私与安全

Shi-tate不实现音频保存、telemetry、crash upload、analytics、remote
configuration、plugin download或应用网络访问，也不运行shell或要求管理员权限。
设备故障时绝不隐式切换到其他输入或扬声器。

VST3是不受信任的native code。扫描过程会隔离，但v0.1的runtime plugin在主
应用内执行，可能以用户权限造成crash、hang、文件访问或网络访问。只加载你信任
的插件。另请参阅[SECURITY.md](SECURITY.md)。

## 许可证与第三方组件

Shi-tate采用[GNU AGPL-3.0-only](LICENSE)。BlackHole和第三方VST3属于独立
项目，不随本项目捆绑。用户必须从官方开发者处获取并遵守各自许可证。

Shi-tate不包含或再分发第三方VST3插件。用户有责任遵守其安装和加载的每个插件
的许可证条款。

另请参阅[第三方声明](THIRD_PARTY_NOTICES.md)。

## 贡献

请先阅读[CONTRIBUTING.md](CONTRIBUTING.md)、[详细设计](docs/design.md)和
[SECURITY.md](SECURITY.md)。所有贡献都必须保持real-time、privacy、signature
与fail-closed边界。
