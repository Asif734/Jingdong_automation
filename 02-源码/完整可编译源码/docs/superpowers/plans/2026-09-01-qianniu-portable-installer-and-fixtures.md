# Qianniu Portable Installer and Cross-Machine Fixtures Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver one install-and-run DMG, privacy-safe diagnostics, and reproducible colleague A/B/current-machine compatibility gates for the completed adaptive runtime.

**Architecture:** A small signed installer app validates an embedded payload and installs it atomically to a fixed Applications directory before launch. A fixture exporter/replayer turns real machine structures into redacted regression inputs, while packaging tests enforce manifest, signing, rollback, resources, and privacy requirements.

**Tech Stack:** Swift 5.9/AppKit/SwiftUI, zsh packaging, Python unittest, `codesign`, `hdiutil`, optional `notarytool`, SHA-256 manifests.

**Spec:** `docs/superpowers/specs/2026-09-01-qianniu-universal-autoconfiguration-design.md`

## Global Constraints

- Execute after both foundation and adaptive-runtime plans pass.
- The DMG targets Apple Silicon; no Windows or multi-account automation is added.
- Never install or launch from WeChat, ZIP, DMG, or App Translocation paths.
- Installation must preserve the old App until the new payload passes hash/signature verification.
- The default diagnostic bundle contains no credentials, customer identifiers, full chat, raw full-screen captures, or personal Codex configuration.
- Ad-hoc internal packages must describe their Gatekeeper limitation honestly; notarized output is produced only with valid Developer ID credentials.

## File Map

- Create `Sources/QianniuInstallerApp/InstallerApplication.swift`: installer UI and state.
- Create `Sources/QianniuInstallerApp/InstallationTransaction.swift`: manifest validation, destination choice, backup, atomic install, launch.
- Create `Sources/AutoReplyApp/Autoconfiguration/DiagnosticBundleExporter.swift`: redacted diagnostic export.
- Create `Tests/Fixtures/Compatibility/{current,colleague-a,colleague-b}`: redacted snapshots and expected profiles.
- Create `Tests/CompatibilityFixturesTests/compatibility_fixture_test.py`: fixture schema/privacy/replay gate.
- Create `scripts/export-compatibility-fixture.swift`: one-click fixture capture through app-owned probe interfaces.
- Create `scripts/build-installer-app.sh`: build and embed payload.
- Create `scripts/build-distribution-dmg.sh`: build final DMG.
- Create `scripts/notarize-distribution.sh`: optional Developer ID notarization/stapling.
- Modify `Package.swift`, `scripts/build-app.sh`, and packaging tests.

---

### Task 1: Privacy-safe diagnostic and fixture exporter

**Files:**
- Create: `Sources/AutoReplyApp/Autoconfiguration/DiagnosticBundleExporter.swift`
- Modify: `Sources/AutoReplyApp/Autoconfiguration/FirstRunView.swift`
- Create: `scripts/export-compatibility-fixture.swift`
- Test: `Tests/AutoReplyAppTests/DiagnosticBundleExporterTests.swift`

**Interfaces:**
- Consumes: `CalibrationSnapshot`, `EnvironmentFingerprint`, current/candidate/last-known-good profiles, bounded structured errors.
- Produces: `DiagnosticBundleExporter.export(to:includeRawEvidence:)` and a ZIP-ready directory.

- [ ] **Step 1: Write default-redaction and explicit-raw-mode tests**

```swift
func testDefaultBundleContainsNoCustomerOrCredentialMaterial() throws {
    let exporter = DiagnosticBundleExporter.fixture(
        customerUID: "tb-secret", nickname: "secret-name", authToken: "secret-token"
    )
    let directory = try exporter.export(to: temporaryDirectory(), includeRawEvidence: false)
    let bytes = try allFileText(in: directory)
    XCTAssertFalse(bytes.contains("tb-secret"))
    XCTAssertFalse(bytes.contains("secret-name"))
    XCTAssertFalse(bytes.contains("secret-token"))
    XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("full-screen.png").path))
}
```

