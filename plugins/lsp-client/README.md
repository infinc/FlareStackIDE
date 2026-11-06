# LSP Client

Language Server Protocol（LSP）の言語サーバーとつないで、コードの意味を理解した機能を使えるようにするプラグインです。

## 対応している言語と準備

使う言語の言語サーバーをインストールしてください（同じ行に複数あるときは左から順に探します）。

| 言語 | 拡張子 | 言語サーバー | インストールの例 |
|---|---|---|---|
| Python | `.py` `.pyi` `.pyw` | Pyright / basedpyright / python-lsp-server | `pip install pyright` |
| TypeScript / JavaScript | `.ts` `.tsx` `.mts` `.cts` `.js` `.jsx` `.mjs` `.cjs` | typescript-language-server | `npm install -g typescript typescript-language-server` |
| Swift | `.swift` | sourcekit-lsp | Xcode か `xcode-select --install` |
| Rust | `.rs` | rust-analyzer | `rustup component add rust-analyzer` |
| Go | `.go` | gopls | `go install golang.org/x/tools/gopls@latest` |
| C / C++ / Objective-C | `.c` `.h` `.cpp` `.cc` `.cxx` `.hpp` `.hh` `.hxx` `.m` `.mm` | clangd | Xcode か `xcode-select --install` |
| Ruby | `.rb` `.rake` | ruby-lsp / solargraph | `gem install ruby-lsp` |
| PHP | `.php` | intelephense / phpactor | `npm install -g intelephense` |
| シェルスクリプト | `.sh` `.bash` | bash-language-server | `npm install -g bash-language-server` |
| Lua | `.lua` | lua-language-server | `brew install lua-language-server` |

ログインシェル（zsh）の `PATH` から探すので、ターミナルで使えるコマンドならそのまま動きます。見つからないときは、言語ごとに一度だけ通知します。別のコマンドを使うときは、設定の「（言語）のコマンド」に書いてください（例: `/opt/homebrew/bin/pyright-langserver --stdio`）。

## できること

| 機能 | 操作 |
|---|---|
| 診断 | エラーと警告に波線を引きます |
| ホバー | 名前の上でマウスを1秒止めると、型や説明を表示します（診断があれば一緒に出します） |
| 定義へ移動 | F12 か ⌘クリック。別のファイルなら開きます |
| 参照を検索 | ⇧F12。一覧から選ぶとその場所へ移動します |
| 名前の変更 | F2。プロジェクト全体の該当箇所を書き換えます。通知の「元に戻す」で戻せます |
| 補完 | Interpolate Variable プラグインが入っていれば、言語サーバーの候補を先頭に出します |

どの操作もコマンドパレット（⌘⇧P）の「LSP: …」から実行でき、Shortcut プラグインでキーを割り当てることもできます。「LSP: 言語サーバーを再起動」でサーバーを起動し直せます。

言語サーバーはプロジェクトと言語の組ごとに1つ起動し、そのプロジェクトのウィンドウをすべて閉じると終了します。

## Code Scanner と一緒に使うとき

両方入れても競合しないようにしています。

- 波線・右上の数・問題フィード・ミニマップの印は Code Scanner がまとめて表示します（問題フィードには出元の `Pyright` などが付きます）
- 言語サーバーが動いているファイルでは、Code Scanner の外部ツールによる検査（`python3` の構文チェックなど）を止め、同じエラーが二重に出ないようにします。全角スペースやマージ競合の印など、Code Scanner だけが見つけるものは引き続き表示します
- ホバーのポップアップは1つにまとめ、言語サーバーの診断と型の情報を一緒に出します
- どちらかを外すと、残った方だけで元どおりに動きます
