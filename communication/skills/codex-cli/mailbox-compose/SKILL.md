---
name: mailbox-compose
description: Send a new Mailbox message to a specific teammate by calling send_mailbox_message.sh. Use when the user explicitly wants to relay a fresh request, question, response, or error to another member.
metadata:
  short-description: Send a new Mailbox message
---

# Mailbox Compose

Use this skill only when you need to send a new Mailbox message proactively.

Do not use this skill for replies to a `[Mailbox]` prompt. Normal replies are returned automatically by hooks.

## Inputs to confirm

Before sending, make sure these values are known:

- `member`: sender mailbox ID such as `alpha`
- `to`: destination mailbox ID such as `bravo`
- `type`: one of `request`, `response`, `question`, `error`
- `message`: Markdown body to send

If any field is missing, ask only for the missing values.

## Execution

Run:

```bash
.ai-team/scripts/send_mailbox_message.sh \
  --member charlie \
  --to alpha \
  --type response \
  --message "I finished the review. No blocking issues found."
```

## After sending

- Emit only a one-line confirmation (destination + message type) and then stop
- Do not poll, do not follow up, do not start any other work
- Wait silently for the recipient's reply. The reply will arrive as a `[Mailbox]` prompt handled automatically by hooks; continue only after it arrives

## Guardrails

- Use mailbox IDs, not display names
- Do not invent missing recipients or message types
- Do not use this skill for ordinary direct conversation in the same pane
- The skill's contract ends at delivery — never chain additional actions or checks after the send
