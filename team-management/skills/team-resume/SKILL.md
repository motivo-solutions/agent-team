---
name: team-resume
description: Resume the existing Mailbox-based team session from saved state
---

# /team-resume

保存済み state を使って、既存の Mailbox ベースチームセッションを復旧する。

## Procedure

### 1. Keep the Current Session Name

- Do not rename the tmux session
- Reuse the current session name to read `.ai-team/{session_name}/panes.env`

### 2. Prepare Configuration Files

Use the installed configuration files:

```bash
.ai-team/agents.config.json
```

### 3. Resume Team from Saved State

Execute the dedicated helper script with the resume option:

```bash
.ai-team/scripts/team-start-runtime.sh --resume \
  ".ai-team/agents.config.json"
```

This script is responsible for:

- Loading pane IDs from `.ai-team/{session_name}/panes.env`
- Running `.ai-team/scripts/resume-agents.sh` with the configured members and saved pane map
- Restarting the single bridge only when `bridge.pid` is missing or the process is no longer alive

The runtime script must treat the agent composition as an external input. Do not hardcode the team structure in the skill itself.

### 4. Verify Bridge

- Confirm the bridge process is running: `.ai-team/{session_name}/bridge.pid` exists and its PID is alive
- Do not complete recovery if the bridge is not running. No further ping / acknowledgement checks are performed here
