# Fully automatic Qianniu reply scheduler

Approved conversational design, 2026-08-26. User authorized implementation and phone-Taobao self-account testing. Baseline: ../current-before-autoreply-20260826-225405. Original installed apps and original source must remain unchanged.

## Architecture and boundaries

Create a separate signed macOS app with one lightweight scheduler and direct reuse of existing OCR, unread detection, CLI generator, and send transaction libraries from copied components. A single UI driver serializes all Qianniu operations; five asynchronous CLI generations may run concurrently. This removes cross-app button/lock races without changing OCR/parser/image/link algorithms, prompt, model, reasoning effort, knowledge base or sending text logic. Original component apps must be idle/closed during auto mode; detect incompatible active operators and pause, never race them.

The isolated app uses its own record root, ~/Desktop/AI客服记录-全自动版, with copied history/images as initial context, no imported actionable queue, and the same existing cleaned KB path. No old queue is replayed. Test mode limits recipients to stoneshishininger and tb263147182, clearly displayed; normal mode supports arbitrary full UIDs with no fixed coordinates or prefix guesses. Start/Stop is explicit; no login item or system daemon. Stop prevents further UI actions after the current safe boundary; in-flight CLI outcomes remain persisted, never sent while stopped.

## Scheduling

Discover full UIDs from fresh visible list red dots. Register each before clicking. Preserve first-seen FIFO, including when the list reorders. Bounded scrolling discovers offscreen rows without monopolizing the UI. Active UID is deduplicated but not forgotten; selected chat is checked periodically because new messages can arrive without a red dot. One UI operation at a time. Each cycle checks ready sends before starting another read. Current capture includes OCR and all image/link copying and durable export before UI handoff. Prioritize ready-send FIFO; no global wait for an earlier slow customer's AI. At most five live CLI processes including cleanup. New arrivals can use free slots immediately, not after a batch snapshot drains.

Persist jobs with UID, sequence, state, immutable prompt snapshot, customer revision, attempt ID, retries, reply, timestamps and errors. Save before externally consequential actions. Main-thread ownership serializes state transitions; OS advisory singleton lock releases on crash. Do not introduce another source of truth alongside these jobs: pending/active/ready are views over the same records. Archive completed jobs and readable replies/events. Never restore historical queue state on rollback.

## Freshness

Use existing exporter customer-new-message decision for admission. Keep full local history for context but use customer-message revision (exclude service and read status) for freshness; raw whole-file hashes are not customer changes. Freeze exact history and image manifest for each generation. At send time capture the target again, validate UID and compare revision. New customer content supersedes the old unsent result; regenerate from newest snapshot, only one generation per UID. If a human has already answered after the pending customer question, suppress the stale AI response. No content-based approval gates are added. After sending, revisit the selected/recently handled customer to detect supplements. UI-only verification cannot provide server-atomic exactly-once delivery; ambiguous sends remain separate and are reconciled rather than blindly retried.

## Failures and recovery

No-new-message capture completes an observation without generating. Bounded cooldown avoids persistent badge loops. Capture and pre-send failures retry with backoff, not endless immediate loops; other customers can advance after UI is verified safe. Uncertain sends are not automatically resent, and an unclean modal/UI state pauses automation. On restart, interrupted capture/generation may retry; sending becomes uncertain. Missing/corrupt persistent state fails visibly, not silently reset. Keep completed versions to prevent replay. Queue/status/history are readable locally. No secrets in logs.

## Acceptance

1. Frozen apps verify original signatures and manifest hashes; originals untouched.
2. Red/green tests cover duplicate UID, FIFO under reorder, sends-first safe boundary, dynamic arrival while another generation blocks, maximum five including cleanup, immutable context, stale results, no-new observation, stop, restart, and ambiguous send.
3. Original OCR/parser/image/link, prompt/model files match baseline hashes unless the change is explicitly an adapter API only.
4. Build separate app, verify signature/resources and permissions. Use Computer Use only for manual UI interactions.
5. Phone sends ordinary product question; one initial Start, then no assistant clicking OCR/send. Verify discovery, UID, capture, CLI output, send acknowledgement, buyer-side arrival, queue completion and timing log. Repeat with supplements, another customer selected, and another UID when available. Separate simulated tests from actual phone evidence. Never call manual replies evidence of automation.
