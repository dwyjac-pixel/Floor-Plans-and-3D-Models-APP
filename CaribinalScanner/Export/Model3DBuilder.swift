import Foundation
import SceneKit
import UIKit

/// Builds the 3D scene for captured corner rooms: extruded walls, floor,
/// lighting, a framing camera, and floating dimension labels. The same
/// geometry is exported as USDZ (without labels) for sharing.
enum Model3DBuilder {
    private static let doorHeadHeight = 2.03
    private static let windowSillHeight = 0.91
    private static let windowHeadHeight = 1.98
    private static let wallThickness = 0.08
    private static let baseboardHeight = 0.09

    enum BuildError: LocalizedError {
        case notEnoughCorners
        case exportFailed

        var errorDescription: String? {
            switch self {
            case .notEnoughCorners: "At least 3 corners are needed to build a 3D model."
            case .exportFailed: "Could not write the 3D model file."
            }
        }
    }

    static func makeScene(room: CornerRoom, useImperial: Bool, withLabels: Bool) -> SCNScene? {
        makeScene(rooms: [room], useImperial: useImperial, withLabels: withLabels)
    }

    /// One scene containing every room, drawn side by side in the shared
    /// plan space. Lighting, studio ground, and the framing camera are
    /// shared; walls, fixtures, floors, and labels are added per room.
    static func makeScene(rooms: [CornerRoom], useImperial: Bool, withLabels: Bool) -> SCNScene? {
        let validRooms = rooms.filter { $0.corners.count >= 3 }
        guard !validRooms.isEmpty else { return nil }

        // Recenter the whole plan so the model sits at the origin.
        let allCorners = validRooms.flatMap(\.corners)
        let minX = allCorners.map(\.x).min() ?? 0
        let minZ = allCorners.map(\.z).min() ?? 0

        let scene = SCNScene()
        applyStudioEnvironment(to: scene)

        var maxHeight = 2.4
        for (roomIndex, room) in validRooms.enumerated() {
            // 3D wall taps only edit in single-room scope, so multi-room
            // wall names use a form the tap parser ignores.
            let height = addRoom(room, to: scene,
                                 originX: minX, originZ: minZ,
                                 wallNamePrefix: validRooms.count == 1 ? "wall-" : "wall-\(roomIndex)-",
                                 useImperial: useImperial,
                                 withLabels: withLabels,
                                 withHeightDimension: withLabels && roomIndex == 0)
            maxHeight = max(maxHeight, height)
        }

        // Viewer scaffolding — studio lights, framing camera, faded ground,
        // and the orbit-target node — is for the on-screen viewer only. The
        // export scene (withLabels == false, used by writeUSDZ) omits it so
        // shared USDZ files don't carry the viewer's lights/camera/target.
        if withLabels {
            let extentX = allCorners.map { $0.x - minX }.max() ?? 4
            let extentZ = allCorners.map { $0.z - minZ }.max() ?? 4
            let centerX = Float(extentX / 2)
            let centerZ = Float(extentZ / 2)
            let maxDimension = Float(max(extentX, extentZ, maxHeight))

            // Lighting: the environment map carries the fill; a low ambient
            // keeps shadowed faces from going black, the key light casts the
            // shadows, and a weak opposing fill softens them.
            let ambientNode = SCNNode()
            ambientNode.light = SCNLight()
            ambientNode.light?.type = .ambient
            ambientNode.light?.intensity = 100
            scene.rootNode.addChildNode(ambientNode)

            let keyNode = SCNNode()
            keyNode.light = SCNLight()
            keyNode.light?.type = .directional
            keyNode.light?.intensity = 450
            keyNode.light?.castsShadow = true
            keyNode.light?.shadowMode = .forward
            keyNode.light?.shadowColor = UIColor(white: 0, alpha: 0.3)
            keyNode.light?.shadowRadius = 5
            keyNode.light?.shadowSampleCount = 24
            keyNode.eulerAngles = SCNVector3(-Float.pi / 3, -Float.pi / 4, 0)
            scene.rootNode.addChildNode(keyNode)

            let fillNode = SCNNode()
            fillNode.light = SCNLight()
            fillNode.light?.type = .directional
            fillNode.light?.intensity = 100
            fillNode.light?.castsShadow = false
            fillNode.eulerAngles = SCNVector3(-Float.pi / 5, Float.pi * 0.7, 0)
            scene.rootNode.addChildNode(fillNode)

            // Viewer-only studio ground: a disc that fades into the backdrop,
            // so the model sits in a pool of light and still catches its shadow.
            let radius = CGFloat(max(Double(maxDimension) * 1.6, 8))
            let ground = SCNPlane(width: radius * 2, height: radius * 2)
            let groundMaterial = SCNMaterial()
            groundMaterial.lightingModel = .physicallyBased
            groundMaterial.diffuse.contents = groundFadeImage
            groundMaterial.roughness.contents = 0.9 as NSNumber
            ground.materials = [groundMaterial]
            let groundNode = SCNNode(geometry: ground)
            groundNode.eulerAngles = SCNVector3(-Float.pi / 2, 0, 0)
            groundNode.position = SCNVector3(centerX, -0.03, centerZ)
            groundNode.castsShadow = false
            // First among transparent surfaces, so the faded disc never
            // composites over glass or textured geometry above it.
            groundNode.renderingOrder = -1
            scene.rootNode.addChildNode(groundNode)

            // Camera framing the whole plan from a three-quarter aerial view.
            let cameraNode = SCNNode()
            let camera = SCNCamera()
            configureCamera(camera)
            cameraNode.camera = camera
            let pose = aerialPose(centerX: centerX, centerZ: centerZ,
                                  maxDimension: maxDimension, maxHeight: Float(maxHeight))
            cameraNode.position = pose.position
            cameraNode.look(at: pose.target)
            scene.rootNode.addChildNode(cameraNode)

            // The viewer orbits about this point — without it, SceneKit's
            // camera controller orbits the world origin (the plan's corner)
            // and the model swings wildly instead of turning in place.
            let orbitTarget = SCNNode()
            orbitTarget.name = "orbit-target"
            orbitTarget.position = SCNVector3(centerX, Float(maxHeight) * 0.3, centerZ)
            scene.rootNode.addChildNode(orbitTarget)
        }

        return scene
    }

    /// Three-quarter dollhouse pose. Steep (~60° elevation), because from
    /// a shallow angle the near walls hide the whole interior and their
    /// blank outer faces read as the floor.
    static func aerialPose(centerX: Float, centerZ: Float,
                           maxDimension: Float, maxHeight: Float)
        -> (position: SCNVector3, target: SCNVector3) {
        (SCNVector3(centerX + maxDimension * 0.55,
                    maxHeight + maxDimension * 1.35,
                    centerZ + maxDimension * 0.75),
         SCNVector3(centerX, maxHeight * 0.25, centerZ))
    }

    // MARK: - Studio environment & camera

    /// Backdrop plus image-based lighting for every viewer scene; PBR
    /// materials get their reflections and fill light from this.
    static func applyStudioEnvironment(to scene: SCNScene) {
        scene.background.contents = UIColor.secondarySystemBackground
        scene.lightingEnvironment.contents = studioEnvironmentImage
        scene.lightingEnvironment.intensity = 0.45
    }

