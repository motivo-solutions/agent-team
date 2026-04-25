# agent-team

`agent-team` は、tmux ペイン上の複数 AI エージェントを Mailbox で連携させるための基盤モジュール集です。`team-management` と、その実行に必要な `tmux-layout` / `communication` / `bridge` / `session-management` を含みます。

## セットアップ

対象プロジェクトのルートへインストールします。

```bash
./install.sh --project-dir ~/workspace/my-project
```

インストール後、対象プロジェクトには主に以下が配置されます。

| パス | 内容 |
|---|---|
| `.ai-team/scripts/` | 起動、復旧、Mailbox、tmux layout 用 shell script |
| `.ai-team/agents.config.json` | チームメンバーと起動方法の設定 |
| `.ai-team/layouts.config.json` | tmux ペイン配置の設定 |
| `.claude/skills/team-start/` | `/team-start` skill |
| `.claude/skills/team-resume/` | `/team-resume` skill |
| `.claude/skills/team-stop/` | `/team-stop` skill |
| `.claude/settings.json` | Claude Code hooks |
| `.codex/config.toml` / `.codex/hooks.json` | Codex hooks |

## 最低限必要なファイル

`/team-start` を動かすには、対象プロジェクト側に次のファイルが必要です。

- `.ai-team/agents.config.json`
- `.ai-team/layouts.config.json`
- `.ai-team/prompts/<member>.md`

`install.sh` は generic な `agents.config.json` / `layouts.config.json` を配置します。実際のチーム構成に合わせて、この 2 つを編集し、全メンバー分の prompt ファイルを `.ai-team/prompts/{member}.md` として作成してください。

## prompt ファイルを作成する

leader を含む全 member の prompt を `.ai-team/prompts/` に作ります。ファイル名は `agents.config.json` の `member` と一致させてください。
各 prompt には、メンバー間で依頼・報告できるように、少なくとも次の基礎知識を入れてください。

- 自分の `member` ID と役割
- leader と teammate の `member` ID
- 各メンバーの主な担当領域
- メンバー間の依頼・相談・報告では `member` ID で相手を指定すること
- 迷ったら leader へ相談し、完了時は依頼元へ報告すること

```bash
mkdir -p .ai-team/prompts

cat > .ai-team/prompts/leader.md <<'EOF'
# Leader

あなたはチームのリーダー。依頼を整理し、各メンバーへ作業を依頼する。

## チーム構成

- leader: あなた。タスク整理、判断、メンバーへの依頼を担当する。
- planner: 仕様整理とタスク分解を担当する。
- builder: 実装とテストを担当する。

## コミュニケーション

`planner` / `builder` の member ID 宛に依頼する。
各メンバーからの報告を受け、必要に応じて追加指示を出す。
EOF

cat > .ai-team/prompts/planner.md <<'EOF'
# Planner

あなたは仕様整理とタスク分解を担当する。

## チーム構成

- leader: チームのリーダー。判断と作業依頼を担当する。
- planner: あなた。仕様整理とタスク分解を担当する。
- builder: 実装とテストを担当する。

## コミュニケーション

メンバー間の依頼・相談・報告では member ID で相手を指定する。
作業依頼は主に `leader` から届く。実装が必要な内容は `builder` に相談できる。
届いた依頼に応答し、完了時は依頼元へ報告する。
EOF

cat > .ai-team/prompts/builder.md <<'EOF'
# Builder

あなたは実装担当。依頼された変更を行い、テスト結果を添えて報告する。

## チーム構成

- leader: チームのリーダー。判断と作業依頼を担当する。
- planner: 仕様整理とタスク分解を担当する。
- builder: あなた。実装とテストを担当する。

## コミュニケーション

メンバー間の依頼・相談・報告では member ID で相手を指定する。
作業依頼は主に `leader` から届く。仕様が曖昧な場合は `leader` または `planner` に確認する。
EOF
```

leader は既存の Claude Code セッションで動作する前提なので、`launcher` は不要です。ただし leader 用の prompt ファイルは `.ai-team/prompts/leader.md` として作成してください。

## agents.config.json を作成する

`.ai-team/agents.config.json` は、メンバー一覧と各メンバーの CLI 起動方法を定義します。

```json
{
  "members": [
    {
      "member": "leader",
      "leader": true
    },
    {
      "member": "planner",
      "leader": false,
      "launcher": {
        "cli": "claude",
        "model": "sonnet",
        "permission_mode": "acceptEdits"
      }
    },
    {
      "member": "builder",
      "leader": false,
      "launcher": {
        "cli": "codex",
        "sandbox": "workspace-write",
        "approval_policy": "on-request"
      }
    }
  ]
}
```

主な項目:

- `member`: メンバー ID。Mailbox や pane state のキーになります。
- `leader`: リーダーだけ `true`。リーダーは現在の Claude Code pane を使うため `launcher` は不要です。
- `launcher.cli`: `claude` または `codex`。
- prompt ファイル: `member` 名から `.ai-team/prompts/{member}.md` を暗黙的に読み込みます。

## layouts.config.json を作成する

`.ai-team/layouts.config.json` は、メンバーを tmux のどの位置へ配置するかを定義します。`agents.config.json` の全メンバーを必ず含めてください。

```json
[
  { "member": "leader", "group_id": 0, "position": "top-left" },
  { "member": "planner", "group_id": 0, "position": "top-right" },
  { "member": "builder", "group_id": 0, "position": "bottom" }
]
```

`position` は `top-left`, `top-right`, `bottom-left`, `bottom-right`, `top`, `bottom`, `left`, `right`, `whole` を使えます。`group_id` が同じメンバーは同じ tmux window に配置されます。

## 起動と復旧

対象プロジェクトを tmux 上の Claude Code セッションで開き、リーダーの pane から `/team-start <session_name>` を実行します。

復旧時は同じ tmux session 名のまま `/team-resume` を実行します。保存済み state は `.ai-team/<tmux-session>/` に置かれます。

停止時は `/team-stop` を実行します。

## アンインストール

```bash
./uninstall.sh --project-dir ~/workspace/my-project
```

## テスト

```bash
bats tmux-layout/tests
bats communication/tests
bats session-management/tests
bats team-management/tests
```
