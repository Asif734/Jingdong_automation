# Resilient Customer Video Download Design

**Date:** 2026-09-02  
**Status:** Approved in chat
**Baseline:** commit `533bb26` (`customer video analysis handoff guide`)

## 1. Problem and Goal

The current exact-105 route can identify and open a customer video, capture its signed MP4 URL, and start a background `URLSession.shared.download`. It treats download start as a completed video observation. If that single request later fails, the transfer journal records only `视频后台下载失败`, while the video-open and processed-event journals prevent another attempt. The result is a silent, permanent loss: no MP4, no evidence, no Codex task, and no customer reply.

The 2026-09-02 live failure demonstrated this sequence:

- One video downloaded and reached Codex normally.
- The next video produced a valid signed MP4 URL and entered `downloading`.
- The request timed out exactly 60 seconds later on an unreachable CDN edge.
- The same signed URL subsequently returned HTTP 200 and a valid `video/mp4` file in about 1.27 seconds after DNS selected a reachable edge.

The goal is to make video handling eventually resolve without blocking the UI lane or other customers. A transient CDN, DNS, network, application restart, or file-validation failure must never cause a video to be silently forgotten or retried forever.

## 2. Scope and Non-goals

This change covers only the exact-105 video transfer and its handoff to the existing video-analysis pipeline.

It does not change:

- text OCR, red-dot discovery, customer identity, image copying, link copying, V2 retrieval, Codex model, prompt facts, or normal sending;
- the rule that `101`/`IMAGETEXT` continues through the existing visual path;
- the existing requirement to open a video once when a signed URL is not already available;
- the existing per-customer scheduler and delivery-confirmation behavior.

Screen recording is not a normal download fallback. It may remain a separate future capability, but it is not part of this change.

## 3. Required Invariants

- Only an exact `105`/`MESSAGETEMPLATETYPE_VIDEO` event may enter the video downloader.
- `opened`, `downloaded`, `admittedToAI`, and `completed` are distinct states.
- Opening the player must not mark the message as fully processed.
- A visible in-flight video is skipped without being reopened, but remains eligible for its scheduled background retry.
- A transfer may be submitted to video analysis exactly once.
- A customer fallback acknowledgement may be sent at most once per message hash.
- A failure in one video never owns the Qianniu UI lease, blocks another customer, pauses discovery, or consumes a Codex concurrency slot.
- Raw message IDs and signed URLs never appear in user history, prompts, ordinary logs, exported diagnostics, or filenames.
- A final MP4 is published only after HTTP, size, container, and video-track validation.
- State survives application restart and resumes deterministically.
- No retry loop is unbounded in the foreground. Long-term recovery is scheduled and yields between attempts.

## 4. Durable State Machine

Replace the current independent "open attempt", "processed event", and terminal download records for videos with one coordinated durable transfer record keyed by `customerIdentityHash + messageHash`:

```text
discovered
  -> opening
  -> addressCaptured
  -> downloading
  -> validating
  -> downloaded
  -> preparingEvidence
  -> readyForAI
  -> admittedToAI
  -> completed

retryable failures:
  opening/address/download/validation -> waitingForRetry

customer-facing fallback is an orthogonal flag:
  waitingForRetry[fallbackAdmitted=false]
    -> waitingForRetry[fallbackAdmitted=true]
  the same record may still progress to downloaded -> ... -> completed
```

The record stores only the local routing and sanitized data required for recovery:

- validated customer UID when known, customer identity hash, and message hash;
- phase and attempt counters;
- timestamps, `nextAttemptAt`, and lease expiry;
- failure category and sanitized diagnostic detail;
- local partial/final filename after one exists;
- whether fallback acknowledgement has been admitted to the scheduler;
- whether evidence was admitted to the scheduler.

The customer UID already exists in local conversation history and is retained only so a retry can reopen the correct local conversation; diagnostic exports hash or omit it. Legacy journals contain only customer hashes, so an old unbound record remains quarantined until the same log event is observed and supplies a UID whose hash matches. The signed URL remains memory-only. If the app relaunches or the URL expires, a bound record returns to `opening` at its next scheduled retry, submits one external-discovery job for that UID through the shared scheduler UI lane, and lets Qianniu emit a fresh address.

The bounded queue continues to use atomic JSON writes. A process-local actor serializes mutations, and a 60-second renewable lease protects each job from duplicate workers after recovery.

