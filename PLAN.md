# App Plan: Home Space Scanner for Floor Plans and 3D Models

## 1. App Purpose

Create an internal business app for Caribinal Creations Ltd. that can scan an existing home space, especially basements, and generate:

* Existing floor plan
* Room measurements
* 3D model of the space
* Door, window, wall, ceiling, stair, and opening locations
* Basic renovation planning information
* Exportable files for estimates, permits, design review, and client presentation

The first version should be built for Caribinal Creations' internal workflow. If the app works well, it can later become a marketable product for contractors, renovators, real estate investors, and homeowners.

## 2. Core Problem the App Solves

When viewing a basement or renovation space, measurements, photos, layout sketches, ceiling heights, obstructions, windows, stairs, beams, mechanical areas, and possible suite layouts all need to be documented.

This app would reduce manual measuring and help create a faster, more professional starting point for:

* Basement renovation estimates
* Legal secondary suite planning
* Side-door entrance planning
* Egress window planning
* Permit preparation
* Client presentations
* Before-and-after design concepts

## 3. Recommended First Platform

Start with iPhone Pro / iPad Pro because Apple's RoomPlan API uses the camera and LiDAR scanner to create 3D room models and floor-plan-style outputs. Apple describes RoomPlan as a Swift API that uses camera and LiDAR to create a 3D floor plan of a room, including dimensions and furniture/object information.

Android can come later using ARCore Depth API, which provides depth maps so the device can understand the shape and distance of real-world objects.

## 4. Main App Modules

### Module 1: User Login and Project Dashboard

The app should allow Caribinal Creations to create and manage projects.

Each project should include:

* Client name
* Property address
* Phone/email
* Project type
* Basement size
* Scan date
* Notes
* Photos
* Floor plan
* 3D model
* Estimate status
* Permit status

### Module 2: Space Scanning

The app should guide the user through scanning the basement or home area.

Scanning should capture:

* Walls
* Floor area
* Ceiling height
* Doors
* Windows
* Stairs
* Beams/posts
* Mechanical room
* Electrical panel
* Plumbing rough-ins
* Existing rooms
* Exterior access points
* Possible side-door location
* Window well / egress window areas

For the first version, use Apple RoomPlan for room scanning. Later versions can add photogrammetry or Android support.

### Module 3: Floor Plan Generation

After scanning, the app should generate a clean floor plan showing:

* Room dimensions
* Wall lengths
* Door locations
* Window locations
* Stair location
* Mechanical area
* Ceiling height notes
* Existing layout
* Measurement labels

The app should allow manual corrections because scanning will not always be perfect.

Manual edit tools should include:

* Move wall
* Add wall
* Delete wall
* Adjust measurement
* Add door
* Add window
* Label room
* Mark mechanical area
* Mark electrical panel
* Add notes

### Module 4: 3D Model Viewer

The app should generate or display a 3D model of the scanned space.

The 3D model should help show:

* Existing space
* Room volume
* Ceiling height
* Openings
* Layout restrictions
* Possible renovation ideas

Recommended visualization options:

* Apple RealityKit for iOS
* Unity for more advanced 3D
* Three.js if creating a web-based viewer

Apple's Object Capture can also create 3D models from photographs using photogrammetry, which may be useful later for capturing objects, fixtures, or detailed existing conditions.

### Module 5: Renovation Planning Layer

This is where the app becomes specific to Caribinal Creations.

The app should allow the user to add renovation planning items on top of the scan:

* Bedroom location
* Bathroom location
* Kitchenette location
* Laundry location
* Mechanical room
* Storage
* Rec room
* Egress window location
* Side-door entrance
* Fire separation areas
* Sound separation areas
* Plumbing route
* Electrical notes
* Permit notes

This layer should eventually help determine whether a basement can work as:

* 1-bedroom suite
* 2-bedroom suite
* 3-bedroom suite
* Non-legal basement development
* Family-use basement
* Rental-ready legal secondary suite

### Module 6: Estimate Support

The app should use the scanned square footage and project selections to help create a rough estimate.

Inputs:

* Total square footage
* Number of bedrooms
* Bathroom required
* Kitchenette/full kitchen
* Side-door entrance
* Egress windows
* Finish level
* Flooring type
* Ceiling type
* Existing demolition required
* Plumbing distance
* Electrical complexity

Outputs:

* Rough project range
* Materials category
* Labour category
* Permit/design allowance
* Notes for final quote

### Module 7: Export and Reports

The app should export useful files for the business.

Export options:

* PDF floor plan
* PDF project report
* 3D model file
* Measurement summary
* Client presentation
* Photos with notes
* Permit preparation package
* Estimate support document

Possible file formats:

* PDF
* PNG/JPEG
* USDZ for Apple 3D models
* OBJ/GLB for 3D models
* DXF/DWG later for CAD compatibility

### Module 8: Cloud Storage

Each scan and project should be saved securely.

Recommended storage:

* Firebase
* AWS Amplify
* Supabase

Stored data:

* Project details
* Scan files
* Floor plans
* Photos
* Notes
* Measurements
* Estimate versions
* Client reports

## 5. Recommended Tech Stack

### First Version

* iOS app: Swift / SwiftUI
* Scanning: Apple RoomPlan + ARKit
* 3D display: RealityKit
* Storage: Firebase or AWS Amplify
* Reports: PDF generation inside app
* Admin dashboard: Later

