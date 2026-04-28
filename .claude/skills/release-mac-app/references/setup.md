# 初回セットアップ

QuickTranslate を **公証付きで GitHub Releases に公開する** ために、ユーザーが事前に揃えておくものを整理する。Claude が代行できない (人手の操作が必須な) ものが多いので、未整備なら順番に案内すること。

## 1. Apple Developer Program のメンバーシップ

- 年額 $99 / Apple ID にひもづく
- 「Developer ID Application」証明書を発行できる権利が必要
- 個人/組織どちらでも可

確認: https://developer.apple.com/account/ で「Membership」が Active

## 2. Developer ID Application 証明書

ローカル Keychain に「Developer ID Application: <名前> (<TEAM_ID>)」が入っている状態にする。

```bash
security find-identity -v -p codesigning | grep "Developer ID Application"
```

これが空 → 未取得。手順:

1. Xcode を開く
2. Settings > Accounts > Apple ID 追加
3. チームを選び **Manage Certificates...** → 左下 + → **Developer ID Application** を発行
4. 自動で Keychain に入る

または `developer.apple.com/account/resources/certificates` から CSR を出して手動発行も可。

## 3. App-specific password (公証用)

`notarytool` で Apple ID 経由認証する際に使う。Apple ID のパスワードは使えない。

1. https://account.apple.com/account/manage に行き **App用パスワード** を発行
2. ラベルは何でも可 (例: `notarytool quicktranslate`)
3. 発行されたパスワードを **その場でコピー** (二度と表示されない)

## 4. Team ID の確認

Apple Developer サイトの Membership ページにある10桁英数字。または:

```bash
security find-identity -v -p codesigning | grep "Developer ID Application"
# 例: "Developer ID Application: 〇〇 (WF2DT668RS)" → WF2DT668RS が Team ID
```

## 5. notarytool の Keychain プロファイル登録

毎回 Apple ID とパスワードを入れずに済むよう、Keychain にプロファイル保存する。プロファイル名は任意 (例 `notarytool-quicktranslate`)。

```bash
xcrun notarytool store-credentials notarytool-quicktranslate \
  --apple-id "<your-apple-id@example.com>" \
  --team-id "<TEAM_ID>" \
  --password "<app-specific-password>"
```

確認:

```bash
xcrun notarytool history --keychain-profile notarytool-quicktranslate
```

エラーにならず履歴 (空でも OK) が出れば成功。

## 6. gh CLI の認証

```bash
gh auth status
# 未認証なら
gh auth login
```

`gh release create` できるスコープ (repo) が必要。

## 7. xcodegen のインストール

```bash
brew install xcodegen
```

(本プロジェクトは Sources のファイル追加削除が xcodegen 経由で `.xcodeproj` に反映される構成)

## 8. config.local.json の作成

スキルが値を毎回聞かずに済むよう、以下を作成 (gitignore 対象):

```bash
cat > .claude/skills/release-mac-app/config.local.json <<'EOF'
{
  "team_id": "WF2DT668RS",
  "notary_profile": "notarytool-quicktranslate",
  "signing_identity": "Developer ID Application: Kentaro Matsumae (WF2DT668RS)"
}
EOF
```

`.gitignore` への追加:

```
.claude/skills/release-mac-app/config.local.json
```

## セットアップ完了の確認

下記が全て pass すれば、メインフローを実行可能:

```bash
# 1. 証明書
security find-identity -v -p codesigning | grep "Developer ID Application" && echo OK

# 2. notarytool プロファイル
xcrun notarytool history --keychain-profile notarytool-quicktranslate >/dev/null 2>&1 && echo OK

# 3. gh
gh auth status >/dev/null 2>&1 && echo OK

# 4. xcodegen
which xcodegen >/dev/null && echo OK

# 5. config.local.json
test -f .claude/skills/release-mac-app/config.local.json && echo OK
```