## 5. Download Strategy

### 5.1 First attempt: normal system route

Use a dedicated ephemeral `URLSession` for every attempt rather than `URLSession.shared`:

- no persistent URL cache or cookies;
- `waitsForConnectivity = false`;
- connect timeout: 5 seconds;
- total first-attempt timeout: 15 seconds;
- cellular/constrained/expensive access allowed because these are small customer videos and the Mac may use varied networks;
- cancel and invalidate the session after success or failure.

The request must retain the original HTTPS hostname and signed query. Redirects are accepted only when the resulting scheme is HTTPS and the host remains in the approved Taobao video-host allowlist.

### 5.2 Immediate recovery: fresh route

For connection timeout, DNS failure, connection reset, or transient HTTP 408/425/429/500/502/503/504:

1. Destroy the failed session and wait a short jittered delay.
2. Create a fresh session and resolve again.
3. Retry without reopening Qianniu because the captured signed URL is still available in memory.

Non-retryable failures such as an invalid host, malformed URL, or definitively non-video content skip the immediate retry and return to the durable policy.

### 5.3 Alternate CDN route fallback

The live failure showed that different resolvers returned different CDN address pools and one entire pool was unreachable from the current network. A new session alone may continue receiving the same bad pool until its short DNS TTL expires.

After one system-route connection failure, the downloader uses an isolated helper based on `/usr/bin/curl` argument arrays when autoconfiguration has confirmed the helper and at least one alternate resolver are available (never a shell command string):

- resolve only the fixed approved video hostname through a bounded set of alternate DNS providers;
- validate every returned value as a public IPv4/IPv6 address;
- race a small number of addresses from distinct pools;
- use `--resolve` so TLS SNI, certificate validation, HTTP `Host`, path, and signed query remain the original Taobao hostname;
- terminate losing processes and their process groups immediately after one validated download succeeds;
- never print the command, URL, query, authorization token, or raw resolver response.

The fallback DNS query contains only the public hostname, never the signed path or customer information. If alternate DNS is unavailable, the state machine continues with timed recovery rather than blocking.

### 5.4 Validation and publication

Every attempt downloads to a unique hidden partial file. Success requires:

- HTTP 200 or 206;
- an accepted media MIME type, allowing absent MIME only until file inspection;
- non-zero bounded file size;
- valid MP4/QuickTime container readable by AVFoundation;
- at least one video track and positive duration;
- dimensions and codecs captured for diagnostics.

Only then is the file atomically renamed to `收到的视频/<message-hash>.mp4`. All losing or failed partial files are removed.

## 6. Retry and Customer-response Policy

### 6.1 Immediate attempts

The downloader gets a foreground-independent immediate budget of at most 30 seconds:

- one normal system-route attempt of at most 15 seconds;
- one alternate-route race of at most 15 seconds across no more than three validated addresses from at least two address pools, stopped as soon as one succeeds.

These attempts run in the background and never keep the video player or UI lease open.

### 6.2 Scheduled recovery

If immediate attempts fail, persist `waitingForRetry` and retry after the following delay from the preceding failure, with up to 10% random jitter to avoid synchronized traffic:

- 60 seconds;
- 180 seconds;
- 600 seconds.

If a signed URL is still present in the live process and valid, reuse it. Otherwise reopen the video once at the due time to obtain a fresh address. Repeated OCR scans see the in-flight/delayed record and do not create another job.

After the final scheduled failure, retain a terminal diagnostic record but never block future messages. If the customer sends the video again with a new message ID, it is a new event and may be processed normally.

### 6.3 Truthful fallback acknowledgement

If all immediate routes fail, enqueue exactly one normal customer reply through the existing scheduler:

> 亲，视频暂时加载失败，麻烦您重新发送一次或简单描述一下问题，我这边继续帮您查看。

This acknowledgement is deduplicated by message hash and is not treated as successful video analysis. Scheduled background recovery continues. If the video later succeeds, the actual evidence-based answer may be sent as a follow-up.

## 7. Error Taxonomy and Observability

Replace the generic `视频后台下载失败` with sanitized categories:

- DNS resolution failed;
- connect timeout;
- TLS/certificate failure;
- connection reset/offline;
- HTTP status rejected;
- redirect rejected;
- response timed out;
- invalid/empty/oversized content;
- invalid MP4 or missing video track;
- local file write/publication failure;
- retry budget exhausted.

