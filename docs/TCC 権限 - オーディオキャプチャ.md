---
title: TCC 権限 - オーディオキャプチャ
tags: [tcc, macos, core-audio, gotcha]
created: 2026-09-24
---

# TCC 権限 - オーディオキャプチャ

**この領域の失敗はエラーではなく無音として現れる。** これが調査を最も難しくした。

タップは `noErr` で作成でき、Aggregate Device も作成でき、IOProc も正しい形の
バッファで正しいレートで発火する。それでいて全サンプルが 0 になる。
返り値を確認するだけでは絶対に気づけない。

## 必要な権限は2種類ある

| 用途 | TCC サービス | Info.plist キー | システム設定のペイン |
|---|---|---|---|
| 仮想デバイスの**入力**読み取り | `kTCCServiceMicrophone` | `NSMicrophoneUsageDescription` | マイク |
| アプリ単位の**プロセスタップ** | `kTCCServiceAudioCapture` | `NSAudioCaptureUsageDescription` | 画面収録とシステムオーディオ録音 |

仮想デバイスにマイクは付いていないが、**入力ストリームの読み取りは TCC 上マイク
アクセス扱い**になる。この点を見落とすと、タップ側の権限だけ整えても無音のままになる。

ターミナルは通常マイク権限を持っているため、**CLI ビルドでは完璧に動いて見えるのに
パッケージ化したエージェントでは無音**という現象が起きる。ターミナルの許可が
肩代わりしていただけ。→ [[TCC 責任プロセス]]

## Info.plist キーがないとプロンプトすら出ない

```
Refusing authorization request for service kTCCServiceMicrophone and subject
Sub:{com.audioattenuator.agent} ... without NSMicrophoneUsageDescription key
```

キーが無いと macOS は確認ダイアログを表示することを拒否し、無言で拒否扱いにする。

## 許可は「許可後に起動したプロセス」にのみ適用される

許可を与えた時点で既に動いていたプロセスは失敗し続ける
(`AudioDeviceStart` が `268451843` を返す)。**再起動が必要**。

## 起動時にブロックする

デバイスを開く処理はプロンプトへの応答があるまでブロックする。そのため
`applicationDidFinishLaunching` の中で同期的に呼ぶと、メニューバーアイコンすら
表示されないままアプリが固まったように見える。オーディオの初期化は UI 表示後に
回すこと。

## 調査方法

```bash
log stream --info --debug --style compact --predicate 'process == "tccd"'
```

`AUTHREQ_RESULT` の `authValue` が判定結果。

| 値 | 意味 |
|---|---|
| 0 | 拒否 |
| 1 | 未設定 |
| 2 | 許可 |

## 関連

- [[TCC 責任プロセス]]
- [[コード署名と TCC 許可の失効]]
- [[Core Audio Process Tap]]
