# Audio Attenuator

macOS用の仮想オーディオドライバ + アプリ単位音量ミキサー。仮想デバイス「Attenuator Device」を日常のデフォルト出力として使いつつ、アプリごとに独立した音量(0〜150%)を設定できるようにする。

参照実装: [`micloop`](../micloop) (仮想マイク/ループバック録音ツール)。実装計画は `~/.claude/plans/radiant-mixing-pretzel.md` を参照。

## 現在の状態: Phase 1(仮想ドライバ単体)まで実装済み

- `driver/`: AudioServerPlugInベースの仮想出力デバイス「Attenuator Device」(48kHz/Float32/2ch、Input+Outputストリーム、Volume/Muteコントロール)。ビルド・ad-hoc署名まで確認済み。
- アプリ単位音量(Process Tap経由)とメニューバーUIはPhase 3/4で実装予定。現時点ではドライバは「デフォルト出力として安定して選択できること」のみを検証する段階で、まだ何もこのデバイスの出力を読み出していないため無音が正常。

## 必要環境

- macOS 14.4以降
- CMake 3.20以降
- C++17対応コンパイラ (Xcode Command Line Tools)

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

## プロジェクト構造

```
audio-attenuator/
├── CMakeLists.txt
├── driver/                     # 仮想オーディオドライバ (Phase 1)
│   ├── CMakeLists.txt
│   ├── Info.plist
│   └── src/
│       ├── AttenuatorDriver.cpp
│       └── AttenuatorDriver.h
├── scripts/
│   ├── install.sh
│   ├── uninstall.sh
│   └── restart-coreaudio.sh
└── agent/                      # メニューバー常駐アプリ (Phase 2以降で実装予定)
```

## ライセンス

MIT