The floating UI shows concise state such as:

- 视频下载中（第 1 次）
- CDN线路不可达，正在换线路
- 视频等待后台重试；不影响其他客户
- 视频已下载，正在准备 AI 证据
- 视频临时无法加载，已提示客户并继续后台恢复

Diagnostics include timing, selected strategy, sanitized IP-family/pool identifier, attempt count, and error category. They exclude raw URLs, query strings, customer text, and credentials.

## 8. Recovery and Deduplication Rules

- `video-open-attempts.json` may record the physical click but cannot by itself suppress a transfer forever.
- `processed-events.json` must not mark an exact-105 event complete at download start. Completion moves to `admittedToAI` or an explicit final state.
- If OCR sees the same message while it is `downloading`, `waitingForRetry`, or preparing evidence, it returns a non-generating observation and does not click.
- If a download callback is delivered twice, the inbox accepts the first atomic `downloaded` transition only.
- If the app crashes after MP4 publication but before journal update, startup scans validated orphan MP4 filenames and repairs the record.
- If the app crashes after scheduler admission, the existing external-event deduplication prevents a second Codex task.
- A fallback acknowledgement and a later evidence-based answer are separate, explicitly tracked sends; neither may repeat.

## 9. Cross-machine Behavior

The download pipeline does not depend on AX node positions, display scale, chip generation, or fixed customer IDs. It uses the existing adaptive UI layer only when a fresh signed address must be acquired.

Compatibility requirements:

- Apple Silicon M1, M2, and the local development Mac;
- colleague A and B Qianniu/macOS combinations;
- `/usr/bin/curl` capability checked during autoconfiguration;
- absent or blocked alternate DNS degrades to system-route scheduled recovery;
- all capability decisions recorded in the machine compatibility profile;
- installation preflight performs a small hostname-connectivity test without opening customer media or exposing signed URLs.

## 10. Testing

### 10.1 Unit and integration tests

- first attempt success publishes one MP4 and one completion;
- first network route times out, alternate route succeeds;
- all immediate routes fail and exactly one fallback is enqueued;
- scheduled retry later succeeds and sends one evidence-based follow-up;
- no raw URL appears in journals, logs, prompts, or diagnostics;
- failure categories preserve the underlying cause;
- in-flight OCR scans neither reopen nor mark complete;
- restart resumes `waitingForRetry` and orphan MP4 recovery;
- expired address causes one controlled reopen for a fresh address;
- invalid MIME, empty file, HTML error body, corrupt MP4, and missing video track are rejected;
- racing downloads publish only one winner and remove all partial files;
- `101` remains on the existing visual path and exact `105` remains the only video route;
- existing text, image, V2, per-customer session, and sender test suites remain unchanged and pass.

### 10.2 Fault-injection acceptance

- force the first CDN address pool to be unreachable;
- disconnect and reconnect Wi-Fi during download;
- terminate and relaunch the app in every durable state;
- send two videos consecutively;
- send text while a video is retrying;
- verify another customer's ready reply sends while download recovery continues;
- verify the fallback message and later analysis answer each occur at most once.

### 10.3 Live A/B acceptance

On the local Mac and colleague A/B machines:

- send at least 20 normal videos per machine;
- require every event to reach either validated analysis or the truthful fallback, with zero silent losses;
- require normal successful downloads to begin within 5 seconds and ordinarily finish within 20 seconds;
- verify no repeated player opening, image-copy fallback, duplicate Codex task, or duplicate customer reply;
- export and compare sanitized compatibility and transfer reports.

The release package is produced only after all automated tests pass and at least the local live fault-injection path plus one real colleague-machine path pass.

## 11. Rollout and Rollback

- Implement in the current isolated video-integration worktree.
- Preserve the currently installed app and its runtime records as a rollback snapshot.
- Migrate a legacy record with a validated local MP4 to `downloaded` so evidence preparation can resume; use `completed` only when legacy scheduler evidence proves terminal delivery accounting.
- Migrate existing failed video records to `waitingForRetry` without inventing or persisting signed URLs.
- Start with the local test account, then colleague B, then colleague A.
- Keep a feature flag that can disable alternate-route resolution while retaining system-route retries and durable state.
- Rollback restores the previous application bundle without deleting downloaded videos, customer history, or diagnostics.
