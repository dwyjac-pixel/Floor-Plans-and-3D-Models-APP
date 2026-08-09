import Foundation
import simd
#if canImport(RoomPlan)
import RoomPlan
#endif

/// Converts a RoomPlan LiDAR scan into an editable CornerRoom.
///
/// The room outline comes from RoomPlan's own floor polygon when available
/// (iOS 17 delivers the "beautified" floor boundary already ordered — the
/// same outline the raw scan view draws), and otherwise from a graph
/// reconstruction of the wall segments: endpoints are clustered into corner
/// nodes, walls become edges, and the outline is the outer face of that
/// graph. Wall segments that are not part of the outline (closet partitions)
/// become editable interior walls, and doors/windows attach to whichever
/// host — outline wall or partition — they actually sit on. Every result
/// must pass hard gates (simple polygon, minimum area) or the conversion
/// returns nil so the caller keeps the raw scan instead of showing a
/// distorted plan.
enum ScanConverter {

    // MARK: - Geometry primitives (platform-independent, unit-testable)

    struct Segment {
        var a: SIMD2<Double>
        var b: SIMD2<Double>
        var length: Double { simd_distance(a, b) }
    }

    // Tunables, in metres unless noted.
    static let clusterTolerance = 0.35      // endpoint corner-cluster radius…
    static let joinFraction = 0.45          // …capped vs the shorter wall
    static let danglingWeld = 0.6           // relaxed-round loose-end weld
    static let minSegment = 0.15            // drop scan-noise slivers
    static let weightCap = 3.0              // cluster-average length weight cap
    static let dedupTolerance = 0.12        // consecutive-corner merge
    static let collinearDegrees = 3.0       // straight-through corner removal
    static let minInteriorLength = 0.3
    static let outlineHugDistance = 0.2     // duplicate-of-outline filter
    static let minRoomArea = 1.5            // m²
    static let attachTolerance = 0.5
    static let attachRescueTolerance = 1.0

    static func signedArea(_ points: [SIMD2<Double>]) -> Double {
        guard points.count >= 3 else { return 0 }
        var sum = 0.0
        for i in points.indices {
            let a = points[i]
            let b = points[(i + 1) % points.count]
            sum += a.x * b.y - b.x * a.y
        }
        return sum / 2
    }

    static func isSimplePolygon(_ points: [SIMD2<Double>]) -> Bool {
        let n = points.count
        guard n >= 3 else { return false }
        func cross(_ o: SIMD2<Double>, _ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }
        func properlyIntersects(_ p1: SIMD2<Double>, _ p2: SIMD2<Double>,
                                _ q1: SIMD2<Double>, _ q2: SIMD2<Double>) -> Bool {
            let d1 = cross(q1, q2, p1), d2 = cross(q1, q2, p2)
            let d3 = cross(p1, p2, q1), d4 = cross(p1, p2, q2)
            return ((d1 > 1e-9 && d2 < -1e-9) || (d1 < -1e-9 && d2 > 1e-9))
                && ((d3 > 1e-9 && d4 < -1e-9) || (d3 < -1e-9 && d4 > 1e-9))
        }
        for i in 0..<n {
            for j in (i + 1)..<n {
                if j == i + 1 || (i == 0 && j == n - 1) { continue }
                if properlyIntersects(points[i], points[(i + 1) % n],
                                      points[j], points[(j + 1) % n]) { return false }
            }
        }
        return true
    }

    static func distanceToPolygon(_ point: SIMD2<Double>, _ polygon: [SIMD2<Double>]) -> Double {
        guard polygon.count >= 2 else { return .infinity }
        var best = Double.infinity
        for i in polygon.indices {
            let a = polygon[i]
            let b = polygon[(i + 1) % polygon.count]
            let ab = b - a
            let lengthSquared = simd_length_squared(ab)
            let t = lengthSquared > 1e-12 ? max(0, min(1, simd_dot(point - a, ab) / lengthSquared)) : 0
            best = min(best, simd_distance(point, a + ab * t))
        }
        return best
    }

    static func containsPoint(_ polygon: [SIMD2<Double>], _ point: SIMD2<Double>) -> Bool {
        guard polygon.count >= 3 else { return false }
        var inside = false
        var j = polygon.count - 1
        for i in polygon.indices {
            let a = polygon[i], b = polygon[j]
            if (a.y > point.y) != (b.y > point.y),
               point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x {
                inside.toggle()
            }
            j = i
        }
        return inside
    }

