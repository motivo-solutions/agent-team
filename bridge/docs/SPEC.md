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

```mermaid
sequenceDiagram
    participant Starter as 起動元
    participant Bridge as メッセージ中継処理
    participant Outbox as 送信者の outbox ディレクトリ
    participant Inbox as 受信者の inbox ディレクトリ
    participant Pane as 受信者の tmux pane

    Starter->>Bridge: Mailbox ルートと宛先 pane の対応を与えて起動
    Bridge->>Pane: 各メンバーの pane の存在を確認
    Bridge->>Outbox: 各メンバーの outbox の監視を開始

    Bridge->>Outbox: 起動時点で残っている既存メッセージを取得
    Outbox-->>Bridge: 既存メッセージ一覧

    loop outbox にファイルが追加されるたび
        Outbox-->>Bridge: 追加された Mailbox ファイル
        Bridge->>Outbox: frontmatter（from/to/type）と本文を読み取る
        Outbox-->>Bridge: メッセージ内容

        alt 必須 frontmatter が欠落している
            Bridge->>Bridge: 警告ログを出して破棄
        else 宛先が未登録のメンバー
            Bridge->>Bridge: 警告ログを出して破棄
        else 正常系
            Bridge->>Inbox: 同名ファイルを保存
            Bridge->>Pane: [Mailbox] プレフィックス付きで本文を入力
            Bridge->>Pane: Enter で入力を確定
        end
    end
```

## 公開インターフェース

| スクリプト | 引数 | 説明 |
|---|---|---|
| `mailbox-bridge.sh` | `<mailbox_root>` `<member:pane>`... | Mailbox を監視して対象 pane に配送する |
| `install.sh` | なし | `.ai-team/scripts/mailbox-bridge.sh` を配置する |
| `uninstall.sh` | なし | 配置済み bridge を除去する |