- [ ] **Step 2: Run and confirm RED**

Run: `swift test --filter DiagnosticBundleExporterTests`

Expected: exporter is absent.

- [ ] **Step 3: Implement fixed-schema export**

```swift
struct DiagnosticManifest: Codable, Equatable {
    let schemaVersion: Int
    let createdAt: Date
    let fingerprint: EnvironmentFingerprint
    let capabilityStates: [String: CapabilityStatus]
    let includedRawEvidence: Bool
}

struct DiagnosticBundleExporter {
    func export(to root: URL, includeRawEvidence: Bool) throws -> URL
}
```

Use category labels and relative frames from `CalibrationSnapshot`. Keep at most 200 structured errors. Add an advanced-view button titled `导出脱敏诊断包`; raw evidence mode is off by default and requires an explicit UI checkbox each export.

- [ ] **Step 4: Run exporter and full tests**

Run: `swift test --filter DiagnosticBundleExporterTests && swift test`

Expected: privacy assertions and full suite pass.

- [ ] **Step 5: Commit diagnostic export**

```bash
git add Sources/AutoReplyApp/Autoconfiguration/DiagnosticBundleExporter.swift Sources/AutoReplyApp/Autoconfiguration/FirstRunView.swift scripts/export-compatibility-fixture.swift Tests/AutoReplyAppTests/DiagnosticBundleExporterTests.swift
git commit -m "Export privacy-safe compatibility diagnostics"
```

---

### Task 2: Colleague A/B/current fixture bank and deterministic replay

**Files:**
- Create: `Tests/Fixtures/Compatibility/current/snapshot.json`
- Create: `Tests/Fixtures/Compatibility/current/expected-profile.json`
- Create: `Tests/Fixtures/Compatibility/colleague-a/snapshot.json`
- Create: `Tests/Fixtures/Compatibility/colleague-a/expected-profile.json`
- Create: `Tests/Fixtures/Compatibility/colleague-b/snapshot.json`
- Create: `Tests/Fixtures/Compatibility/colleague-b/expected-profile.json`
- Create: `Tests/CompatibilityFixturesTests/compatibility_fixture_test.py`
- Create: `Tests/AutoReplyAppTests/CompatibilityFixtureReplayTests.swift`

**Interfaces:**
- Consumes: diagnostic ZIPs already supplied by current machine and colleagues A/B.
- Produces: versioned redacted fixtures and expected capability/profile results.

- [ ] **Step 1: Write a fixture schema/privacy test before importing samples**

```python
class CompatibilityFixtureTest(unittest.TestCase):
    def test_all_fixtures_are_redacted_and_complete(self):
        for snapshot in FIXTURE_ROOT.glob("*/snapshot.json"):
            data = json.loads(snapshot.read_text(encoding="utf-8"))
            self.assertEqual(data["schemaVersion"], 1)
            self.assertNotIn("customerUID", json.dumps(data))
            self.assertNotIn("auth", json.dumps(data).lower())
            self.assertTrue((snapshot.parent / "expected-profile.json").is_file())
```

- [ ] **Step 2: Run and confirm RED**

Run: `python3 -m unittest Tests.CompatibilityFixturesTests.compatibility_fixture_test`

Expected: fixture directories/files are missing.

- [ ] **Step 3: Import only redacted structural evidence and define expectations**

The colleague B expected profile must classify the blank 34-point AXGroup as a section header and resolve `stoneshishininger` from the row container. Colleague A/current expectations must reflect their own observed source order; do not copy B's profile bytes between machines.

- [ ] **Step 4: Add Swift replay assertions**

```swift
func testAllCompatibilityFixturesProduceExpectedProfiles() throws {
    for fixture in try CompatibilityFixture.loadAll() {
        let actual = try AdaptiveCalibrationEngine.offline.calibrate(snapshot: fixture.snapshot)
        XCTAssertEqual(actual.normalizedForFixtureComparison(), fixture.expectedProfile)
    }
}
```

