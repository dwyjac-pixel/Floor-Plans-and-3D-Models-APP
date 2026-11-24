# Finished Preview

Preview Renovation shows a client what a room will look like when the job is done, drawn on the device from a saved proposed revision. This file is the working spec: what is built, the rules it follows, the gates it has to pass, and who does what next.

Lead: Claude. Reviewer and second builder: Codex. Owner decisions: Dwayne.

## Where it stands

The work is on branch `finished-preview`. It is a prototype for the owner to judge, not a release. Nothing has been measured on a physical device.

Built and working:

- **One room.** An enclosed room from a saved revision, with ceiling, interior lighting, lined door and window openings, baseboard and casing. Finished vanity, toilet and shower, each built to its drawn footprint. A bulkhead at its real height.
- **Finishes.** Two looks, Warm Modern and Bright Neutral, plus one at a time changes for floor, shower or tub surround (prefab by default, or tile), paint, vanity, counter and hardware.
- **Bathroom fixtures to choose.** A ceiling fixture, an above-mirror light where it fits under the ceiling or bulkhead, or pot lights; a plain or lighted mirror. The choice changes which fixtures are drawn. The room is lit the same way for every choice, so finishes are always compared under one light.
- **Views.** Doorway, Inside and Overhead stops worked out from the plan, with a glide between the two standing stops.
- **Pictures.** A captioned still, a comparison of the looks from one camera, and saved Option A and Option B with a two page PDF.
- **A kitchen.** Cabinets, sink, dishwasher, stove, microwave and refrigerator as finished models. Sample only for now: see Held back.
- **A saved floor walkthrough.** Rooms of a proposed revision that share a doorway are joined at their drawn positions and walked through, with floor and paint chosen per room. A room with no shared doorway is named, not drawn.
- **Samples.** A sample bathroom, a sample kitchen and a sample floor. The sample floor is a staged set (its hall, living room and bedroom are placed by hand) and says so on screen.
- **Choices are kept with the project** in `preview_choices.json` in the project folder: synced, backed up, removed with the project. A room reopens the way it was left.

Held back on purpose:

- **Four kitchen fixture kinds** (short upper cabinet, sink cabinet, microwave, dishwasher) exist in the room model but are not offered in the plan editor. Version 1.0.2 skips a fixture whose kind it does not know, then saves the room and every saved revision without it. A kitchen drawn with them would lose them for good on any older device that shares the project. Before they can be offered, a version that keeps unknown kinds has to replace 1.0.2. This was reproduced against the 1.0.2 model: a room with a stove, a dishwasher and a sink cabinet reads back as a stove alone.

Not built yet: rooms with interior walls, tubs as finished models, any link to the quote, mirror reflections, carpet or plank floors in a walkthrough (every floor is tile), separate faucet and door handle finishes, stairs.

## Rules

1. **The saved revision is the drawing.** The preview is built from one room of an immutable `PlanHistory.Snapshot`. It never reads the live editable plan and never writes to the snapshot.
2. **The picture never invents a dimension.** Wall faces sit on the plan line and wall thickness goes outward, so a clear size in the picture equals the drawing. When the plan lacks a number (a door height, a window sill, a bulkhead drop, a ceiling that was scanned and not measured), the default is used, named on screen and printed under every still.
3. **Nothing is silently clipped.** A room the preview cannot draw faithfully does not open. The screen says why in plain words. See Blocking problems.
4. **It stays apart from the editor and the exports, with five stated exceptions.** The feature lives under `CaribinalScanner/Preview/`. Outside it: entry buttons in `Views/PlanHistoryScreen.swift`; four fixture kinds in `Models/CornerRoom.swift` (held out of the editor, see Where it stands); matching cases for them in `Export/Model3DBuilder.swift` and `FloorPlan/FloorPlanCanvas.swift`; `PDFExporter.makeBathroomComparison`; and one line in `Models/SuiteCompliance.swift`. Nothing else in the editor, the 3D model, the USDZ export or the existing PDF changed. Any further edit outside the folder is a decision, not a convenience.
5. **On the device, no network, no key.** Textures are drawn in code. Nothing is downloaded or uploaded. The App Privacy answer does not change.
6. **It is an illustration and says so.** Every still starts with "Illustration from the drawing" and names the room and revision. Finish names are generic; no brand or product is implied.
7. **No dashes in anything a user reads.**

## How it is put together

