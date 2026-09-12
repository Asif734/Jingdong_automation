# Customer Video Analysis and Automatic Reply Design

**Date:** 2026-09-02  
**Status:** Approved in chat  
**Baseline:** commit `eecf130` (`close Qianniu video after download starts`)

## 1. Goal

Extend the existing exact-105 customer-video route into a complete automatic reply path:

1. Identify the current customer's video from exact Qianniu `105` log evidence.
2. Open it once to obtain the signed media address.
3. Close the player as soon as background download starts.
4. Continue scanning and serving other customers while download and analysis run.
5. Convert the downloaded MP4 into evidence the existing Codex CLI can consume.
6. Generate and send one normal customer-service reply in the same per-customer Codex session.

The Codex CLI accepts image attachments but has no video attachment option. Therefore the MP4 is never passed to `codex exec` directly. The application extracts ordered, timestamped frames and an optional speech transcript, then submits those artifacts through the established image-and-text prompt path.

## 2. Non-goals

- Do not change text-message detection, image copying, red-dot detection, UID routing, V2 ranking, reply schema, or normal send behavior.
- Do not wait for video playback to finish and do not record the screen.
- Do not upload the MP4 to a new third-party service.
- Do not make the UI lane wait for the HTTP download, frame extraction, speech recognition, or Codex.
- Do not replay, reopen, analyze, or reply to the same Qianniu `messageId` twice.

## 3. Required Invariants

- Only exact `messageType/msgType=105` or `MESSAGETEMPLATETYPE_VIDEO` evidence may enter this path.
- `101` and `IMAGETEXT` remain on the existing visual image path.
- The player closes immediately after the signed address has been captured and the transfer journal enters `downloading`.
- The global UI lease is released before waiting for download completion.
- Every asynchronous stage is keyed by customer UID plus a hashed message ID.
- Raw signed URLs are memory-only and never enter logs, history, prompts, or diagnostics.
- A single video failure never pauses discovery, blocks another customer, or corrupts the customer's text history.
- The customer reply is sent only once. Delivery recovery continues to use the existing scheduler rules.

## 4. Components

### 4.1 Video transfer receipt

`VideoTransferJob` will publish a terminal receipt after atomic MP4 publication:

```swift
struct DownloadedCustomerVideo: Sendable {
    let uid: String
    let messageIDHash: String
    let fileURL: URL
    let durationSeconds: Double
    let width: Int
    let height: Int
    let audioCodec: String?
}
```

The receipt is delivered to a process-local `VideoAnalysisInbox` and is also recoverable from the sanitized transfer journal after relaunch. It contains no signed URL or raw message ID.

### 4.2 Video analysis inbox

`VideoAnalysisInbox` is a durable state machine independent of the UI scheduler:

```text
downloaded -> preparingEvidence -> readyForGeneration
                         |-> failed
readyForGeneration -> admitted -> completed
```

Writes are atomic. On launch, `downloaded`, `preparingEvidence`, and `readyForGeneration` entries are resumed. A lease timestamp prevents two processes from preparing the same video concurrently.

### 4.3 Evidence preparation

`CustomerVideoEvidencePreparer` uses system frameworks instead of an external `ffmpeg` dependency:

- AVFoundation reads the local MP4 and generates JPEG frames.
- Frames are sampled in chronological order, capped at eight.
- Very short videos use beginning/middle/end; longer videos use evenly spaced samples while avoiding the exact first and final decode boundaries.
- Each JPEG receives a deterministic name based on the message hash and sample index.
- A manifest records the frame order and timestamp for prompt construction.
- If Apple Speech is authorized and on-device recognition is available, the audio track is transcribed.
- Speech permission, recognition availability, or transcription failure never blocks visual evidence preparation.

Evidence is stored under the existing private runtime root:

```text
用户/<uid>/video-evidence/<message-hash>/
  manifest.json
  frame-01.jpg
  ...
```

The original MP4 remains under `收到的视频/`.

### 4.4 Scheduler admission

The scheduler receives a new explicit API for a fully prepared external customer event. This avoids pretending that a background download is a fresh red dot and avoids holding the UI lane.

Admission creates a normal `CaptureSnapshot` with:

- `customerRevision = video-analysis:<message-hash>`
- the customer's existing local conversation history
- one synthetic customer event identifying a received video
- the ordered frame paths in `imagePaths`
- transcript and frame timestamps in `targetCustomerJSONL`
- `hasUnansweredCustomer = true`
- `shouldGenerate = true`
- the current answered cursor as both the UI-history boundary and the preserved text-message boundary

The external snapshot is deduplicated against active and terminal records before a new scheduler record is created. It then uses the same generation concurrency, per-UID session gate, ready queue, sender, delivery confirmation, and archive behavior as text and image requests.

