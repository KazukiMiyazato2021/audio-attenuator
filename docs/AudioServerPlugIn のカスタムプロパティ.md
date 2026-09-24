---
title: AudioServerPlugIn のカスタムプロパティ
tags: [core-audio, audioserverplugin, driver]
created: 2026-09-24
---

# AudioServerPlugIn のカスタムプロパティ

自作のミキサーから自作のドライバへ値を渡したい、という一見単純な要求に対して
3つの仕様が順に立ちはだかる。

## 1. 標準プロパティは書き込めない

HAL は `kAudioDevicePropertyLatency` のような読み取り専用プロパティへの
クライアント書き込みを、**ドライバへ届く前に**拒否する。

```
status 1852797029 = 'nope' (kAudioHardwareIllegalOperationError)
```

ドライバ側の `IsPropertySettable` で `true` を返しても無関係に拒否される。
よって独自のセレクタが必要になる。

## 2. 独自セレクタは宣言しないと転送されない

独自セレクタを定義してドライバ側で処理を書いても、それだけでは届かない。

```
status 2003332927 = 'who?' (kAudioHardwareUnknownPropertyError)
```

`AudioObjectHasProperty` ですら `false` を返す。HAL が知らないセレクタを
そもそもドライバへ問い合わせないため。

ドライバが `kAudioObjectPropertyCustomPropertyInfoList` (`'cust'`) を実装し、
`AudioServerPlugInCustomPropertyInfo` の配列として**自分が持つカスタムプロパティを
宣言する**必要がある。

```c
info->mSelector = kAttenuatorProperty_DownstreamLatency;  // 'atls'
info->mPropertyDataType  = kAudioServerPlugInCustomPropertyDataTypeCFPropertyList;
info->mQualifierDataType = kAudioServerPlugInCustomPropertyDataTypeNone;
```

## 3. 運べる型は2つだけ

`AudioServerPlugInCustomPropertyDataType` は以下しかない。

| 定数 | 型 |
|---|---|
| `kAudioServerPlugInCustomPropertyDataTypeNone` | なし |
| `kAudioServerPlugInCustomPropertyDataTypeCFString` | `CFStringRef` |
| `kAudioServerPlugInCustomPropertyDataTypeCFPropertyList` | `CFPropertyListRef` |

**`UInt32` をそのまま渡すことはできない。** フレーム数のような数値も
`CFNumber` に包んで `CFPropertyList` として渡す。

Get 側で `CFNumberCreate` したものを返す場合、解放責任は呼び出し側にある。

## 段階的に確認する

3つの障壁は順番に現れるため、`AudioObjectHasProperty` が `true` を返すか、
Set が `status 0` を返すか、読み戻せるかを一段ずつ確認すると早い。

## 関連

- [[仮想デバイスの遅延申告]]
- [[AudioServerPlugIn の変更通知]]
