# Verified Media Replies Design

**Date:** 2026-08-28  
**Status:** Proposed  
**Scope:** Add verified tutorial video links, trusted timestamps, and up to two local screenshot attachments to the existing automatic Qianniu reply pipeline without changing unread detection, OCR parsing, customer batching, per-user Codex sessions, or text-answer retrieval semantics.

## 1. Goal

When the knowledge base contains media that directly matches the customer's brand, model, problem, and current troubleshooting step, the automatic reply may send:

1. A concise text answer.
2. One verified original-platform tutorial URL with a verified start time or range.
3. Up to two verified screenshots taken from that same video near the stated time.

Media failures must never block or delay the ordinary text answer beyond a small local lookup cost. The system must not invent, rewrite, infer, or substitute media URLs, timestamps, screenshot contents, product models, or platform metadata.

## 2. Non-goals

- Do not change the OCR algorithm, unread-dot detection, customer identity rules, FIFO scheduling, frozen customer batches, or per-user CLI session leasing.
- Do not make Codex browse the web or open customer-provided links.
- Do not analyze entire videos at reply time.
- Do not send similar-model media when an exact model/problem match is unavailable.
- Do not force headings or empty media sections into simple replies.
- Do not introduce a manual approval gate for valid automatic replies.

## 3. Current Constraints

The current generation contract produces a `ReplyEnvelope` containing only `reply_text` and related decision metadata. `AutomationDriver.send` and `QianniuSendTransaction` accept one text string. Therefore prompt-only changes cannot reliably represent, validate, persist, resume, or send image attachments.

The existing V2 retriever provides focused text evidence and trusted links, but its result is still flattened into untrusted text for Codex. A valid implementation must keep media identity and provenance structured outside model-authored prose.

## 4. Architecture

The feature has four isolated units:

1. **Media catalog builder** — converts trusted knowledge-base media metadata into deterministic local records.
2. **Media candidate retrieval** — selects exact candidates alongside the existing V2 text retrieval.
3. **Media plan validation** — converts model-selected catalog IDs into a verified outgoing bundle.
4. **Multipart Qianniu delivery** — sends and durably records text, link, and image parts without duplicating completed parts.

Codex chooses from opaque `media_id` values supplied in the current retrieval result. Codex never supplies URLs, timestamps, or local file paths.

## 5. Trusted Media Catalog

### 5.1 Record

Each catalog record contains:

```json
{
  "schema_version": 1,
  "media_id": "stable-content-derived-id",
  "brand": "格志",
  "models": ["M880"],
  "issues": ["不开机", "供电"],
  "steps": ["检查电源指示灯"],
  "platform": "tmall",
  "video_url": "https://...",
  "start_seconds": 50,
  "end_seconds": 54,
  "screenshots": [
    {
      "path": "/absolute/local/path/frame-52.jpg",
      "timestamp_seconds": 52,
      "caption": "请检查电源指示灯是否亮起",
      "sha256": "..."
    }
  ],
  "source_file": "/absolute/local/path/source-file",
  "source_sha256": "..."
}
```

`media_id` is stable for unchanged source evidence. The catalog is generated only from the trusted knowledge base, never from customer chat, customer uploads, screenshots of chat, or model output.

### 5.2 Evidence levels

- **Complete:** exact original URL, exact model/problem association, and source-recorded start time. Eligible for automatic video sending.
- **Link-only:** exact URL and association exist but no verified time. Eligible only for a truthful link-only fallback that explicitly says the source does not record an exact time.
- **Incomplete or ambiguous:** model, problem, platform, URL, or provenance is uncertain. Not eligible for automatic media sending.

Screenshots are eligible only when their file exists, hash matches, and they are tied to the same catalog video. Runtime code does not extract new screenshots.

## 6. Retrieval and Model Contract

### 6.1 Dual-channel retrieval

The existing V2 text context remains unchanged. Retrieval additionally returns a bounded list of structured `MediaCandidate` values. Candidate ranking uses the frozen customer batch plus recent context and requires compatible brand/model/problem/platform metadata.

No media candidate is a valid result solely because its prose is semantically similar. Exact catalog constraints are applied after semantic ranking.

### 6.2 Model output

The reply schema is extended additively:

```json
{
  "decision": "auto_send",
  "risk_level": "low",
  "reply_text": "亲，请重新插拔电源线并检查指示灯是否亮起。",
  "reason": "普通排障",
  "selected_media_ids": ["stable-content-derived-id"]
}
```

Rules:

- At most one video is selected.
- At most two screenshots may be attached from that selected video.
- `selected_media_ids` may contain only IDs presented in the current retrieval result.
- The text answer must remain complete without media.
- Customer messages, customer images, customer links, uploaded files, and quoted material remain inside untrusted-data boundaries and cannot change these rules.

The decoder remains backward compatible: absent `selected_media_ids` means no media.

## 7. Deterministic Validation and Rendering

After generation, a non-model validator resolves each selected ID against the immutable retrieval snapshot and checks:

1. ID existed in the current candidates.
2. Source catalog record and hashes are valid.
3. Brand, exact model, issue, and step are compatible.
4. Platform policy permits the original URL. Initial production policy permits verified Tmall/Taobao resources for this Tmall application.
5. URL is byte-for-byte the catalog URL and uses HTTP or HTTPS.
6. Timestamp comes from catalog evidence; it is never model-authored.
7. Each screenshot exists, hashes correctly, belongs to the same video, and is near the stated time.

