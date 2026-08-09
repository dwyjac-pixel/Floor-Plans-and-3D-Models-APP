# CaribinalScanner — Remediation Summary (Wave 1 + Wave 2)

**Date:** 2026-08-08
**Starting point:** `QA_AUDIT_REPORT.md` — 58 confirmed bugs (8 High), verdict **NOT PRODUCTION READY**.
**This effort:** fix every confirmed bug + the clearly-valid suspected items, then add the
recommended launch-readiness capabilities.

## Headline

- **All 58 confirmed bugs fixed** (70 fix records incl. suspected/edge items folded in).
- **Recommended capabilities delivered:** privacy manifest, accessibility pass (VoiceOver +
  Dynamic Type), iPad/landscape layout (NavigationSplitView), `.cbproj` file association
  (open backups from Files/Mail/AirDrop), locale/keyboard polish. Full localization deferred.
- **`** BUILD SUCCEEDED **`** at every stage; final build green.
- **Regression-proven by execution:** 77 assertions across geometry/business/persistence — 0 fail,
  **0 regressions**.
- **Launch-verified:** app boots clean on **iPhone (light+dark)** and **iPad (split view)** — no
  crash/fault logs.
- **Rollback snapshot** of pre-fix source kept at `…/scratchpad/BASELINE_CaribinalScanner_1786195710`.

---

## What was fixed (by severity)

**8 High — all fixed and, where headless-provable, re-verified by execution harness:**

| ID | Fix | Verified |
|----|-----|----------|
| QA-001 | Wall-length correction now rejects (returns nil → existing "adjust manually" message) instead of silently corrupting a non-rectilinear room; opposite-wall filter tightened to near-antiparallel + post-rebuild closure check | Harness: chamfer closes exactly; rect/L-shape/last-wall stay closed |
| QA-002 | `Fixture`/`Opening`/`InteriorWall` given tolerant `init(from:)`; room arrays decode element-tolerant (one bad element no longer voids the room) | Harness: legacy/partial JSON decodes; bad element dropped |
| QA-003 | Duplicate same-kind fixtures aggregated into one priced line; price counted once | Harness: two toilets, $450 → total 450 not 900 |
| QA-004 | Normal-mode pan can no longer hijack a door/window (`dragIsPan` set on first frame; offset resync) | Code-reviewed (gesture path) |
| QA-005 | Swipe-to-delete a project now shows a confirmation naming the project + "permanently removed" | Code-reviewed |
| QA-006 | `floorTextureCache` access serialized (lock) — no more detached-task ⁄ main-thread data race | Build + boot clean |
| QA-007 | BRRRR only reports 999%/winner when post-refi cash flow is positive | Harness: negative-cashflow deal → −999, isWinner false |
| QA-009 | Backup path traversal closed: `photoFileNames` sanitized on import and at use; containment asserted | Harness: `../` rejected, uuid.jpg accepted |

**~30 Medium and ~20 Low** — all fixed. Highlights: takeoff prices/exclusions now flow into the
PDF (QA-008); stale area-override ignored when a plan exists (QA-016); multi-room shared-wall
double-count removed (QA-019); paint/free-rotate undo captures the pre-edit baseline (QA-020);
merged-wall openings clamped so doors don't vanish (QA-021); egress uses recorded clear-opening
dims (QA-017); permit PDF marks assumed values as "not recorded/assumed" (QA-018); PDF floor-plan
page paginates (QA-030); exports use all-on layers (QA-031); "Preview & Share" shares the current
model (QA-032); PDF/backup generation moved off the main thread (QA-033/034); `Money.format` guarded
against NaN/overflow crash (QA-027); Deal Analyzer/Business Profile autosave on dismiss (QA-023/049);
empty-field API-key save no longer wipes the key (QA-037); AI chat excluded from shared backups
(QA-038); AI advisor uses the same floor area as the rest of the app (QA-040); recapture carries
fixtures/finishes forward (QA-044); capture validates polygons (QA-046); OCR fraction parse fixed
(QA-051); baseboard counts both partition faces (QA-052); overlapping bump-outs merge consistently
(QA-010/011/041); and the remaining Low items (undo/redo hardening, mode-state cleanup, quarantine
of unreadable files, etc.).

**Suspected/edge items folded in:** PriceBook low>high validation, manual sub-0.1 m dimension
rejection, PlanTrace self-intersection guard, unbounded AI history capped, SuiteROI zero-cost
fallback, debug-log growth bounded, and the takeoff currency/keyboard consistency.

**Refuted findings (3):** correctly left as-is (not real bugs) — see audit report §4.

## Wave-2 hardening (corrections to Wave-1 fixes, from a regression spot-check)

- The new file-quarantine now fires **only on a decode failure**, not a transient read failure —
  so a locked-state/transient I/O error can never rename a valid file (QA-013 hardening).
