# HTTP Client

`.http` / `.rest` ファイルに書いた HTTP リクエストを、エディタから送信するプラグインです。

## 書き方

```http
@base = https://httpbin.org
@token = abc123

### ユーザー一覧
GET {{base}}/get?page=1
Accept: application/json

### 作成
# @name create
POST {{base}}/post
Content-Type: application/json
Authorization: Bearer {{token}}

{ "name": "FlareStackIDE", "id": "{{$uuid}}" }
```

- `###` でリクエストを区切ります（後ろの文字は名前になります）
- `@名前 = 値` で変数を決め、`{{名前}}` で使います
- 組み込みの変数: `{{$timestamp}}`・`{{$uuid}}`・`{{$isoTimestamp}}`・`{{$processEnv 環境変数名}}`
- メソッドを省くと GET になります。ヘッダーの後に空行を1つ入れると、それ以降が本文です
- `#` か `//` で始まる行はコメントです

## 送信

| 操作 | 内容 |
|---|---|
| ▶ 送信 | リクエスト行の右に出るボタン |
| ⌘↩ | カーソルのあるリクエストを送信 |
| コマンドパレット | 「HTTP: カーソル位置のリクエストを送信」 |

応答は下の「HTTP 応答」フィードに出ます。ステータス・かかった時間・サイズ、本文（JSON は整形）とヘッダーを切り替えて見られます。直近20件は履歴から選び直せます。

localhost 以外へ `http://`（暗号化なし）で送るときは、確認が出ます（設定でオフにできます）。

## 設定

| 項目 | 内容 |
|---|---|
| タイムアウト（秒） | 既定は30秒 |
| http（暗号化なし）で送る前に確認する | 既定はオン |
