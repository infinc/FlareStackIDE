# FlareStackIDE

軽量で使いやすい macOS 向けのテキストエディタ・IDE です。必要なものだけを、プラグインで足していけます。

## プレビュー

<img width="720" height="450" alt="Image" src="https://github.com/user-attachments/assets/cf1a92e7-252e-4ee8-af33-dca0800cdfab" />

<img width="720" height="450" alt="Image" src="https://github.com/user-attachments/assets/55bcc704-b0d3-4f72-b4d4-75beef79b147" />

<img width="720" height="450" alt="Image" src="https://github.com/user-attachments/assets/484528fb-822f-4a65-b5c2-353557a1d5bf" />

<img width="720" height="450" alt="Image" src="https://github.com/user-attachments/assets/03522aaf-b94b-4326-98d6-457c94996b1d" />

## 主な機能

- ディレクトリツリー（ファイルの作成・削除をほぼリアルタイムで反映、Git の状態で色分け）
- ファイルタブ（持ち上げるようなアニメーションでドラッグして並べ替え）とコード編集画面
- 分割画面（ファイルのタブやディレクトリを右クリック →「右に開く」で右側に2つ目の編集画面とタブ）
- 左のアイコン列は ⌘ を押しながらドラッグで並べ替え（上のグループ・下のグループの中だけ）
- 内蔵ターミナル（複数タブ、ドラッグで並べ替え、ダブルクリックで名前変更）
- プロジェクト内検索（上のバーの🔍、⇧⌘F。ファイル名とコードの一致を表示し、押すとその行を開く）
- Git パネル（ブランチ・変更ファイル・全ブランチのコミット履歴をツリーで表示）と GitHub からのクローン
- 自動保存（即時 / 3・10・30・60 秒ごと / オフ）
- テーマ・背景色・フォント・ターミナルのカーソル・大タブの大きさの設定
- プラグイン（オンラインのカタログからインストール・更新）

## ツリーの色

| 色 | 意味 |
|---|---|
| 緑 | 新しく追加したファイル（push するか、1日たつと白に戻る） |
| 水色 | 変更したファイル、または push していないコミットに含まれるファイル |
| オレンジ | Git で追跡していないファイル |

## プラグイン

左のアイコン列のパズルボタンからインストールできます。歯車メニューの「プラグイン」で更新・削除・設定ができます。

| プラグイン | 内容 |
|---|---|
| MD Viewer | Markdown のプレビュー（表にも対応、切替タブの色・透明を設定可） |
| Code Colors | 主要な言語のコードに色を付ける |
| Runner | 起動構成を作ってプログラムを実行 |
| Code Scanner | エラー・警告をリアルタイムで表示 |
| lines | 編集画面の左に行数を表示 |
| Light Editer | ファイルだけを開く軽量エディタ |
| Web Feed | 下のフィードで Google などの Web ページをタブで開く |
| Interpolate Code | カッコ・引用符・リスト記号・インデントを自動で補完 |
| Interpolate Variable | 入力中の変数名・モジュール名の候補を表示（Tab / Enter で補完） |
| File Tab Cleaner | タブの列の一番左にボタンを追加し、押すとタブをすべて閉じる（ファイルは消えない） |

プラグインは `plugins/` にあり、`plugins/index.json` がカタログです。

## ビルド

Xcode のコマンドラインツール（`swiftc`）が必要です。

```bash
./build.sh
```

`build/FlareStackIDE.app` と `FlareStackIDE-<バージョン>.dmg` ができます。バージョンは `VERSION` で管理しています。

## 動作環境

macOS 13 以降（Apple シリコン）

## ライセンス

[LICENSE](LICENSE) を参照してください。