    /// A scanned wall that runs parallel to and within ~0.3m of an outline
    /// edge is the boundary wall itself re-reported (corner overshoot, or a
    /// shallow bay the beautified floor polygon straightened) — not a
    /// partition. Perpendicular distance is measured to the edge's infinite
    /// line so overshoot past a corner still reads as "on the wall".
    static func isBoundaryDuplicate(_ start: SIMD2<Double>, _ end: SIMD2<Double>,
                                    outline: [SIMD2<Double>]) -> Bool {
        let mid = (start + end) / 2
        let span = end - start
        let spanLength = simd_length(span)
        guard spanLength > 1e-9 else { return true }
        let unit = span / spanLength

        var nearestEdge: Int?
        var nearestDistance = Double.infinity
        for i in outline.indices {
            let a = outline[i]
            let b = outline[(i + 1) % outline.count]
            let ab = b - a
            let lengthSquared = simd_length_squared(ab)
            guard lengthSquared > 1e-12 else { continue }
            let t = max(0, min(1, simd_dot(mid - a, ab) / lengthSquared))
            let distance = simd_distance(mid, a + ab * t)
            if distance < nearestDistance {
                nearestDistance = distance
                nearestEdge = i
            }
        }
        guard let i = nearestEdge else { return false }
        let a = outline[i]
        let b = outline[(i + 1) % outline.count]
        let ab = b - a
        let edgeLength = simd_length(ab)
        guard edgeLength > 1e-9 else { return false }
        let edgeUnit = ab / edgeLength
        guard abs(simd_dot(unit, edgeUnit)) >= cos(10 * .pi / 180) else { return false }
        func lineDistance(_ p: SIMD2<Double>) -> Double {
            abs((p.x - a.x) * edgeUnit.y - (p.y - a.y) * edgeUnit.x)
        }
        guard lineDistance(start) < 0.3, lineDistance(end) < 0.3 else { return false }
        let s0 = simd_dot(start - a, edgeUnit)
        let s1 = simd_dot(end - a, edgeUnit)
        return max(s0, s1) > -0.5 && min(s0, s1) < edgeLength + 0.5
    }

    // MARK: - Outline polish + validation gates (shared by every path)

    /// Dedup, collinear-merge, winding-normalize, and gate an ordered ring;
    /// filter interior-wall candidates against the final outline.
    /// `removableCorner[i] == false` protects partition-junction corners from
    /// the collinear merge; nil means every corner is eligible.
    static func finishOutline(points rawPoints: [SIMD2<Double>],
                              removableCorner: [Bool]?,
                              interiorCandidates: [(SIMD2<Double>, SIMD2<Double>)])
        -> (outline: [SIMD2<Double>], interiors: [(SIMD2<Double>, SIMD2<Double>)])? {

        var points = rawPoints
        var removable = removableCorner ?? Array(repeating: true, count: points.count)
        guard removable.count == points.count else { return nil }

        // Merge consecutive near-duplicate corners (cyclic), preferring to
        // keep the position of protected junction corners.
        var index = 0
        while points.count > 3 && index < points.count {
            let next = (index + 1) % points.count
            if simd_distance(points[index], points[next]) < dedupTolerance {
                if removable[next] && !removable[index] {
                    points.remove(at: next); removable.remove(at: next)
                } else if removable[index] && !removable[next] {
                    points.remove(at: index); removable.remove(at: index)
                } else {
                    points[index] = (points[index] + points[next]) / 2
                    points.remove(at: next); removable.remove(at: next)
                }
                index = 0
            } else {
                index += 1
            }
        }

        // Re-fuse walls RoomPlan split into collinear pieces: remove corners
        // that continue nearly straight through, unless a partition joins there.
        let collinearCosine = cos(collinearDegrees * .pi / 180)
        var changed = true
        while changed && points.count > 3 {
            changed = false
            for k in points.indices {
                guard removable[k] else { continue }
                let previous = points[(k + points.count - 1) % points.count]
                let next = points[(k + 1) % points.count]
                let d1 = points[k] - previous
                let d2 = next - points[k]
                let l1 = simd_length(d1), l2 = simd_length(d2)
                guard l1 >= 0.3, l2 >= 0.3 else { continue }
                if simd_dot(d1, d2) / (l1 * l2) > collinearCosine {
                    points.remove(at: k); removable.remove(at: k)
                    changed = true
                    break
                }
            }
        }

        guard points.count >= 3 else { return nil }
        let area = signedArea(points)
        guard abs(area) >= minRoomArea else { return nil }
        if area < 0 { points.reverse() }
        guard isSimplePolygon(points) else { return nil }

        // Interior walls: drop noise stubs, double-reported boundary walls,
        // and fragments scanned through doorways into other spaces; snap
        // loose ends onto the corners they abut; dedupe.
        var interiors: [(SIMD2<Double>, SIMD2<Double>)] = []
        for candidate in interiorCandidates {
            guard simd_distance(candidate.0, candidate.1) >= minInteriorLength else { continue }
            if isBoundaryDuplicate(candidate.0, candidate.1, outline: points) { continue }
            let mid = (candidate.0 + candidate.1) / 2
            guard containsPoint(points, mid) || distanceToPolygon(mid, points) < 0.3 else { continue }
            var start = candidate.0, end = candidate.1
            if let corner = points.min(by: { simd_distance($0, start) < simd_distance($1, start) }),
               simd_distance(corner, start) < 0.2 { start = corner }
            if let corner = points.min(by: { simd_distance($0, end) < simd_distance($1, end) }),
               simd_distance(corner, end) < 0.2 { end = corner }
            guard simd_distance(start, end) >= minInteriorLength else { continue }
            let duplicate = interiors.contains { existing in
                (simd_distance(existing.0, start) < 0.1 && simd_distance(existing.1, end) < 0.1) ||
                (simd_distance(existing.0, end) < 0.1 && simd_distance(existing.1, start) < 0.1)
            }
            if !duplicate { interiors.append((start, end)) }
        }
        return (points, interiors)
    }

