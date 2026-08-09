# Drafting Mode Spec — match Edwin Duplex drawing conventions

Reference drawings (user's Desktop):
`~/Desktop/Turnstone Terrace/floor plan/fwbeliveaudrawingschangesuptodecember12/`
(A2 BASEMENT FLR PLAN studied in detail; A1–A7, S1–S2 same conventions.)

Goal: FloorPlanCanvas + PDF export render like a stamped architectural
sheet, not an app sketch. Changes, in build order:

## 1. Double-line walls (biggest visual change)
- Walls drawn as two parallel lines at true scaled thickness, not single
  strokes. Thickness by type: exterior/concrete 10" (0.254 m), interior
  4" (0.102 m), double separation 8".
- Fill between lines: exterior = concrete stipple/aggregate hatch;
  interior = diagonal hatch; keep hollow at small zoom for clarity.
- Requires CornerRoom walls to carry a `thicknessMeters` + `wallType`
  (exterior default for outline, interior default for interior walls).
- Legend block (like reference): swatch + "4" TYP. INTERIOR WALL" etc.

## 2. Dimension strings outside the plan (architect standard)
- Extension lines projecting from wall faces/opening edges past the
  outline; dimension lines with tick marks (45° slashes) at extension
  crossings; text above the line, parallel to it, e.g. `12'-7"`.
- Two stacked chains per side: inner chain = segment dimensions broken at
  every corner AND opening edge; outer chain = overall wall length.
- Replaces current mid-wall floating labels (keep those only as a
  "simple mode" toggle).
- Dash format: `36'-3"` (foot-dash-inch), not `36' 3"`.

## 3. Door swing arcs
- Door = leaf line perpendicular-ish + quarter-circle swing arc from the
  hinge side, gap in wall. Add `hingeOnStart: Bool` + `swingInward: Bool`
  to Opening for arc orientation; tap to flip.
- Windows: triple parallel lines across the wall gap (frame + glazing).

## 4. Room labels & notes
- Room-label markers render UPPERCASE, centered, architectural feel
  (rounded hand-drafted font look is optional; caps + tracking is enough).
- Notes boxes: bordered rectangles with small caps text (marker kind
  `note` gets a box instead of a dot).

## 5. Sheet furniture (PDF export page)
- Title block bottom-left: circled sheet number + underlined sheet title
  ("BASEMENT PLAN") + scale note (e.g. 3/16" = 1'-0" — compute from fit).
- North arrow (rotatable, stored per project), legend block top-right,
  ground-note boxes.
- White background, black linework only on export (already forced).

## 6. Stairs
- Already have treads + direction arrow; add "UP" text at arrow tail and
  break-line (zigzag) convention for tall runs.

## 7. Fixture symbols — refine to reference weight
- Toilet/sink/tub/washer symbols exist; thin the strokes, remove grey
  fill in drafting mode (hollow outlines, black).

Existing style system hooks: PlanStyle gains `draftingMode: Bool`
(default on for exports), wall type colours ignored in drafting mode
(black ink). All of this feeds PDF/PNG exports automatically since they
render FloorPlanCanvas.
