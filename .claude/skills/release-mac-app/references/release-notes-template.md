# リリースノートテンプレート

`gh release create --notes-file` に渡す内容。プレースホルダ `{{...}}` を埋めて使う。

## 初回リリース (v1.0.0 など、git tag がまだ無いケース)

```markdown
## QuickTranslate v{{VERSION}} — 初回リリース

macOS メニューバー常駐型の翻訳アプリ。Apple Translation API を使った日本語⇔英語のオンデバイス翻訳を、グローバルショートカット (⌘⇧T) でどこからでも起動できます。

### 主な機能

{{FEATURES_BULLET_LIST}}

### システム要件

- macOS {{MIN_OS}} 以降
- 初回起動時に必要:
  - アクセシビリティ権限の許可
  - Translation 言語パックのダウンロード (システム設定 > 一般 > 言語と地域 > 翻訳言語)

### 配布物

`QuickTranslate-v{{VERSION}}.zip` — Developer ID 署名 + Apple 公証済み
```

`{{FEATURES_BULLET_LIST}}` は `git log --pretty='- %s'` の結果ではなく、ユーザー向けの機能列に整形する。例:

- グローバルショートカット (⌘⇧T) でクリップボードのテキストを翻訳
- 日本語/英語の自動言語判定 + 手動切り替えピッカー
- 縦/横スプリット切り替え
- ⌘Enter で翻訳、⇧⌘Enter で入れ替え+翻訳
- フォントサイズスライダー
- メニューバー常駐 (Dock 非表示)

ソースコードや README から拾って書く (`SwiftUI` とか実装詳細ではなく、ユーザーが嬉しい単位)。

## 2 回目以降のリリース

```markdown
## QuickTranslate v{{VERSION}}

### 変更点

{{CHANGES_BULLET_LIST}}

### システム要件

- macOS {{MIN_OS}} 以降

### 配布物

`QuickTranslate-v{{VERSION}}.zip` — Developer ID 署名 + Apple 公証済み

**Full Changelog**: https://github.com/{{REPO}}/compare/{{LAST_TAG}}...v{{VERSION}}
```

`{{CHANGES_BULLET_LIST}}` の作り方:

```bash
LAST_TAG=$(git describe --tags --abbrev=0 HEAD~)  # release コミットの一個前のタグ
git log --pretty='- %s' $LAST_TAG..HEAD^          # release コミット自身は除外
```

その出力を **そのまま貼らずに**、ユーザー向けの言葉に直す。`Refactor`, `Cleanup`, `Bump dep`, `Fix typo` のような内部チェンジは省くか「内部改善」一行にまとめる。`Add ...`, `Implement ...`, `Fix bug ...` は積極的に含める。

`{{REPO}}` は `gh repo view --json nameWithOwner -q .nameWithOwner` で取得。