- [ ] **Step 5: Run fixture, component, and root suites**

Run:

```bash
python3 -m unittest Tests.CompatibilityFixturesTests.compatibility_fixture_test
swift test --filter CompatibilityFixtureReplayTests
swift test --package-path components/unread-source
swift test --package-path components/ocr-source
swift test --package-path components/sender-source
swift test
```

Expected: all three profiles pass from one binary.

- [ ] **Step 6: Commit fixture gates**

```bash
git add Tests/Fixtures/Compatibility Tests/CompatibilityFixturesTests Tests/AutoReplyAppTests/CompatibilityFixtureReplayTests.swift
git commit -m "Gate releases on cross-machine Qianniu fixtures"
```

---

### Task 3: Atomic installer transaction

**Files:**
- Modify: `Package.swift`
- Create: `Sources/QianniuInstallerApp/InstallationTransaction.swift`
- Create: `Sources/QianniuInstallerApp/InstallerApplication.swift`
- Create: `Tests/QianniuInstallerAppTests/InstallationTransactionTests.swift`

**Interfaces:**
- Produces: executable target `QianniuInstallerApp` and `InstallationTransaction.install(payload:manifest:destinations:)`.
- Consumes: embedded main App payload and `distribution-manifest.json`.

- [ ] **Step 1: Write destination, validation, backup, and rollback tests**

```swift
func testUsesUserApplicationsWhenSystemApplicationsIsNotWritable() throws {
    let transaction = InstallationTransaction(fileSystem: FixtureFileSystem(systemWritable: false))
    XCTAssertEqual(try transaction.chooseDestination().path, "/Users/test/Applications/千牛全自动客服-通用自适应版.app")
}

func testHashFailureLeavesExistingApplicationUntouched() throws {
    let fileSystem = FixtureFileSystem(existingAppBytes: Data("old".utf8))
    let transaction = InstallationTransaction(fileSystem: fileSystem)
    XCTAssertThrowsError(try transaction.install(payload: .badHashFixture, manifest: .fixture, destinations: .fixture))
    XCTAssertEqual(fileSystem.installedAppBytes, Data("old".utf8))
}
```

- [ ] **Step 2: Run and confirm RED**

Run: `swift test --filter InstallationTransactionTests`

Expected: target and transaction types are absent.

- [ ] **Step 3: Implement same-volume staging and atomic replacement**

```swift
struct DistributionManifest: Codable, Equatable {
    let schemaVersion: Int
    let appVersion: String
    let appSHA256: String
    let architecture: String
}

struct InstallationReceipt: Codable, Equatable {
    let installedAt: Date
    let destinationURL: URL
    let appVersion: String
    let appSHA256: String
}

struct InstallationTransaction {
    func chooseDestination() throws -> URL
    func install(payload: URL, manifest: DistributionManifest, destinations: InstallationDestinations) throws -> InstallationReceipt
}
```

Stage beside the destination, verify payload hash and `arm64`, verify code signature, rename old App to a timestamped backup, rename staged App into place, verify again, then remove only backups older than the retention limit. Restore the backup on any post-rename failure. Only after final verification succeeds may `InstallerApplication` call `NSWorkspace.shared.open(receipt.destinationURL)`; it must never launch the embedded payload or staging path.

- [ ] **Step 4: Run installer and full Swift tests**

Run: `swift test --filter InstallationTransactionTests && swift test`

Expected: atomic-install fixtures and existing suites pass.

- [ ] **Step 5: Commit installer transaction**

```bash
git add Package.swift Sources/QianniuInstallerApp Tests/QianniuInstallerAppTests
git commit -m "Add atomic install-and-launch application"
```

---

### Task 4: Build embedded payload and final DMG

**Files:**
- Create: `scripts/build-installer-app.sh`
- Create: `scripts/build-distribution-dmg.sh`
- Modify: `scripts/build-app.sh`
- Create: `Tests/Packaging/installer_payload_test.py`
- Create: `Tests/Packaging/distribution_dmg_test.sh`