### Later Version

* Android app: Kotlin + ARCore Depth API
* Web dashboard: Next.js
* 3D web viewer: Three.js
* Advanced 3D engine: Unity if needed
* CAD export: DXF/DWG integration
* AI layout suggestions: Future phase

## 6. MVP Version

The first working version should be simple.

MVP features:

1. Create project
2. Scan room/basement area
3. Generate basic floor plan
4. View 3D model
5. Add notes
6. Add photos
7. Manually adjust measurements
8. Export PDF report
9. Save project

Do not start with every feature. The goal is to prove that the app can scan a real basement and create a useful business record.

## 7. Phase-by-Phase Build Plan

### Phase 1: Research and Prototype

Goal: Prove the scanning works.

Tasks:

* Test Apple RoomPlan
* Scan a real basement
* Check measurement accuracy
* Export sample 3D model
* Export basic floor plan
* Identify scanning limitations

Deliverable:

* Basic prototype that scans one room and produces a model/floor plan

### Phase 2: Business Workflow Prototype

Goal: Make it useful for Caribinal Creations.

Tasks:

* Add project creation
* Add client/property details
* Add notes
* Add photos
* Save scan to project
* Create basic project summary

Deliverable:

* Internal app prototype for site visits

### Phase 3: Floor Plan Editing

Goal: Make scans usable even when imperfect.

Tasks:

* Add manual measurement correction
* Add wall/door/window editing
* Add room labels
* Add ceiling height notes
* Add mechanical/electrical markers

Deliverable:

* Editable floor plan tool

### Phase 4: Renovation Planning Tools

Goal: Connect the scan to basement development planning.

Tasks:

* Add bedroom/bathroom/kitchenette planning layer
* Add egress window marker
* Add side-door marker
* Add legal suite checklist
* Add estimate inputs

Deliverable:

* Basement renovation planning version

### Phase 5: Export System

Goal: Create professional documents.

Tasks:

* Export PDF floor plan
* Export project summary
* Export measurement report
* Export client presentation
* Export permit-prep notes

Deliverable:

* Branded Caribinal Creations project report

### Phase 6: Cloud and Team Use

Goal: Save, access, and manage projects.

Tasks:

* Add login
* Add cloud project storage
* Add backup
* Add admin view
* Add search by client/address
* Add project status

Deliverable:

* Internal business-ready version

### Phase 7: Marketable Product

Goal: Turn it into a software product.

Tasks:

* Add subscription accounts
* Add contractor profiles
* Add branded exports
* Add payment system
* Add onboarding
* Add support system
* Add Android support
* Add web dashboard

Deliverable:

* Commercial SaaS/mobile product

## 8. Key Challenges

The biggest challenges will be:

* Accuracy of measurements
* Scanning cluttered spaces
* Handling basements with multiple rooms
* Capturing low ceilings, beams, ducts, and posts
* Exporting clean CAD-style files
* Making the app simple enough for job-site use
* Manual correction tools
* Legal/privacy handling for client homes

## 9. Privacy and Legal Considerations

Because the app scans inside people's homes, it should include:

* Client consent
* Secure storage
* Ability to delete project data
* Clear privacy policy
* No public sharing without permission
* Secure login
* Company-only access for internal version

## 10. Long-Term Vision

The long-term version could become a specialized contractor tool for basement development and legal secondary suites.

Possible future AI features:

* Automatically suggest suite layouts
* Detect possible bedrooms
* Identify egress window opportunities
* Estimate renovation cost
* Flag permit concerns
* Generate before-and-after concepts
* Create client-ready proposals
* Integrate with City permit documentation
* Connect with Caribinal Creations' website estimator

## 11. Cross-Platform Strategy (added July 2026)

### iPad
The Phase 1 app is universal (iPhone + iPad) already. iPad Pro models (2020+)
have LiDAR and can scan. Non-Pro iPads run everything except scanning
(projects, floor plans, 3D viewing, photos, notes, PDF reports).

### Android
There is no Android equivalent of Apple RoomPlan — ARCore's Depth API provides
raw depth data, not walls/doors/windows/dimensions, and most Android phones
have no LiDAR. Building automatic room capture on Android is a large custom
project (this is why magicplan-style apps use manual corner-marking on
Android).

Recommended path, in order:

1. **Web dashboard (Phase 6, moved up in priority)** — Next.js + Supabase +
   Three.js, matching the EstiMater stack. Any device with a browser
   (Android phones/tablets, desktop, client's home computer) can view and
   manage projects, floor plans, 3D models, photos, and reports. The scan's
   `room.json` (parametric walls/doors/windows) is enough to render both the
   2D plan and a simple extruded 3D model in Three.js — no USDZ conversion
   required.
2. **Scanning stays on iOS** — the crew carries one LiDAR iPhone/iPad Pro as
   the capture device; everything downstream is cross-platform via the web.
3. **Native Android capture (optional, later)** — only if truly needed:
   ARCore with manual corner-marking (tap wall corners in AR). Significant
   build; revisit after the web dashboard proves the workflow.

## 12. Recommended First Step

The first practical step is to build an iOS prototype using Apple RoomPlan.

The first prototype should only do this:

* Open app
* Create project
* Scan basement room
* Generate floor plan
* View 3D model
* Save/export PDF

Once that works, the app can be expanded into estimating, renovation planning, and legal suite design support.
