---
title: コード署名と TCC 許可の失効
tags: [tcc, codesign, macos, workflow]
created: 2026-09-24
---

# コード署名と TCC 許可の失効

TCC の許可は**コード識別(cdhash)に紐付く**。ad-hoc 署名(`codesign --sign -`)は
ビルドごとに cdhash が変わるため、**再ビルドのたびに全ての許可が失効する**。

開発中は「直したはずなのに無音」の原因がこれであることが多い。

## 自己署名証明書で解消する

ローカルに code-signing 用の自己署名証明書を作れば識別が固定され、許可は一度で済む。
`scripts/create-signing-identity.sh` が該当する。

### macOS 固有の罠が2つある

1. **`extendedKeyUsage=codeSigning` が必須**
   これが無いと証明書は作成できても `codesign` が候補として提示しない。

2. **PKCS#12 はレガシーアルゴリズムで書き出す**
   現行 OpenSSL の既定値では Security フレームワークが受け付けず、
   誤解を招くエラーを返す。

   ```
   SecKeychainItemImport: MAC verification failed during PKCS12 import (wrong password?)
   ```

   パスワードは間違っていない。以下の指定が必要。

   ```
   -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1
   ```

   空パスワードも MAC 検証に引っかかるため、使い捨てのパスワードを設定する。

## 配布時

この証明書はこのマシンでのみ意味を持つ開発用の便宜であり、配布には
Developer ID 署名が必要。

## 関連

- [[TCC 権限 - オーディオキャプチャ]]
- [[TCC 責任プロセス]]