**Interfaces:**
- Produces: `build-output/千牛全自动客服-通用自适应版.dmg` containing only `安装并启动.app` and a short readme.
- Consumes: main App, installer target, payload manifest, signing environment.

- [ ] **Step 1: Write packaging contract tests**

```python
def test_manifest_covers_every_payload_file(self):
    manifest = json.loads((self.payload / "distribution-manifest.json").read_text())
    actual = sorted(relative_files(self.payload / "千牛全自动客服-通用自适应版.app"))
    self.assertEqual(sorted(manifest["files"]), actual)
    self.assertEqual(manifest["architecture"], "arm64")
```

The shell DMG test must mount the image read-only, assert `安装并启动.app` exists, assert the main App is embedded inside the installer resources, and verify both signatures.

- [ ] **Step 2: Run and confirm RED**

Run: `python3 Tests/Packaging/installer_payload_test.py && zsh Tests/Packaging/distribution_dmg_test.sh`

Expected: build scripts and artifacts are absent.

- [ ] **Step 3: Implement reproducible payload/DMG scripts**

`build-installer-app.sh` must call the existing `build-app.sh`, create a per-file SHA-256 manifest, embed the App without following external symlinks, sign nested binaries from inside out, then sign the installer. `build-distribution-dmg.sh` stages the installer and readme, creates a UDZO DMG, mounts it, re-verifies hashes/signatures, then unmounts it.

- [ ] **Step 4: Run package and existing developer-delivery tests**

Run:

```bash
python3 Tests/Packaging/installer_payload_test.py
zsh Tests/Packaging/distribution_dmg_test.sh
python3 Tests/Packaging/developer_delivery_test.py
python3 Tests/Packaging/verify_baseline_test.py
```

Expected: all pass in ad-hoc mode without querying unavailable certificates.

- [ ] **Step 5: Build an actual internal DMG and inspect it**

Run: `AUTOREPLY_SIGNING_IDENTITY=- scripts/build-distribution-dmg.sh`

Expected: DMG exists, mounts, installer launches from the installed fixed path, and manifest checks pass.

- [ ] **Step 6: Commit distribution packaging**

```bash
git add scripts/build-app.sh scripts/build-installer-app.sh scripts/build-distribution-dmg.sh Tests/Packaging
git commit -m "Package universal Qianniu install-and-run DMG"
```

---

### Task 5: Optional Developer ID notarization with honest fallback

**Files:**
- Create: `scripts/notarize-distribution.sh`
- Modify: `scripts/build-distribution-dmg.sh`
- Create: `Tests/Packaging/notarization_mode_test.py`
- Create: `Packaging/首次安装说明.txt`

**Interfaces:**
- Consumes: `AUTOREPLY_SIGNING_IDENTITY`, `AUTOREPLY_NOTARY_PROFILE`, and built DMG.
- Produces: stapled notarized DMG only when both Developer ID signing and notary credentials are valid.

- [ ] **Step 1: Write explicit-mode tests**

```python
def test_ad_hoc_mode_never_claims_notarized(self):
    result = run_notary(env={"AUTOREPLY_SIGNING_IDENTITY": "-"})
    self.assertNotEqual(result.returncode, 0)
    self.assertIn("NOTARIZATION_SKIPPED_ADHOC", result.stderr)

def test_missing_profile_fails_before_submission(self):
    result = run_notary(env={"AUTOREPLY_SIGNING_IDENTITY": "Developer ID Application: Test"})
    self.assertIn("AUTOREPLY_NOTARY_PROFILE", result.stderr)
```

- [ ] **Step 2: Run and confirm RED**

Run: `python3 Tests/Packaging/notarization_mode_test.py`

Expected: notarization script is absent.

- [ ] **Step 3: Implement strict notarization and install copy**

The script must run `codesign --verify --deep --strict`, submit with `xcrun notarytool submit --wait --keychain-profile`, require `Accepted`, staple, and run `spctl --assess`. Ad-hoc builds skip this script and the readme states the first-open Gatekeeper action.