| File | Job | Imports |
| --- | --- | --- |
| `PreviewLayout.swift` | One `CornerRoom` in, plain numbers out: wall faces, opening voids, fixture footprints, wall cells split paint and tile, assumptions, blocking problems | Foundation |
| `PreviewCamera.swift` | Doorway, Inside and Overhead stops from the layout; whether a glide between two stops is clear | Foundation |
| `PreviewFinishes.swift` | Slots, finishes, looks, a `Selection`, and the caption wording | Foundation |
| `PreviewReferenceRoom.swift` | The reference bathroom (also the in-app sample) | Foundation |
| `PreviewMesh.swift` | Triangles with texture coordinates in metres | SceneKit |
| `PreviewTextures.swift` | Tile, wood and stone textures and the lighting environment, drawn in code | CoreGraphics |
| `PreviewMaterials.swift` | One ready material per finish | SceneKit |
| `PreviewRoomScene.swift` | The room: shell, openings, lights, the one camera, and `apply(_:)` | SceneKit |
| `PreviewFixtures.swift`, `PreviewVanity.swift`, `PreviewToilet.swift`, `PreviewShower.swift` | Fixture models | SceneKit |
| `PreviewStill.swift` | Off screen stills and the caption band | SceneKit, CoreText |
| `FinishedPreviewScreen.swift` | The screen, the model behind it and the timing readout | SwiftUI |
| `PreviewBathroomLighting.swift` | Light and mirror choices and the clearance rule | SceneKit |
| `PreviewKitchen.swift`, `PreviewReferenceKitchen.swift` | Kitchen models and the sample kitchen | SceneKit |
| `PreviewHallway.swift`, `PreviewReferenceFloor.swift` | The staged sample floor | SceneKit |
| `SavedFloorWalkthrough.swift` | Joins saved rooms through shared doorways and routes the camera | SceneKit |
| `ReferenceFloorScreen.swift` | The walkthrough screen, for the sample and for a saved floor | SwiftUI |
| `BathroomComparison.swift` | Saved Option A and B and their comparison | SwiftUI |
| `PreviewChoiceStore.swift` | Choices kept in the project folder | Foundation, iOS only |

The first four files import only Foundation. That is deliberate: the fidelity tests run against them on the Mac in seconds, and a second renderer (RealityKit) can be built from the same layout, camera and catalog and be held to the same tests.

**Finish slots.** Every piece of geometry belongs to exactly one slot (floor, shower tile, paint, vanity, counter, hardware, and fixed ones such as ceiling, trim, china and glass). Changing a finish assigns a ready material to the slot's geometry inside a zero length transaction. No node is added, moved or removed, the scene is not rebuilt and the camera is not touched.

**True scale.** Texture coordinates on room surfaces are distances in metres. Each tile finish states its real face size and joint width, and its texture holds a whole number of tiles. The material sets the repeat size, so the same 100 x 300 mm tile is 100 x 300 mm on every wall of every room.

**Camera.** Standing stops use a level camera and a shifted lens, the way an architectural photographer works: walls and door frames stay upright, and the picture still shows the floor. The field of view is 70 degrees across a fixed 4:3 picture, about a 26 mm lens. The picture is the same shape on screen and in every still, so a phone held upright does not turn it into an ultra wide.

**Light.** One fixed setup for every look, so two looks are compared under the same light: a soft key from above that is the only shadow caster, a bounce light for the ceiling, up to three recessed ceiling lights, and a painted lighting environment close to neutral so grey paint reads grey.

## Blocking problems

The preview refuses to open and lists the reason when:

- the outline is not a closed shape, or the ceiling height is missing or under 0.5 m;
- a door or window runs past the end of its wall, is taller than the ceiling, or overlaps another;
- a bulkhead's drawn underside and the room's measured clearance differ by more than 10 mm;
- a fixture sits more than 5 mm into a wall, or two floor fixtures overlap by more than 5 mm;
- the room has interior walls (not drawn yet; save the bathroom as its own room).

## Acceptance gates

Codex's five review points are folded in below. Status is honest: **Auto** runs in a script today, **Manual** has a written check, **Open** is not done.

### A. Fidelity: the model matches the drawing

This gate is about model to drawing only. It says nothing about whether the drawing matches the house.