    // MARK: - Graph reconstruction (fallback when no floor polygon exists)

    private final class UnionFind {
        private var parent: [Int]
        init(count: Int) { parent = Array(0..<count) }
        func find(_ x: Int) -> Int {
            var root = x
            while parent[root] != root { root = parent[root] }
            var current = x
            while parent[current] != root {
                let next = parent[current]
                parent[current] = root
                current = next
            }
            return root
        }
        func union(_ x: Int, _ y: Int) {
            let rootX = find(x), rootY = find(y)
            if rootX != rootY { parent[rootX] = rootY }
        }
    }

    private struct GraphEdge {
        var u: Int
        var v: Int
        var length: Double
    }

    /// Chain scanned wall segments into an outline by clustering endpoints
    /// into corner nodes and walking the outer face of the resulting graph.
    /// The relaxed round additionally welds pairs of loose ends (degree-1
    /// nodes) to bridge unwalled passage gaps that strict clustering leaves.
    static func buildOutline(from segments: [Segment], relaxed: Bool)
        -> (outline: [SIMD2<Double>], interiors: [(SIMD2<Double>, SIMD2<Double>)])? {

        guard segments.count >= 3 else { return nil }

        // Stage 1: cluster endpoints. Tolerance adapts to the shorter wall so
        // a small jamb stub cannot have its own two ends fused together.
        let unionFind = UnionFind(count: segments.count * 2)
        func endpoint(_ index: Int) -> SIMD2<Double> {
            index % 2 == 0 ? segments[index / 2].a : segments[index / 2].b
        }
        for i in 0..<segments.count {
            for j in (i + 1)..<segments.count {
                let tolerance = min(clusterTolerance,
                                    joinFraction * min(segments[i].length, segments[j].length))
                for ei in [2 * i, 2 * i + 1] {
                    for ej in [2 * j, 2 * j + 1]
                    where simd_distance(endpoint(ei), endpoint(ej)) < tolerance {
                        unionFind.union(ei, ej)
                    }
                }
            }
        }

        // Node per cluster; position is the length-weighted mean of members
        // (longer walls have steadier endpoints; computed once, order-free).
        var nodeIndexByRoot: [Int: Int] = [:]
        var nodePositions: [SIMD2<Double>] = []
        var weightSums: [Double] = []
        for e in 0..<(segments.count * 2) {
            let root = unionFind.find(e)
            let weight = max(min(segments[e / 2].length, weightCap), 0.01)
            if let n = nodeIndexByRoot[root] {
                nodePositions[n] += endpoint(e) * weight
                weightSums[n] += weight
            } else {
                nodeIndexByRoot[root] = nodePositions.count
                nodePositions.append(endpoint(e) * weight)
                weightSums.append(weight)
            }
        }
        for n in nodePositions.indices { nodePositions[n] /= weightSums[n] }

        // Stage 2: multigraph. Drop degenerate self-loops; a second wall
        // reported between the same two corners is a duplicate — keep longer.
        var edges: [GraphEdge] = []
        for (i, segment) in segments.enumerated() {
            guard let u = nodeIndexByRoot[unionFind.find(2 * i)],
                  let v = nodeIndexByRoot[unionFind.find(2 * i + 1)], u != v else { continue }
            if let existing = edges.firstIndex(where: {
                ($0.u == u && $0.v == v) || ($0.u == v && $0.v == u) }) {
                if segment.length > edges[existing].length {
                    edges[existing] = GraphEdge(u: u, v: v, length: segment.length)
                }
                continue
            }
            edges.append(GraphEdge(u: u, v: v, length: segment.length))
        }
        guard edges.count >= 3 else { return nil }

        if relaxed {
            while true {
                var degree = [Int](repeating: 0, count: nodePositions.count)
                for edge in edges { degree[edge.u] += 1; degree[edge.v] += 1 }
                var best: (a: Int, b: Int, distance: Double)?
                for a in nodePositions.indices where degree[a] == 1 {
                    for b in nodePositions.indices where b > a && degree[b] == 1 {
                        let d = simd_distance(nodePositions[a], nodePositions[b])
                        if d < danglingWeld, d < (best?.distance ?? .infinity) {
                            best = (a, b, d)
                        }
                    }
                }
                guard let weld = best else { break }
                nodePositions[weld.a] = (nodePositions[weld.a] + nodePositions[weld.b]) / 2
                for k in edges.indices {
                    if edges[k].u == weld.b { edges[k].u = weld.a }
                    if edges[k].v == weld.b { edges[k].v = weld.a }
                }
                edges.removeAll { $0.u == $0.v }
            }
            guard edges.count >= 3 else { return nil }
        }

        // Junction corners (partitions meeting the outline) are protected
        // from the collinear merge later; degree is over the full graph.
        var fullDegree = [Int](repeating: 0, count: nodePositions.count)
        for edge in edges { fullDegree[edge.u] += 1; fullDegree[edge.v] += 1 }

        // Stage 3: split the graph into connected components. The room is
        // the component with the greatest total wall length — a stray
        // fragment scanned through a doorway can sit further west than the
        // room, but it can never out-measure it. Try components in rank
        // order so a candidate that fails the gates doesn't sink the scan.
        var adjacency = [[Int]](repeating: [], count: nodePositions.count)
        for (k, edge) in edges.enumerated() {
            adjacency[edge.u].append(k)
            adjacency[edge.v].append(k)
        }
        var component = [Int](repeating: -1, count: nodePositions.count)
        var componentCount = 0
        for start in nodePositions.indices
        where component[start] == -1 && !adjacency[start].isEmpty {
            var stack = [start]
            component[start] = componentCount
            while let n = stack.popLast() {
                for k in adjacency[n] {
                    let other = edges[k].u == n ? edges[k].v : edges[k].u
                    if component[other] == -1 {
                        component[other] = componentCount
                        stack.append(other)
                    }
                }
            }
            componentCount += 1
        }
        var edgesByComponent = [[Int]](repeating: [], count: componentCount)
        for (k, edge) in edges.enumerated() {
            edgesByComponent[component[edge.u]].append(k)
        }
        let rankedComponents = (0..<componentCount).sorted { lhs, rhs in
            let lhsLength = edgesByComponent[lhs].reduce(0.0) { $0 + edges[$1].length }
            let rhsLength = edgesByComponent[rhs].reduce(0.0) { $0 + edges[$1].length }
            return lhsLength > rhsLength
        }

        for outlineComponent in rankedComponents {
            if let result = outlineAttempt(component: outlineComponent,
                                           componentOf: component,
                                           edges: edges,
                                           nodePositions: nodePositions,
                                           fullDegree: fullDegree) {
                return result
            }
        }
        return nil
    }

