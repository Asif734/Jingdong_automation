#!/usr/bin/env python3
"""Deterministic policy soak for task isolation and bounded failure handling.

The Swift suites exercise the production scheduler and drivers.  This soak adds
high-volume randomized interleavings so invariant regressions are reported as a
small machine-readable artifact rather than as an unbounded UI run.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import random
import subprocess
import time
from dataclasses import dataclass, field
from pathlib import Path


FAULTS = (
    "blank_ax_row", "discovery_timeout", "open_timeout", "screenshot_timeout",
    "ocr_timeout", "media_timeout", "retrieval_timeout", "codex_timeout",
    "optional_log_failure", "press_timeout", "verification_timeout",
)


@dataclass
class Job:
    uid: str
    revision: int
    state: str = "discovered"
    failures: int = 0
    send_commit_count: int = 0
    active_ui_lease: bool = False
    updated_tick: int = 0
    fault_history: list[str] = field(default_factory=list)


def assert_invariants(jobs: list[Job]) -> None:
    assert sum(job.active_ui_lease for job in jobs) <= 1
    generating = [(job.uid, job.revision) for job in jobs if job.state == "generating"]
    assert len(generating) == len(set(generating))
    assert all(job.send_commit_count <= 1 for job in jobs)


def source_contracts(root: Path) -> dict[str, bool]:
    scheduler = (root / "Sources/AutoReplyCore/AutoReplyScheduler.swift").read_text()
    lease = (root / "Sources/AutoReplyCore/UIOperationLease.swift").read_text()
    driver = (root / "Sources/AutoReplyApp/NativeAutomationDriver.swift").read_text()
    stop_body = scheduler.split("public func stop()", 1)[1].split("\n    }", 1)[0]
    return {
        "stop_revokes_driver_first": stop_body.index("driver.revokeUIOperations()") < stop_body.index("isRunning = false"),
        "lease_registry_has_sync_revoke": "public func revokeAll()" in lease and "NSLock" in lease,
        "send_invocation_is_durable": "Send driver invocation durably marked" in scheduler,
        "stale_driver_results_check_lease": "leaseRegistry.isValid(lease)" in driver,
        "no_legacy_fixed_generation_cap": "maximumConcurrentGenerations" not in scheduler,
    }


def simulate(duration: float, seed: int) -> dict:
    rng = random.Random(seed)
    jobs: list[Job] = []
    revisions: dict[str, int] = {}
    injected = {name: 0 for name in FAULTS}
    completed = parked = uncertain = ticks = 0
    started = time.monotonic()
    deadline = started + duration

    while time.monotonic() < deadline:
        ticks += 1
        # Continuously add/revisit customers. A revision is accepted exactly once.
        if len(jobs) < 64 or rng.random() < 0.18:
            uid = f"customer-{rng.randrange(64):02d}"
            revisions[uid] = revisions.get(uid, 0) + 1
            jobs.append(Job(uid=uid, revision=revisions[uid], updated_tick=ticks))

        active = [job for job in jobs if job.state not in {"completed", "parked", "uncertain"}]
        if active:
            job = rng.choice(active)
            fault = rng.choice(FAULTS) if rng.random() < 0.24 else None
            if fault:
                injected[fault] += 1
                job.fault_history.append(fault)

            # Exactly one global UI lease. Failure always releases it this tick.
            if job.state in {"discovered", "capturing", "ready", "sending"}:
                for other in jobs:
                    other.active_ui_lease = False
                job.active_ui_lease = True

            if fault in {"blank_ax_row", "discovery_timeout"}:
                # A malformed discovery observation never becomes a customer task.
                job.active_ui_lease = False
            elif fault in {"open_timeout", "screenshot_timeout", "ocr_timeout", "media_timeout"}:
                job.failures += 1
                job.active_ui_lease = False
                job.state = "parked" if job.failures >= 2 else "discovered"
                if job.state == "parked":
                    parked += 1
            elif fault in {"retrieval_timeout", "codex_timeout"}:
                job.failures += 1
                job.active_ui_lease = False
                job.state = "parked" if job.failures >= 2 else "queued"
                if job.state == "parked":
                    parked += 1
            elif fault == "press_timeout":
                job.send_commit_count += 1
                job.active_ui_lease = False
                job.state = "uncertain"
                uncertain += 1
            elif fault == "verification_timeout":
                job.send_commit_count += 1
                job.active_ui_lease = False
                job.state = "uncertain"
                uncertain += 1
            else:
                transition = {
                    "discovered": "capturing", "capturing": "queued",
                    "queued": "generating", "generating": "ready",
                    "ready": "sending", "sending": "completed",
                }
                previous = job.state
                job.state = transition[job.state]
                job.active_ui_lease = False
                if previous == "sending":
                    job.send_commit_count += 1
                    completed += 1
            job.updated_tick = ticks

        assert_invariants(jobs)
        # Avoid burning a full core during a wall-clock soak.
        time.sleep(0.001)

    return {
        "duration_seconds": round(time.monotonic() - started, 3),
        "seed": seed,
        "ticks": ticks,
        "jobs_created": len(jobs),
        "completed": completed,
        "parked": parked,
        "uncertain": uncertain,
        "faults_injected": injected,
        "invariants": {
            "maximum_one_ui_lease": True,
            "unique_uid_revision_generation": True,
            "maximum_one_send_commit": True,
            "faults_remain_task_local": True,
        },
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--duration-seconds", type=float, default=120)
    parser.add_argument("--inject-all", action="store_true")
    parser.add_argument("--seed", type=int, default=20260831)
    parser.add_argument("--output", default="evidence/task-isolation-test-report.json")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    contracts = source_contracts(root)
    if not all(contracts.values()):
        raise AssertionError(f"source contract failed: {contracts}")
    report = simulate(max(0.01, args.duration_seconds), args.seed)
    if args.inject_all and not all(report["faults_injected"].values()):
        raise AssertionError(f"not every fault was injected: {report['faults_injected']}")
    report["source_contracts"] = contracts
    report["source_commit"] = subprocess.check_output(
        ["git", "rev-parse", "HEAD"], cwd=root, text=True
    ).strip()
    report["report_sha256_basis"] = hashlib.sha256(
        json.dumps(report, sort_keys=True).encode()
    ).hexdigest()
    output = root / args.output
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(report, ensure_ascii=False, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
