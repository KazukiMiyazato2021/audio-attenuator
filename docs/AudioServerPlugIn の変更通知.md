---
title: AudioServerPlugIn の変更通知
tags: [core-audio, audioserverplugin, driver, gotcha]
created: 2026-09-24
---

# AudioServerPlugIn の変更通知

**値を保存するだけでは誰も気づかない。**

`SetPropertyData` で受け取った値を内部状態に格納しても、ホストへ通知しなければ
CoreAudio はプロパティが変わったことを知らない。結果、そのプロパティに登録した
リスナーは**一度も発火しない**。

## 症状

OS の音量キーやシステム設定の音量スライダーを操作しても、ミキサー側が変化に
気づかない。値自体は正しく書き込まれており、読み出せば新しい値が返る。
リスナーだけが動かない。

## 対処

```c
gPlugIn_Host->PropertiesChanged(gPlugIn_Host, <objectID>, <count>, <addresses>);
```

ボリュームなら `kAudioLevelControlPropertyScalarValue` と
`kAudioLevelControlPropertyDecibelValue` の両方を、ミュートなら
`kAudioBooleanControlPropertyValue` を、対象のコントロールオブジェクト ID に対して通知する。

## 非同期で呼ぶこと

ホストがドライバへコールバックしてくる可能性があるため、
`SetPropertyData` の中から同期的に呼ぶとデッドロックしうる。
`dispatch_async` で別キューへ逃がす。

## リスナーを当てにしすぎない

ドライバ側の通知漏れは無言の失敗になる。他者のドライバを相手にする場合は
特に、低頻度のポーリングを保険として併用すると、通知が来なくても機能を保てる。
プロパティの読み取り2回程度なら、機能が丸ごと死ぬリスクに比べれば安い。

## 音量の適用場所

ドライバが音量値を保持していても、**それを音声に適用するのは誰かの仕事**。

このプロジェクトではミキサー側の最終ミックスで適用している。ドライバの通過処理で
適用すると、タップ経由の音声(ドライバを通らない)が対象外になり、
アプリごとに音量キーの効き方が食い違うため。

## 関連

- [[AudioServerPlugIn のカスタムプロパティ]]
- [[coreaudiod 再起動への対応]]
