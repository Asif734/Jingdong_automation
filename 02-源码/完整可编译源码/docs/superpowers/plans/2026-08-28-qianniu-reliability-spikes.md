# Qianniu Reliability Spikes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build three isolated, deterministic experiments for persistent run intent, uncertain-delivery reconciliation, and portable runtime resolution without touching production automation.

**Architecture:** A standalone Swift package contains three pure components. Tests use temporary directories and event reducers; no component imports production app targets or performs UI/network actions.

**Tech Stack:** Swift 5.9, XCTest, Foundation, CryptoKit.

**Spec:** `docs/superpowers/specs/2026-08-28-qianniu-reliability-spikes-design.md`

## Global Constraints

- Do not modify production OCR, discovery, scheduler, prompt, model, sender, or logging code.
- Do not launch Qianniu, Codex, or the installed production app.
- Do not delete or rotate any existing logs.
- Every experiment must use deterministic inputs and temporary directories.

---

### Task 1: Persistent Run Intent Reducer

**Files:**
- Create: `Experiments/ReliabilitySpikes/Package.swift`
- Create: `Experiments/ReliabilitySpikes/Tests/ReliabilitySpikesTests/RunIntentSupervisorTests.swift`
- Create: `Experiments/ReliabilitySpikes/Sources/ReliabilitySpikes/RunIntentSupervisor.swift`

**Interfaces:**
- Produces: `RunIntentStore`, `RunIntent`, `RuntimeReadiness`, `RunSupervisorState`, and `RunSupervisor.reduce(readiness:)`.

- [ ] Write tests proving running intent survives restart, stopped intent remains stopped, transient failures preserve intent, and retry delays are `1,2,5,10,30,30`.
- [ ] Run `swift test --filter RunIntentSupervisorTests` and confirm compilation/test failure because the interfaces do not exist.
- [ ] Implement atomic JSON persistence and the pure supervisor reducer.
- [ ] Re-run the focused tests and confirm they pass.

### Task 2: Uncertain Delivery Reconciler

**Files:**
- Create: `Experiments/ReliabilitySpikes/Tests/ReliabilitySpikesTests/DeliveryReconcilerTests.swift`
- Create: `Experiments/ReliabilitySpikes/Sources/ReliabilitySpikes/DeliveryReconciler.swift`

**Interfaces:**
- Produces: `DeliveryAttempt`, `DeliveryObservation`, `DeliveryAction`, and `DeliveryReconciler.observe(_:)`.

- [ ] Write tests for exact confirmation, three stable misses causing one resend, unreadable observations causing no progress, and post-resend exhaustion producing a terminal released result with cursor advancement.
- [ ] Run `swift test --filter DeliveryReconcilerTests` and confirm failure because the interfaces do not exist.
- [ ] Implement the minimal deterministic state machine with a hard resend limit of one.
- [ ] Re-run focused tests and confirm they pass.

### Task 3: Portable Runtime Resolver

**Files:**
- Create: `Experiments/ReliabilitySpikes/Tests/ReliabilitySpikesTests/PortableRuntimeResolverTests.swift`
- Create: `Experiments/ReliabilitySpikes/Sources/ReliabilitySpikes/PortableRuntimeResolver.swift`

**Interfaces:**
- Produces: `RuntimeLayout`, `RuntimeHealthReport`, `RuntimeComponentStatus`, and `PortableRuntimeResolver.inspect()`.

- [ ] Write tests proving bundle-relative Python wins, missing Python blocks, a moved/missing knowledge base blocks, a later Codex candidate is selected, and resolved paths contain no fixed username.
- [ ] Run `swift test --filter PortableRuntimeResolverTests` and confirm failure because the interfaces do not exist.
- [ ] Implement the resolver and explicit health report without fallback behavior.
- [ ] Re-run focused tests and confirm they pass.

### Task 4: Isolation and Full Verification

**Files:**
- Test: `Experiments/ReliabilitySpikes/Tests/ReliabilitySpikesTests/*`

- [ ] Run `swift test` inside the experiment package.
- [ ] Run the production `swift test` suite to prove the experiment did not break existing code.
- [ ] Compare the installed production executable SHA-256 against its pre-experiment value `a97db509175df3628b5ac3927af195d44fe6c65ce336cdb369ba32943158b0fd`.
- [ ] Verify `git diff -- Sources Tests components scripts` contains no experiment-caused production edits.
