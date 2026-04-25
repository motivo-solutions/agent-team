# ブリッジモジュール — 仕様書

## 実装ファイル

| ファイル | 説明 |
|---|---|
| `scripts/mailbox-bridge.sh` | 全メンバーの outbox を監視し、宛先ペインへ配送する常駐スクリプト |
| `scripts/install.sh` | `mailbox-bridge.sh` を `.ai-team/scripts/` に配置する |
| `scripts/uninstall.sh` | 配置した bridge スクリプトを除去する |

## 構成

```mermaid
graph TB
    BR[mailbox-bridge.sh]
    MB[Mailbox root]
    A[alpha pane]
    B[bravo pane]
    C[charlie pane]
    D[member_n pane]

    BR --> MB
    BR --> A
    BR --> B
    BR --> C
    BR --> D
```

## 処理フロー

### メッセージ中継

1. bridge は `<mailbox_root> <member:pane>...` を受け取って起動する
2. 各メンバーの `outbox/` を `inotifywait` で監視する
3. メッセージファイルの frontmatter から `from` / `to` / `type` を読む
4. 受信者の `inbox/` に同名ファイルを保存する
5. 受信者の pane へ `[Mailbox]` プレフィックス付きメッセージを複数行のまま貼り付ける
6. 受信者 pane に `Enter` を送って入力を確定する

## 公開インターフェース

| スクリプト | 引数 | 説明 |
|---|---|---|
| `mailbox-bridge.sh` | `<mailbox_root>` `<member:pane>`... | Mailbox を監視して対象 pane に配送する |
| `install.sh` | なし | `.ai-team/scripts/mailbox-bridge.sh` を配置する |
| `uninstall.sh` | なし | 配置済み bridge を除去する |