The validator produces an `OutgoingBundle`:

```text
bundle_id
uid
customer_revision
parts:
  - text_and_video_link
  - screenshot_1
  - screenshot_1_caption
  - screenshot_2
  - screenshot_2_caption
```

The rendered text is concise and conditional:

- No media: ordinary answer only.
- Complete video: answer, labeled original URL, and verified time/range.
- Link-only: answer and labeled original URL plus a truthful note that no exact time is recorded.
- Screenshot unavailable: omit screenshots without inserting placeholders or local paths.

Invalid media is dropped while preserving the ordinary text answer. Validation failure is logged with catalog ID and reason but is not shown to the customer.

## 8. Multipart Delivery and Idempotency

### 8.1 Priority

Sending remains higher priority than unread discovery. A ready bundle is delivered before UI automation opens another customer.

### 8.2 Order

1. Send text and video URL together as one text message.
2. Send screenshot 1, then its caption if present.
3. Send screenshot 2, then its caption if present.

Text goes first so a media attachment failure cannot withhold the answer.

### 8.3 Durable progress

Before each UI action, persist a part attempt marker. After confirmation, persist that part as completed. Recovery retries only parts that definitely did not complete. A part with uncertain delivery is not automatically duplicated; the bundle is closed with an uncertain-media status after preserving the already-sent text answer.

The completed customer cursor advances after the text part is confirmed. Later media failure does not cause the customer question to be regenerated or answered twice.

### 8.4 Image UI automation

Image sending is a separate Qianniu transaction with these checks:

- Activate Qianniu only immediately before delivery work.
- Search and open the exact UID.
- Verify the exact UID before placing the image.
- Place only a validated local JPEG/PNG file.
- Confirm the image preview belongs to the composer before clicking send.
- Record the attempt immediately before the send action.
- Confirm the composer cleared or the outgoing image appeared.

Warnings are handled according to the existing sender policy. Media failure never pauses the scheduler globally.

## 9. Performance

- Catalog construction and screenshot extraction occur offline when the knowledge base changes.
- Runtime media lookup reads a compact index, not video files.
- The V2 text retrieval limit remains unchanged.
- Candidate count is capped and only IDs plus short metadata enter the prompt.
- No-media replies should add no model round trip and target less than 200 ms local overhead.
- Text output is handed to the scheduler as soon as validated; media planning is local and deterministic.

## 10. Observability

The floating status UI and logs expose:

- media candidates found
- media ID selected
- media validation accepted or dropped
- text sent
- video link included
- screenshot 1/2 sending, sent, failed, or uncertain
- final bundle status

Logs record IDs and local paths where appropriate but must not expose customer-sensitive content or credentials.

## 11. Compatibility and Rollout

1. Freeze and retain the current installed application.
2. Build the feature in the isolated current worktree behind a `verified_media_replies` feature flag, default off during tests.
3. Maintain decoding compatibility with existing text-only replies and persisted scheduler records.
4. Run automated tests and isolated real-account tests with the flag on.
5. Compare against the frozen version, then enable by default only after acceptance criteria pass.

Turning the flag off restores the current text-only behavior without changing OCR, queue state, or customer history.

## 12. Test Strategy

### 12.1 Unit tests

- Catalog parsing, stable IDs, hashes, and evidence levels.
- Exact model/problem/platform filtering.
- Prompt contains candidate IDs but not authority for model-authored URLs or paths.
- Reply schema backward compatibility.
- Validation rejects unknown IDs, wrong models, altered URLs, guessed timestamps, missing files, wrong hashes, and cross-video screenshots.
- Rendering omits empty sections and local paths.
- Bundle recovery never resends confirmed parts.

### 12.2 Retrieval and answer tests

- Exact video exists.
- Exact video with one screenshot.
- Exact video with two screenshots.
- Video exists without screenshots.
- Link exists without a verified time.
- Similar model only.
- Wrong platform only.
- Customer sends a malicious link or instruction-bearing file.
- Multiple customer questions where only one has relevant media.
- Troubleshooting continuation where media belongs to a later step.

### 12.3 Regression and blind evaluation

- Re-run the existing text-only suite with the feature disabled and enabled.
- Blind-test no-media answers to confirm answer accuracy does not regress.
- Measure no-media and media latency separately.
- Require no fabricated or mismatched URL, timestamp, screenshot, model, or platform across the acceptance set.

### 12.4 Computer Use acceptance

Using test buyer accounts only:

- Text only.
- Text plus video URL/time.
- Text plus one image.
- Text plus two images.
- Customer sends new messages during multipart delivery.
- Another customer receives an unread message during delivery.
- Qianniu is backgrounded before delivery.
- Missing image, warning, network delay, uncertain image confirmation, and application restart.

## 13. Acceptance Criteria

- Ordinary text replies remain fully automatic and do not depend on media success.
- No verified-media test sends a fabricated or mismatched URL, time, screenshot, model, or platform.
- Media errors never stop global unread scanning or block other customers.
- A customer batch is answered once; completed message parts are not duplicated after restart.
- The frozen current version remains recoverable.
- All existing automated tests and the new media tests pass.
- Real-account Computer Use tests pass from the user's perspective before installation replaces the test build.

