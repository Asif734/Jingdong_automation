# Qianniu Video Open and Background Download Integration Design

## Goal

When the existing visual media detector finds a visible customer-media candidate, use only exact Qianniu log evidence `messageType/msgType=105` (or `MESSAGETEMPLATETYPE_VIDEO`) for the current customer to route that observation to a video transaction. Arm a tail watcher before the click, open the video once, verify a new Qianniu-owned player window, then capture the newly emitted signed MP4 address and download it in the background. Complete the customer observation without creating a Codex request, replying, deleting, recording the screen, or closing the player. Continue serving other customers while the download runs.

## Invariants

- Keep the existing text and image algorithms unchanged.
- `101` and `IMAGETEXT` are not image evidence and continue through the visual image-copy path.
- No visual media candidate means the log cannot independently trigger a click.
- A video click requires the current routed customer, exact `105` message ID, a fresh customer-side media rectangle, and a valid UI lease.
- A message ID is clicked at most once, including after relaunch.
- The entire open transaction is bounded to ten seconds and cannot retain the global UI slot.
- The log watcher is armed synchronously before the click, so an address emitted immediately by Qianniu cannot be missed.
- Address wait and download are background work and never hold the UI lease.
- Signed URLs, raw customer IDs and raw message IDs are never persisted.
- A final file exists only after HTTP and media validation; H.264 and HEVC MP4 are both accepted.
- An opened video observation is terminal for that task but does not stop the scheduler.

## Data Flow

1. Existing discovery opens and confirms the unread customer.
2. Existing OCR and visual media detectors run.
3. Only when media rectangles exist, `QianniuMediaLogResolver` checks the newest exact event for the active customer.
4. Non-105 or unavailable evidence returns `copyImage` and runs the unchanged image-copy algorithm.
5. Exact 105 returns `openVideo(messageID)`.
6. The video opener selects the bottom-most high-confidence customer-side media rectangle, maps it to screen coordinates, reactivates the same reception window, hovers, recaptures, and locates the play triangle. The media center is allowed only when the candidate remains stable and satisfies the minimum video geometry.
7. Before clicking, the opener snapshots the current Qianniu log tail and existing window IDs. It performs exactly one click, starts the already-armed transfer job, and accepts open success only when a new Qianniu-owned player-like window appears.
8. The message ID is durably marked attempted before the click and opened after verification. A post-click uncertainty is never clicked again.
9. The transfer waits up to 30 seconds for a new MP4 candidate after the armed log offset, downloads to a hidden `.partial.mp4`, validates status/type/container/duration/video track, then atomically publishes `收到的视频/<message-sha256>.mp4`.
10. The transfer journal persists only sanitized hashes and media metadata. Failure removes partial files and cannot trigger image copying, Codex or a reply.
11. OCR returns `videoOpened(messageID)` to the native driver. The driver produces a non-generating terminal snapshot with revision derived from the video message ID, so the scheduler records completion and continues while transfer work finishes independently.

## Failure Policy

- Before-click failures do not click and return a non-generating failed video observation for this red-dot cycle.
- After-click uncertainty is durably recorded and never automatically clicked again.
- Timeout or cancellation revokes the lease and releases the scheduler UI slot.
- Address or download failure is recorded for that video only; it cannot stop scanning or block another customer.
- No failure may fall through into Codex generation for the same confirmed video event.

## Verification

- Unit tests cover exact-105 routing, 101 fallback, newest customer media target selection, one-click durability, pre-click watcher arming, new-window verification, timeout, sanitized download state, partial-file cleanup, and explicit non-generation.
- Existing image/text tests remain unchanged and pass.
- Recorded A/B fixtures must validate both H.264/AAC and HEVC/AAC MP4 files. Live acceptance on each colleague machine requires one test video: one player open, one verified file, zero Codex generations, zero sends/deletes, no URL leakage, and no reopen on the next scan or relaunch.
