---
name: team-start
description: Start the team and establish Mailbox-based coordination across tmux panes
arguments:
  - name: session_name
    description: tmux session name for this team session
    required: true
---

# /team-start <session_name>

Mailbox ベースのチーム開発セッションを起動する。

## Procedure

### 1. Determine Session Name

- Use the `session_name` argument as the tmux session name
- Rename the tmux session with `tmux rename-session "$session_name"`

### 2. Prepare Configuration Files

Use the installed configuration files:

```bash
.ai-team/agents.config.json
.ai-team/layouts.config.json
```

### 3. Receive Leader Prompt

- Resolve the leader member from `.ai-team/agents.config.json` where `leader` is `true`
- Read `.ai-team/prompts/{leader_member}.md`
- Treat that file as the operating prompt for the current leader session before starting teammates
- Do not start a separate CLI for the leader

### 4. Bootstrap Team from External Configuration

Execute the dedicated helper script:

```bash
.ai-team/scripts/team-start-runtime.sh \
  ".ai-team/agents.config.json" \
  ".ai-team/layouts.config.json"
```

This script is responsible for:

- Running `.ai-team/scripts/mailbox-init.sh` for all configured members
- Running `.ai-team/scripts/apply-layout.sh` with the configured layout
- Persisting pane IDs to `.ai-team/{session_name}/panes.env`
- Starting each configured non-leader member in its pane
- Starting the single bridge and writing `.ai-team/{session_name}/bridge.pid`

The runtime script must treat the agent composition and layout as external inputs. Do not hardcode the team structure in the skill itself.

### 5. Verify Bridge

- Confirm the bridge process is running: `.ai-team/{session_name}/bridge.pid` exists and its PID is alive
- Do not complete startup if the bridge is not running. No further ping / acknowledgement checks are performed here

## Recovery

- To resume an existing session, use `/team-resume`
