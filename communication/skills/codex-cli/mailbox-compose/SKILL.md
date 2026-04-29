---
name: mailbox-compose
description: Send a NEW outbound Mailbox message to a teammate via send_mailbox_message.sh. Use ONLY for proactive request / question / error messages. NEVER use this skill while handling a `[Mailbox]` prompt — replies to incoming Mailbox messages are delivered automatically by the Stop hook, and this skill will be rejected by send_mailbox_message.sh in that situation.
metadata:
  short-description: Send a new Mailbox message
---

# Mailbox Compose

Use this skill only when you need to send a new Mailbox message proactively.

**Never** use this skill if the current turn is handling a `[Mailbox]` prompt. Replies are returned automatically by the Stop hook; the send script enforces this and will exit with an error if invoked while a pending Mailbox reply state exists.

## Inputs to confirm

Before sending, make sure these values are known:

- `member`: sender mailbox ID such as `alpha`
- `to`: destination mailbox ID such as `bravo`
- `type`: one of `request`, `question`, `error`
- `message`: Markdown body to send

If any field is missing, ask only for the missing values.

## Execution

Run:

```bash
.ai-team/scripts/send_mailbox_message.sh \
  --member charlie \
  --to alpha \
  --type question \
  --message "Could you confirm the expected behavior of the patch?"
```

## After sending

- Emit only a one-line confirmation (destination + message type) and then stop
- Do not poll, do not follow up, do not start any other work
- Wait silently for the recipient's reply. The reply will arrive as a `[Mailbox]` prompt handled automatically by hooks; continue only after it arrives

## Guardrails

- Use mailbox IDs, not display names
- Do not invent missing recipients or message types
- Do not use this skill for ordinary direct conversation in the same pane
- Do not use this skill while a `[Mailbox]` prompt is being handled — the Stop hook delivers the reply
- The skill's contract ends at delivery — never chain additional actions or checks after the send
