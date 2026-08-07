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
> **Pre-alpha — 尚未达到生产可用状态。** `0.2.0-dev`仍在实现中。目前没有
> 可安装的release，也没有广泛的第三方VST3兼容性证据。

在相应的自动与手动验证证据发布之前，请勿在通话、录音或生产工作流中依赖它。

## v0.2范围

- Apple Silicon（`arm64`）和macOS 14或更高版本。
- 选择一个物理麦克风通道并转换为立体声dual mono。
- 串联处理最多八个由用户提供的arm64 VST3 Audio Effect。
- 以48 kHz输出到单独安装的BlackHole 2ch。
- 仅在用户明确操作时，以与BlackHole互斥的Preview方式把处理后音频发送到
  当前macOS物理主输出。
- 每个VST3 bundle使用独立Helper process进行隔离扫描。
- 保存的设备、格式或插件无效时，以静音方式fail closed。
- dirty shutdown后，在加载任何VST3之前进入safe mode。
- 设置与plugin state仅保存在本地，绝不保存音频。

## 非目标

v0.2不包含自定义虚拟driver、BlackHole/VST3再分发、Intel/Windows/Linux、
AU/CLAP/VST2、resampling、sidechain、instrument、BlackHole与主输出同时
monitoring、Preview输出选择或音量、recording、telemetry、updater或runtime
plugin isolation。

## 架构

```text
物理麦克风
  → Shi-tate（串联VST3 Audio Effects）
  ├→ BlackHole 2ch → Zoom / Slack / Google Meet / Discord
  └→ 当前macOS主输出（互斥Preview）
```

SwiftUI负责产品UI和本地状态。轻量Objective-C++ bridge隔离C++20/JUCE音频
核心。主target名为`Shitate`，发布的应用名为`Shi-tate.app`。

请参阅[实现架构](docs/architecture.md)、[威胁模型](docs/threat-model.md)和
[规范详细设计](docs/design.md)。

## 环境要求

- Apple Silicon Mac
- macOS 14+
- Xcode 26.6 / Swift 6.3
- 支持flake的Nix 2.34+，或等效的CMake 3.31+工具环境
- 从官方项目单独安装的BlackHole 2ch
- 用户提供的兼容arm64或Universal VST3 Audio Effect

选择插件前，请阅读范围有限的[VST3兼容性与扫描约定](docs/plugin-compatibility.md)。

JUCE固定在commit
`f8f8864172464b9adf9eba6101e1f784838d1597`。

## 构建与测试

在repository root中运行以下受支持的开发workflow：

```bash
nix develop
./scripts/bootstrap.sh
./scripts/configure.sh dev
./scripts/build.sh dev
./scripts/test.sh dev
./scripts/check-format.sh
./scripts/check-docs.sh
```

自动测试覆盖build、audio core、scanner隔离和确定性的仓库内VST3 fixture。
这些测试不能证明生产可用性，也不能证明与特定第三方插件兼容。

## 试用开发版应用

构建完成后，启动本地Debug应用：

```bash
open build/dev/Debug/Shi-tate.app
```

原生onboarding会检查BlackHole 2ch、请求麦克风权限、以48 kHz验证物理输入、
扫描本地VST3、保存default session，并说明通话应用中的选择步骤。零插件chain
也是有效的passthrough设置。Shi-tate绝不会替你安装BlackHole或插件。

在通话应用中把麦克风选为BlackHole 2ch，然后从Dashboard或menu bar开始
routing。`Control-Shift-M`无需Accessibility权限即可切换master mute。关闭主
窗口后menu bar utility仍会运行；使用Quit可完全退出。

`Start Preview`会先停止BlackHole routing，再把处理后的dual mono发送到当前
macOS物理主输出。它只支持Automatic routing、48 kHz、双方共有的
128/256/512-frame buffer以及可用的立体声输出。请使用耳机或调低扬声器音量以
避免反馈。明确执行`Stop Preview`后，仅当Preview开始前routing正在运行时，才会
按原mute状态恢复BlackHole。输出变化、sleep、权限丢失或错误都会停止Preview，
且不会自动重启。

请参阅[Manual audio QA](docs/manual-qa.md)，了解每项hardware与产品流程中已验证
和未验证的证据。

## 验证未来的签名release

目前尚无签名release。发布后，请从同一个获准release下载DMG及其checksum，
并在打开前执行验证：

```bash
shasum -a 256 -c Shi-tate_0.2.0_arm64.dmg.sha256
spctl --assess --type open --context context:primary-signature --verbose=4 \
  Shi-tate_0.2.0_arm64.dmg
```

把应用拖入Applications后，再执行
`spctl --assess --type execute --verbose=4 /Applications/Shi-tate.app`。
如果任一检查失败，请勿绕过Gatekeeper。release还会提供recursive
`shitate-0.2.0-source.tar.zst`及SHA-256。GitHub自动生成的source archive
不包含JUCE内容，因此不是对应source。

## 隐私与安全

Shi-tate不实现音频保存、telemetry、crash upload、analytics、remote
configuration、plugin download或应用网络访问，也不运行shell或要求管理员权限。
设备故障时绝不隐式切换到其他输入或输出。主输出Preview只能由用户明确启动，
该输出发生变化时会立即停止。

本地异步log仅限所有者访问，单文件上限5 MiB并保留三个轮换世代，同时会
redact home path与device UID。`Copy Diagnostics`只在用户明确操作时写入
clipboard；Shi-tate不会发送或自动保存该report。

VST3是不受信任的native code。扫描过程会隔离，但v0.2的runtime plugin在主
应用内执行，可能以用户权限造成crash、hang、文件访问或网络访问。只加载你信任
的插件。为支持用户VST3，App Sandbox已禁用，app/scanner也禁用了Library
Validation；Hardened Runtime并不能隔离这些插件。另请参阅[SECURITY.md](SECURITY.md)。

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
