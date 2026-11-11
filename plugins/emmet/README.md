# Emmet

短い記法を Tab で展開するプラグインです。

## 使い方

HTML（`html` `vue` `svelte` `php` `jsx` `tsx` など）と CSS（`css` `scss` `sass` `less`）で使えます。

| 入力 | 結果 |
|---|---|
| `ul>li*3` | リストと項目3つ |
| `div#main.box>p{本文}` | id・class・文字付きの要素 |
| `li.item$*2` | 連番 `item1` `item2` |
| `(header>nav)+main` | グループ |
| `!` | HTML の雛形 |
| `m10-20` | `margin: 10px 20px;` |
| `df` | `display: flex;` |
| `c#333` | `color: #333333;` |

Snippets のトリガーや補完候補がある場合は、そちらを優先します。

## 更新履歴

### v1.3

- プラグイン API 3（apiVersion 3）への対応

### v1.2

- プラグイン API 2（apiVersion 2）への対応
- プラグインフィードのカテゴリ「編集」の追加

### v1.1

- プラグイン API 1（apiVersion 1）への対応
- 配布ファイルのハッシュと署名による改ざんの確認に対応

### v1.0

- 初版