- [ ] **Step 4: Run mode tests and signed dry-run validation**

Run: `python3 Tests/Packaging/notarization_mode_test.py && AUTOREPLY_SIGNING_IDENTITY=- scripts/build-distribution-dmg.sh`

Expected: mode tests pass and internal DMG does not claim notarization.

- [ ] **Step 5: Commit notarization support**

```bash
git add scripts/notarize-distribution.sh scripts/build-distribution-dmg.sh Tests/Packaging/notarization_mode_test.py Packaging/首次安装说明.txt
git commit -m "Add explicit notarized distribution path"
```

---

### Task 6: Fresh-machine and real-account acceptance runbook

**Files:**
- Create: `docs/千牛通用自适应版-首次安装与真机验收.md`
- Create: `Tests/Packaging/fresh_install_state_test.py`
- Modify: `docs/把这个文件交给Codex-项目完整接管与Debug手册.md`

**Interfaces:**
- Consumes: final DMG, compatibility fixture suite, first-run state machine, diagnostic exporter.
- Produces: exact A/B/current-machine acceptance evidence and operator/Codex recovery instructions.

- [ ] **Step 1: Write the fresh-state test contract**

```python
def test_fresh_install_reaches_read_only_ready_without_existing_profile(self):
    state = run_first_launch_fixture(
        permissions=True, qianniu=True, alias="小甘", codex_logged_in=True
    )
    self.assertEqual(state["phase"], "readOnlyReady")
    self.assertTrue(state["ocrPrepared"])
    self.assertTrue(state["v2Prepared"])
    self.assertTrue(state["profileCreated"])
```

- [ ] **Step 2: Run and confirm the fixture harness is missing**

Run: `python3 Tests/Packaging/fresh_install_state_test.py`

Expected: FAIL because the packaged test harness/readiness export is not yet wired.

- [ ] **Step 3: Add a no-send readiness export and complete the runbook**

The runbook must contain exact steps for: install, permissions, Qianniu online/text mode, alias, dedicated Codex device login, read-only readiness, one text-message end-to-end test, one image test, diagnostic export, rollback, and stopping old versions. It must explicitly distinguish `readOnlyReady` from `endToEndVerified`.

- [ ] **Step 4: Execute all automated release gates**

Run:

```bash
swift test
swift test --package-path components/unread-source
swift test --package-path components/ocr-source
swift test --package-path components/sender-source
swift test --package-path components/batch-source
python3 -m unittest discover -s Tests -p '*test*.py'
zsh Tests/Packaging/distribution_dmg_test.sh
```

Expected: every gate passes from a clean build directory.

- [ ] **Step 5: Execute current-machine, colleague A, and colleague B truth-table tests**

For each machine, record:

```text
install fixed path: PASS/FAIL
permissions observed: PASS/FAIL
read-only calibration: PASS/FAIL
OCR prewarm: seconds
V2 prewarm: seconds
Codex isolated login: PASS/FAIL
text end-to-end: PASS/FAIL and total seconds
image end-to-end: PASS/FAIL and total seconds
profile strategy summary: attached
diagnostic privacy scan: PASS/FAIL
```

Do not call the release universal unless all three machines pass the text path and no fixture privacy test fails. Image failures may ship only if explicitly labeled as a known degraded capability and text remains unaffected.

- [ ] **Step 6: Commit the acceptance documentation and harness**

```bash
git add docs/千牛通用自适应版-首次安装与真机验收.md docs/把这个文件交给Codex-项目完整接管与Debug手册.md Tests/Packaging/fresh_install_state_test.py
git commit -m "Document and gate universal Qianniu rollout"
```

## Distribution Acceptance Checkpoint

- One DMG installs and launches from a fixed location without terminal commands.
- Existing installation remains recoverable after any failed install.
- Internal ad-hoc and formal notarized modes are clearly distinguished.
- A/B/current structural fixtures pass from the same binary.
- Default diagnostics are privacy-safe.
- Each real machine reaches read-only readiness and completes one text end-to-end test before universal release is claimed.