    /// Shared camera setup: slightly long lens (flatters interiors), HDR
    /// pipeline with fixed exposure, and tight contact-shadow AO.
    static func configureCamera(_ camera: SCNCamera) {
        camera.fieldOfView = 50
        camera.zNear = 0.05
        camera.zFar = 300
        camera.wantsHDR = true
        camera.wantsExposureAdaptation = false
        camera.exposureOffset = -0.5
        camera.screenSpaceAmbientOcclusionIntensity = 0.9
        camera.screenSpaceAmbientOcclusionRadius = 0.5
    }

    /// Equirectangular sky-to-ground gradient — soft image-based lighting
    /// without shipping an HDR asset.
    private static let studioEnvironmentImage: UIImage = {
        let size = CGSize(width: 512, height: 256)
        return UIGraphicsImageRenderer(size: size).image { context in
            let colors = [UIColor(red: 0.96, green: 0.97, blue: 1.00, alpha: 1).cgColor,
                          UIColor(red: 0.80, green: 0.84, blue: 0.90, alpha: 1).cgColor,
                          UIColor(white: 0.52, alpha: 1).cgColor,
                          UIColor(white: 0.34, alpha: 1).cgColor]
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                         colors: colors as CFArray,
                                         locations: [0, 0.45, 0.55, 1]) {
                context.cgContext.drawLinearGradient(gradient, start: .zero,
                                                     end: CGPoint(x: 0, y: size.height),
                                                     options: [])
            }
        }
    }()

    /// Radial disc texture for the studio ground — opaque under the model,
    /// fading out so the floor never shows a hard edge.
    private static let groundFadeImage: UIImage = {
        let side: CGFloat = 512
        let size = CGSize(width: side, height: side)
        return UIGraphicsImageRenderer(size: size).image { context in
            let colors = [UIColor(white: 0.87, alpha: 1).cgColor,
                          UIColor(white: 0.87, alpha: 1).cgColor,
                          UIColor(white: 0.87, alpha: 0).cgColor]
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                         colors: colors as CFArray,
                                         locations: [0, 0.45, 1]) {
                context.cgContext.drawRadialGradient(
                    gradient,
                    startCenter: CGPoint(x: side / 2, y: side / 2), startRadius: 0,
                    endCenter: CGPoint(x: side / 2, y: side / 2), endRadius: side / 2,
                    options: [])
            }
        }
    }()

    /// Physically based material with the app's standard defaults.
    private static func pbrMaterial(_ diffuse: UIColor, roughness: CGFloat,
                                    metalness: CGFloat = 0,
                                    doubleSided: Bool = false) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.diffuse.contents = diffuse
        material.roughness.contents = roughness as NSNumber
        material.metalness.contents = metalness as NSNumber
        material.isDoubleSided = doubleSided
        return material
    }

    /// Adds one room's walls (with door/window cut-outs), interior walls,
    /// fixtures, floor slab, and dimension labels to the scene. Returns
    /// the room's ceiling height.
    private static func addRoom(_ room: CornerRoom, to scene: SCNScene,
                                originX: Double, originZ: Double,
                                wallNamePrefix: String,
                                useImperial: Bool, withLabels: Bool,
                                withHeightDimension: Bool) -> Double {
        let points = room.corners.map { CornerRoom.Point(x: $0.x - originX, z: $0.z - originZ) }
        let height = room.ceilingHeightMeters > 0.5 ? room.ceilingHeightMeters : 2.4

        let centroidX = points.map(\.x).reduce(0, +) / Double(points.count)
        let centroidZ = points.map(\.z).reduce(0, +) / Double(points.count)

        let wallMaterial = pbrMaterial(UIColor(red: 0.93, green: 0.92, blue: 0.90, alpha: 1),
                                       roughness: 0.85, doubleSided: true)
        let trimMaterial = pbrMaterial(UIColor(white: 0.95, alpha: 1), roughness: 0.35)

        for index in 0..<points.count {
            let a = points[index]
            let b = points[(index + 1) % points.count]
            let dx = b.x - a.x
            let dz = b.z - a.z
            let length = (dx * dx + dz * dz).squareRoot()
            guard length > 0.05 else { continue }
            let dirX = dx / length
            let dirZ = dz / length
            let angle = Float(-atan2(dz, dx))
            // Per-wall paint shadows the shared finish for this wall only.
            let wallMaterial = paintedMaterial(hex: room.outlineWallHex[index], base: wallMaterial)

            // Build the wall in pieces around its doors and windows.
            let wallOpenings = room.openings
                .filter { $0.wallIndex == index && $0.interiorWallID == nil }
                .compactMap { opening -> (from: Double, to: Double, kind: CornerRoom.Opening.Kind, id: UUID, sill: Double, windowHeight: Double)? in
                    let from = min(max(opening.offsetMeters, 0), length)
                    let to = min(from + max(opening.widthMeters, 0.05), length)
                    return to > from ? (from, to, opening.kind, opening.id,
                                        opening.sillMeters ?? windowSillHeight,
                                        opening.heightMeters ?? 1.07) : nil
                }
                .sorted { $0.from < $1.from }

            var cursor = 0.0
            for opening in wallOpenings {
                let from = max(opening.from, cursor)
                guard opening.to > from else { continue }
                if from > cursor + 0.01 {
                    addWallPiece(startX: a.x, startZ: a.z, dirX: dirX, dirZ: dirZ,
                                 from: cursor, to: from, bottom: 0, top: height, roomHeight: height,
                                 angle: angle, material: wallMaterial, trim: trimMaterial,
                                 in: scene, name: wallNamePrefix + String(index),
                                 cornerExtendedOver: length)
                }
                switch opening.kind {
                case .door, .closetDoor, .opening:
                    let head = min(doorHeadHeight, height)
                    if height - head > 0.02 {
                        addWallPiece(startX: a.x, startZ: a.z, dirX: dirX, dirZ: dirZ,
                                     from: from, to: opening.to, bottom: head, top: height, roomHeight: height,
                                     angle: angle, material: wallMaterial, trim: trimMaterial,
                                     in: scene, name: "opening-\(opening.id.uuidString)",
                                     cornerExtendedOver: length)
                    }
                case .window:
                    let sill = min(opening.sill, height)
                    addWallPiece(startX: a.x, startZ: a.z, dirX: dirX, dirZ: dirZ,
                                 from: from, to: opening.to, bottom: 0, top: sill, roomHeight: height,
                                 angle: angle, material: wallMaterial, trim: trimMaterial,
                                 in: scene, name: "opening-\(opening.id.uuidString)",
                                 cornerExtendedOver: length)
                    let head = min(opening.sill + opening.windowHeight, height)
                    if height - head > 0.02 {
                        addWallPiece(startX: a.x, startZ: a.z, dirX: dirX, dirZ: dirZ,
                                     from: from, to: opening.to, bottom: head, top: height, roomHeight: height,
                                     angle: angle, material: wallMaterial, trim: trimMaterial,
                                     in: scene, name: "opening-\(opening.id.uuidString)",
                                     cornerExtendedOver: length)
                    }
                }
                cursor = opening.to
            }
            if length - cursor > 0.01 {
                addWallPiece(startX: a.x, startZ: a.z, dirX: dirX, dirZ: dirZ,
                             from: cursor, to: length, bottom: 0, top: height, roomHeight: height,
                             angle: angle, material: wallMaterial, trim: trimMaterial,
                             in: scene, name: wallNamePrefix + String(index),
                             cornerExtendedOver: length)
            }

            // Visible fills: door leaves, bifolds, and window glass.
            for opening in room.openings where opening.wallIndex == index && opening.interiorWallID == nil {
                let from = min(max(opening.offsetMeters, 0), length)
                let to = min(from + max(opening.widthMeters, 0.05), length)
                guard to > from else { continue }
                addOpeningFill(opening, from: from, to: to,
                               startX: a.x, startZ: a.z, dirX: dirX, dirZ: dirZ,
                               wallHeight: height,
                               centroidX: centroidX, centroidZ: centroidZ, in: scene)
            }

            if withLabels {
                // Plan-style dimension on the ground just outside the wall.
                let midX = (a.x + b.x) / 2
                let midZ = (a.z + b.z) / 2
                let normal = outwardNormal(dx: dx, dz: dz, midX: midX, midZ: midZ,
                                           centroidX: centroidX, centroidZ: centroidZ)
                addDimension(Measure.length(length, imperial: useImperial),
                             fromX: a.x, fromZ: a.z, toX: b.x, toZ: b.z,
                             normalX: normal.x, normalZ: normal.z, in: scene)
            }
        }

        // Interior walls (partitions, closets), built in pieces around
        // their doors and windows just like the outline walls.
        for wall in room.interiorWalls {
            let sx = wall.start.x - originX
            let sz = wall.start.z - originZ
            let ex = wall.end.x - originX
            let ez = wall.end.z - originZ
            let dx = ex - sx
            let dz = ez - sz
            let length = (dx * dx + dz * dz).squareRoot()
            guard length > 0.05 else { continue }
            let dirX = dx / length
            let dirZ = dz / length
            let angle = Float(-atan2(dz, dx))
            let name = "interior-\(wall.id.uuidString)"
            let wallMaterial = paintedMaterial(hex: wall.paintHex, base: wallMaterial)

            let wallOpenings = room.openings
                .filter { $0.interiorWallID == wall.id }
                .compactMap { opening -> (from: Double, to: Double, kind: CornerRoom.Opening.Kind, id: UUID, sill: Double, windowHeight: Double)? in
                    let from = min(max(opening.offsetMeters, 0), length)
                    let to = min(from + max(opening.widthMeters, 0.05), length)
                    return to > from ? (from, to, opening.kind, opening.id,
                                        opening.sillMeters ?? windowSillHeight,
                                        opening.heightMeters ?? 1.07) : nil
                }
                .sorted { $0.from < $1.from }

            var cursor = 0.0
            for opening in wallOpenings {
                let from = max(opening.from, cursor)
                guard opening.to > from else { continue }
                if from > cursor + 0.01 {
                    addWallPiece(startX: sx, startZ: sz, dirX: dirX, dirZ: dirZ,
                                 from: cursor, to: from, bottom: 0, top: height, roomHeight: height,
                                 angle: angle, material: wallMaterial, trim: trimMaterial,
                                 in: scene, name: name)
                }
                switch opening.kind {
                case .door, .closetDoor, .opening:
                    let head = min(doorHeadHeight, height)
                    if height - head > 0.02 {
                        addWallPiece(startX: sx, startZ: sz, dirX: dirX, dirZ: dirZ,
                                     from: from, to: opening.to, bottom: head, top: height, roomHeight: height,
                                     angle: angle, material: wallMaterial, trim: trimMaterial,
                                     in: scene, name: "opening-\(opening.id.uuidString)")
                    }
                case .window:
                    let sill = min(opening.sill, height)
                    addWallPiece(startX: sx, startZ: sz, dirX: dirX, dirZ: dirZ,
                                 from: from, to: opening.to, bottom: 0, top: sill, roomHeight: height,
                                 angle: angle, material: wallMaterial, trim: trimMaterial,
                                 in: scene, name: "opening-\(opening.id.uuidString)")
                    let head = min(opening.sill + opening.windowHeight, height)
                    if height - head > 0.02 {
                        addWallPiece(startX: sx, startZ: sz, dirX: dirX, dirZ: dirZ,
                                     from: from, to: opening.to, bottom: head, top: height, roomHeight: height,
                                     angle: angle, material: wallMaterial, trim: trimMaterial,
                                     in: scene, name: "opening-\(opening.id.uuidString)")
                    }
                }
                cursor = opening.to
            }
            if length - cursor > 0.01 {
                addWallPiece(startX: sx, startZ: sz, dirX: dirX, dirZ: dirZ,
                             from: cursor, to: length, bottom: 0, top: height, roomHeight: height,
                             angle: angle, material: wallMaterial, trim: trimMaterial,
                             in: scene, name: name)
            }

            for opening in room.openings where opening.interiorWallID == wall.id {
                let from = min(max(opening.offsetMeters, 0), length)
                let to = min(from + max(opening.widthMeters, 0.05), length)
                guard to > from else { continue }
                addOpeningFill(opening, from: from, to: to,
                               startX: sx, startZ: sz, dirX: dirX, dirZ: dirZ,
                               wallHeight: height,
                               centroidX: centroidX, centroidZ: centroidZ, in: scene)
            }
        }

        // Fixtures: cabinets, bathroom pieces, stairs. Each fixture lives
        // under one named parent node so the 3D viewer can drag it.
        let cabinetMaterial = pbrMaterial(UIColor(red: 0.72, green: 0.60, blue: 0.48, alpha: 1),
                                          roughness: 0.55)
        let counterMaterial = pbrMaterial(UIColor(white: 0.25, alpha: 1), roughness: 0.3)
        let ceramicMaterial = pbrMaterial(UIColor(white: 0.97, alpha: 1), roughness: 0.12)

        for fixture in room.fixtures {
            let parent = SCNNode()
            parent.name = "fixture-\(fixture.id.uuidString)"
            parent.position = SCNVector3(Float(fixture.x - originX), 0, Float(fixture.z - originZ))
            parent.eulerAngles = SCNVector3(0, Float(-fixture.rotationDegrees * .pi / 180), 0)
            scene.rootNode.addChildNode(parent)

            func addBox(width: Double, depth: Double, boxHeight: Double, yCenter: Double,
                        xOffset: Double = 0, zOffset: Double = 0, material: SCNMaterial) {
                let box = SCNBox(width: CGFloat(width), height: CGFloat(boxHeight),
                                 length: CGFloat(depth), chamferRadius: 0.01)
                box.materials = [material]
                let node = SCNNode(geometry: box)
                node.position = SCNVector3(Float(xOffset), Float(yCenter), Float(zOffset))
                parent.addChildNode(node)
            }

            func addCylinder(radius: Double, cylinderHeight: Double, yCenter: Double,
                             zOffset: Double = 0, material: SCNMaterial) {
                let cylinder = SCNCylinder(radius: CGFloat(radius), height: CGFloat(cylinderHeight))
                cylinder.materials = [material]
                let node = SCNNode(geometry: cylinder)
                node.position = SCNVector3(0, Float(yCenter), Float(zOffset))
                parent.addChildNode(node)
            }

            let w = fixture.widthMeters
            let d = fixture.depthMeters
            switch fixture.kind {
            case .baseCabinets, .island:
                addBox(width: w, depth: d, boxHeight: 0.9, yCenter: 0.45, material: cabinetMaterial)
                addBox(width: w + 0.05, depth: d + 0.05, boxHeight: 0.04, yCenter: 0.92, material: counterMaterial)
            case .upperCabinets:
                addBox(width: w, depth: d, boxHeight: 0.76, yCenter: 1.75, material: cabinetMaterial)
            case .toilet:
                addBox(width: w, depth: 0.16, boxHeight: 0.45, yCenter: 0.55,
                       zOffset: -d / 2 + 0.08, material: ceramicMaterial)
                addCylinder(radius: min(w, d) * 0.3, cylinderHeight: 0.4, yCenter: 0.2,
                            zOffset: d * 0.15, material: ceramicMaterial)
            case .vanity:
                addBox(width: w, depth: d, boxHeight: 0.85, yCenter: 0.425, material: cabinetMaterial)
                addBox(width: w + 0.04, depth: d + 0.04, boxHeight: 0.03, yCenter: 0.865, material: counterMaterial)
                addCylinder(radius: min(w, d) * 0.25, cylinderHeight: 0.03, yCenter: 0.895, material: ceramicMaterial)
            case .tubShower:
                // A real tub: basin floor, four rim walls you can see into,
                // and a faucet riser on the back rim.
                addBox(width: w, depth: d, boxHeight: 0.12, yCenter: 0.06, material: ceramicMaterial)
                addBox(width: w, depth: 0.09, boxHeight: 0.55, yCenter: 0.275,
                       zOffset: d / 2 - 0.045, material: ceramicMaterial)
                addBox(width: w, depth: 0.09, boxHeight: 0.55, yCenter: 0.275,
                       zOffset: -d / 2 + 0.045, material: ceramicMaterial)
                addBox(width: 0.09, depth: d - 0.18, boxHeight: 0.55, yCenter: 0.275,
                       xOffset: w / 2 - 0.045, material: ceramicMaterial)
                addBox(width: 0.09, depth: d - 0.18, boxHeight: 0.55, yCenter: 0.275,
                       xOffset: -w / 2 + 0.045, material: ceramicMaterial)
                let chrome = pbrMaterial(UIColor(white: 0.95, alpha: 1), roughness: 0.12, metalness: 1)
                addCylinder(radius: 0.018, cylinderHeight: 0.22, yCenter: 0.64,
                            zOffset: -d / 2 + 0.045, material: chrome)
            case .shower:
                addBox(width: w, depth: d, boxHeight: 0.09, yCenter: 0.045, material: ceramicMaterial)
                let showerGlass = pbrMaterial(UIColor(red: 0.75, green: 0.85, blue: 0.90, alpha: 1),
                                              roughness: 0.05, doubleSided: true)
                showerGlass.transparency = 0.3
                addBox(width: w, depth: 0.02, boxHeight: 1.85, yCenter: 1.015,
                       zOffset: d / 2 - 0.01, material: showerGlass)
                addBox(width: 0.02, depth: d, boxHeight: 1.85, yCenter: 1.015,
                       xOffset: w / 2 - 0.01, material: showerGlass)
            case .fridge:
                addBox(width: w, depth: d, boxHeight: 1.7, yCenter: 0.85, material: ceramicMaterial)
            case .stove:
                addBox(width: w, depth: d, boxHeight: 0.91, yCenter: 0.455, material: counterMaterial)
            case .washer, .dryer:
                addBox(width: w, depth: d, boxHeight: 0.9, yCenter: 0.45, material: ceramicMaterial)
            case .furnace:
                addBox(width: w, depth: d, boxHeight: 1.5, yCenter: 0.75, material: counterMaterial)
            case .waterHeater:
                addCylinder(radius: min(w, d) / 2, cylinderHeight: 1.5, yCenter: 0.75, material: ceramicMaterial)
            case .bedQueen, .bedSingle:
                addBox(width: w, depth: 0.08, boxHeight: 1.0, yCenter: 0.5,
                       zOffset: -d / 2 + 0.04, material: cabinetMaterial)
                addBox(width: w, depth: d, boxHeight: 0.3, yCenter: 0.15, material: cabinetMaterial)
                addBox(width: w - 0.06, depth: d - 0.1, boxHeight: 0.22, yCenter: 0.41, material: ceramicMaterial)
            case .dresser:
                addBox(width: w, depth: d, boxHeight: 1.0, yCenter: 0.5, material: cabinetMaterial)
            case .sofa:
                addBox(width: w, depth: d, boxHeight: 0.45, yCenter: 0.225, material: cabinetMaterial)
                addBox(width: w, depth: 0.22, boxHeight: 0.85, yCenter: 0.425,
                       zOffset: -d / 2 + 0.11, material: cabinetMaterial)
            case .stairs:
                let stepCount = max(3, Int(w / 0.25))
                let tread = w / Double(stepCount)
                let rise = height / Double(stepCount)
                for step in 0..<stepCount {
                    let stepHeight = rise * Double(step + 1)
                    addBox(width: tread, depth: d, boxHeight: stepHeight, yCenter: stepHeight / 2,
                           xOffset: -w / 2 + tread * (Double(step) + 0.5), material: cabinetMaterial)
                }
            }
        }

        let path = UIBezierPath()
        path.move(to: CGPoint(x: points[0].x, y: points[0].z))
        for point in points.dropFirst() {
            path.addLine(to: CGPoint(x: point.x, y: point.z))
        }
        path.close()
        let floorShape = SCNShape(path: path, extrusionDepth: 0.05)
        let floorMaterial = SCNMaterial()
        floorMaterial.lightingModel = .physicallyBased
        floorMaterial.metalness.contents = 0 as NSNumber
        // SCNShape's extruded faces are wound so the upward face is
        // back-face culled from aerial angles; render both sides.
        floorMaterial.isDoubleSided = true
        if let texture = floorTexture(for: room.floorType, baseHex: room.floorHex) {
            // One texture tile ≈ 1.2 m; repeat over the room's bounds.
            let minPX = points.map(\.x).min() ?? 0
            let maxPX = points.map(\.x).max() ?? 1
            let minPZ = points.map(\.z).min() ?? 0
            let maxPZ = points.map(\.z).max() ?? 1
            let tiling = SCNMatrix4MakeScale(Float(max(maxPX - minPX, 0.5) / 1.2),
                                             Float(max(maxPZ - minPZ, 0.5) / 1.2), 1)
            floorMaterial.diffuse.contents = texture.color
            floorMaterial.diffuse.wrapS = .repeat
            floorMaterial.diffuse.wrapT = .repeat
            floorMaterial.diffuse.mipFilter = .linear
            floorMaterial.diffuse.contentsTransform = tiling
            floorMaterial.normal.contents = texture.normal
            floorMaterial.normal.wrapS = .repeat
            floorMaterial.normal.wrapT = .repeat
            floorMaterial.normal.mipFilter = .linear
            floorMaterial.normal.contentsTransform = tiling
            floorMaterial.normal.intensity = 0.7
            floorMaterial.roughness.contents = floorRoughness(for: room.floorType) as NSNumber
        } else if let hex = room.floorHex, let tint = UIColor(hexString: hex) {
            floorMaterial.diffuse.contents = tint
            floorMaterial.roughness.contents = 0.6 as NSNumber
        } else {
            floorMaterial.diffuse.contents = UIColor(red: 0.78, green: 0.72, blue: 0.64, alpha: 1)
            floorMaterial.roughness.contents = 0.6 as NSNumber
        }
        floorShape.materials = [floorMaterial]
        let floorNode = SCNNode(geometry: floorShape)
        floorNode.eulerAngles = SCNVector3(Float.pi / 2, 0, 0)
        scene.rootNode.addChildNode(floorNode)

        if withHeightDimension {
            // Vertical dimension line at the first corner, floor to ceiling.
            let corner = points[0]
            let toCornerX = corner.x - centroidX
            let toCornerZ = corner.z - centroidZ
            let distance = max((toCornerX * toCornerX + toCornerZ * toCornerZ).squareRoot(), 0.001)
            let ox = toCornerX / distance
            let oz = toCornerZ / distance

            let line = SCNCylinder(radius: 0.008, height: CGFloat(height))
            let lineMaterial = SCNMaterial()
            lineMaterial.diffuse.contents = UIColor(white: 0.35, alpha: 1)
            lineMaterial.lightingModel = .constant
            line.materials = [lineMaterial]
            let lineNode = SCNNode(geometry: line)
            lineNode.position = SCNVector3(Float(corner.x + ox * 0.3),
                                           Float(height / 2),
                                           Float(corner.z + oz * 0.3))
            lineNode.castsShadow = false
            scene.rootNode.addChildNode(lineNode)

            addLabel("Height \(Measure.length(height, imperial: useImperial))",
                     at: SCNVector3(Float(corner.x + ox * 0.8),
                                    Float(height / 2),
                                    Float(corner.z + oz * 0.8)),
                     in: scene)
        }

        return height
    }

    /// The best available scene for viewing: RoomPlan USDZ if a LiDAR scan
    /// exists, otherwise a labelled corner-capture scene, otherwise any
    /// USDZ on disk.
    static func viewerScene(for project: RenovationProject, useImperial: Bool) -> SCNScene? {
        // Editable rooms own the model once they exist (edits show live);
        // an unconverted LiDAR scan shows its own USDZ.
        let rooms = ScanStore.loadRooms(for: project)
        if !rooms.isEmpty {
            return makeScene(rooms: rooms.map(\.room), useImperial: useImperial, withLabels: true)
        }
        if let url = ScanStore.lidarUSDZURL(for: project),
           let scene = try? SCNScene(url: url) {
            applyStudioEnvironment(to: scene)
            return scene
        }
        if let url = ScanStore.usdzURL(for: project),
           let scene = try? SCNScene(url: url) {
            applyStudioEnvironment(to: scene)
            return scene
        }
        return nil
    }

    // Serial writer so concurrent background writes to the same URL never
    // interleave, plus a per-URL generation token: a newer write (or a
    // cancelUSDZWrite before a delete) supersedes any pending/in-flight
    // write so a coalesced or cancelled write neither wins a race nor
    // resurrects a just-deleted file.
    private static let usdzWriteQueue = DispatchQueue(label: "Model3DBuilder.usdzWrite")
    private static let usdzGenerationLock = NSLock()
    private static var usdzGenerations: [URL: Int] = [:]

    private static func bumpUSDZGeneration(for url: URL) -> Int {
        usdzGenerationLock.lock()
        defer { usdzGenerationLock.unlock() }
        let next = usdzGenerations[url, default: 0] + 1
        usdzGenerations[url] = next
        return next
    }

    private static func currentUSDZGeneration(for url: URL) -> Int {
        usdzGenerationLock.lock()
        defer { usdzGenerationLock.unlock() }
        return usdzGenerations[url, default: 0]
    }

    /// Fire-and-forget USDZ regeneration off the main thread. Scene
    /// building + Model I/O conversion can take many seconds for large
    /// rooms — running it synchronously froze the UI (and, suspended
    /// mid-write, survived app relaunches as a "frozen page"). Writes are
    /// serialized and coalesced per URL.
    static func writeUSDZInBackground(rooms: [CornerRoom], to url: URL) {
        let generation = bumpUSDZGeneration(for: url)
        usdzWriteQueue.async {
            // A newer write (coalesce) or a cancel/delete arrived first.
            guard currentUSDZGeneration(for: url) == generation else { return }
            do {
                try writeUSDZ(rooms: rooms, to: url)
            } catch {
                return   // Non-fatal; the atomic write left no partial file.
            }
            // If a cancel/delete landed while we were writing, don't leave
            // the resurrected file behind.
            if currentUSDZGeneration(for: url) != generation {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    /// Marks any pending or in-flight background write to `url` as
    /// superseded, so a write that finishes after the caller deletes the
    /// file will not (re)create it. Call before deleting a scan's USDZ.
    static func cancelUSDZWrite(to url: URL) {
        _ = bumpUSDZGeneration(for: url)
    }

    static func writeUSDZ(rooms: [CornerRoom], to url: URL) throws {
        guard let scene = makeScene(rooms: rooms, useImperial: true, withLabels: false) else {
            throw BuildError.notEnoughCorners
        }
        // Write to a sibling temp file (kept a .usdz so SceneKit picks the
        // USDZ writer), then atomically swap it into place — a reader or a
        // coalesced later write never sees a half-written model, and a
        // failed write leaves no partial file behind.
        let tempURL = url.deletingLastPathComponent()
            .appendingPathComponent("\(UUID().uuidString).tmp.usdz")
        guard scene.write(to: tempURL, options: nil, delegate: nil, progressHandler: nil) else {
            try? FileManager.default.removeItem(at: tempURL)
            throw BuildError.exportFailed
        }
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL)
            } else {
                try FileManager.default.moveItem(at: tempURL, to: url)
            }
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw BuildError.exportFailed
        }
    }

    // MARK: - Floor textures

    // These caches are read/written from both the main-thread pane rebuild
    // and the detached USDZ write; guard every access with a lock. The lock
    // is only ever held around the dictionary op — never across the
    // expensive image rendering below — so a cold-cache race at worst
    // renders a texture twice, it never traps or corrupts the dictionary.
    private static let cacheLock = NSLock()

    private static var floorTextureCache: [String: (color: UIImage, normal: UIImage?)] = [:]

    /// Surface sheen per finish, applied to the floor's PBR material.
    private static func floorRoughness(for type: CornerRoom.FloorType?) -> CGFloat {
        switch type {
        case .tile: 0.25
        case .hardwood, .laminate: 0.4
        case .vinylPlank: 0.45
        case .carpet: 0.95
        case .concrete: 0.75
        case nil: 0.6
        }
    }

    /// Procedural texture per floor type — plank boards with staggered
    /// joints, grout-lined tile, carpet stipple, mottled concrete — so
    /// finishes read as materials, not colour swatches. One tile ≈ 1.2 m.
    /// Ships with a luminance-derived normal map: plank gaps and grout
    /// lines become real grooves under the key light.
    private static func floorTexture(for type: CornerRoom.FloorType?,
                                     baseHex: String?) -> (color: UIImage, normal: UIImage?)? {
        guard let type else { return nil }
        let cacheKey = "\(type.rawValue)|\(baseHex ?? "default")"
        cacheLock.lock()
        let cached = floorTextureCache[cacheKey]
        cacheLock.unlock()
        if let cached { return cached }
        let customBase = baseHex.flatMap { UIColor(hexString: $0) }

        let side: CGFloat = 512
        let size = CGSize(width: side, height: side)
        var seed: UInt64 = 0x5eed_0f_ca51b1a1
        func random() -> CGFloat {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return CGFloat((seed >> 33) % 1000) / 1000
        }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        // Opaque, or SceneKit sorts the floor into the transparent pass
        // where the fading studio ground can composite over it.
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            let ctx = context.cgContext
            func fill(_ color: UIColor) {
                color.setFill()
                ctx.fill(CGRect(origin: .zero, size: size))
            }
            func planks(base: UIColor) {
                fill(UIColor(white: 0.15, alpha: 1))   // gaps show through
                var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
                base.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
                let rows = 4
                let rowHeight = side / CGFloat(rows)
                for row in 0..<rows {
                    let y = CGFloat(row) * rowHeight
                    var x = -random() * side * 0.6
                    while x < side {
                        let plankLength = side * (0.45 + random() * 0.25)
                        let shade = 0.82 + random() * 0.34
                        UIColor(red: min(red * shade, 1),
                                green: min(green * shade, 1),
                                blue: min(blue * shade, 1), alpha: 1).setFill()
                        ctx.fill(CGRect(x: x + 2, y: y + 2,
                                        width: plankLength - 4, height: rowHeight - 4))
                        x += plankLength
                    }
                }
            }

            switch type {
            case .vinylPlank:
                planks(base: customBase ?? UIColor(red: 0.72, green: 0.58, blue: 0.43, alpha: 1))
            case .laminate:
                planks(base: customBase ?? UIColor(red: 0.81, green: 0.68, blue: 0.51, alpha: 1))
            case .hardwood:
                planks(base: customBase ?? UIColor(red: 0.54, green: 0.37, blue: 0.23, alpha: 1))
            case .tile:
                fill(customBase ?? UIColor(red: 0.86, green: 0.86, blue: 0.84, alpha: 1))
                for tileX in 0..<2 {
                    for tileY in 0..<2 {
                        UIColor(white: 0, alpha: random() * 0.07).setFill()
                        ctx.fill(CGRect(x: CGFloat(tileX) * side / 2, y: CGFloat(tileY) * side / 2,
                                        width: side / 2, height: side / 2))
                    }
                }
                UIColor(white: 0.52, alpha: 1).setFill()
                for line in 0...2 {
                    ctx.fill(CGRect(x: CGFloat(line) * side / 2 - 2.5, y: 0, width: 5, height: side))
                    ctx.fill(CGRect(x: 0, y: CGFloat(line) * side / 2 - 2.5, width: side, height: 5))
                }
            case .carpet:
                fill(customBase ?? UIColor(red: 0.64, green: 0.62, blue: 0.57, alpha: 1))
                for _ in 0..<9000 {
                    UIColor(white: random() > 0.5 ? 1 : 0, alpha: 0.04 + random() * 0.07).setFill()
                    ctx.fill(CGRect(x: random() * side, y: random() * side, width: 3, height: 3))
                }
            case .concrete:
                fill(customBase ?? UIColor(red: 0.64, green: 0.64, blue: 0.66, alpha: 1))
                for _ in 0..<140 {
                    let blotch = 36 + random() * 140
                    UIColor(white: random() > 0.5 ? 0.72 : 0.52, alpha: 0.07).setFill()
                    ctx.fillEllipse(in: CGRect(x: random() * side - blotch / 2,
                                               y: random() * side - blotch / 2,
                                               width: blotch, height: blotch))
                }
            }
        }
        // Carpet relief comes from its stipple; keep it gentler than the
        // hard plank/grout grooves.
        let result = (color: image,
                      normal: normalMap(from: image, strength: type == .carpet ? 0.8 : 2.0))
        cacheLock.lock()
        floorTextureCache[cacheKey] = result
        cacheLock.unlock()
        return result
    }

    /// Tangent-space normal map derived from a texture's luminance, with
    /// wrap-around sampling so the tiled edges stay seamless.
    private static func normalMap(from image: UIImage, strength: Double) -> UIImage? {
        guard let cgImage = image.cgImage else { return nil }
        let width = cgImage.width
        let height = cgImage.height
        guard width > 2, height > 2 else { return nil }
        var luma = [UInt8](repeating: 0, count: width * height)
        let drawn = luma.withUnsafeMutableBytes { buffer -> Bool in
            guard let grayContext = CGContext(data: buffer.baseAddress,
                                              width: width, height: height,
                                              bitsPerComponent: 8, bytesPerRow: width,
                                              space: CGColorSpaceCreateDeviceGray(),
                                              bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            grayContext.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            let up = (y + height - 1) % height
            let down = (y + 1) % height
            for x in 0..<width {
                let left = (x + width - 1) % width
                let right = (x + 1) % width
                let gradientX = (Double(luma[y * width + right]) - Double(luma[y * width + left])) / 255
                let gradientY = (Double(luma[down * width + x]) - Double(luma[up * width + x])) / 255
                let nx = -gradientX * strength
                let ny = gradientY * strength
                let inverseLength = 1 / (nx * nx + ny * ny + 1).squareRoot()
                let offset = (y * width + x) * 4
                pixels[offset] = UInt8((nx * inverseLength * 0.5 + 0.5) * 255)
                pixels[offset + 1] = UInt8((ny * inverseLength * 0.5 + 0.5) * 255)
                pixels[offset + 2] = UInt8((inverseLength * 0.5 + 0.5) * 255)
                pixels[offset + 3] = 255
            }
        }
        let output = pixels.withUnsafeMutableBytes { buffer -> CGImage? in
            guard let context = CGContext(data: buffer.baseAddress,
                                          width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            return context.makeImage()
        }
        guard let output else { return nil }
        return UIImage(cgImage: output)
    }

    /// Per-wall paint: a fresh material in the chosen colour, or the shared
    /// wall finish when no paint is set.
    private static func paintedMaterial(hex: String?, base: SCNMaterial) -> SCNMaterial {
        guard let hex, let color = UIColor(hexString: hex) else { return base }
        return pbrMaterial(color, roughness: 0.85, doubleSided: true)
    }

    // MARK: - Opening fills (door leaves, bifolds, window glass)

    /// Visible geometry inside an opening: a wood-tone door leaf hung from
    /// the chosen hinge jamb and ajar 30° to the swing side, a bifold panel
    /// pair for closet doors, or translucent glass for windows. Cased
    /// openings stay open. Nodes are named "opening-<id>" so taps and
    /// drags treat them like the opening itself.
    private static func addOpeningFill(_ opening: CornerRoom.Opening,
                                       from: Double, to: Double,
                                       startX: Double, startZ: Double,
                                       dirX: Double, dirZ: Double,
                                       wallHeight: Double,
                                       centroidX: Double, centroidZ: Double,
                                       in scene: SCNScene) {
        let width = to - from
        guard width > 0.05 else { return }
        let nodeName = "opening-\(opening.id.uuidString)"
        let fromX = startX + dirX * from
        let fromZ = startZ + dirZ * from
        let toX = startX + dirX * to
        let toZ = startZ + dirZ * to
        let midX = (fromX + toX) / 2
        let midZ = (fromZ + toZ) / 2

        // Perpendicular pointing into the room.
        var nx = -dirZ
        var nz = dirX
        if nx * (centroidX - midX) + nz * (centroidZ - midZ) < 0 {
            nx = -nx
            nz = -nz
        }
        let swingX = (opening.swingsOutward ?? false) ? -nx : nx
        let swingZ = (opening.swingsOutward ?? false) ? -nz : nz

        let leafHeight = min(doorHeadHeight, wallHeight) - 0.01
        let woodMaterial = pbrMaterial(UIColor(red: 0.87, green: 0.82, blue: 0.74, alpha: 1),
                                       roughness: 0.5)

        /// A hinged leaf; `detailed` adds the raised panel pair and a
        /// chrome pull that sell a passage door (bifolds stay plain).
        func addPanel(_ ax: Double, _ az: Double, _ bx: Double, _ bz: Double,
                      detailed: Bool = false) {
            let dx = bx - ax
            let dz = bz - az
            let panelLength = (dx * dx + dz * dz).squareRoot()
            guard panelLength > 0.02 else { return }
            let panel = SCNBox(width: CGFloat(panelLength), height: CGFloat(leafHeight),
                               length: 0.035, chamferRadius: 0.003)
            panel.materials = [woodMaterial]
            let node = SCNNode(geometry: panel)
            node.name = nodeName
            node.position = SCNVector3(Float((ax + bx) / 2),
                                       Float(leafHeight / 2),
                                       Float((az + bz) / 2))
            node.eulerAngles = SCNVector3(0, Float(-atan2(dz, dx)), 0)
            scene.rootNode.addChildNode(node)

            guard detailed else { return }
            let mouldingMaterial = pbrMaterial(UIColor(red: 0.81, green: 0.76, blue: 0.68, alpha: 1),
                                               roughness: 0.5)
            // Slightly proud of the leaf, so both faces read as panelled.
            func addMoulding(centerY: Double, panelHeight: Double) {
                let moulding = SCNBox(width: CGFloat(panelLength * 0.62),
                                      height: CGFloat(panelHeight),
                                      length: 0.045, chamferRadius: 0.004)
                moulding.materials = [mouldingMaterial]
                let mouldingNode = SCNNode(geometry: moulding)
                mouldingNode.name = nodeName
                mouldingNode.position = SCNVector3(0, Float(centerY), 0)
                node.addChildNode(mouldingNode)
            }
            addMoulding(centerY: leafHeight * 0.17, panelHeight: leafHeight * 0.40)
            addMoulding(centerY: -leafHeight * 0.30, panelHeight: leafHeight * 0.32)

            let pull = SCNCylinder(radius: 0.018, height: 0.11)
            pull.materials = [pbrMaterial(UIColor(white: 0.95, alpha: 1), roughness: 0.12, metalness: 1)]
            let pullNode = SCNNode(geometry: pull)
            pullNode.name = nodeName
            pullNode.position = SCNVector3(Float(panelLength / 2 - 0.06),
                                           Float(0.95 - leafHeight / 2), 0)
            pullNode.eulerAngles = SCNVector3(Float.pi / 2, 0, 0)
            node.addChildNode(pullNode)
        }

        /// White jamb lining around the reveal, so cut-outs read as
        /// finished casings instead of raw wall ends.
        func addJambLining() {
            let head = min(doorHeadHeight, wallHeight)
            let jambMaterial = pbrMaterial(UIColor(white: 0.95, alpha: 1), roughness: 0.35)
            let parent = SCNNode()
            parent.name = nodeName
            parent.position = SCNVector3(Float(midX), 0, Float(midZ))
            parent.eulerAngles = SCNVector3(0, Float(-atan2(dirZ, dirX)), 0)
            scene.rootNode.addChildNode(parent)

            let member = 0.035
            let depth = wallThickness + 0.024
            func addJamb(x: Double, y: Double, jambWidth: Double, jambHeight: Double) {
                let box = SCNBox(width: CGFloat(jambWidth), height: CGFloat(jambHeight),
                                 length: CGFloat(depth), chamferRadius: 0.004)
                box.materials = [jambMaterial]
                let jambNode = SCNNode(geometry: box)
                jambNode.name = nodeName
                jambNode.position = SCNVector3(Float(x), Float(y), 0)
                parent.addChildNode(jambNode)
            }
            addJamb(x: -width / 2 + member / 2, y: head / 2, jambWidth: member, jambHeight: head)
            addJamb(x: width / 2 - member / 2, y: head / 2, jambWidth: member, jambHeight: head)
            addJamb(x: 0, y: head - member / 2, jambWidth: width - member * 2, jambHeight: member)
        }

        switch opening.kind {
        case .window:
            let sill = min(opening.sillMeters ?? windowSillHeight, wallHeight)
            let glassHeight = min(opening.heightMeters ?? 1.07, wallHeight - sill)
            guard glassHeight > 0.15 else { return }

            // A real window assembly: white frame + centre mullion +
            // sheened glass + protruding sill ledge, built in the frame's
            // local space and rotated into the wall.
            let parent = SCNNode()
            parent.name = nodeName
            parent.position = SCNVector3(Float(midX), Float(sill + glassHeight / 2), Float(midZ))
            parent.eulerAngles = SCNVector3(0, Float(-atan2(dirZ, dirX)), 0)
            scene.rootNode.addChildNode(parent)

            let frameMaterial = pbrMaterial(UIColor(white: 0.94, alpha: 1), roughness: 0.3)
            let glassMaterial = pbrMaterial(UIColor(red: 0.64, green: 0.79, blue: 0.88, alpha: 1),
                                            roughness: 0.05, doubleSided: true)
            glassMaterial.transparency = 0.4

            let member = 0.05                 // frame face width
            let frameDepth = 0.11             // pokes just past the wall
            func addFramePart(width partWidth: Double, height partHeight: Double,
                              depth partDepth: Double, x: Double, y: Double,
                              material: SCNMaterial) {
                let box = SCNBox(width: CGFloat(partWidth), height: CGFloat(partHeight),
                                 length: CGFloat(partDepth), chamferRadius: 0.004)
                box.materials = [material]
                let node = SCNNode(geometry: box)
                node.position = SCNVector3(Float(x), Float(y), 0)
                parent.addChildNode(node)
            }

            // Rails (top/bottom), stiles (sides), centre mullion, glass.
            addFramePart(width: width, height: member, depth: frameDepth,
                         x: 0, y: glassHeight / 2 - member / 2, material: frameMaterial)
            addFramePart(width: width, height: member, depth: frameDepth,
                         x: 0, y: -glassHeight / 2 + member / 2, material: frameMaterial)
            addFramePart(width: member, height: glassHeight - member * 2, depth: frameDepth,
                         x: width / 2 - member / 2, y: 0, material: frameMaterial)
            addFramePart(width: member, height: glassHeight - member * 2, depth: frameDepth,
                         x: -width / 2 + member / 2, y: 0, material: frameMaterial)
            if width > 0.7 {
                addFramePart(width: 0.03, height: glassHeight - member * 2, depth: frameDepth - 0.02,
                             x: 0, y: 0, material: frameMaterial)
            }
            addFramePart(width: width - member * 2, height: glassHeight - member * 2,
                         depth: 0.015, x: 0, y: 0, material: glassMaterial)
            // Sill ledge along the bottom, proud of the wall on both sides.
            addFramePart(width: width + 0.09, height: 0.03, depth: 0.2,
                         x: 0, y: -glassHeight / 2 - 0.015, material: frameMaterial)
        case .door:
            addJambLining()
            let hingeAtEnd = opening.hingeOnEnd ?? false
            let hingeX = hingeAtEnd ? toX : fromX
            let hingeZ = hingeAtEnd ? toZ : fromZ
            let latchDirX = hingeAtEnd ? -dirX : dirX
            let latchDirZ = hingeAtEnd ? -dirZ : dirZ
            let theta = Double.pi / 6   // ajar 30°
            let openX = latchDirX * cos(theta) + swingX * sin(theta)
            let openZ = latchDirZ * cos(theta) + swingZ * sin(theta)
            addPanel(hingeX, hingeZ, hingeX + openX * width, hingeZ + openZ * width,
                     detailed: true)
        case .closetDoor:
            addJambLining()
            // Bifold pair meeting at the pushed-out centre.
            let depth = width / 4
            let midOutX = midX + swingX * depth
            let midOutZ = midZ + swingZ * depth
            addPanel(fromX, fromZ, midOutX, midOutZ)
            addPanel(midOutX, midOutZ, toX, toZ)
        case .opening:
            // Cased opening: lined reveal, nothing hung in it.
            addJambLining()
        }
    }

    // MARK: - Wall pieces

    private static func addWallPiece(startX: Double, startZ: Double,
                                     dirX: Double, dirZ: Double,
                                     from: Double, to: Double,
                                     bottom: Double, top: Double,
                                     roomHeight: Double,
                                     angle: Float, material: SCNMaterial,
                                     trim: SCNMaterial, in scene: SCNScene,
                                     name: String? = nil,
                                     cornerExtendedOver wallLength: Double? = nil) {
        guard to - from > 0.01, top - bottom > 0.01 else { return }
        // Outline pieces reaching a corner extend half a wall thickness so
        // the two walls close the joint instead of leaving an outer notch.
        var from = from
        var to = to
        if let wallLength {
            if from < 0.005 { from -= wallThickness / 2 }
            if to > wallLength - 0.005 { to += wallThickness / 2 }
        }
        let length = to - from
        let box = SCNBox(width: CGFloat(length), height: CGFloat(top - bottom),
                         length: CGFloat(wallThickness), chamferRadius: 0)
        box.materials = [material]
        let node = SCNNode(geometry: box)
        node.name = name
        let mid = (from + to) / 2
        node.position = SCNVector3(Float(startX + dirX * mid),
                                   Float((bottom + top) / 2),
                                   Float(startZ + dirZ * mid))
        node.eulerAngles = SCNVector3(0, angle, 0)
        scene.rootNode.addChildNode(node)

        // Skirting along floor-level pieces; painted walls keep white trim.
        if bottom < 0.005 {
            let skirting = SCNBox(width: CGFloat(length), height: CGFloat(baseboardHeight),
                                  length: CGFloat(wallThickness + 0.024), chamferRadius: 0.004)
            skirting.materials = [trim]
            let skirtingNode = SCNNode(geometry: skirting)
            skirtingNode.name = name
            skirtingNode.position = SCNVector3(node.position.x,
                                               Float(baseboardHeight / 2),
                                               node.position.z)
            skirtingNode.eulerAngles = node.eulerAngles
            scene.rootNode.addChildNode(skirtingNode)
        }

        // A thin cap on the cut top edge, so the dollhouse section reads
        // as deliberate rather than raw.
        if abs(top - roomHeight) < 0.005 {
            let cap = SCNBox(width: CGFloat(length), height: 0.02,
                             length: CGFloat(wallThickness + 0.012), chamferRadius: 0.002)
            cap.materials = [trim]
            let capNode = SCNNode(geometry: cap)
            capNode.name = name
            capNode.position = SCNVector3(node.position.x,
                                          Float(top + 0.01),
                                          node.position.z)
            capNode.eulerAngles = node.eulerAngles
            scene.rootNode.addChildNode(capNode)
        }
    }

    // MARK: - Labels

    private static func outwardNormal(dx: Double, dz: Double,
                                      midX: Double, midZ: Double,
                                      centroidX: Double, centroidZ: Double) -> (x: Double, z: Double) {
        let length = max((dx * dx + dz * dz).squareRoot(), 0.001)
        var nx = dz / length
        var nz = -dx / length
        if nx * (midX - centroidX) + nz * (midZ - centroidZ) < 0 {
            nx = -nx
            nz = -nz
        }
        return (nx, nz)
    }

    private static var chipImageCache: [String: UIImage] = [:]

    /// Measurement chip: dark text in a white rounded pill, the way plan
    /// annotations read — legible against walls, floor, and backdrop.
    private static func chipImage(_ string: String) -> UIImage {
        cacheLock.lock()
        let cached = chipImageCache[string]
        cacheLock.unlock()
        if let cached { return cached }
        let font = UIFont.systemFont(ofSize: 52, weight: .semibold)
        let text = NSAttributedString(string: string, attributes: [
            .font: font,
            .foregroundColor: UIColor(white: 0.12, alpha: 1),
        ])
        let textSize = text.size()
        let paddingH: CGFloat = 30
        let paddingV: CGFloat = 14
        let size = CGSize(width: ceil(textSize.width) + paddingH * 2,
                          height: ceil(textSize.height) + paddingV * 2)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            UIColor(white: 1, alpha: 0.94).setFill()
            UIBezierPath(roundedRect: CGRect(origin: .zero, size: size),
                         cornerRadius: size.height / 2).fill()
            text.draw(at: CGPoint(x: paddingH, y: paddingV))
        }
        cacheLock.lock()
        chipImageCache[string] = image
        cacheLock.unlock()
        return image
    }

    private static func addLabel(_ string: String, at position: SCNVector3, in scene: SCNScene) {
        let image = chipImage(string)
        let chipHeight: CGFloat = 0.16
        let plane = SCNPlane(width: image.size.width / image.size.height * chipHeight,
                             height: chipHeight)
        let material = SCNMaterial()
        material.diffuse.contents = image
        material.lightingModel = .constant
        material.isDoubleSided = true
        plane.materials = [material]

        let node = SCNNode(geometry: plane)
        node.position = SCNVector3(position.x, position.y + Float(chipHeight / 2), position.z)
        node.constraints = [SCNBillboardConstraint()]
        node.castsShadow = false
        scene.rootNode.addChildNode(node)
    }

    /// Plan-style dimension flat on the ground: witness lines off the wall
    /// ends, a line parallel to the wall with end ticks, and the
    /// measurement chip at its centre.
    private static func addDimension(_ string: String,
                                     fromX: Double, fromZ: Double,
                                     toX: Double, toZ: Double,
                                     normalX: Double, normalZ: Double,
                                     in scene: SCNScene) {
        let dx = toX - fromX
        let dz = toZ - fromZ
        let length = (dx * dx + dz * dz).squareRoot()
        guard length > 0.05 else { return }
        let angle = Float(-atan2(dz, dx))
        let offset = 0.45
        let material = SCNMaterial()
        material.diffuse.contents = UIColor(white: 0.35, alpha: 1)
        material.lightingModel = .constant

        func addBar(x: Double, z: Double, alongWall: Double, alongNormal: Double) {
            let box = SCNBox(width: CGFloat(max(alongWall, 0.012)), height: 0.012,
                             length: CGFloat(max(alongNormal, 0.012)), chamferRadius: 0)
            box.materials = [material]
            let node = SCNNode(geometry: box)
            node.position = SCNVector3(Float(x), 0.02, Float(z))
            node.eulerAngles = SCNVector3(0, angle, 0)
            node.castsShadow = false
            scene.rootNode.addChildNode(node)
        }

        let midX = (fromX + toX) / 2 + normalX * offset
        let midZ = (fromZ + toZ) / 2 + normalZ * offset
        addBar(x: midX, z: midZ, alongWall: length, alongNormal: 0)
        addBar(x: fromX + normalX * offset, z: fromZ + normalZ * offset,
               alongWall: 0, alongNormal: 0.12)
        addBar(x: toX + normalX * offset, z: toZ + normalZ * offset,
               alongWall: 0, alongNormal: 0.12)
        // Witness lines from just off the wall face to a bit past the line.
        let witnessStart = 0.10
        let witnessLength = offset + 0.06 - witnessStart
        let witnessMid = witnessStart + witnessLength / 2
        addBar(x: fromX + normalX * witnessMid, z: fromZ + normalZ * witnessMid,
               alongWall: 0, alongNormal: witnessLength)
        addBar(x: toX + normalX * witnessMid, z: toZ + normalZ * witnessMid,
               alongWall: 0, alongNormal: witnessLength)

        addLabel(string, at: SCNVector3(Float(midX), 0.03, Float(midZ)), in: scene)
    }
}