    /// Attempt to extract the room outline from one connected component;
    /// every edge outside it becomes an interior-wall candidate.
    private static func outlineAttempt(component outlineComponent: Int,
                                       componentOf: [Int],
                                       edges: [GraphEdge],
                                       nodePositions: [SIMD2<Double>],
                                       fullDegree: [Int])
        -> (outline: [SIMD2<Double>], interiors: [(SIMD2<Double>, SIMD2<Double>)])? {

        var interiorPairs: [(SIMD2<Double>, SIMD2<Double>)] = []
        var active = [Bool](repeating: false, count: edges.count)
        var componentEdgeIndices: [Int] = []
        for (k, edge) in edges.enumerated() {
            if componentOf[edge.u] == outlineComponent {
                active[k] = true
                componentEdgeIndices.append(k)
            } else {
                interiorPairs.append((nodePositions[edge.u], nodePositions[edge.v]))
            }
        }
        guard !componentEdgeIndices.isEmpty else { return nil }

        // Prune dangling chains (degree-1 nodes) down to the 2-core; pruned
        // edges are partition candidates, not outline walls.
        var prunedPairs: [(SIMD2<Double>, SIMD2<Double>)] = []
        while true {
            var degree = [Int](repeating: 0, count: nodePositions.count)
            for (k, edge) in edges.enumerated() where active[k] {
                degree[edge.u] += 1
                degree[edge.v] += 1
            }
            var pruned = false
            for (k, edge) in edges.enumerated() where active[k] {
                if degree[edge.u] == 1 || degree[edge.v] == 1 {
                    active[k] = false
                    prunedPairs.append((nodePositions[edge.u], nodePositions[edge.v]))
                    pruned = true
                }
            }
            if !pruned { break }
        }
        let coreEdgeIndices = edges.indices.filter { active[$0] }

        if coreEdgeIndices.isEmpty {
            // The component is a tree (a wall went unscanned): take its
            // length-weighted diameter path and close the gap if modest.
            return treeOutline(nodePositions: nodePositions, edges: edges,
                               componentEdgeIndices: componentEdgeIndices,
                               fullDegree: fullDegree, interiorPairs: interiorPairs)
        }
        interiorPairs.append(contentsOf: prunedPairs)

        // Stage 4: outer-face walk. From the min-(x,z) core node take the
        // lowest-angle edge, then repeatedly take the first edge
        // counterclockwise after the back-edge — a topological rule that
        // traces the outer boundary regardless of junction geometry.
        struct Directed {
            var to: Int
            var edgeIndex: Int
            var angle: Double
        }
        var incident = [[Directed]](repeating: [], count: nodePositions.count)
        for k in coreEdgeIndices {
            let edge = edges[k]
            let d = nodePositions[edge.v] - nodePositions[edge.u]
            incident[edge.u].append(Directed(to: edge.v, edgeIndex: k, angle: atan2(d.y, d.x)))
            incident[edge.v].append(Directed(to: edge.u, edgeIndex: k, angle: atan2(-d.y, -d.x)))
        }
        var startNode = -1
        for n in nodePositions.indices where !incident[n].isEmpty {
            if startNode == -1 { startNode = n; continue }
            let p = nodePositions[n], q = nodePositions[startNode]
            if p.x < q.x || (p.x == q.x && p.y < q.y) { startNode = n }
        }
        guard startNode >= 0,
              let firstEdge = incident[startNode].min(by: { $0.angle < $1.angle })
        else { return nil }

        var walk: [Int] = []
        var usedEdges: Set<Int> = []
        var from = startNode
        var current = firstEdge
        var steps = 0
        while true {
            walk.append(from)
            usedEdges.insert(current.edgeIndex)
            let arrival = current.to
            let back = nodePositions[from] - nodePositions[arrival]
            let backAngle = atan2(back.y, back.x)
            var next: Directed?
            var bestTurn = Double.infinity
            for candidate in incident[arrival] where candidate.edgeIndex != current.edgeIndex {
                var turn = candidate.angle - backAngle
                while turn <= 0 { turn += 2 * .pi }
                if turn < bestTurn { bestTurn = turn; next = candidate }
            }
            if next == nil {
                next = incident[arrival].first { $0.edgeIndex == current.edgeIndex }
            }
            guard let chosen = next else { return nil }
            from = arrival
            current = chosen
            steps += 1
            if steps > 4 * coreEdgeIndices.count + 8 { return nil }
            if from == startNode && current.edgeIndex == firstEdge.edgeIndex
                && current.to == firstEdge.to { break }
        }
        for k in coreEdgeIndices where !usedEdges.contains(k) {
            interiorPairs.append((nodePositions[edges[k].u], nodePositions[edges[k].v]))
        }

        // Stage 5: a bridge or spike makes a node repeat in the walk — keep
        // the larger sub-loop, demote the smaller one to interior candidates
        // (including the ring-closing edge of a discarded closed loop).
        var loop = walk
        while true {
            var firstIndexByNode: [Int: Int] = [:]
            var duplicate: (Int, Int)?
            for (idx, node) in loop.enumerated() {
                if let first = firstIndexByNode[node] { duplicate = (first, idx); break }
                firstIndexByNode[node] = idx
            }
            guard let (i, j) = duplicate else { break }
            let loopA = Array(loop[i..<j])
            let loopB = Array(loop[j...]) + Array(loop[..<i])
            let areaA = abs(signedArea(loopA.map { nodePositions[$0] }))
            let areaB = abs(signedArea(loopB.map { nodePositions[$0] }))
            let kept = areaA >= areaB ? loopA : loopB
            let discarded = areaA >= areaB ? loopB : loopA
            if discarded.count >= 2 {
                for t in 0..<(discarded.count - 1) where discarded[t] != discarded[t + 1] {
                    interiorPairs.append((nodePositions[discarded[t]],
                                          nodePositions[discarded[t + 1]]))
                }
                if discarded.count >= 3, let last = discarded.last,
                   let first = discarded.first, last != first {
                    interiorPairs.append((nodePositions[last], nodePositions[first]))
                }
            }
            loop = kept
            if loop.count < 3 { return nil }
        }

        return finishOutline(points: loop.map { nodePositions[$0] },
                             removableCorner: loop.map { fullDegree[$0] == 2 },
                             interiorCandidates: interiorPairs)
    }