| Gate | Pass when | Status |
| --- | --- | --- |
| A1 Wall faces on the plan line | Face ends within 1 mm of the drawn corners; clear spans equal the drawing | Auto |
| A2 Corners close | Outside corners sit one wall thickness off both neighbouring faces, including a 45 degree corner and an L shape | Auto |
| A3 Openings | Door and window jambs, sill and head within 2 mm of the plan | Auto |
| A4 Fixtures | Position and size within 2 mm, rotation exact, front facing the plan's way | Auto |
| A5 Bulkhead | Underside at ceiling less drop; conflict with measured clearance blocks | Auto |
| A6 Nothing clipped | Every bad input above blocks and offers no camera | Auto |
| A7 Defaults are named | Each default appears in the assumptions and in the caption | Auto |
| A8 Wall finish areas | Paint and tile cells add up to wall area less openings; no cell inside an opening | Auto |
| A9 Same drawing, same picture | Layout signature is stable and changes on a 10 mm move | Auto |
| A10 Scene agrees with layout | Node bounds in the built scene within 2 mm of the layout | Auto (`test-preview-scene.sh`) |
| A11 Overhead is not mirrored | Plan x to the right, plan z down the page | Manual (checked by eye on the reference room), Auto is Open |
| A12 No clipping, no inverted ceiling, no light leaks | Checked by eye from all three stops on a device | Manual |

Expected numbers in `Tests/PreviewGeometryTests.swift` are typed in by hand from the reference bathroom's dimensions, not derived from the code under test.

### B. Finish swaps

Loading and swapping are measured separately, as Codex asked. The room and both looks are built off the main thread; the picture stays covered with "Preparing both looks" until everything is uploaded. The first swap is counted only after that point.

| Gate | Pass when | Status |
| --- | --- | --- |
| B1 Camera does not move | Same camera node, same transform before and after a swap | Auto (`test-preview-scene.sh`) |
| B2 No rebuild | `PreviewRoomScene.buildCount` and node count unchanged across swaps | Auto (`test-preview-scene.sh`) |
| B3 Only the chosen slot changes | Other slots keep the same material | Auto (`test-preview-scene.sh`) |
| B4 Warm swap latency | Tap to first frame under 200 ms on the oldest supported phone | Open (device) |
| B5 Cold entry | Reported on its own, never mixed into B4 | Open (device) |

### C. Motion

| Gate | Pass when | Status |
| --- | --- | --- |
| C1 Glide | Doorway to Inside holds 30 frames a second on an iPhone 12 Pro: no frame over 50 ms, at most 1 in 100 over 33 ms | Open (device) |
| C2 Never through a wall | A glide runs only when the straight path is clear; otherwise the view fades through | Auto (path test), Manual (fade) |

### D. Picture quality reference

Set before any more asset work, as Codex asked. A doorway still passes when all of these hold:

1. Doorway composition: taken on the door's centre line within a step of the wall, with most of the fixtures in frame.
2. No exaggerated wide angle: 70 degrees across, verticals upright.
3. Tile and grout at real size, with visible joints.
4. Glass reads as clear glass with legible edges and hardware.
5. One warm lighting setup; whites read white and grey paint reads grey.
6. Clean trim at doors, windows and the floor line.
7. Fixtures sit on the floor with a shadow.
8. Camera, lens, exposure and lights are identical across the looks being compared.

Stills are rendered at twice their final size and scaled down, separate from the live view. The current reference stills are in `Tests/preview-reference/`; regenerate them with `Tests/render-preview-stills.sh` whenever the look changes. Current status against this list is under Known gaps.

### E. Honesty

| Gate | Pass when | Status |
| --- | --- | --- |
| E1 Caption | First line says illustration, names room and revision; assumptions listed | Auto |
| E2 No dashes | No em or en dash in captions, problem text, finish or look names | Auto |
| E3 Plain blocks are listed | A fixture with no finished model is drawn as a block and named under the picture | Auto |
| E4 Render only items | Mirror, ceiling lights, door hardware and glass hardware are decor: never counted in a takeoff | Rule; no takeoff link exists yet |

## Measured so far

Only numbers that were actually measured, with where.

| What | Number | Where |
| --- | --- | --- |
| Scene build, first look | 0.17 s | Mac, optimised build, `Tests/render-preview-stills.sh` |
| Second look materials | 0.14 s | same |
| Load: build | 4.06 s | iPhone 17 Pro simulator, debug build |
| Load: prepare | 1.47 s | same |
| Look swap, tap to frame | 43 ms | same |
| Glide, 132 frames | worst 106 ms, 1 frame over 33 ms | same |

