# CaribinalScanner — Project Status (July 8, 2026)

46 Swift files · ~11,000 lines · builds clean · field-tested on iPhone 11.
Original plan: [PLAN.md](PLAN.md). Build/usage guide: [README.md](README.md).

## Phase status vs the original plan

| Phase | Goal | Status |
|---|---|---|
| 1 — Prototype | Capture a room, floor plan, 3D, PDF | ✅ Done, verified on device |
| 2 — Business workflow | Projects, clients, notes, photos | ✅ Done |
| 3 — Floor plan editing | Corrections, walls, labels, markers | ✅ Done for camera-captured rooms (LiDAR scan editing deferred) |
| 4 — Renovation planning | Planning layer, suite checklist, estimate inputs | ✅ Done (suite assessment included) |
| 5 — Export system | Branded PDF, plan image, measurements | ✅ Done (incl. DXF/CAD export) |
| 6 — Cloud & team | Login, sync, backup | ⬜ Not started (next major milestone) |
| 7 — Marketable product | Subscriptions, onboarding, Android | ⬜ Future |

## What works today (verified on the user's iPhone 11)

- **Projects**: dashboard with search, status chips (estimate/permit),
  client/property details, notes, captioned photos. SwiftData, on-device.
- **Capture** (three ways):
  - AR corner capture — walk the room, mark floor corners (green crosshair,
    turntable-stable tracking, wall squaring). Works without LiDAR.
  - Manual entry — rectangle + bump-outs, doors/windows; one tap converts
    it to a captured-style room with the full drawing toolset (and 3D).
  - LiDAR RoomPlan scan — fully built, untested (no LiDAR device yet).
- **Multi-room projects**: named rooms (rename/recapture/retrace/delete
  per room), merged floor plan + 3D model, per-room editing scope via a
  room picker, takeoff/estimate/assessment summed across rooms, per-room
  areas in the PDF. Old single-room projects migrate automatically.
- **2D floor plan**: zoom/pan/rotate, customizable style (line weight, wall/
  door/window/background colours), tape-measure dimension corrections,
  wall editor (drag corners, split, remove), interior walls/closets,
  doors + windows, 17-item fixture catalog in 4 room categories with
  architectural symbols (stairs treads, toilet, tub, beds…), markers.
- **3D model**: turntable camera, dimension labels at wall bases + vertical
  height line, real door/window openings (headers/sills), fixtures as built
  geometry (stairs climb to the ceiling), drag fixtures in 3D, add doors/
  windows by tapping walls, USDZ export.
- **Planning & estimating**: renovation checklist, live suite assessment
  (bedroom capacity + legal-suite gaps), estimate calculator with full
  input set driven by an **editable Price Book** (per-sqft, room, and
  service rates; low/high ranges; shipped defaults calibrated for
  bathrooms $8–12k basic / $14–16k std+ and egress $4,700).
- **Suite Compliance Check** (the market differentiator): code-aware
  checks computed from the scan — egress window sizing per bedroom
  (0.35 m² / 380 mm, casement-vs-slider aware), natural-light ratio,
  sill heights, ceiling height, suite area — plus declared checks
  (entrance, fire separation, smoke/CO, bathroom, kitchen, sound) from
  the checklist/estimate/fixtures. Manitoba NBC-based preset; in-app
  screen + PDF page; clearly labelled guidance.
- **Suite ROI / payback**: rent, vacancy, and cost inputs against the
  estimate midpoint → net income, payback years, yield, 10-year
  position. Per-project (roi.json); Investment Outlook page in the PDF.
- **Tape-measure accuracy check**: measure one wall, see the deviation,
  scale the whole room to match; correction badge on plan + PDF.
- **Exports**: branded multi-page PDF (details, styled plan with markers,
  proposed development + assessment, estimate, material takeoff, captioned
  photos), floor plan PNG, DXF CAD file (R12, mm, layered walls/doors/
  windows/fixtures/dimensions/labels), USDZ, Files-app access to raw files.
  Every generated file previews in-app (with name + size) before the
  share sheet opens — nothing leaves the app unseen.
- **Housekeeping**: per-source "Delete Floor Plan…" (LiDAR scan, captured
  rooms, or manual measurements) with confirmation — photos, notes,
  estimate, and planning survive.
- **Backup & transfer**: one-tap single-file project backup (.cbproj —
  every file plus the project record) with preview-before-send; import
  from the dashboard ⋯ menu. The pre-cloud safety net.
- **Permit package**: bordered drawing sheets with a real title block
  (business, project, client, sheet number, date), north arrow, approx.
  scale note — floor plan + suite compliance + material takeoff in one
  submission-ready PDF. Plans draw with drafting double-line walls
  (style toggle), exterior dimension strings, and auto room labels
  (name + area at each room's centre).

## Known limitations

- Free Apple ID: app signature expires every 7 days — re-Run from Xcode.
- Rooms auto-place side by side on the merged plan; no drag-to-arrange yet.
- All data on-device only; no backup until cloud phase.
- AR capture accuracy vs tape not yet quantified by field test.
- Suite assessment thresholds are guidance, not code review.
- LiDAR path untested until a Pro device is available.

## Recommended next steps (in order)

1. **Cloud sync (Supabase, shared with EstiMater)** — backup, iPad access,
   client quote acceptance, the foundation for the Android/web dashboard
   strategy (PLAN.md §11). Needs the user's Supabase project + auth choices.
2. **Drafting mode** (DRAFTING_SPEC.md) — permit-grade drawings; combined
   with the compliance report it becomes a city-submittable permit package.
3. **AI trace assist (#5)** — Vision OCR of dimension labels for
   auto-scale on plan trace, document scanning, contour corner-snap.
4. **Field calibration** — real rates into the Price Book; takeoff
   constants; tape-check an AR capture on site.
5. **LiDAR device** (used iPhone 12/13 Pro) → test the RoomPlan path.
