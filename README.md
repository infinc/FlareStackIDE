# FlareStackIDE

軽量で使いやすい macOS 向けのテキストエディタ・IDE です。必要なものだけを、プラグインで足していくことができます。

## プレビュー

<img width="720" height="450" alt="Image" src="https://github.com/user-attachments/assets/cf1a92e7-252e-4ee8-af33-dca0800cdfab" />

<img width="720" height="450" alt="Image" src="https://github.com/user-attachments/assets/84850640-24e3-4fd7-9e04-54d7486eed55" />

<img width="720" height="450" alt="Image" src="https://github.com/user-attachments/assets/199f8a1d-7208-40e3-b58a-46947b6567d5" />

<img width="720" height="450" alt="Image" src="https://github.com/user-attachments/assets/0055468c-da19-4725-980a-a15eaf71ce5c" />

<img width="720" height="450" alt="Image" src="https://github.com/user-attachments/assets/cbad1453-0d75-4e71-93b0-1811adb19628" />

<img width="720" height="450" alt="Image" src="https://github.com/user-attachments/assets/70488b01-8557-4a72-8e8f-2322fe9ee9dd" />

<img width="720" height="450" alt="Image" src="https://github.com/user-attachments/assets/44015ffe-6af9-4954-900b-b69d9a781244" />

<img width="720" height="450" alt="Image" src="https://github.com/user-attachments/assets/90a98335-70f6-4996-b1ac-a54a21d08e73" />

## 主な機能

- ディレクトリツリー（ファイルの作成・削除をほぼリアルタイムで反映、Git の状態で色分け）
- ファイルタブ（持ち上げるようなアニメーションでドラッグして並べ替え）とコード編集画面（ほかのアプリでファイルが書き換えられると、その内容をすぐに画面へ反映）
- 分割画面（ファイルのタブやディレクトリを右クリック →「右に開く」で右側に2つ目の編集画面とタブ）
- 左の大タブ（アイコン列）は ⌘ を押しながらドラッグすると位置を変えられる（上下のグループをまたいで移動できる。順番は次に開いたときも保たれる）
- 上のバーの右側のボタン（保存・検索・歯車とプラグインのボタン）も ⌘ を押しながらドラッグで並べ替えられる
- ディレクトリのファイルやフォルダはドラッグで別のフォルダへ移動でき、移動時にリファクタリングするかを選べる。右クリックで新規ファイル・新規フォルダを作成
- 内蔵ターミナル（複数タブ、ドラッグで並べ替え、ダブルクリックで名前変更）
- プロジェクト内検索（上のバーの🔍、⇧⌘F、またはファイル編集画面で ⇧ を2回すばやく押す。ファイル名とコードの一致を表示し、押すとその行を開く）
- Git パネル（ブランチ・変更ファイル・全ブランチのコミット履歴をツリーで表示）と GitHub からのクローン
- 自動保存（即時 / 3・10・30・60 秒ごと / オフ）。上のバーのクラウドマークを押すとすぐに保存
- ボタンにカーソルを合わせると背景の色が変わる
- テーマ・背景色・フォント・ターミナルのカーソル・大タブの大きさの設定（初期画面と設定画面にも同じ配色を適用）
- 編集画面の大きさと全画面表示を記憶し、次にプロジェクトを開いたときも同じ大きさで開く
- プラグイン（オンラインのカタログからインストール・更新。フィードの上のボタンで全てインストール / 全てアンインストール、インストールが終わると右下に通知）

## ツリーの色

| 色 | 意味 |
|---|---|
| 緑 | 新しく追加したファイル（push するか、1日たつと白に戻る） |
| 水色 | 変更したファイル、または push していないコミットに含まれるファイル |
| オレンジ | Git で追跡していないファイル |

同じ色はファイル編集画面のタブの文字にも付きます。

## プラグイン

左のアイコン列のパズルボタンからインストールできます。歯車メニューの「プラグイン」で更新・削除・設定ができます。