Simulator and debug numbers are not performance claims. Nothing has been measured on a physical device. No claim about smoothness should be published until gates B4, B5 and C1 are read on a named iPhone and iPad. The readout for that is built in: tap the picture three times.

## Where Claude and Codex differ

1. **Stable IDs now.** Codex asks for stable IDs on proposed revision surfaces now. Openings and fixtures already have UUIDs. Outline walls do not, and adding them changes the saved room format that 1.0.2 users have in iCloud and that EstiMater imports. Because a saved revision never changes, (revision id, room id, wall index) is already a stable key for that revision. Proposal: keep that key now, and add persistent wall IDs with a migration at the shared wall milestone, where they are needed for real.
2. **Finishes per face.** Milestone 1 is one finish per slot per room. The saved selection format should allow per surface overrides from day one so it never needs a format break: slot, then optional wall index, then optional fixture id. That is a note for whoever writes storage (Codex's lane).
3. **Camera bookmarks.** Stops are computed from the plan, not stored. Stored bookmarks in project coordinates belong with free walking, which both sides agreed to defer.
4. **5 mm.** Agreed as the fit tolerance for fixtures. The drawing fidelity tests are tighter: 1 to 2 mm.

Everything else in Codex's review is adopted as written.

## Lanes

**Claude**: layout, camera, catalog, scene, fixtures, lighting, stills, the fidelity tests, this spec.

**Codex** (proposed):

1. `Models/FinishSelections.swift`: store a `PreviewFinish.Selection` per (revision id, room id) in its own file beside `plan_history.json`, include it in `ProjectBackup`, and remove it when the plan is deleted. Snapshots stay immutable. Resolve a selection whose revision or room no longer exists.
2. Readiness prompts: when a height is assumed, offer to enter it on the proposed layout before previewing.
3. The entry points in `Views/PlanHistoryScreen.swift` are provisional. Restyle or move them.
4. Gates A10, B1, B2 and B3 as a simulator test target, if the project gains XCTest.

Codex reviews through pull requests on `finished-preview`. One writer per file at a time.

## Full home

In order, each proven before the next:

1. **Bathroom plus hall.** One shared wall with a different finish on each face, one real doorway between them, a camera that crosses it without a cut, and room based loading tested from near detail to far. This is where persistent wall IDs and wall thickness between rooms arrive.
2. **One floor.** Shared walls and openings across every room on a floor.
3. **Floors and stairs.**
4. **RealityKit comparison**, time boxed, on the same room, layout, catalog and camera. SceneKit stays the baseline until RealityKit wins on the picture quality list on a real device.

## Ideas beyond milestone 1

Ranked by what a homeowner feels for the work it takes. This came out of a design review that compared three independent proposals with ChatGPT's own answer to the same question. Credit shows who raised it.

| # | Idea | What the homeowner sees | Size | Raised by |
| --- | --- | --- | --- | --- |
| 1 | Finished view of a saved revision | The room with a ceiling, lights on and real finishes | Started here | Both |
| 2 | Doorway reveal and room stops | Opens at eye level in the doorway; one tap glides to each room | Started here | Both |
| 3 | Take home pictures with a matching code | A still per room, and the same short code on picture, PDF and quote, so an old picture is easy to spot | Days | Both |
| 4 | Suite check inside the picture | Plain tags: ceiling meets the minimum, egress window is OK, bulkhead clearance | Days | Claude |
| 5 | Before and after from the same spot | The bare basement wipes to the finished room | 1 to 2 weeks | Both |
| 6 | Ready to show check | The app asks for any assumed height before a client picture opens; posts, beams, sump and panel can be drawn | Days | ChatGPT |
| 7 | Their own basement on the EstiMater proposal | The proposal link opens with their room, beside Accept | Days, then 1 to 2 weeks | Claude |
| 8 | Tap a surface to change it | Tap floor, wall, cabinet or counter; see what the quote includes for it | 2 to 4 weeks | Both |
| 9 | Good, Better, Best with the price moving | Three packages over the picture, total updates live | 3 weeks or more, after 8 | Both |
| 10 | Tour video and a tabletop model | Something to send to a spouse | About a week | Claude |
| 11 | Stand in it | The design at full size in the real basement through the camera | 3 weeks or more | Claude |
| 12 | AI concept picture held to the drawing | A labelled photo style extra, in EstiMater only, and only if a test on real jobs shows it keeps windows, ceilings and bulkheads where the drawing puts them | A week to test | Both |

Two cautions from that review that still stand. A polished picture can hide an assumed ceiling height or a missing telepost, so idea 6 is a guard, not a nicety. And no price goes beside a picture until the takeoff and quote read the same frozen revision as the picture (idea 9 depends on it).

## Review of November 24

Six reviewers went through everything added after milestone 1. They were cut off before finishing, but each saved its findings as it went, and every item below was reproduced before it was fixed.

Fixed:

1. **Light choices washed out the picture.** The ceiling fixture, above-mirror light and lighted mirror each added an uncalibrated bulb near a wall. The sample bathroom opened with about a tenth of the picture at pure white; a lighted mirror took the inside view past a third. Now the calibrated ceiling spots light every choice. Tested: under 2 percent pure white for every light and mirror choice, both standing views, both looks.
2. **Dark smudged frames and black chrome.** Ambient occlusion radius was 0.16 m. At 0.04 m the frame round flat panels is gone and a contact line under fixtures stays.
3. **A joined floor was lit by every room's sun.** A four room floor had eight directional lights and four shadow casters; ceilings burned white and the same room changed brightness with the number of rooms and between runs. A floor now has one key and one bounce, and each room's ceiling lights reach only that room. Tested.
4. **The walkthrough picture was stretched** on any screen that was not an upright phone: 7 percent on an upright iPad, more than double sideways. It now keeps its 4:3 shape.
5. **The walkthrough carried no honesty labels** and the sample floor never said it was a sample. Both now do, with the revision, assumed dimensions and plain blocks named.
6. **Saved choices lived outside the project** (not synced, not backed up, never removed, shared with an imported copy) and were lost by a reworded label or renamed slot. They are now in the project folder, saved by stable keys and read tolerantly.
7. **Four fixture kinds would be lost on 1.0.2.** Held out of the editor (see Where it stands).
8. Smaller: no walkthrough on Existing Conditions; Show Whole Room is now Wide View; the suite check counts a sink cabinet or microwave as kitchen fixtures; cabinet finish names no longer say vanity in a kitchen; the saved floor path now has tests.

Open, found but not fixed:

- **Sample floor: leaving the kitchen**, the camera turns into the open kitchen door and the picture is a blank grey panel for about a second.
- **Plan editor, stacked items.** A tap picks the first fixture under the finger, not the smallest, and labels of stacked items overprint. It only bites once the four held kinds are offered.
- **A saved floor ignores the saved floor type.** A bedroom saved as carpet is drawn with tile.
- **The runtime review did not finish.** `FinishedPreviewScreen.swift` (about 700 lines), the PDF path and memory use on older phones have not been reviewed.
- **iPad was not run.** The 4:3 fix was checked on an iPhone simulator only.

## Known gaps

Stated plainly so nobody is surprised:

- It is a clean illustration, not a photograph. There is no real bounced light.
- The mirror is a flat silver panel. It does not reflect the room.
- With the prefab surround as the default, the two looks no longer differ in the shower walls.
- The vanity sits right inside the door in the reference room, so the doorway view shows more counter than a photographer would choose.
- Rooms with interior walls are blocked. Dwayne's saved plans are whole basement scans, so none of them can be previewed yet; each room has to be saved as its own room.
- Load takes several seconds in a debug build because textures are drawn in code without optimisation. A phone has not been measured.

## Running it

```
sh Tests/test-preview-geometry.sh          # fidelity, camera, catalog, captions
sh Tests/test-preview-scene.sh             # the built room, swaps, light budget, blown whites, saved choices
sh Tests/test-preview-floor.sh             # sample floor and a saved floor joined through a doorway
sh Tests/render-preview-stills.sh out/     # both looks from every stop, on the Mac
sh Tests/render-doorway-pair.sh out/       # the locked doorway pair with a manifest
```

On a device: open a project, Plan History, then Open Sample Bathroom, Open Sample Kitchen or Open Sample Floor. For your own room: open a proposed revision and tap Preview Renovation under the room, or Walk Through Saved Floor when the revision has two or more rooms. In the room preview, tap the picture three times for timings.

## Residential product priorities

Focus on the residential workflow for Caribinal Creations, other contractors, and homeowners. A customer should be able to capture or draw a home, confirm the dimensions, open a connected walkthrough, and compare proposed finishes from the same saved drawing. Improve that flow before expanding into commercial spaces.

Add a separate **Shower or Tub Surround** control. Default to a prefab surround and offer tile around either a shower or a bathtub. Keep this choice independent of the bathroom floor and general wall paint. Switching the surround should preserve the fixture footprint and update only the wet-area surfaces around the selected fixture. Test both fixture types and keep the selected surround with the saved proposal before mapping it to takeoff or pricing.

The app is already listed on the App Store. A purchase price and the timing of that change are future owner decisions.

For the reference floor, verify the hall to living room, bedroom, and bathroom route on iPhone and iPad. Check a floor-only change and a paint-only change in different rooms and confirm that adjoining room selections remain intact.

## Bathroom lighting and phone performance

Default to an above-mirror vanity light when the confirmed space above the mirror fits the fixture. Include any nearby bulkhead in the clearance check. For lower ceilings, offer a standard ceiling fixture or recessed pot lights, paired with either a plain mirror or a mirror with built-in lighting. When a scan leaves clearance uncertain, show the missing measurement and let the user confirm it before applying the above-mirror default.

Keep the initial scene lightweight with a basic lighting setup. Load optional fixture previews when the user opens their choices, and reuse loaded assets when they switch options. Keep navigation and finish controls responsive while optional assets load.

Verify on a physical iPhone 12 or another representative older supported iPhone, as well as the iPhone 15 Pro Max and iPad. Record the device and OS, then measure a cold app launch, time until the floor is visible and interactive, and time from a finish selection to the first frame showing it. Check the first flooring and paint swaps after the preview is ready and repeat them after the assets are warm. Verify that opening optional lighting choices leaves the preview and controls responsive. Record simulator results separately from physical device timings.

## Bathroom hardware finishes

The current preview uses a shared Hardware finish for the faucet and door
lever. The Warm Modern look starts with brushed brass. Bright Neutral
starts with polished chrome. Matte black is also available.

Add separate Faucet and Room Door Handle controls. Offer matte black,
polished chrome, and brushed brass in both so clients can match or mix
them. Keep the starting finishes editable and use the look's current
hardware finish as the fallback for older saved options. Save each choice
with the room and with each saved comparison option.

Verify that changing the faucet leaves the room door handle unchanged
and vice versa. Check that both choices survive reopening the room and
appear separately in the comparison and PDF.

## Camera control after walkthrough stops

The hallway-to-living-room transition ends with the camera facing a
corner, leaving much of the room out of view. Give the user camera
control after arriving. Let them drag to look around, pinch to zoom, and
tap preset viewpoints that show the room from useful corners. Provide a
Show Whole Room action for a wide view.

On iPhone and iPad simulators, walk from the hallway into the living
room. Verify that the user can inspect the full room from the arrival
point and preset views, then continue to the next room without restarting
the tour. Confirm that changing views and resuming the tour preserve the
selected room finishes.

Use a slightly slower default pace and ease into and out of movement and
turns, especially at room entrances. Let users pause and resume the tour,
choose the next room, or switch to manual exploration while retaining
their tour position. Offer look-around, zoom-out, and Show Whole Room
controls in the hallway as well as inside rooms.

On both simulators, pause in the hallway, look around, and zoom out or
switch to the wide view. Resume the tour, choose a room, and watch the
doorway transition for abrupt movement or turns. Confirm that manual
exploration preserves tour progress and all room finish selections.

Keep corners readable in the walkthrough, starting with the bedroom.
Evaluate soft fill light to lift deep shadows while keeping enough
shading to show depth. Preserve crisp wall-to-wall and wall-to-floor
edges so adjacent surfaces remain easy to distinguish.

Check the bedroom from the wide view and corner viewpoints on the
iPhone and iPad simulators. Compare edge clarity and shadow detail
before and after, and measure frame pacing during movement and turns
to catch rendering regressions.

## Kitchen rendering and fixture editing

Render the kitchen from the confirmed drawing. Show cabinet doors,
drawers, and handles, plus countertops, the sink and faucet, stove,
microwave, and other appliances present. Keep edges crisp and use the
saved fixture positions and orientations. Let users add missed items or
reposition and rotate items in the plan, then see those edits in the
walkthrough.

On iPhone and iPad simulators, check that the wide view shows the full
kitchen layout and that cabinet hardware, countertop edges, and fixtures
remain clear up close. Move one appliance and add a missing item, then
reopen the preview to verify the saved positions. Measure loading and
frame pacing during doorway transitions and close-up navigation.
