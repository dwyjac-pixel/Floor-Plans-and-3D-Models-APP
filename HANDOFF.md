# HANDOFF — CaribinalScanner (July 8, 2026)

## The goal
~~#2 Multi-room projects~~ done, then **#4 DXF export** + a user ask
(**delete-plan option**) — both ✅ COMPLETE, build verified (see below).
Next: #5 AI trace assist, then #1 cloud sync; #3 awaits LiDAR hardware.

## ✅ ALSO COMPLETE (July 8, 2026, second round)
- **Delete Floor Plan…** (user request): destructive button at the end of
  Scan & Measurements when a plan exists → confirmationDialog with one
  destructive option per existing source (LiDAR scan / all rooms / manual).
  `cleanUpAfterPlanDelete()` in ProjectDetailView rebuilds or removes
  scan.usdz, clears project.scanDate when no capture remains, and deletes
  markers.json only when NO plan source is left. Deleting rooms also
  removes legacy corner_room.json so it can't re-migrate. Photos/notes/
  estimate/planning always survive.
- **#4 DXF export**: Export/DXFExporter.swift emits DXF R12 (AC1009),
  millimetres, 1:1 model space, Y flipped so the plan reads screen-up.
  Sections: HEADER ($ACADVER/$INSBASE/$EXTMIN/$EXTMAX), TABLES (LTYPE
  CONTINUOUS + 7 layers), ENTITIES. Layers: WALLS(7) DOORS(3) WINDOWS(5)
  OPENINGS(4) FIXTURES(8) DIMENSIONS(1) LABELS(2). Walls get rotated
  centred TEXT dimensions (Measure.length, nudged 1.2×text-height off the
  wall); fixtures = closed outlines + label; markers + room names (multi-
  room) on LABELS. Report section: "Create CAD File (DXF)" → ShareLink,
  same pattern as the plan PNG; ASCII with lossy conversion so user-typed
  labels can't fail the export. NOT verified in a real CAD app yet — ask
  the user to open one in a viewer (e.g. Autodesk Viewer) and report.

## ✅ COMPLETE (July 8, 2026) — build verified
- **Storage**: `rooms.json` (`RoomsFile` → `[RoomEntry]`: id, name,
  CornerRoom) via `ScanStore.loadRooms/saveRooms`. Legacy
  `corner_room.json` is read as "Room 1" until the first rooms.json save
  (an empty rooms.json intentionally blocks re-migration after deletes).
- **Coordinates**: rooms live in ONE shared plan space — placement is
  baked into geometry (`translated/placedAlongside/placedOver` in
  Models/RoomsFile.swift), NOT origin fields. New rooms are normalised
  to origin (first) or placed right of the plan +0.5 m gap; recapture
  drops new geometry at the old room's min corner. Markers stay valid in
  both merged and single-room views because coordinates never change.
- **Merged views**: `FloorPlanModel(rooms:)` (area summed, ceiling max);
  `Model3DBuilder.makeScene(rooms:)` — per-room `addRoom(...)` helper,
  shared lights/ground/camera; `writeUSDZ(rooms:)`; `viewerScene` loads
  rooms. Multi-room wall nodes are named `wall-<room>-<index>`, which the
  Interactive3DView tap parser ignores by design (edits are single-room).
- **Project detail**: "Rooms" section — rows (name + area), context menu
  Rename / Recapture with Camera / Retrace from Photo-PDF / Delete, swipe
  delete, Add Room buttons. Capture screens take `targetRoomID` (nil =
  append). Deleting the last room removes scan.usdz unless LiDAR owns it.
- **FloorPlanScreen**: Room menu picker under the units bar (only when
  >1 room): "All Rooms" = merged, view-only (markers still work; edit
  chips hidden because `cornerRoom == nil`); picking a room loads it for
  full editing. `persist()`/`applySnapshot` write through `saveRoom(_:)`
  into the rooms list + regenerate the all-rooms USDZ. Undo/redo stacks
  clear on room switch (snapshots are per-room).
- **Calculators**: `MaterialTakeoff.calculate(rooms:)` sums geometry with
  per-room ceilings; estimate + suite assessment get the summed area via
  the merged plan automatically. PDF: takeoff from all rooms, plus a
  per-room area list on the Floor Plan page when >1 room.

## Failed attempts / gotchas to remember
- Xcode type-checker timeout on FloorPlanScreen → body is split into
  mainStack/layerChrome/layerAlerts/layerDialogs/layerSheets; add new
  modifiers to the right layer, never all on one view.
- Switches over DragTarget/Fixture.Kind must stay exhaustive.
- The room picker deliberately does NOT let you edit in "All Rooms" —
  every FloorPlanScreen mutation guards `cornerRoom != nil`, so merged
  mode gets read-only + markers for free. Don't add edit paths there
  without converting coordinates per room.
- Rooms are auto-placed side by side; there is no drag-to-arrange yet
  (follow-up idea: "Move Room" mode in All Rooms view that calls
  `translated(dx:dz:)` and saves).
- Build command: `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/
  Developer xcodebuild -project CaribinalScanner.xcodeproj -scheme
  CaribinalScanner -destination 'generic/platform=iOS Simulator'
  CODE_SIGNING_ALLOWED=NO build`

## ✅ ALSO COMPLETE (July 8, 2026, third round — "market edge" build)
Four features from the competitive analysis, all build-verified:
- **Suite Compliance Check** (Models/SuiteCompliance.swift +
  Views/ComplianceScreen.swift): measured checks from geometry — per-
  bedroom egress (0.35 m²/380 mm, passes-as-slider vs casement-only
  logic), natural light ratio (5%), sill height (1.5 m guidance), ceiling
  (1.95 m), suite area/bedroom capacity — plus declared checks (entrance,
  fire separation, smoke/CO, bathroom, kitchen, sound) from checklist +
  estimate + placed fixtures. Preset struct (.manitoba) ready for more
  municipalities. Bedrooms are matched by room NAME containing "bed".
  Opening gained heightMeters (windows; nil = 1.07) — edit in the opening
  sheet; 3D head height uses it. Entry: Renovation Planning section; PDF
  page "Suite Compliance (Guidance)" before the estimate.
- **Suite ROI** (Models/SuiteROI.swift + Views/ROIScreen.swift): rent /
  vacancy / monthly costs vs estimate midpoint (override supported) →
  net income, payback, yield, 10-year position; roi.json per project;
  "Investment Outlook" PDF page after the estimate.
- **Price Book** (Models/PriceBook.swift + Views/PriceBookScreen.swift):
  all EstimateCalculator constants moved to a UserDefaults-backed,
  user-editable rate book (low/high per line, permit as %). Link inside
  EstimateScreen. Reset-to-defaults included.
- **Tape accuracy check** (FloorPlanScreen calibration sheet + 
  CornerRoom.scaled(by:) in RoomsFile.swift + verifiedAccuracyPercent on
  CornerRoom): pick a wall, enter the tape length, see deviation, scale
  the whole room (fixture sizes stay true); correction shown in Summary
  and printed on the PDF plan page.
- PlanningChecklist.standard() gained "Smoke & CO alarms (interconnected)"
  (existing saved checklists won't have it — compliance then shows a
  warning, which is correct behaviour).

## Next feature
**#1 Cloud sync (Supabase)** — the one edge feature that needs the user
(account, auth choices); everything else from the market plan is in.
Then: drafting mode per DRAFTING_SPEC.md (turns compliance + drawings
into a permit package), #5 AI trace assist, drag-to-arrange rooms.
Compliance thresholds live in SuiteCompliance.Preset — add municipal
presets there. DXF still awaiting user verification in a CAD viewer.
