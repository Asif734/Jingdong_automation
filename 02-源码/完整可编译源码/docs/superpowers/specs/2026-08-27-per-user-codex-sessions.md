# Per-user Codex sessions for Tmall customer service

Approved conversational direction, 2026-08-27. This change replaces the fixed five stateless Codex generations with per-customer resumable Codex sessions while retaining durable local chat history as the source of truth. The application remains the separate experimental automatic-reply app and must not modify OCR, customer identity, unread-dot, image-copy, link-copy, or Qianniu send algorithms.

## Goals

- Give every canonical customer UID an isolated Codex conversation so follow-up turns do not resend another customer's context or restart reasoning from zero.
- Keep an active customer session reusable for one hour after its latest activity.
- Preserve every captured customer/service message, image, link, generated reply, and delivery result in the existing local record store regardless of session lifetime.
- Remove the fixed five-session model. Logical customer sessions are not capped; actual CLI commands scale dynamically within a local safety budget.
- Allow the Tmall service reply to include useful image or video HTTPS links when those links are explicitly present in the trusted knowledge base. Never invent, transform, or execute a link.

## Important distinction: session versus process

A customer owns a logical Codex session, not a permanently running operating-system process. The first turn starts `codex exec` without `--ephemeral`, captures its session ID, and lets the process exit after the reply. A later turn starts `codex exec resume <session-id>` for the same UID. This preserves conversation memory without leaving one idle CLI process per customer.

The persistent local history remains authoritative. A Codex session is only an acceleration cache and may be discarded and rebuilt at any time.

## Session registry

Store an atomic JSON registry under the experimental runtime directory. Each binding contains:

- canonical UID;
- Codex session ID;
- creation and last-activity timestamps;
- expiry timestamp;
- prompt contract version and knowledge-base version;
- last accepted local history cursor and stable message fingerprints;
- attachment hashes already supplied to this session;
- state: creating, ready, generating, invalid, or expired;
- last error and recovery count.

The UID is the only lookup key. A session ID must never be selected by recency or `--last`, preventing cross-customer context leakage. Registry writes are atomic. Corrupt or missing state causes safe per-UID rehydration from local history rather than reuse of an uncertain session.

## First turn

For a UID without a valid binding:

1. Freeze the existing immutable task snapshot.
2. Build the established customer-service instructions, trusted knowledge-base paths, full ordered local chat history, and relevant chat attachments.
3. Start a non-ephemeral structured `codex exec` using ChatGPT login, the existing model and medium reasoning effort.
4. Parse the session ID from the CLI JSON event stream and bind it to the exact UID before accepting the generated answer.
5. Validate and publish the structured reply through the existing freshness and send path.

If no session ID is observed, the answer may still be retained for diagnostics but the UID is not considered resumable. The next turn rehydrates a new session.

## Follow-up within one hour

Only one generation may be active per UID. Different UIDs may generate concurrently.

For a valid, unexpired binding, compute the strict append-only suffix of `history.jsonl` since the stored cursor. Resume the exact session and provide only:

- newly captured messages in their original order;
- newly captured image attachments, once per content hash;
- newly captured links;
- the current immutable history version and task identity.

The continuation tells Codex to answer the final unanswered customer message using the conversation and knowledge already present in the session. It does not resend the full knowledge base or full history.

If the local history is not a strict append of the version previously supplied—for example, OCR reconciliation rewrote or merged earlier records—the binding is invalidated and the session is rebuilt from the complete current history. Correctness takes priority over incremental reuse.

## One-hour expiry and recovery

The idle timer is measured from the most recent customer activity or completed Codex turn, whichever is later. An in-flight generation cannot expire. After one hour of inactivity, mark the binding expired and allow its remote/local session data to remain as diagnostic history, but never resume it for replies.

When an expired customer returns, create a new session and supply the complete saved local conversation and relevant attachments. This first post-expiry turn may be slower; subsequent turns within the next hour are incremental again.

If `resume` fails, returns an identity-mismatched session, or reports unavailable/corrupt state, invalidate only that UID's binding and retry once by creating a fresh session from local history. Do not move the task to another customer's session.