    private static func treeOutline(nodePositions: [SIMD2<Double>],
                                    edges: [GraphEdge],
                                    componentEdgeIndices: [Int],
                                    fullDegree: [Int],
                                    interiorPairs: [(SIMD2<Double>, SIMD2<Double>)])
        -> (outline: [SIMD2<Double>], interiors: [(SIMD2<Double>, SIMD2<Double>)])? {

        var adjacency: [Int: [(edge: Int, other: Int)]] = [:]
        for k in componentEdgeIndices {
            adjacency[edges[k].u, default: []].append((k, edges[k].v))
            adjacency[edges[k].v, default: []].append((k, edges[k].u))
        }
        guard let seed = adjacency.keys.min() else { return nil }

        func farthest(from start: Int) -> (node: Int, parent: [Int: (node: Int, edge: Int)]) {
            var parent: [Int: (node: Int, edge: Int)] = [:]
            var distance: [Int: Double] = [start: 0]
            var stack = [start]
            var bestNode = start
            while let n = stack.popLast() {
                let d = distance[n] ?? 0
                if d > (distance[bestNode] ?? 0) { bestNode = n }
                for (edgeIndex, other) in adjacency[n] ?? [] where distance[other] == nil {
                    distance[other] = d + edges[edgeIndex].length
                    parent[other] = (n, edgeIndex)
                    stack.append(other)
                }
            }
            return (bestNode, parent)
        }

        let endA = farthest(from: seed).node
        let endB = farthest(from: endA)
        var pathNodes: [Int] = [endB.node]
        var pathEdges: Set<Int> = []
        var cursor = endB.node
        while let step = endB.parent[cursor] {
            pathEdges.insert(step.edge)
            pathNodes.append(step.node)
            cursor = step.node
        }
        guard pathNodes.count >= 3 else { return nil }

        var interiors = interiorPairs
        for k in componentEdgeIndices where !pathEdges.contains(k) {
            interiors.append((nodePositions[edges[k].u], nodePositions[edges[k].v]))
        }
        let points = pathNodes.map { nodePositions[$0] }
        let chainLength = pathEdges.reduce(0.0) { $0 + edges[$1].length }
        guard let first = points.first, let last = points.last else { return nil }
        let gap = simd_distance(first, last)
        guard gap <= min(3.0, 0.35 * chainLength) else { return nil }

        return finishOutline(points: points,
                             removableCorner: pathNodes.map { fullDegree[$0] == 2 },
                             interiorCandidates: interiors)
    }
}

