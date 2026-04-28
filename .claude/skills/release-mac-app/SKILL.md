---
name: release-mac-app
description: QuickTranslate を macOS アプリとして GitHub Releases に公開する。バージョン自動バンプ、Developer ID 署名、Apple 公証、git tag、`gh release create` までを一気通貫で行う。ユーザーが「リリース」「新バージョンを出す」「公開する」「release」「タグを打って配布」「GitHub Releases に上げる」「公証して配布」などと言ったら、たとえ手順を全て指定していなくてもこのスキルを使うこと。`make install` のようなローカル配置とは別物 (これは外部配布のためのフロー) なので、混同せず外部配布の意図が読み取れたら必ずこのスキルで対応する。
---

# QuickTranslate リリーススキル

GitHub Releases へ Developer ID 署名 + Apple 公証済みの `.app` を zip で配布するワークフロー。

## このスキルがやること

1. 前提条件の確認 (証明書、ツール、作業ツリーの状態)
2. semver でのバージョン推定 → ユーザー承認
3. `project.yml` / `Info.plist` のバージョン更新と `xcodegen` 再生成
4. `xcodebuild archive` → `exportArchive` で署名済み `.app` を作成
5. `notarytool` で Apple 公証 → `stapler` で staple
6. zip 化、`git commit` → `git tag` → `git push`
7. `gh release create` で zip をアセット添付して公開

各ステップで失敗したら止まり、ユーザーに状況を伝えて指示を仰ぐ。中断点で人間の確認を入れるのは、リリースは取り消しが効きにくいから。

## 重要なガード

- **作業ツリーがクリーンでなければ実行しない**。release コミットの差分が混ざると後追い不能になる。
- **main ブランチ以外では実行しない**。事故防止。`git rev-parse --abbrev-ref HEAD` で確認。
- **`origin` と同期済みであること**。`git fetch && git status -uno` で `up to date` を確認。
- **タグの重複チェック**。`git rev-parse vX.Y.Z 2>/dev/null` が空でなければ衝突。
- **`gh release create` と `git push --tags` は必ずユーザーの最終承認後**。push してしまうと巻き戻しは可能だが他者から見える。
- 何か想定外 (権限拒否、署名失敗、公証拒否) が起きたら、フローを止め、推測で代替手段に走らず、状況を要約してユーザーに判断を仰ぐ。

## 初回セットアップが終わっているか

スキル実行前に **`references/setup.md` の前提条件 (Developer ID Application 証明書、`notarytool` keychain プロファイル、`gh` 認証) を満たしているか** を必ず確認すること。`security find-identity -v -p codesigning` に `Developer ID Application` が出ない、`xcrun notarytool history --keychain-profile <profile>` がエラーになる、などで未整備なら、**勝手に進めず `references/setup.md` を読ませて初回セットアップを促す**。

未セットアップの兆候を見たら一度フローを止めること。署名なし配布や ad-hoc 署名で誤魔化すと、最終配布物のユーザーが Gatekeeper でブロックされて意味がなくなる。

## ステップ詳細

### 1. 前提チェック

並列で以下を確認する:

```bash
# ブランチと作業ツリー
git rev-parse --abbrev-ref HEAD                              # main であること
git status --porcelain                                       # 空であること
git fetch origin && git status -uno                          # up to date であること

# ツール
which xcodegen gh xcrun
xcrun --find notarytool

# 証明書
security find-identity -v -p codesigning | grep "Developer ID Application"

# notarytool keychain プロファイル (ユーザー初回設定時の名称を尊重。デフォルトは `notarytool-quicktranslate` を提案)
xcrun notarytool history --keychain-profile notarytool-quicktranslate 2>&1 | head -5
```

どれかが欠けている → `references/setup.md` を案内して停止。

### 2. バージョン推定 (semver 自動バンプ)

直近タグからの commit メッセージを使ってバンプ種別を提案する。タグが無い (初回リリース) 場合は `1.0.0` を提案。

```bash
LAST_TAG=$(git describe --tags --abbrev=0 2>/dev/null || echo "")
if [ -z "$LAST_TAG" ]; then
  RANGE=""
else
  RANGE="$LAST_TAG..HEAD"
fi
git log --pretty=%s $RANGE
```

ヒューリスティック (Conventional Commits ではないので緩めに):

| 兆候 | バンプ |
|------|--------|
| `BREAKING`, `Breaking`, `breaking change`, メジャー機能撤去/再構築 | major |
| `Add`, `Implement`, `Introduce`, `Support` で始まる新機能、`feat:` | minor |
| `Fix`, `Bugfix`, `Correct`, `Resolve`, `fix:`、文言/挙動修正のみ | patch |
| `Refactor`, `Cleanup`, `Remove dead`, `chore:`、コードのみで挙動変化なし | patch |

**ユーザー承認を必ず取ること**。「直近のコミット (最大10件) からは X.Y.Z (理由: ...) を提案します。これで進めますか？」と聞く。ユーザーが別のバージョンを指定したらそれに従う。

### 3. バージョン適用と xcodeproj 再生成

`project.yml` の `info.properties` 配下と `SupportingFiles/Info.plist` の **両方** を更新する (xcodegen が後者を上書きするが、競合避けのため source も合わせる)。

- `CFBundleShortVersionString`: 新バージョン (例: `"1.1.0"`)
- `CFBundleVersion`: 直前から +1 した整数値 (例: `"1"` → `"2"`)

更新後:

```bash
xcodegen generate
```

### 4. archive と export

