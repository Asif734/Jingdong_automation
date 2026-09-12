# 千牛全自动客服-实验版

This repository builds a separate, stopped-by-default macOS scheduler app. It
does not replace the old installed apps, import their queues, or write to the
original customer-history root.

## Packaging

Run `scripts/build-app.sh`. It builds **arm64 only**, signs with `Apple
Development: Chu Ye Shi (6Q9HFP6LJJ)`, and writes:

`output/千牛全自动客服-实验版.app`

The script refuses to replace an unrelated bundle or a running instance of the
new executable. Before replacement it moves an older build to
`output/previous-builds/` with a timestamp, so the previous build remains
recoverable. It does not install or launch the app.

The bundle contains the root `Contents/Resources/WebOCR` payload selected by
`ResourceRootSelection` and the required
`QianniuCodexBatchRunner_CustomerReplyBatchAppSupport.bundle` schema. The OCR
SwiftPM fallback resource bundle is intentionally not copied, avoiding a second
copy of the same large offline assets.

## Integrity checks

Run `scripts/verify-baseline.py` to SHA-256 verify the frozen baseline,
protected old component sources, the two copied algorithm files, and signatures
of frozen plus installed old apps. `scripts/verify-baseline.py --self-test`
uses a temporary fixture: unchanged protected bytes pass; altered bytes fail.

New terminal records keep immutable JSON evidence under
`运行状态/调度器/archive/records/`. When a generated answer reaches a terminal
archive, a derived read-only text sidecar is written to
`运行状态/调度器/archive/replies/<job-id>.txt`. It includes job ID, UID, terminal
state, answer, and a conservative delivery outcome. It is not a queue, is never
read by the scheduler loop, and never labels superseded or uncertain work as
sent.

Each UID also has a durable answered cursor. A generated reply owns one frozen
customer-only range `(startCursor, endCursor]`; customer messages that arrive
while that reply is being generated remain in the following range instead of
replacing the ready reply. Only a verified `.sent` result advances the cursor.
Failed or uncertain delivery leaves it unchanged, and the scheduler captures
the remaining customer range again without requiring another unread dot.

## Rollback and live validation

Rollback restores the frozen old app bundles only after stopping this new app.
Do not restore old queues or overwrite newer histories: that can resend a
completed reply. The isolated runtime is `/Users/scy/Desktop/AI客服记录-全自动版`
and contains copied `用户` context only.

Real permission approval, install/launch, phone-driven end-to-end validation,
and message sending are controller-owned and remain pending until separately
recorded evidence exists.