#if canImport(RoomPlan)
extension ScanConverter {

    private static func endpoints(_ surface: CapturedRoom.Surface) -> Segment {
        let t = surface.transform
        let center = SIMD3(Double(t.columns.3.x), Double(t.columns.3.y), Double(t.columns.3.z))
        var xAxis = SIMD3(Double(t.columns.0.x), Double(t.columns.0.y), Double(t.columns.0.z))
        let axisLength = simd_length(xAxis)
        if axisLength > 0 { xAxis /= axisLength }
        let half = Double(surface.dimensions.x) / 2
        let a = center - xAxis * half
        let b = center + xAxis * half
        return Segment(a: SIMD2(a.x, a.z), b: SIMD2(b.x, b.z))
    }

    /// RoomPlan's floor surface carries the authoritative ordered boundary
    /// polygon (iOS 17 "beautified" outline). Multiple floors can be
    /// reported for one room — take the largest by area, never sum.
    /// Floors without a polygon are skipped unless `allowRectangle`: the
    /// synthesized bounding box would silently ship a rectangle for an
    /// L-shaped room, so graph reconstruction from walls must outrank it.
    private static func floorRing(_ captured: CapturedRoom, allowRectangle: Bool)
        -> (ring: [SIMD2<Double>], floorY: Double)? {
        var best: (ring: [SIMD2<Double>], area: Double, y: Double)?
        for floor in captured.floors {
            let t = floor.transform
            var local = floor.polygonCorners
            if local.count < 3 {
                guard allowRectangle else { continue }
                let hx = floor.dimensions.x / 2
                let hy = floor.dimensions.y / 2
                local = [SIMD3(-hx, -hy, 0), SIMD3(hx, -hy, 0),
                         SIMD3(hx, hy, 0), SIMD3(-hx, hy, 0)]
            }
            var ring = local.map { corner -> SIMD2<Double> in
                let world = t * SIMD4<Float>(corner.x, corner.y, corner.z, 1)
                return SIMD2(Double(world.x), Double(world.z))
            }
            if ring.count > 3, let first = ring.first, let last = ring.last,
               simd_distance(first, last) < 0.01 {
                ring.removeLast()
            }
            guard ring.count >= 3 else { continue }
            let area = abs(signedArea(ring))
            if area > (best?.area ?? 0) {
                best = (ring, area, Double(t.columns.3.y))
            }
        }
        guard let chosen = best else { return nil }
        return (chosen.ring, chosen.y)
    }

