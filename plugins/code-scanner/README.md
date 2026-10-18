# Code Scanner

主要な言語のエラーと警告を、入力しながらリアルタイムで表示するプラグインです。

## 使い方

1. このプラグインをインストールします
2. ファイルを開くと、編集画面の右上に赤い ! (エラー数) と黄色い ⚠ (警告数) が表示されます
3. 数字を押すと、下のフィードに問題の一覧（内容・コード・ファイル名・行）が表示されます
4. 一覧の行を押すと、そのコードの位置に移動します

コード内のエラーは赤い文字と赤い波線、警告は黄色い波線で表示されます。波線の上にマウスを重ねると内容が表示されます。

## 対応している言語

| 言語 | 使うツール |
|---|---|
| Python | python3（構文エラー、SyntaxWarning、未使用の import） |
| JavaScript | node --check |
| Swift | swiftc -parse |
| C / C++ / Objective-C | clang -fsyntax-only |
| Go | gofmt -e |
| Ruby | ruby -wc |
| Shell (bash / zsh) | bash -n / zsh -n |
| PHP | php -l |
| Perl | perl -wc |
| Lua | luac -p |
| JSON / JSONC | プラグイン内で検査 |

ツールがインストールされていない言語は検査しません。
