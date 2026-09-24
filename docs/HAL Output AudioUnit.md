---
title: HAL Output AudioUnit
tags: [core-audio, audiounit, sample-rate]
created: 2026-09-24
---

# HAL Output AudioUnit

出力を生の `AudioDeviceIOProc` ではなく `kAudioUnitSubType_HALOutput` の
AudioUnit 経由にすると、**デバイス側のレートとチャンネル数への変換を
AudioUnit が引き受ける**。

固定レートのパイプラインから任意のデバイスへ出す場合、これが最も確実な手段。
自前でリサンプリングを書くより堅い。

## 構成手順

1. `AudioComponentFindNext` で `kAudioUnitType_Output` / `kAudioUnitSubType_HALOutput`
2. `kAudioOutputUnitProperty_CurrentDevice` に出力先デバイスを設定
3. `kAudioUnitProperty_StreamFormat` の **Input スコープ, bus 0** に
   自分側のフォーマット(ここでは 48kHz stereo Float32 interleaved)を設定
4. `kAudioUnitProperty_SetRenderCallback` でレンダーコールバックを登録
5. `AudioUnitInitialize` → `AudioOutputUnitStart`

**デバイス設定の後にフォーマットを設定する**こと。順序が逆だと意図通りにならない。

## 変換が働いているかの確認

初期化後に両スコープのフォーマットを読み戻すと確認できる。

```
input format after init: 2ch @ 48000.0Hz
output (device) format:   2ch @ 44100.0Hz
render callback pulled 383966 frames in 8.00s = 47968 Hz
```

デバイスが 44100 でもレンダーコールバックは 48000 で要求してくる。
これが変換が働いている証拠。**実測すること** — 申告値だけ見ても分からない。

## 副次的な利点

変換を任せられるので、「インターリーブ Float32 で 2ch 以上」といった
入力フォーマットの制約をアプリ側に課す必要がなくなる。制約を課すと、
本来使えるデバイスを不必要に弾いてしまう。

## レンダーコールバックの実装上の注意

オーディオスレッドで走るため、メモリ確保・ロック・ブロッキング呼び出しは禁止。
ゲインはアトミックなテーブルから読み、音声はロックフリーのリングバッファから取る。

## 関連

- [[出力デバイスのサンプルレートを強制しない]]
- [[リングバッファの遅延管理]]
