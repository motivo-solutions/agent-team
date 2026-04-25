---
name: team-stop
description: Stop the Mailbox-based team session and clean up resources
---

# /team-stop

Mailbox ベースのチームセッションを終了し、関連リソースを片付ける。

## Procedure

### 1. Execute the Dedicated Cleanup Script

Run:

```bash
.ai-team/scripts/team-stop-runtime.sh
```

This script is responsible for:

- Stopping the bridge process if it is alive
- Running `.ai-team/scripts/mailbox-cleanup.sh`
- Removing the configured non-leader panes via `.ai-team/scripts/apply-layout.sh`
- Removing `.ai-team/{session_name}/bridge.pid`, `bridge.log`, and `panes.env`