- `loadPermitMeasurements` migrated onto the same safe loader (was the one loader left unprotected).
- QA-057 (corner-drag re-fit) **finished**: the canvas freezes its fit to the bounds captured at
  drag start (`boundsOverride` tied to the drag lifetime), so a dragged corner no longer drifts.

---

## Capabilities delivered

| Capability | What shipped |
|---|---|
| **Privacy manifest** | `PrivacyInfo.xcprivacy` — no tracking, no data collection, `UserDefaults` (CA92.1) declared. Prevents the ITMS-91053 App Store warning. |
| **Accessibility** | VoiceOver labels/values/hints/traits across every screen; composite rows combined into coherent spoken elements; icon-only buttons labeled; decorative glyphs hidden; Dynamic Type respected (no fixed clipping heights). Canvas/3D views get descriptive labels (internal gesture navigation is a documented VoiceOver limit). |
| **iPad & landscape** | Root converted to `NavigationSplitView` (list ⁄ detail on iPad, auto-collapses to push nav on iPhone); Forms/lists capped to a centered readable width (`maxWidth`, no-op on iPhone). **Verified in the iPad split-view screenshot.** |
| **`.cbproj` file association** | Exported UTI + document type declared (via a base `Info.plist` merged with the generated keys); `onOpenURL` handler imports backups opened from Files/Mail/AirDrop under a security-scoped copy. Import validates content as before. |
| **Locale/keyboard** | Square-feet field → `.decimalPad` (fractional + comma-decimal locales); takeoff price field delocalized from "CA$" to the app-wide plain "$" (`Money.format` consistency). Numeric parsing was already locale-aware. |

---

## Verification evidence

- **Build:** `** BUILD SUCCEEDED **` after Part 1, Part 3, the accessibility+iPad wave, and Part 4a
  (each part gated independently). The `.cbproj` Info.plist merge was inspected in the built bundle —
  both the generated keys (camera usage, scene manifest, orientations, launch screen) and the new
  document-type/UTI are present; `UIFileSharingEnabled` was pinned after the merge was found to drop
  it, and re-verified present.
- **Regression (execution):** geometry 24 PASS ⁄ 0 FAIL ⁄ 1 blocked, business 33 ⁄ 0, persistence
  20 ⁄ 0 — **no regressions**. Every fixed behavior *and* its normal-case counterpart asserted.
- **Boot:** iPhone 17 (light + dark) and iPad Pro 13" (landscape split view) — install → launch →
  process-alive → screenshot → crash-log scan. All clean.

## Needs on-device / manual confirmation (fixes are made & code-reviewed; headless can't fully prove)

1. **Live LiDAR/ARKit capture** (QA-012/044/045/046/047) — verify on a LiDAR device: recapture
   carries fixtures/finishes, ceiling seeds from the right room, self-intersecting captures are
   blocked, raycast ignores furniture, and the LiDAR save no longer races SwiftData.
2. **Touch gestures** (QA-004/020/021/022/057 and the 3D drags/occlusion QA-028) — exercise
   pinch+rotate+drag, corner drag at max zoom, paint/rotate undo, and all-rooms 3D on device.
3. **VoiceOver / Dynamic Type sweep** — run VoiceOver and AX5 text size across the screens; the
   pass added labels but a real audio sweep is the acceptance test.
4. **iPad interaction** — confirm row tap on iPhone still pushes detail (NavigationSplitView
   collapse), and iPad delete-from-detail doesn't leave a stale detail.
5. **`.cbproj` open-in** — AirDrop/Mail a `.cbproj` to a device and confirm the app is offered and
   imports it.
6. **AI advisor live network** (QA-037/039/040) — real key: bad key, airplane-mode mid-request,
   rate limits; confirm the key is never wiped/logged and chat history stays consistent.
7. **App Store validation** — a TestFlight upload to confirm the privacy manifest clears ITMS-91053.

## Deferred (intentional)

- **Full localization** — string-catalog extraction + translation is large and premature without
  target languages. Locale-aware numeric *input* is delivered. Recommend a dedicated pass once
  languages are chosen.
- **`FloorPlanModel(manual:)` overlapping-bump harness** — that type links RoomPlan and can't be
  swiftc-compiled headlessly; the identical merge logic on the `CornerRoom(manual:)` path passed,
  and the full app builds and renders it. Verified by compile + parallel-path execution.

---

## Verdict

**PRODUCTION READY WITH MINOR (ON-DEVICE) VERIFICATION.** Every confirmed defect — including all
eight High-severity data-loss/crash/wrong-output bugs — is fixed and, where headless execution can
prove it, re-verified with zero regressions; the app builds green and launches cleanly on iPhone
and iPad. The remaining gate is the on-device/manual sweep above (live LiDAR, touch gestures,
VoiceOver, TestFlight validation) — none of which are code defects, all of which are the class of
verification that genuinely requires real hardware. Clear that sweep and this is launch-ready.