Changing the customer-service prompt contract, model, reasoning effort, output schema, or knowledge-base version invalidates all bindings so no customer continues under stale policy or facts.

## Concurrent scheduling

Logical per-UID sessions are unlimited. Actual CLI processes are short-lived and dynamically scheduled:

- one active generation per UID;
- start work for another ready UID immediately when capacity exists;
- derive current capacity from ready UID count, available memory, active cleanup processes, and recent CLI backpressure;
- reduce capacity after resource pressure, login/rate-limit signals, or repeated launch failures;
- retain a configurable emergency ceiling to prevent process storms, but do not preserve the old fixed value of five.

The existing sends-first UI priority and single Qianniu UI driver remain unchanged. AI generation can be parallel, but reading, selecting customers, and sending remain serialized to avoid UI races.

If a customer sends another message while their generation is running, do not start a second generation for that UID. Record the new revision. The old result is rejected by the existing freshness check, then the same UID session receives the accumulated new suffix in its next turn.

## Tmall image and video links

Replies remain plain text sent through the existing Qianniu sender. The structured `reply_text` may contain one or more full `https://` links to an image or video when useful to answer the customer.

Link rules:

- only send a media link found verbatim in the trusted knowledge-base files read for that answer;
- never copy a link from untrusted customer chat into an authoritative support answer unless the reply is explicitly discussing that customer-provided link;
- never fabricate or guess a URL;
- preserve the exact URL, including path and query string;
- include short explanatory text around the link so the customer knows what it contains;
- if no trusted media link exists, answer normally without one;
- the program does not open the link and does not upload the linked media; Tmall/Qianniu receives the URL as reply text and may render it as clickable content.

No content gate is added after generation. A valid structured answer, with or without links, follows the existing automatic-send path.

## Observability

Add per-UID status and timing records showing:

- new session versus resumed session;
- anonymized or full local UID according to existing logging practice;
- session age and remaining idle lease;
- full-history rehydration versus incremental suffix size;
- number of new images and links attached;
- CLI queue wait, generation time, and recovery outcome;
- invalidation reason without secrets or customer content.

The floating status UI may display concise stages such as “新建客户会话”, “恢复客户会话”, “增量提交 2 条消息”, and “会话过期，重载历史”.

## Test strategy

1. Unit-test atomic registry persistence, exact UID isolation, one-hour boundary, in-flight lease protection, prompt/KB version invalidation, and corrupt-registry recovery.
2. Use a fake CLI to verify session-ID capture, exact `resume` routing, no `--last`, incremental prompts, image de-duplication, resume failure rehydration, and structured output on every turn.
3. Verify the same UID is serialized while different UIDs run concurrently and dynamic capacity is not capped at five when resources permit.
4. Verify a history rewrite forces full rehydration instead of an unsafe suffix.
5. Test media replies with trusted image/video URLs, missing URLs, customer-injected URLs, malformed URLs, and multiple URLs. Ensure the existing sender transmits exact text.
6. Run regression tests for OCR, unread discovery, customer selection, images, links, freshness, and sending without modifying their algorithms.
7. Benchmark first-turn and follow-up latency against the current stateless baseline. The acceptance target is unchanged first-turn correctness and a material reduction in repeated prompt bytes and median follow-up latency.
8. Perform live self-account tests with two UIDs: concurrent first turns, multiple follow-ups within one hour, forced expiry, session-resume failure, image input, and a trusted video/image link response.

## Rollout and rollback

Freeze the current experimental build before changing the batch component. Introduce the session registry behind an experimental runtime flag until simulated and live evidence passes. Rollback restores the frozen build without deleting local customer history. Session registry files may be ignored by the old build and must never be translated into outgoing queue entries.

## Non-goals

- No change to OCR, red-dot detection, message parsing, UID resolution, image/link copying, or Qianniu click/send algorithms.
- No API-key authentication; continue using the local Codex CLI with ChatGPT login.
- No permanent CLI daemon per customer.
- No model or reasoning-effort change.
- No automatic media upload; only trusted text links are supported in this phase.
