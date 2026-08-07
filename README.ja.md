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
> **プレアルファ — まだ本番利用できません。** 現在は`0.2.0-dev`を実装中です。
> インストール可能なreleaseと、第三者VST3への広範な互換性実績はありません。

対応する自動・手動検証結果が公開されるまでは、通話、録音、本番ワークフローへ
依存しないでください。

## v0.2の範囲

- Apple Silicon（`arm64`）とmacOS 14以降。
- 物理マイク1チャンネルを選び、ステレオdual monoへ変換。
- 利用者が用意したarm64 VST3 Audio Effectを最大8個直列処理。
- 外部インストール済みBlackHole 2chへ48 kHzで出力。
- 明示操作時だけ、BlackHoleとの排他Previewとして加工音を現在のmacOS物理
  メイン出力へ送る。
- VST3を1 bundleずつHelper processで隔離スキャン。
- 保存済みデバイス、形式、プラグインが無効なら無音でfail closed。
- dirty shutdown後はVST3ロード前にsafe mode起動。
- 設定とplugin stateはローカル保存し、音声は保存しない。

## 非対象

v0.2には、独自仮想driver、BlackHole/VST3同梱、Intel/Windows/Linux、
AU/CLAP/VST2、resampling、sidechain、instrument、BlackHoleとメイン出力の
同時monitoring、Preview出力選択・音量、recording、telemetry、updater、
runtime plugin isolationを含めません。

## アーキテクチャ

```text
物理マイク
  → Shi-tate（直列VST3 Audio Effects）
  ├→ BlackHole 2ch → Zoom / Slack / Google Meet / Discord
  └→ 現在のmacOSメイン出力（排他Preview）
```

SwiftUIが製品UIとローカル状態を担当します。薄いObjective-C++ bridgeが
C++20/JUCE audio coreを分離します。main targetは`Shitate`、配布アプリ名は
`Shi-tate.app`です。

[実装アーキテクチャ](docs/architecture.md)、
[脅威モデル](docs/threat-model.md)、[Canonical詳細設計](docs/design.md)を
参照してください。

## 必要環境

- Apple Silicon Mac
- macOS 14+
- Xcode 26.6 / Swift 6.3
- flake対応Nix 2.34+、または同等のCMake 3.31+環境
- 公式プロジェクトから別途インストールしたBlackHole 2ch
- 利用者が用意した互換arm64またはUniversal VST3 Audio Effect

pluginを選ぶ前に、限定的な[VST3互換性・スキャン契約](docs/plugin-compatibility.md)
を確認してください。

JUCEはcommit
`f8f8864172464b9adf9eba6101e1f784838d1597`へ固定します。

## ビルドとテスト

repository rootから、対応する開発workflowを実行します。

```bash
nix develop
./scripts/bootstrap.sh
./scripts/configure.sh dev
./scripts/build.sh dev
./scripts/test.sh dev
./scripts/check-format.sh
./scripts/check-docs.sh
```

自動テストはbuild、audio core、scanner隔離、決定的な同梱テスト用VST3 fixtureを
検証します。本番利用や特定の第三者pluginとの互換性を証明するものではありません。

## 開発版アプリを試す

build後、ローカルのDebugアプリを起動します。

```bash
open build/dev/Debug/Shi-tate.app
```

native onboardingは、BlackHole 2ch確認、マイク権限要求、物理入力の48 kHz検証、
ローカルVST3 scan、default session保存、通話アプリ側の選択案内を行います。
plugin 0個のchainも有効なpassthrough設定です。Shi-tateがBlackHoleやpluginを
インストールすることはありません。

通話アプリ内でマイクにBlackHole 2chを選び、Dashboardまたはmenu barから
routingを開始します。`Control-Shift-M`はAccessibility権限なしでmaster muteを
切り替えます。main windowを閉じてもmenu bar utilityは動作し、Quitで終了します。

`Start Preview`はBlackHole routingを一度停止し、加工済みdual monoを現在の
macOS物理メイン出力へ送ります。Automatic routing、48 kHz、共有可能な
128/256/512 frames、live stereo出力でのみ利用できます。ハウリング防止のため
headphoneを使うかspeaker音量を下げてください。明示的な`Stop Preview`では、
開始前にrouting中だった場合だけ元のmute状態でBlackHoleを再開します。出力変更、
sleep、権限喪失、error時はPreviewを停止し、自動再開しません。

hardware・製品導線ごとの検証済み／未検証evidenceは
[Manual audio QA](docs/manual-qa.md)を参照してください。

## 将来の署名済みreleaseを検証する

現在、署名済みreleaseはありません。公開後は、同じ承認済みreleaseからDMGと
隣接するchecksumを取得し、開く前に検証してください。

```bash
shasum -a 256 -c Shi-tate_0.2.0_arm64.dmg.sha256
spctl --assess --type open --context context:primary-signature --verbose=4 \
  Shi-tate_0.2.0_arm64.dmg
```

Applicationsへdrag後、
`spctl --assess --type execute --verbose=4 /Applications/Shi-tate.app`でも
再検証します。いずれかが失敗した場合はGatekeeperを迂回しないでください。
releaseにはrecursive `shitate-0.2.0-source.tar.zst`とSHA-256も含まれます。
GitHubの自動source archiveはJUCE内容を欠くため、対応sourceではありません。

## プライバシーとセキュリティ

Shi-tateは音声保存、telemetry、crash upload、analytics、remote configuration、
plugin download、アプリ本体の外部通信を実装しません。shellや管理者権限も要求
しません。デバイス障害時に別入力や出力へ暗黙切替しません。メイン出力Previewは
利用者の明示操作でのみ開始し、その出力が変わると停止します。

local非同期logはowner-onlyで、5 MiBと3世代rotationに制限し、home pathと
device UIDをredactします。`Copy Diagnostics`は明示的なclipboard操作であり、
reportを送信または自動保存しません。

VST3は未信頼のnative codeです。scanは隔離しますが、v0.2のruntime pluginは
main app内で実行され、利用者権限でcrash、hang、file access、network accessを
起こし得ます。user VST3対応のためApp Sandboxを無効にし、app/scannerでは
Library Validationも無効にしています。Hardened Runtimeはpluginを隔離しません。
信頼できるpluginだけを利用してください。[SECURITY.md](SECURITY.md)も参照してください。

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
