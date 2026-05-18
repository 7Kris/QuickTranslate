---
name: release-preflight
description: リリース前の動作確認用に、Developer ID Application で署名 + Hardened Runtime 有効の Release ビルドを `/Applications/QuickTranslate.app` に置き換える。公証 (notarize) はしない。ユーザーが「リリース前に動作確認したい」「署名付きで /Applications/ に入れて試したい」「本番に近い状態でローカル検証」「Developer ID 署名のまま試す」「証明書周りいい感じにして /Applications/ に入れて」などと言ったらこのスキルを使う。`make install` のような ad-hoc 署名での開発イテレーションとは別物。実際の配布 (公証込み GitHub Release) は `release-mac-app` を使う。
---

# QuickTranslate リリース前プレビューインストール

公証前の Developer ID 署名 + Hardened Runtime な Release ビルドをローカルの `/Applications/` に入れ、本番に近い状態で挙動を確認するためのフロー。

## なぜ専用フローにしているか

- `make install` (project.yml の postBuildScript 経由) は ad-hoc 署名で済ませる開発用フロー。Hardened Runtime + Developer ID 署名でないと再現しない権限挙動 (CGEventTap、Pasteboard 周り) があるので、リリース前確認には別フローが必要。
- `release-mac-app` はフル配布 (公証 + zip + GitHub Release) まで走るので、ローカル確認だけしたいときには重く、また公証はコストが掛かる。
- このスキルはその中間: 「Developer ID 署名 + Hardened Runtime までやって `/Applications/` に置く」だけ。

## 重要な落とし穴

**project.yml の postBuildScript は署名前の `.app` を `/Applications/` にコピーしてしまう。** Xcode のビルドフェーズ順は (1) コンパイル/リンク → (2) postBuildScripts → (3) コード署名 なので、postBuildScript の `cp -R` が走った時点では署名されていない。

このフローでは **postBuildScript の結果は信用せず、ビルド完了後に `build/Release/QuickTranslate.app` (こちらは署名済み) を改めて `/Applications/` へコピーし直す** こと。`codesign --verify` をかけて確認するまで「インストール完了」と言わない。

## 手順

### 1. 前提確認

Developer ID Application 証明書がキーチェーンにあること。以下のコマンドの `<NAME>` (例: `Kentaro Matsumae`) と `<TEAMID>` (例: `D9UCJ653YY`) を**自分の identity と Team ID に置き換えて**実行する。本スキル内のサンプルコマンドに含まれる `<NAME>` / `<TEAMID>` も同様に置き換えること。

```bash
security find-identity -v -p codesigning | grep "Developer ID Application: <NAME> (<TEAMID>)"
```

リリース前確認なので、検証したいコミットが HEAD にある状態で行う。

### 2. 起動中インスタンスを停止

```bash
osascript -e 'tell application "QuickTranslate" to quit' 2>/dev/null
sleep 1
pkill -x QuickTranslate 2>/dev/null
```

### 3. 既存の `/Applications/QuickTranslate.app` を削除

`cp -R` の中途半端なマージで古いファイルが残らないように。

```bash
rm -rf /Applications/QuickTranslate.app
```

### 4. Developer ID 署名 + Hardened Runtime + Timestamp でビルド

project.yml は `ENABLE_HARDENED_RUNTIME: NO` なのでコマンドラインで上書きする。

```bash
xcodebuild -project QuickTranslate.xcodeproj \
           -scheme QuickTranslate \
           -configuration Release \
           CODE_SIGN_STYLE=Manual \
           CODE_SIGN_IDENTITY="Developer ID Application: <NAME> (<TEAMID>)" \
           DEVELOPMENT_TEAM=<TEAMID> \
           ENABLE_HARDENED_RUNTIME=YES \
           OTHER_CODE_SIGN_FLAGS="--timestamp --options=runtime" \
           CONFIGURATION_BUILD_DIR="$(pwd)/build/Release"
```

成功すれば `build/Release/QuickTranslate.app` が署名済みで出来上がる。

### 5. 署名済み `.app` を `/Applications/` に再コピー

postBuildScript で入った未署名版を上書きする (落とし穴対応)。

```bash
rm -rf /Applications/QuickTranslate.app
cp -R build/Release/QuickTranslate.app /Applications/
```

### 6. 署名検証

```bash
codesign --verify --deep --strict --verbose=2 /Applications/QuickTranslate.app
codesign -dv /Applications/QuickTranslate.app 2>&1 | head -12
```

期待値:
- `valid on disk` / `satisfies its Designated Requirement`
- `flags=0x10000(runtime)` (Hardened Runtime 有効)
- `TeamIdentifier=<TEAMID>` (自分の Team ID と一致する)
- `Timestamp=...` が入っている (Apple のタイムスタンプサーバーが応答した証拠)

`spctl -a -vv /Applications/QuickTranslate.app` は **公証してないので `rejected, source=Unnotarized Developer ID` が出る** が、これは想定どおり。ローカルでは隔離属性 (`com.apple.quarantine`) が付かないので普通に起動できる。

### 7. 起動

```bash
open /Applications/QuickTranslate.app
sleep 2
pgrep -x QuickTranslate
```

### 8. 動作確認のポイント

- 初回はアクセシビリティ権限の付与が必要 (Hardened Runtime とは独立の CGEventTap の都合)
- グローバルショートカット (現状: `Cmd+C` ダブルタップ → 翻訳ウインドウ)
- 単発 `Cmd+C` が普通のコピーとしてそのまま動くこと (Safari の `Cmd+D` 衝突問題で対処済み)
- Apple Translation 言語パック未インストール時のエラー表示
- Hardened Runtime 起因の権限/エンタイトルメント不足が出ないか (CGEventTap、NSPasteboard アクセスなど)

## 想定外が起きたとき

- **署名失敗**: 証明書の有効期限切れ、キーチェーンのアクセス権、Team ID の不一致を疑う。
- **ビルド成功するのに `codesign --verify` が失敗**: ステップ 5 の再コピーを忘れて未署名版を見ている可能性。あるいは DerivedData のキャッシュ汚染 → `rm -rf ~/Library/Developer/Xcode/DerivedData/QuickTranslate-*` でクリーン。
- **起動しない / 即終了**: Console.app で `QuickTranslate` の crash log、もしくは `~/Library/Logs/DiagnosticReports/` を確認。Hardened Runtime + entitlements 不足が典型。
- **アクセシビリティ権限ダイアログが出ない**: TCC データベースに古い bundle 情報が残っているケース。`tccutil reset Accessibility net.kenmaz.QuickTranslate` でリセット。

確認が完了して問題なければ、本番配布は `release-mac-app` のフローへ。
