# tmux レイアウトモジュール — 仕様書

> 本書は [tmux レイアウトモジュール要件定義書](./REQUIREMENTS.md) に基づく設計仕様である。内部処理のロジックについては最小限に留めること。

---

## 実装ファイル

| ファイル | 説明 |
|---|---|
| `scripts/apply-layout.sh` | レイアウト定義に基づきペイン構成を適用する（ペインの移動・削除・新規作成） |
| `scripts/install.sh` | apply-layout.sh を `.ai-team/scripts/` に配置するインストールスクリプト |
| `scripts/uninstall.sh` | install.sh で配置したファイルを除去するアンインストールスクリプト |

---

## 参照元

| 参照元モジュール | 使用スクリプト | 用途 |
|---|---|---|
| session-management | `apply-layout.sh` | エージェント起動・復旧時のペイン再配置 |

---

## インフラ構成図

```mermaid
graph LR
    C[呼び出し元] -->|レイアウト定義 JSON| AL[apply-layout.sh]
    AL -->|ペインの移動・削除・作成| TM[tmux]
```

本モジュールは tmux のペイン識別に関する独自の仕組みを持たない。呼び出し元が `pane_id` を含むレイアウト定義を渡し、`apply-layout.sh` はその指示に従ってペインを操作する汎用ツールである。

---

## 処理フロー

### レイアウト適用（FR-S1）

```mermaid
sequenceDiagram
    participant C as 呼び出し元
    participant SM as apply-layout.sh
    participant TM as tmux

    C->>SM: apply-layout.sh '<layout_json>' <session_name>

    Note over SM: Step 1: バリデーション
    SM->>SM: レイアウト定義の整合性を検証
    Note over SM: - position の組み合わせが有効か<br/>- whole は group 内で単独か<br/>- 必須フィールドが存在するか
    alt バリデーションエラー
        SM-->>C: エラー（exit 1）
    end

    Note over SM,TM: Step 2: 削除対象の処理
    loop position が null の要素
        SM->>TM: 該当ペインを削除
    end

    Note over SM,TM: Step 3: ウィンドウ数の調整
    SM->>TM: 現在のウィンドウ数を取得
    alt ウィンドウが不足
        SM->>TM: 不足分のウィンドウを作成
    end

    Note over SM,TM: Step 4: ペインの移動・作成
    loop 既存ペイン
        alt 現在のウィンドウ ≠ 目標のウィンドウ
            SM->>TM: ペインを目標ウィンドウに移動
        end
    end
    loop 新規ペイン（pane_id: null）
        SM->>TM: 目標ウィンドウに新規ペインを作成
        Note over SM: 既存ペインの作業ディレクトリを引き継ぐ
    end

    Note over SM,TM: Step 5: ウィンドウ内のペイン配置調整
    loop 各ウィンドウ
        SM->>TM: position に基づきペインの並び順を調整
    end

    Note over SM: Step 6: 結果出力
    SM-->>C: 適用結果 JSON（window_id → {pane_id, position} のマッピング）
```

---

## 外部依存

### tmux

| 項目 | 内容 |
|---|---|
| 用途 | ウィンドウ・ペインの作成・移動・削除 |
| バージョン | 3.x 以上 |

### jq

| 項目 | 内容 |
|---|---|
| 用途 | レイアウト定義 JSON のパース |

---

## 公開インターフェース

### スクリプト

| スクリプト | 引数 | 説明 |
|---|---|---|
| `apply-layout.sh` | `<layout_json>` `<session_name>` | レイアウト定義に基づきペイン構成を適用し、適用結果を JSON で stdout に出力する。`install.sh` により `.ai-team/scripts/apply-layout.sh` に配置される |
| `install.sh` | なし | `apply-layout.sh` を `.ai-team/scripts/` に配置する |

### レイアウト定義（入力）

`apply-layout.sh` に渡す JSON。辞書のリストであり、各要素が 1 つのペイン操作を表す。呼び出し元が `pane_id` を直接指定するため、本モジュールはペインの識別に関する独自の仕組みを持たない。

```json
[
  { "group_id": 0, "pane_id": "%5",  "position": "top-left" },
  { "group_id": 0, "pane_id": "%6",  "position": "top-right" },
  { "group_id": 0, "pane_id": null,  "position": "bottom-left" },
  { "group_id": 0, "pane_id": null,  "position": "bottom-right" },
  { "group_id": 1, "pane_id": "%7",  "position": "left" },
  { "group_id": 1, "pane_id": "%8",  "position": "right" },
  { "group_id": null, "pane_id": "%9", "position": null }
]
```

| フィールド | 型 | 説明 |
|---|---|---|
| `group_id` | int \| null | ウィンドウ単位のグループ ID。番号が小さい順にウィンドウが並ぶ。`position` が `null` の場合は `null` |
| `pane_id` | string \| null | 既存ペインの tmux ペイン ID（例: `%5`）。新規作成の場合は `null` |
| `position` | string \| null | ペインの目標位置。`top-left`, `top-right`, `bottom-left`, `bottom-right`, `top`, `bottom`, `left`, `right`, `whole`（ウィンドウ全体）。削除する場合は `null` |

同一 group 内の position は、`top-left`, `top-right`, `bottom-left`, `bottom-right` の 4 つの基本領域を重複なく覆う必要がある。`left` と `top-right` / `bottom-right` のように 2 ペイン系と 4 ペイン系が混在しても、占有領域が重ならなければ有効である。

### 適用結果（出力）

`apply-layout.sh` が stdout に出力する JSON。適用後のウィンドウ・ペイン構成を返す。呼び出し元はこの結果を使って、新規作成されたペインへの CLI 起動などの後続処理を行える。

```json
{
  "@1": [
    { "pane_id": "%5",  "position": "top-left" },
    { "pane_id": "%6",  "position": "top-right" },
    { "pane_id": "%10", "position": "bottom-left" },
    { "pane_id": "%11", "position": "bottom-right" }
  ],
  "@2": [
    { "pane_id": "%7",  "position": "left" },
    { "pane_id": "%8",  "position": "right" }
  ]
}
```

| フィールド | 型 | 説明 |
|---|---|---|
| キー | string | tmux の window_id（例: `@1`） |
| `[].pane_id` | string | 適用後のペイン ID。新規作成されたペインには新しい ID が割り当てられる |
| `[].position` | string | 適用された位置 |
