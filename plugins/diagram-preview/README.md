# Diagram Preview

Mermaid のファイル（`.mmd` / `.mermaid`）を開くと、コードの横に図を表示するプラグインです。

## 使い方

- 上のバーで「コード」「コード＋図」「図」を切り替えます
- 入力の0.3秒後に図を描き直します。書き間違いがあると、図の上に赤字でエラーを表示し、前の図を薄く残します
- エディタの背景が暗いときは、図も暗い配色になります
- 「SVG をコピー」で、表示中の図を SVG の文字列としてコピーします

## 安全のための制限

- 図はアプリ内の WebView で描きます。外部への通信（http / https / file など）は全て遮断しています
- ページ内のリンクを押しても移動しません。Mermaid は `securityLevel: strict` で動かし、図の中のスクリプトやクリック処理は動きません

## 同梱しているライブラリ

mermaid 11.4.1（`mermaid.min.js`、https://github.com/mermaid-js/mermaid）

```
The MIT License (MIT)

Copyright (c) 2014 - 2022 Knut Sveidqvist

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