Hardened Runtime を有効化して archive する。`project.yml` には `ENABLE_HARDENED_RUNTIME: NO` と書かれているが、リリース時はコマンドライン上書きで `YES` にして archive する (普段の開発体験を壊さないため)。

```bash
BUILD_DIR=build/release
ARCHIVE_PATH=$BUILD_DIR/QuickTranslate.xcarchive
EXPORT_PATH=$BUILD_DIR/export

mkdir -p $BUILD_DIR

xcodebuild \
  -project QuickTranslate.xcodeproj \
  -scheme QuickTranslate \
  -configuration Release \
  -archivePath $ARCHIVE_PATH \
  ENABLE_HARDENED_RUNTIME=YES \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="Developer ID Application" \
  DEVELOPMENT_TEAM=<TEAM_ID> \
  archive
```

`<TEAM_ID>` は `security find-identity -v -p codesigning | grep "Developer ID Application"` で出る括弧内 (例: `WF2DT668RS`) を埋める。または初回セットアップで `.claude/skills/release-mac-app/.team_id` などに書き留めた値を使う (gitignore 対象。後述)。

ExportOptions.plist は `references/ExportOptions.plist` を使う。値は固定でよい。

```bash
xcodebuild -exportArchive \
  -archivePath $ARCHIVE_PATH \
  -exportPath $EXPORT_PATH \
  -exportOptionsPlist .claude/skills/release-mac-app/references/ExportOptions.plist
```

成功したら `$EXPORT_PATH/QuickTranslate.app` ができている。

### 5. 公証 (notarization)

公証は `.app` 単体では submit できない。zip にしてから submit する。staple は `.app` に直接行う。

```bash
SUBMIT_ZIP=$BUILD_DIR/QuickTranslate-submit.zip
ditto -c -k --keepParent $EXPORT_PATH/QuickTranslate.app $SUBMIT_ZIP

xcrun notarytool submit $SUBMIT_ZIP \
  --keychain-profile notarytool-quicktranslate \
  --wait
```

`--wait` で完了まで待つ。`status: Accepted` を確認する。`Invalid` の場合は `xcrun notarytool log <submission-id> --keychain-profile notarytool-quicktranslate` でログを取得し、ユーザーに見せる (推測修正は禁止)。

成功したら staple:

```bash
xcrun stapler staple $EXPORT_PATH/QuickTranslate.app
xcrun stapler validate $EXPORT_PATH/QuickTranslate.app
spctl --assess --type execute -vv $EXPORT_PATH/QuickTranslate.app
```

`spctl` が `accepted` かつ `source=Notarized Developer ID` であれば成功。

### 6. 配布用 zip

公証済み `.app` を **改めて** zip し直す (submit 用 zip とは別物)。配布用は staple 後の `.app` を含める必要があるため。

```bash
RELEASE_ZIP=$BUILD_DIR/QuickTranslate-v$VERSION.zip
ditto -c -k --keepParent $EXPORT_PATH/QuickTranslate.app $RELEASE_ZIP
```

### 7. コミット & タグ

`project.yml` と `Info.plist` のバージョン差分のみをコミットする。`build/` は `.gitignore` 対象であること (含まれていなければ追加を提案)。

```bash
git add project.yml SupportingFiles/Info.plist
git diff --cached
```

差分を見せ、ユーザーに「コミットしてタグを打ってよいか」を確認してから:

```bash
git commit -m "Release v$VERSION

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude <noreply@anthropic.com>"

git tag -a v$VERSION -m "v$VERSION"
```

push もユーザー承認後:

```bash
git push origin main
git push origin v$VERSION
```

### 8. GitHub Release 作成

リリースノートは直近タグからの commit リストを元に下書きし、ユーザーに提示してから `gh release create` する。プレリリース判定: バージョンに `-rc`, `-beta`, `-alpha` が含まれていれば `--prerelease` を付ける。

```bash
gh release create v$VERSION \
  --title "v$VERSION" \
  --notes-file <(printf "## 変更点\n\n%s\n" "$(git log --pretty='- %s' $LAST_TAG..HEAD^)") \
  $RELEASE_ZIP
```

(`$LAST_TAG..HEAD^` で release コミット自身を除外する)

成功したら URL を表示し、ユーザーに知らせる。

## 失敗時の対処

- **archive 失敗 (証明書周り)**: `references/setup.md` の証明書セクションを再確認。プロビジョニングプロファイル不要 (Developer ID は Direct Distribution)。
- **公証 Invalid**: `notarytool log` でログ取得 → ユーザーに見せる。よくある原因は Hardened Runtime 未設定、`com.apple.security.cs.*` entitlements 不足、未署名のフレームワーク同梱など。憶測で entitlements を追加せず、ログに従う。
- **`spctl --assess` で reject**: staple し忘れ、または公証されていない。staple validate からやり直し。
- **`gh release create` 失敗**: `gh auth status` を確認。タグだけ先に push 済みなら、`gh release create` だけリトライで OK。

## 設定値 (gitignore する個人情報)

`DEVELOPMENT_TEAM` (Team ID) や notarytool keychain プロファイル名はユーザーごとに違う。`.claude/skills/release-mac-app/config.local.json` (gitignore 対象) に保存しておくとよい:

```json
{
  "team_id": "WF2DT668RS",
  "notary_profile": "notarytool-quicktranslate",
  "signing_identity": "Developer ID Application: Kentaro Matsumae (WF2DT668RS)"
}
```

スキル実行時、このファイルがあれば値を読み出して使う。なければ初回設定を `references/setup.md` 通りに案内する。`.gitignore` に `.claude/skills/release-mac-app/config.local.json` の行を入れること。
