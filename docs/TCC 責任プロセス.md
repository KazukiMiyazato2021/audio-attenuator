---
title: TCC 責任プロセス
tags: [tcc, macos, launchd, gotcha]
created: 2026-09-24
---

# TCC 責任プロセス

**TCC は API を呼び出したプロセスの権限を見ない。「責任プロセス
(responsible process)」の権限を見る。**

ターミナルから起動したものは、何であれ**ターミナルが責任プロセス**になる。
この一点の理解に最も時間を要した。

## 症状

ターミナルからエージェントを起動すると、ログはこうなる。

```
AUTHREQ_ATTRIBUTION: responsible={identifier=com.mitchellh.ghostty ...},
                     accessing={identifier=com.audioattenuator.agent ...}
AUTHREQ_PROMPTING: service=kTCCServiceAudioCapture, subject=Sub:{com.mitchellh.ghostty}
Refusing authorization request ... without NSAudioCaptureUsageDescription key
AUTHREQ_RESULT: authValue=0, authReason=8
```

アプリは `accessing` として正しく識別されている。しかし権限の照会先は
ターミナルであり、ターミナルには該当の usage description が無いため、macOS は
プロンプトを出すことすら拒否する。

**システム設定で対象アプリに許可を与えても解決しない。** 問われているのは
ターミナルの権限だから。

## `open -a` では解決しない

LaunchServices も呼び出し元のターミナルを責任プロセスとして扱う。

## launchd から起動すれば解決する

launchd が起動したプロセスは**自分自身が責任プロセス**になるため、対象アプリに
与えた許可がそのまま適用される。

したがって `launchd/com.audioattenuator.agent.plist` は単なる自動起動の利便性
ではなく、**タップが機能するための必須要素**である。

## 検証時の含意

普段使いの経路(パッケージ化した .app + launchd 起動)で確認しない限り、
この問題は表面化しない。CLI で通る = 動く、ではない。
→ [[オーディオ検証の落とし穴]]

## 関連

- [[TCC 権限 - オーディオキャプチャ]]
- [[コード署名と TCC 許可の失効]]