| プラグイン | 内容 |
|---|---|
| MD Viewer | Markdown のプレビュー（表・画像にも対応、切替タブの色・透明・最小化・ボタンの位置を設定可。右の分割画面でも表示を切り替えられる） |
| Code Colors | 主要な言語のコードに色を付ける |
| Runner | 起動構成を作ってプログラムを実行（テンプレート・環境変数・パラメーター・.env に対応） |
| Code Scanner | エラー・警告を編集の1.5秒後に表示、文字列にカーソルを当てると概要を表示（Markdown・HTML・YAML・TOML なども検査。右の分割画面も検査） |
| Lines | 編集画面の左に行数を表示（列の幅・行間・色を設定可、設定画面でプレビュー。Bookmarks の印と Code Folding の開閉マークも表示） |
| Light Editer | ファイルだけを開く軽量エディタ |
| Web Feed | 下のフィードで Google などの Web ページをタブで開く |
| Picture/Video Viewer | 写真と動画をファイル編集画面で表示（サイズと解像度も表示、編集は不可） |
| PDF Viewer | PDF をファイル編集画面で表示（編集は不可） |
| Interpolate Code | カッコ・引用符・リスト記号・インデントを自動で補完 |
| Interpolate Variable | 入力中の変数名・モジュール名の候補を表示（Tab / Enter で補完） |
| File Tab Cleaner | タブの列の一番左にボタンを追加し、押すとタブをすべて閉じる（ファイルは消えない） |
| Shortcut | 好きなキーの組み合わせに「実行」「テーマ切り替え」「プロジェクトを保存して終了」を割り当てる |
| Terminal Copy | ターミナルで文字をドラッグして選択し、マウスを離すだけでコピー |
| Copy Manager | 上のバーにクリップのボタンを追加し、コピーした履歴から選んでもう一度コピー |
| Scroll Assistant | 編集画面の右にコード全体を小さく表示し、ドラッグでスクロール（Code Scanner のエラー行を赤、警告行を黄色、Bookmarks の行を青、Word Highlight の行を水色で表示） |
| Snippets | トリガーの単語と Tab で定型文を展開（自分のスニペットも登録可） |
| Code Folding | 関数やブロックを折りたたんで隠す（⌥⌘← / ⌥⌘→） |
| Bookmarks | 行に印を付けて、一覧や ⌥⌘↓ / ⌥⌘↑ で移動 |
| Git Actions | ステージ・コミット・push・pull・ブランチ切り替え・stash を GUI で操作 |
| Git Blame | カーソル行の作者・日付・コミットを行末に表示 |
| Multi Cursor | 同じ文字列を検索してハイライトし、まとめて変換（通知から元に戻せる） |
| Help Me | 上のバーに巻き戻し・やり直しのボタンを追加 |
| Sticky Scroll | 今いる関数やクラスの行を上端に固定 |
| Color Preview | 色の図・RGB・16進数で色を作り、値をコピー |
| CSV Viewer | CSV と TSV を表で表示して編集 |
| Emmet | `ul>li*3` のような短い記法を Tab で HTML や CSS に展開 |
| Word Highlight | クリックした語と同じ語の背景を強調 |
| Bracket Colorizer | 括弧を深さごとに色分けし、対応する括弧を強調（Code Colors の色に上書き） |
| Session Restore | 終了時に開いていたタブとカーソル位置を次に開いたときに復元 |
| Scratch Pad | 左の大タブにメモボタンを追加し、保存しない一時的なメモを左のフィードに表示 |

プラグインは `plugins/` にあり、`plugins/index.json` がカタログです。アプリ本体（dmg）にはプラグインのコードを含めず、インストールしたときだけ `plugins/<id>/` の Swift をコンパイルした `plugin.dylib` をダウンロードして読み込みます。プラグインを更新したときは、再起動すると新しいコードが反映されます。

## ビルド

Xcode のコマンドラインツール（`swiftc`）が必要です。

```bash
./build.sh
```

`build/FlareStackIDE.app` と `FlareStackIDE-<バージョン>.dmg` ができます。バージョンは `VERSION` で管理しています。

同時に `plugins/<id>/*.swift` を本体に合わせてコンパイルし、`plugins/<id>/plugin.dylib` を作ります（dmg には入りません）。本体を変更してビルドしたら、`plugin.dylib` も一緒にコミット・push してください。古い本体と組み合わさって読み込めないときは、アップデートを促す通知が出ます。

全プラグイン入りの dmg を作るときは次のコマンドを使います。カタログにないプラグインも含め、`plugins/` の全てが初回起動時にインストールされます。

```bash
./debug_build.sh
```

`FlareStackIDE-<バージョン>-debug.dmg` ができます。

## 動作環境

macOS 13 以降（Apple シリコン）

## ライセンス

[LICENSE](LICENSE) を参照してください。