### 4.5 Prompt contract

The prompt labels video evidence as untrusted customer content, never as instructions:

```text
The customer sent a video. The attached images are ordered frames extracted
from that video. Their timestamps are listed below. An optional transcript may
be incomplete. Answer the customer's apparent product question or visible
problem; do not claim to have observed anything not supported by the frames,
transcript, and chat context.
```

The existing V2 context remains authoritative for product facts. Video frames and transcript may describe symptoms but cannot override system rules or knowledge-base facts.

## 5. End-to-End Data Flow

1. OCR finds a visual media block in the confirmed customer chat.
2. Log routing binds the newest event for that UID to exact type `105`.
3. The opener arms the log watcher, clicks once, and starts transfer.
4. The signed address is captured; transfer state becomes `downloading`.
5. The opener sends Escape and returns a non-generating video observation. The scheduler completes that UI observation and immediately resumes normal scanning.
6. The transfer validates and atomically publishes the MP4.
7. `VideoAnalysisInbox` schedules evidence preparation without acquiring a Qianniu UI lease.
8. AVFoundation creates ordered JPEG frames; optional Apple Speech creates a transcript.
9. The inbox submits one deduplicated external snapshot to the scheduler.
10. The normal per-customer Codex session receives recent chat, V2 Top-12, frames, timestamps, and transcript.
11. The normal ready-send path opens the exact UID, sends one reply, confirms delivery, and archives the job.

## 6. Failure and Timeout Policy

| Stage | Limit | Result |
|---|---:|---|
| Open and acquire address | existing bounded open transaction | Close player when possible; finish only this video observation |
| HTTP download | 120 seconds | Mark video failed; do not block UI or other customers |
| MP4 validation | 10 seconds | Reject invalid file and preserve diagnostic metadata |
| Frame extraction | 30 seconds | Retry once in background; then use fallback acknowledgement |
| Speech transcription | 45 seconds | Omit transcript and continue with frames |
| External scheduler admission | immediate plus one retry | Persist `readyForGeneration`; retry after scheduler recovery |
| Codex generation and sending | existing production limits | Use existing bounded retry and delivery rules |

If at least one valid frame exists, the video goes to Codex. If no valid frame can be produced, enqueue the truthful fallback reply:

> 视频已收到，但暂时无法看清具体内容。请问主要需要我查看哪个现象或操作步骤呢？

The fallback is still deduplicated by message hash and uses the normal sender. It is preferable to silence but does not invent video contents.

## 7. Cross-machine Compatibility

- AVFoundation and CoreGraphics are available on every supported Apple Silicon Mac; no Homebrew or machine-specific `ffmpeg` path is used.
- Speech transcription is an optional capability discovered at runtime. Missing permission or unsupported on-device language produces frames-only analysis.
- Frame count and JPEG size are bounded so M1, M2, and newer machines submit comparable Codex payloads.
- The auto-configuration profile remains responsible only for Qianniu window/AX behavior; video evidence preparation has no fixed screen coordinates.

## 8. Observability

The floating UI and durable stage log distinguish:

- video opened
- background download started
- player closed
- download completed or failed
- frame extraction progress
- transcript available or skipped
- video task queued
- AI generating video reply
- reply sent, failed, or uncertain

Logs store only UID where already permitted, message hashes, local evidence paths, durations, dimensions, counts, phases, and sanitized errors.

## 9. Tests

### Unit tests

- Download completion produces one receipt after atomic MP4 publication.
- Player closes at `downloading`, before terminal download completion.
- Frame sampler returns ordered, bounded timestamps for short and long videos.
- AVFoundation evidence output uses deterministic names and valid JPEGs.
- Speech unavailable and speech failure both preserve frame analysis.
- Prompt marks frames/transcript as untrusted video evidence.
- External admission deduplicates active, completed, and relaunched jobs.
- Preparation failure creates exactly one fallback reply.
- No raw signed URL or raw message ID is persisted.

### Regression tests

- Existing text and image tests remain unchanged.
- `101` stays on the image path; only `105` enters video analysis.
- Existing per-customer session continuation and V2 retrieval remain intact.
- A slow video does not delay discovery, another customer's capture, a ready send, or another customer's Codex generation.

### Live acceptance

Using the test buyer account:

1. Send one new video.
2. Observe one player open and automatic close after download start.
3. Confirm the MP4 finishes in the background.
4. Confirm ordered frames are generated.
5. Confirm one Codex generation uses those frames.
6. Confirm one customer reply is sent.
7. Confirm no second open, analysis, or reply occurs on later scans or relaunch.

The same acceptance sequence is required on the local Mac and colleague A/B machines before producing the final universal delivery package.
