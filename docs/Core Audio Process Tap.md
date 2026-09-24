---
title: Core Audio Process Tap
tags: [core-audio, macos, process-tap]
created: 2026-09-24
---

# Core Audio Process Tap

macOS 14.2+ の `AudioHardwareCreateProcessTap` により、**プロセス単位**で音声を
取り出せる。AudioServerPlugIn(HAL ドライバ)は CoreAudio がミックスした後の
単一ストリームしか受け取れず、どのアプリの音かを区別できないため、アプリ単位
音量にはこの API が必須になる。

## 特別な entitlement は不要

非サンドボックス・ad-hoc 署名のバイナリからでも `noErr` で成功する。
Apple から付与される特別な entitlement は要らない。

ただし**権限は別途必要**で、それが最大の落とし穴になる → [[TCC 権限 - オーディオキャプチャ]]

## プロセスの列挙

`kAudioHardwarePropertyProcessObjectList` で全プロセスの `AudioObjectID` を取得し、
各オブジェクトから以下が読める。

| プロパティ | 内容 |
|---|---|
| `kAudioProcessPropertyPID` | PID |
| `kAudioProcessPropertyBundleID` | バンドル ID |
| `kAudioProcessPropertyIsRunningOutput` | 現在音を出しているか |

`AudioObjectID` は再起動で変わるため、永続化のキーには使えない。
→ [[オーディオプロセスのグループ化]]

## Aggregate Device でのバッファ構造

N 個のタップを 1 つの Aggregate Device にまとめると、入力 IOProc は
**`mNumberBuffers == N`、1 タップにつき 1 バッファ、サブタップリスト順**で届く。
3 タップ同時で検証済み(2ch × 3 バッファ)。

これによりバッファのインデックスをそのままゲインのスロットとして使える。
ただし実装では読み戻して不一致を警告している。仕様として明記された挙動ではないため。

## ミュート動作

`muteBehavior = .muted` にすると、タップが存在した瞬間から**そのアプリの音声は
通常の出力経路へ流れなくなる**。振幅 0.3 のトーンで実測したところ、フォールバック
経路の測定値がちょうど 0.0000 に落ち、タップ側が音声を運ぶ。二重再生も欠落もない。

この性質があるため「各アプリの音声はフォールバック経路かタップのどちらか一方だけを
通る」という不変条件を保てる。

## 関連

- [[TCC 権限 - オーディオキャプチャ]]
- [[TCC 責任プロセス]]
- [[オーディオプロセスのグループ化]]
