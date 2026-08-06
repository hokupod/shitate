[English](README.md) | [日本語](README.ja.md) | [简体中文](README.zh-CN.md)

# Shi-tate

**通話の手前で、声を仕立てる。**

Shi-tate（Shitate / 仕立て）は、macOS向けのオープンソースVST3 Audio
Input FXホストです。物理マイクの1チャンネルを個人用エフェクトチェーンで
処理し、ステレオdual monoとしてBlackHole 2ch経由で通話アプリへ渡します。

「仕立て」は、素材を特定の人や目的に合わせて整えることを意味します。
Shi-tateは、通話へ届く前のマイク信号を自分向けに仕立てます。

## ステータス

> [!WARNING]
> **プレアルファ — まだ利用できません。** インストール可能なアプリと検証済み
> 音声経路は存在しません。現在は`0.1.0-dev`を実装中です。

対応する自動・手動検証結果が公開されるまでは、通話、録音、本番ワークフローへ
依存しないでください。

## v0.1の範囲

- Apple Silicon（`arm64`）とmacOS 14以降。
- 物理マイク1チャンネルを選び、ステレオdual monoへ変換。
- 利用者が用意したarm64 VST3 Audio Effectを最大8個直列処理。
- 外部インストール済みBlackHole 2chへ48 kHzでのみ出力。
- VST3を1 bundleずつHelper processで隔離スキャン。
- 保存済みデバイス、形式、プラグインが無効なら無音でfail closed。
- dirty shutdown後はVST3ロード前にsafe mode起動。
- 設定とplugin stateはローカル保存し、音声は保存しない。

## 非対象

v0.1には、独自仮想driver、BlackHole/VST3同梱、Intel/Windows/Linux、
AU/CLAP/VST2、resampling、sidechain、instrument、monitoring、recording、
telemetry、updater、runtime plugin isolationを含めません。

## アーキテクチャ

```text
物理マイク
  → Shi-tate（直列VST3 Audio Effects）
  → BlackHole 2ch
  → Zoom / Slack / Google Meet / Discord
```

SwiftUIが製品UIとローカル状態を担当します。薄いObjective-C++ bridgeが
C++20/JUCE audio coreを分離します。main targetは`Shitate`、配布アプリ名は
`Shi-tate.app`です。

[Canonical詳細設計](docs/design.md)を参照してください。

## 必要環境

- Apple Silicon Mac
- macOS 14+
- Xcode 26.6 / Swift 6.3
- flake対応Nix 2.34+、または同等のCMake 3.31+環境
- 公式プロジェクトから別途インストールしたBlackHole 2ch
- 利用者が用意した互換arm64またはUniversal VST3 Audio Effect

JUCEはcommit
`f8f8864172464b9adf9eba6101e1f784838d1597`へ固定します。

## ビルドとテスト

以下は予定している共通interfaceですが、**build foundation実装までは利用できません**。

```bash
nix develop
./scripts/bootstrap.sh
./scripts/configure.sh dev
./scripts/build.sh dev
./scripts/test.sh dev
./scripts/check-format.sh
./scripts/check-docs.sh
```

現時点では、build、起動、音声routing、第三者plugin hostの成功実績はありません。

## プライバシーとセキュリティ

Shi-tateは音声保存、telemetry、crash upload、analytics、remote configuration、
plugin download、アプリ本体の外部通信を実装しません。shellや管理者権限も要求
しません。デバイス障害時に別入力やspeakerへ暗黙切替しません。

VST3は未信頼のnative codeです。scanは隔離しますが、v0.1のruntime pluginは
main app内で実行され、利用者権限でcrash、hang、file access、network accessを
起こし得ます。信頼できるpluginだけを利用してください。[SECURITY.md](SECURITY.md)
も参照してください。

## ライセンスと第三者コンポーネント

Shi-tateは[GNU AGPL-3.0-only](LICENSE)です。BlackHoleと第三者VST3は別
projectであり、同梱しません。利用者が公式開発元から入手し、各license条件を
遵守してください。

Shi-tateは第三者VST3 pluginを同梱・再配布しません。インストールしてロードする
各pluginのlicense条件を遵守する責任は利用者にあります。

[Third-party notices](THIRD_PARTY_NOTICES.md)も参照してください。

## コントリビューション

[CONTRIBUTING.md](CONTRIBUTING.md)、[詳細設計](docs/design.md)、
[SECURITY.md](SECURITY.md)を確認してください。real-time、privacy、signature、
fail-closedの境界を維持する必要があります。
