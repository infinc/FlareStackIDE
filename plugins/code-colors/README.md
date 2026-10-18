# Code Colors

開いているファイルのコードに、言語に合わせた色をつけるプラグインです。キーワード・文字列・数値・コメント・型・関数名・タグ・属性などを色分けします。

## 使い方

1. このプラグインをインストールします
2. 対応しているファイルを開くと、自動で色がつきます
3. 編集中も入力に合わせて色が更新されます

背景が暗いときは暗い背景用の配色に、明るいときは明るい背景用の配色に自動で切り替わります。

## 対応している言語

| 言語 | 拡張子・ファイル名 |
|---|---|
| HTML | `.html` `.htm` `.xhtml` `.vue` `.svelte`（`<script>` / `<style>` の中も色分け） |
| XML | `.xml` `.svg` `.plist` `.xsd` `.xsl` `.rss` `.atom` `.storyboard` `.xib` |
| CSS | `.css` |
| SCSS / Sass / Less | `.scss` `.sass` `.less` |
| JavaScript | `.js` `.mjs` `.cjs` `.jsx` |
| TypeScript | `.ts` `.tsx` `.mts` `.cts` |
| JSON | `.json` `.jsonc` `.json5` `.geojson` `.babelrc` `.prettierrc` `.eslintrc` |
| Python | `.py` `.pyw` `.pyi` |
| Java | `.java` |
| Kotlin | `.kt` `.kts` |
| Swift | `.swift` |
| C | `.c` `.h` |
| C++ | `.cpp` `.cc` `.cxx` `.hpp` `.hh` `.hxx` `.ino` |
| Objective-C | `.m` `.mm` |
| C# | `.cs` |
| Go | `.go` |
| Rust | `.rs` |
| Dart | `.dart` |
| Ruby | `.rb` `.rake` `.gemspec` `Gemfile` `Rakefile` `Podfile` |
| PHP | `.php` |
| Lua | `.lua` |
| シェルスクリプト | `.sh` `.bash` `.zsh` `.ksh` `.bashrc` `.zshrc` `.profile` `.bash_profile` `.zprofile` |
| SQL | `.sql` |
| YAML | `.yaml` `.yml` |
| TOML | `.toml` |
| INI / 設定ファイル | `.ini` `.cfg` `.conf` `.properties` `.env` `.gitconfig` `.editorconfig` |
| Markdown | `.md` `.markdown` `.mdown` `.mkd`（コードブロックは指定した言語で色分け） |
| Dockerfile | `Dockerfile` |
| Makefile | `Makefile` `.mk` |

## 色分けの種類

- キーワード（`if` `class` `return` など）
- 文字列、数値、定数（`true` `null` など）
- コメント
- 型名、関数名、変数
- HTML / XML のタグ・属性
- Markdown の見出し・強調・リンク・コード・リスト記号
