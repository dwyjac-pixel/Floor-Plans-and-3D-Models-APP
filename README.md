# Caribinal Scanner — Phase 1 Prototype

An iOS app for Caribinal Creations Ltd. that scans basements and rooms with
Apple RoomPlan (LiDAR) and produces a floor plan, a 3D model, measurements,
photos, notes, and a client-ready PDF report.

This is the Phase 1 prototype from [PLAN.md](PLAN.md): create project → scan
room → floor plan → 3D model → notes/photos → PDF export.

## What you need

- **Xcode** (Mac App Store, free — large download). Command Line Tools alone
  are not enough.
- **For LiDAR scanning: an iPhone Pro or iPad Pro** (iPhone 12 Pro or newer
  Pro model, or iPad Pro 2020+) running iOS 17 or later. On devices without
  LiDAR (e.g. iPhone 11) and in the Simulator, the scan button is replaced
  with an explanation — use **Enter Measurements Manually** instead, which
  produces the same floor plan and PDF report from typed measurements.
- **A free Apple ID** added to Xcode (Xcode → Settings → Accounts). No paid
  developer account is needed to run on your own device.

## First build — step by step

1. Install Xcode from the Mac App Store and open it once so it can finish
   installing iOS platform support.
2. Double-click `CaribinalScanner.xcodeproj` in this folder.
3. In Xcode, click the blue **CaribinalScanner** project icon at the top of the
   left sidebar → select the **CaribinalScanner** target → **Signing &
   Capabilities** tab → set **Team** to your Apple ID (add it via Xcode →
   Settings → Accounts if it's not listed). If Xcode complains the bundle
   identifier is taken, change `com.caribinalcreations.scanner` to anything
   unique, e.g. add your initials.
4. Plug in your iPhone with a cable and choose it in the device menu at the
   top of the Xcode window (next to the scheme name).
5. Press **Run** (▶). The first run on a new phone requires two one-time
   steps on the phone itself:
   - Enable **Developer Mode**: Settings → Privacy & Security → Developer
     Mode → on, then restart the phone.
   - Trust the developer: Settings → General → VPN & Device Management →
     tap your Apple ID → Trust.
6. On first scan the app will ask for camera permission — allow it.

## Using the app on site

1. Tap **+** and create a project (client, address, type).
2. Open the project and capture the space — three ways, best available first:
   - **Scan Room (LiDAR)** — iPhone Pro / iPad Pro only. Walk the room;
     RoomPlan detects walls, doors, windows and openings automatically.
   - **Capture Corners with Camera** — works on any iPhone (including the
     iPhone 11, no LiDAR needed). Walk the room, aim the crosshair at each
     floor corner in order, tap **Mark Corner** (wall lengths show live),
     then **Finish** and enter the ceiling height. Produces the floor plan
     and a simple 3D model of the room.
   - **Enter Measurements Manually** — type width/length/ceiling, add
     doors, windows, openings and bump-outs, with a live preview.
   Priority when several exist: LiDAR scan → corner capture → manual.
3. **Floor Plan** shows the 2D plan with wall lengths (toggle feet/metres),
   ceiling height, approximate floor area, and counts of doors/windows.
   Pinch to zoom, drag to pan, twist (or the Rotate chip) to rotate,
   double-tap to reset. The cube/map button switches the pane between the
   2D plan and the 3D model; the 3D camera is a turntable (the floor stays
   level) and supports adding doors/windows by tapping walls and dragging
   fixtures (cabinets, toilet, vanity, tub/shower, stairs) into place.
   A tool-chip strip under the pane holds the tools:
   - **Add Marker** — room labels, mechanical, electrical panel, stairs,
     beams/posts, notes.
   - **Add Fixture** — base cabinets & countertop, upper cabinets, island;
     footprints in 2D, real boxes with countertops in 3D.
   - **Draw Interior Wall** — tap start and end to add partitions and
     closets (snaps to corners and axis-aligns).
   - **Edit Walls** — drag corners/endpoints/fixtures to move them; tap a
     wall for Add Door / Add Window / Add Opening / Split / Correct Length;
     tap a corner to remove it. Doors and windows cut real openings into
     the 3D walls (with headers and window sills).
   - **Plan Style…** — wall line thickness and wall/door/window colours,
     applied on screen and in every export.
   Tap any wall length (or Adjust Ceiling Height) to correct it against a
   tape measure — the outline re-solves and the 3D model regenerates.
4. **View 3D Model** opens the interactive viewer: drag to orbit, pinch to
   zoom, two-finger drag to move, with wall-length and ceiling labels, a
   measurements bar, Reset View, and Done.
5. Add **notes** and **photos** (electrical panel, mechanical room, egress
   window locations, etc.).
6. **Estimate** — set the scope (bedrooms, bathroom, kitchen, egress windows,
   side door, finish level) and the app computes a rough low–high range from
   the floor area. Rates are placeholders in `Models/Estimate.swift` —
   calibrate them to real pricing before quoting.
7. **Planning Checklist** — tick what the development will include (fire
   separation, egress, side entrance…); a live **Suite Assessment** rates
   the space (bedroom capacity, legal-suite gaps) as you toggle items.
8. **Generate PDF Report** → **Share** to AirDrop/email the branded report:
   cover page, project details + estimate/permit status, floor plan with
   markers and wall lengths, proposed development with suite assessment,
   preliminary estimate, and captioned photos. The Report section can also
   share the **floor plan as a PNG** and the **3D scan as USDZ**.
9. Track **Estimate status** and **Permit status** per project (shown on
   the dashboard), and search projects by client, address, or name.

Scan files are also visible in the **Files app** → On My iPhone →
CaribinalScanner → Projects — the `scan.usdz` in each project folder can be
AirDropped to a Mac and opened in Preview, or imported into CAD tools later.

## Project structure

```
CaribinalScanner.xcodeproj      Xcode project (uses folder-synced groups —
                                new files added to CaribinalScanner/ appear
                                in the project automatically)
CaribinalScanner/
  CaribinalScannerApp.swift     App entry point (SwiftUI + SwiftData)
  Models/
    Project.swift               RenovationProject — the saved business record
    ManualRoom.swift            Hand-measured room + bump-outs (non-LiDAR fallback)
    CornerRoom.swift            Corner-captured room outline (ARKit)
    Estimate.swift              Estimate inputs + rough range calculator
    PlanningChecklist.swift     Renovation planning checklist model
    PlanMarkers.swift           Floor-plan markers (rooms, mech, electrical…)
    SuiteAssessment.swift       Suite-potential guidance logic
    ScanStore.swift             File storage: USDZ, room/estimate/planning JSON, photos
  Scanning/
    ScanSessionController.swift RoomPlan session + delegate
    RoomCaptureViewRep.swift    UIKit→SwiftUI bridge for the capture view
    ScanScreen.swift            Full-screen scan flow (scan → review → save)
    CornerCaptureController.swift ARKit corner marking (no LiDAR needed)
    CornerCaptureScreen.swift   AR corner capture UI + finish/save flow
  FloorPlan/
    FloorPlanModel.swift        CapturedRoom → 2D segments, area, heights
    FloorPlanCanvas.swift       Draws the plan (walls, doors, windows, labels)
    FloorPlanScreen.swift       Plan screen with unit toggle + measurements
    ManualRoomEntryScreen.swift Manual measurement entry with live preview
    Measure.swift               ft/in and metric formatting
  Viewer/
    Model3DScreen.swift         Interactive 3D viewer (orbit/zoom/pan, labels)
  Export/
    PDFExporter.swift           Multi-page PDF report generator
    Model3DBuilder.swift        Corner outline → extruded USDZ 3D model
  Views/
    ProjectListView.swift       Dashboard
    NewProjectSheet.swift       Create project form
    ProjectDetailView.swift     Project hub
    EstimateScreen.swift        Estimate inputs form with live range
    PlanningScreen.swift        Planning checklist editor
    PhotoSection.swift          Photo picker + grid
```

## Known limits of Phase 1 (by design)

- One room per project scan; multi-room merging (RoomPlan StructureBuilder)
  is planned for a later phase.
- Scanned floor plans can't be edited yet (Phase 3 in PLAN.md); manual
  entry covers one main rectangle plus bump-outs for L-shapes.
- Estimate rates: bathrooms and egress windows use Caribinal pricing
  (July 2026); the rest are placeholder CAD figures — tune them in
  `Models/Estimate.swift`.
- Floor area is a bounding-rectangle estimate — L-shaped rooms read high.
- Everything is stored on the device; cloud sync (Supabase) comes in Phase 6.
- Measurements are typically within an inch or two but are not survey-grade;
  verify critical dimensions for permit drawings.

## Troubleshooting

- **"Signing for CaribinalScanner requires a development team"** — step 3
  above.
- **Xcode refuses to open the project file** — recreate it in 2 minutes:
  File → New → Project → iOS App, name it `CaribinalScanner`, interface
  SwiftUI, storage SwiftData, save it anywhere. Delete the template Swift
  files, then drag the `CaribinalScanner` source folder from this directory
  into the project navigator (choose "Create folder references" off /
  "Copy items if needed" as appropriate). In the target's Build Settings set
  the iOS Deployment Target to 17.0, and under Info add
  `NSCameraUsageDescription`.
- **Build errors in the Swift files** — this code was written before Xcode
  was installed on this Mac and has not been compiled yet. Ask Claude Code to
  fix whatever the first build reports.
- **Scan button says LiDAR required** — the device has no LiDAR scanner
  (only Pro models have it), or you're in the Simulator.
