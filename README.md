# Audio Attenuator

macOS用の仮想オーディオドライバ + アプリ単位音量ミキサー。仮想デバイス「Attenuator Device」を日常のデフォルト出力として使いつつ、アプリごとに独立した音量(0〜150%)を設定できるようにする。

参照実装: [`micloop`](../micloop) (仮想マイク/ループバック録音ツール)。実装計画は `~/.claude/plans/radiant-mixing-pretzel.md` を参照。

## 現在の状態: Phase 3(アプリ単位音量)まで実装済み

- `driver/`: AudioServerPlugInベースの仮想出力デバイス「Attenuator Device」(48kHz/Float32/2ch)
- `agent/`: 仮想デバイスの音声を実出力へ中継し、アプリごとに独立した音量を適用するCLI
- アプリ単位音量は実測で検証済み(音量100%/50%/20%/0% に対しレベルが正確にスケール)
- メニューバーUIはPhase 4で実装予定。現時点ではCLIから操作する

**重要**: アプリ単位音量はシステム音声キャプチャ権限を必要とし、その権限はエージェントが
launchd経由で起動されている場合にのみ適用される。ターミナルから直接起動するとタップは
エラーなく無音を返す。詳細は [docs/PROCESS-TAPS.md](docs/PROCESS-TAPS.md)。

## 必要環境

- macOS 14.4以降 (Core Audio Process Tap APIが必要)
- CMake 3.20以降
- Swift 5.10以降 / C++17対応コンパイラ (Xcode Command Line Tools)

## ビルド

```bash
cmake -S . -B build
cmake --build build
```

## ドライバへの署名

```bash
codesign --force --sign - build/driver/Attenuator.driver
```

## インストール(要sudo)

```bash
sudo scripts/install.sh
```

`coreaudiod`が再起動するため、既存の音声出力が一瞬途切れます。インストール後、Audio MIDI設定.appで「Attenuator Device」が表示されることを確認してください。

## アンインストール

```bash
sudo scripts/uninstall.sh
```

## アプリ単位音量の使い方

1. エージェントを`.app`としてビルド(権限付与に必要なバンドル識別と署名が付く):

```bash
scripts/package-app.sh
```

2. システム設定 → プライバシーとセキュリティ → 画面収録とシステムオーディオ録音 で
   「Attenuator」を有効にする

3. launchd経由で起動する(ターミナルからの直接起動では権限が適用されない):

```bash
cp launchd/com.audioattenuator.agent.plist ~/Library/LaunchAgents/
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.audioattenuator.agent.plist
```

### CLIオプション

| オプション | 説明 |
|---|---|
| `--list-devices` | 出力デバイス一覧 |
| `--list-apps` | 音声を出しているプロセス一覧 |
| `--tap <bundle>=<pct>` | アプリ個別の音量 0〜150 (複数指定可) |
| `--fallback <pct>` | タップしていないアプリ全体の音量 (既定100) |
| `--master <pct>` | 最終ミックス全体の音量 (既定100) |
| `--output <uid\|name>` | 実際の出力先デバイス |
| `--duration <秒>` | 指定秒数で自動停止 (0=Ctrl+Cまで) |
| `--diag` | リングバッファ滞留とピークレベルを表示 (計測用) |

### 動作検証

```bash
scripts/build-testtools.sh
scripts/verify-per-app-volume.sh    # 音量設定に対しレベルが正確にスケールすることを実測
scripts/measure-onset-latency.sh    # 遅延を計測
```

## プロジェクト構造

```
audio-attenuator/
├── CMakeLists.txt
├── driver/                     # 仮想オーディオドライバ
│   ├── CMakeLists.txt
│   ├── Info.plist
│   └── src/AttenuatorDriver.cpp/.h
├── agent/                      # 音量ミキサー (SwiftPM)
│   ├── Package.swift
│   └── Sources/
│       ├── CAudioShim/         # ロックフリーのリングバッファ・ゲインストア (C)
│       └── AttenuatorAgent/
│           ├── main.swift            # CLI
│           ├── CoreAudioHelpers.swift
│           ├── ProcessRegistry.swift # プロセス列挙
│           ├── TapManager.swift      # タップとAggregate Deviceの管理
│           ├── AudioRelay.swift      # 3つのIOProcとミキシング
│           └── Resources/Info.plist  # 権限要求に必要
├── launchd/                    # LaunchAgent (権限適用に必須)
├── testtools/                  # 検証用トーン生成
├── scripts/
└── docs/
    └── PROCESS-TAPS.md         # Process Tapの実地調査結果
```

## ライセンス

MIT