    static func convert(_ captured: CapturedRoom) -> CornerRoom? {
        let wallSegments = captured.walls.map(endpoints).filter { $0.length >= minSegment }
        let wallPairs = wallSegments.map { ($0.a, $0.b) }

        var built: (outline: [SIMD2<Double>], interiors: [(SIMD2<Double>, SIMD2<Double>)])?
        var floorLevel: Double?

        // Gold path: the floor polygon is already the ordered outline; walls
        // that hug it are boundary duplicates, the rest become partitions.
        if let floor = floorRing(captured, allowRectangle: false) {
            built = finishOutline(points: floor.ring, removableCorner: nil,
                                  interiorCandidates: wallPairs)
            if built != nil { floorLevel = floor.floorY }
        }
        // Fallback: graph reconstruction from wall segments, strict round
        // first, then with loose-end welding across passage gaps.
        if built == nil, wallSegments.count >= 3 {
            for relaxed in [false, true] {
                if let outline = buildOutline(from: wallSegments, relaxed: relaxed) {
                    built = outline
                    break
                }
            }
        }
        // Last resort: a rectangle synthesized from the floor's bounding box
        // (only when the wall set couldn't reconstruct the true shape).
        if built == nil, let floor = floorRing(captured, allowRectangle: true) {
            built = finishOutline(points: floor.ring, removableCorner: nil,
                                  interiorCandidates: wallPairs)
            if built != nil { floorLevel = floor.floorY }
        }
        guard let result = built else { return nil }

        // Median wall height, not max: one wall running up an open stairwell
        // would otherwise set the whole room's ceiling (and window sill caps).
        let wallHeights = captured.walls.map { Double($0.dimensions.y) }.sorted()
        let ceiling = wallHeights.isEmpty ? 2.4 : wallHeights[wallHeights.count / 2]
        var room = CornerRoom(
            corners: result.outline.map { CornerRoom.Point(x: $0.x, z: $0.y) },
            ceilingHeightMeters: ceiling)
        room.interiorWalls = result.interiors.map {
            CornerRoom.InteriorWall(start: CornerRoom.Point(x: $0.0.x, z: $0.0.y),
                                    end: CornerRoom.Point(x: $0.1.x, z: $0.1.y))
        }

        // Floor level anchors window sills: the floor surface is
        // authoritative; otherwise the median wall bottom (min is fragile —
        // one wall dipping into a stairwell would shift every sill).
        let wallBottoms = captured.walls
            .map { Double($0.transform.columns.3.y) - Double($0.dimensions.y) / 2 }
            .sorted()
        let floorY = floorLevel ?? (wallBottoms.isEmpty ? 0 : wallBottoms[wallBottoms.count / 2])

        // Openings attach to whichever host — outline wall or interior
        // partition — they actually sit on: nearest by distance among
        // candidates that pass alignment, fit, and overlap gates.
        struct HostCandidate {
            var interiorID: UUID?
            var wallIndex: Int
            var a: SIMD2<Double>
            var b: SIMD2<Double>
        }
        var hosts: [HostCandidate] = []
        let cornerCount = room.corners.count
        for index in 0..<cornerCount {
            hosts.append(HostCandidate(
                interiorID: nil, wallIndex: index,
                a: SIMD2(room.corners[index].x, room.corners[index].z),
                b: SIMD2(room.corners[(index + 1) % cornerCount].x,
                         room.corners[(index + 1) % cornerCount].z)))
        }
        for wall in room.interiorWalls where wall.lengthMeters >= minInteriorLength {
            hosts.append(HostCandidate(
                interiorID: wall.id, wallIndex: 0,
                a: SIMD2(wall.start.x, wall.start.z),
                b: SIMD2(wall.end.x, wall.end.z)))
        }

        func attach(_ surface: CapturedRoom.Surface, kind: CornerRoom.Opening.Kind) {
            let segment = endpoints(surface)
            let mid = (segment.a + segment.b) / 2
            let measuredWidth = Double(surface.dimensions.x)
            let axis = segment.b - segment.a
            let axisLength = simd_length(axis)
            let direction: SIMD2<Double>? = axisLength > 0.05 ? axis / axisLength : nil

            struct Scored {
                var host: HostCandidate
                var t: Double
                var distance: Double
                var align: Double
                var length: Double
            }
            var passing: [Scored] = []
            var rescue: Scored?
            for host in hosts {
                // Windows only sit on the room boundary — never rescue one
                // onto a partition (it would also corrupt egress compliance).
                if kind == .window, host.interiorID != nil { continue }
                let ab = host.b - host.a
                let lengthSquared = simd_length_squared(ab)
                guard lengthSquared > 0.01 else { continue }
                let length = lengthSquared.squareRoot()
                // A door must fit its host: reject rather than shrink onto a stub.
                guard measuredWidth <= length + 0.3 else { continue }
                let tRaw = simd_dot(mid - host.a, ab) / lengthSquared
                let t = max(0, min(1, tRaw))
                let distance = simd_distance(mid, host.a + ab * t)
                let align = direction.map { abs(simd_dot($0, ab / length)) } ?? 1.0
                let scored = Scored(host: host, t: t, distance: distance,
                                    align: align, length: length)
                let along = tRaw * length
                let overlap = min(length, along + measuredWidth / 2)
                    - max(0, along - measuredWidth / 2)
                if distance < attachTolerance, align >= 0.8,
                   overlap >= 0.5 * min(measuredWidth, length) {
                    passing.append(scored)
                }
                // Rescue keeps a measured door from vanishing when the
                // beautified outline shifted its wall — but it must still be
                // parallel and actually overlap; scan offset degrades
                // distance, never orientation.
                if distance < attachRescueTolerance, align >= 0.8, overlap > 0,
                   distance < (rescue?.distance ?? .infinity) {
                    rescue = scored
                }
            }
            let winner = passing.min { lhs, rhs in
                let lhsBucket = (lhs.distance / 0.05).rounded()
                let rhsBucket = (rhs.distance / 0.05).rounded()
                if lhsBucket != rhsBucket { return lhsBucket < rhsBucket }
                return lhs.align > rhs.align
            } ?? rescue
            guard let best = winner else { return }

            let width = min(measuredWidth, best.length)
            let offset = min(max(best.t * best.length - width / 2, 0),
                             max(best.length - width, 0))
            var opening = CornerRoom.Opening(kind: kind, wallIndex: best.host.wallIndex,
                                             offsetMeters: offset, widthMeters: width)
            opening.interiorWallID = best.host.interiorID
            opening.heightMeters = Double(surface.dimensions.y)
            if kind == .window {
                let raw = Double(surface.transform.columns.3.y)
                    - Double(surface.dimensions.y) / 2 - floorY
                let ceilingCap = max(room.ceilingHeightMeters
                                     - Double(surface.dimensions.y) - 0.05, 0)
                opening.sillMeters = min(max(raw, 0), ceilingCap)
            }
            room.openings.append(opening)
        }

        for door in captured.doors { attach(door, kind: .door) }
        for window in captured.windows { attach(window, kind: .window) }
        for opening in captured.openings { attach(opening, kind: .opening) }

        return room
    }
}
#endif
