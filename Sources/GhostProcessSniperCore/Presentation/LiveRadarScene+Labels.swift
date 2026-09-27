import Foundation

extension LiveRadarScene {
    struct Box {
        let minX: Double
        let minY: Double
        let maxX: Double
        let maxY: Double

        func overlaps(_ other: Box) -> Bool {
            minX < other.maxX && other.minX < maxX && minY < other.maxY && other.minY < maxY
        }
    }

    /// Where a sector's name sits: outside the rim, on its diagonal.
    public static func sectorLabelPoint(_ sector: LiveRadarSector, centerX: Double, centerY: Double,
                                        radius: Double) -> (x: Double, y: Double) {
        let reach = radius + 11
        return (centerX + cos(sector.midAngle) * reach, centerY + sin(sector.midAngle) * reach)
    }

    /// Where a ring's name sits: on the 12 o'clock line, just inside the ring.
    public static func bandLabelPoint(_ level: GhostLevel, centerX: Double, centerY: Double,
                                      radius: Double) -> (x: Double, y: Double) {
        (centerX, centerY - radius * LiveRadarBands.band(level).upperBound + 7)
    }

    static func bandBox(_ level: GhostLevel, geometry: Geometry) -> Box {
        let point = bandLabelPoint(level, centerX: geometry.centerX, centerY: geometry.centerY, radius: geometry.radius)
        let half = Double(LiveRadarBands.name(level).count) * 5.6 / 2 + 3
        return Box(minX: point.x - half, minY: point.y - 5, maxX: point.x + half, maxY: point.y + 5)
    }

    static func sectorBox(_ sector: LiveRadarSector, geometry: Geometry) -> Box {
        let point = sectorLabelPoint(sector, centerX: geometry.centerX, centerY: geometry.centerY, radius: geometry.radius)
        let half = Double(sector.label.count) * labelFontWidth / 2 + 3
        return Box(minX: point.x - half, minY: point.y - labelHeight / 2, maxX: point.x + half, maxY: point.y + labelHeight / 2)
    }

    public static func trend(of input: LiveRadarInput, history: LiveRadarHistory) -> LiveRadarTrend {
        trend(input, origin: history.origin(of: input.id))
    }

    /// Worst first: by level, then closing in, then memory; ties keep their order.
    public static func ranked(_ inputs: [LiveRadarInput], history: LiveRadarHistory) -> [LiveRadarInput] {
        rankOrder(inputs, closing: inputs.map { trend(of: $0, history: history) == .closing }).map { inputs[$0] }
    }

    static func rankOrder(_ inputs: [LiveRadarInput], closing: [Bool]) -> [Int] {
        inputs.indices.sorted { first, second in
            let (a, b) = (inputs[first], inputs[second])
            if a.level != b.level { return a.level > b.level }
            if closing[first] != closing[second] { return closing[first] }
            if a.memoryBytes != b.memoryBytes { return a.memoryBytes > b.memoryBytes }
            return first < second
        }
    }

    static func truncated(_ title: String) -> String {
        title.count > labelCharacters ? String(title.prefix(labelCharacters - 1)) + "\u{2026}" : title
    }

    /// Names what matters: everything elevated or closing in, then the
    /// biggest while few are named. Each goes on the side facing out, then
    /// the other side, above or below, and never over another name, blip,
    /// ring or sector name. What matters and found no room nearby is named
    /// in the margin beside the rim, with a line to its blip.
    static func placeLabels(_ inputs: [LiveRadarInput], bearings: [Double], geometry: Geometry, width: Double,
                            height: Double, history: LiveRadarHistory) -> [String: LiveRadarLabel] {
        let points = inputs.indices.map { geometry.point(distance: inputs[$0].distance, bearing: bearings[$0]) }
        let sizes = inputs.map { diameter(for: $0.memoryBytes) }
        let closing = inputs.map { trend(of: $0, history: history) == .closing }
        let order = rankOrder(inputs, closing: closing)
        let dots = inputs.indices.map { index in
            let half = sizes[index] / 2 + 1
            return Box(minX: points[index].x - half, minY: points[index].y - half,
                       maxX: points[index].x + half, maxY: points[index].y + half)
        }
        var taken = LiveRadarSector.allCases.map { sectorBox($0, geometry: geometry) } +
            GhostLevel.allCases.map { bandBox($0, geometry: geometry) }
        var labels: [String: LiveRadarLabel] = [:]
        for index in order where labels.count < maximumLabels {
            let input = inputs[index]
            let matters = input.level >= .watch || closing[index]
            guard matters || labels.count < 5 else { continue }
            let text = truncated(input.title)
            let textWidth = Double(text.count) * labelFontWidth + 2
            let gap = sizes[index] / 2 + 4
            let point = points[index]
            let outward = point.x >= geometry.centerX
            let beside = [outward, !outward].map { toRight in
                toRight ? LiveRadarLabel(text: text, anchor: .start, x: point.x + gap, y: point.y)
                    : LiveRadarLabel(text: text, anchor: .end, x: point.x - gap, y: point.y)
            }
            let vertical = sizes[index] / 2 + 2 + labelHeight / 2
            let stacked = [-1.0, 1.0].map { LiveRadarLabel(text: text, anchor: .middle, x: point.x, y: point.y + $0 * vertical) }
            let diagonal = [-1.0, 1.0].flatMap { above in
                [LiveRadarLabel(text: text, anchor: .start, x: point.x + 2, y: point.y + above * vertical),
                 LiveRadarLabel(text: text, anchor: .end, x: point.x - 2, y: point.y + above * vertical)]
            }
            let rimX = geometry.radius + 16
            let margin = [0, -1, 1, -2, 2, -3, 3, -4, 4, -5, 5].map { step -> LiveRadarLabel in
                var label = outward
                    ? LiveRadarLabel(text: text, anchor: .start, x: geometry.centerX + rimX, y: point.y + Double(step) * (labelHeight + 1))
                    : LiveRadarLabel(text: text, anchor: .end, x: geometry.centerX - rimX, y: point.y + Double(step) * (labelHeight + 1))
                label.hasLeader = true
                return label
            }
            for label in beside + stacked + diagonal + (matters ? margin : []) {
                let minX = label.minX(width: textWidth)
                let box = Box(minX: minX, minY: label.y - labelHeight / 2, maxX: minX + textWidth, maxY: label.y + labelHeight / 2)
                guard box.minX >= 0, box.maxX <= width, box.minY >= 0, box.maxY <= height,
                      !taken.contains(where: box.overlaps),
                      !dots.indices.contains(where: { $0 != index && dots[$0].overlaps(box) })
                else { continue }
                taken.append(box)
                labels[input.id] = label
                break
            }
        }
        return labels
    }
}

/// Where each family sat on the scope over the last few minutes, so a blip
/// can show where it came from. The session keeps it while the console is
/// open; a family gone for the whole window is forgotten.
public struct LiveRadarHistory: Equatable, Sendable {
    struct Mark: Equatable, Sendable {
        let at: Date
        let distance: Double
    }

    public static let window: TimeInterval = 300
    /// A family that does not move still gets a mark this often, so the
    /// window's start is never older than the window.
    static let heartbeat: TimeInterval = 30
    static let capacity = 24

    private var marks: [String: [Mark]] = [:]

    public init() {}

    /// Returns whether anything changed, so callers publish only changes.
    @discardableResult
    public mutating func record(_ inputs: [LiveRadarInput], at now: Date) -> Bool {
        let cutoff = now.addingTimeInterval(-Self.window)
        var changed = false
        var present = Set<String>()
        for input in inputs {
            present.insert(input.id)
            var list = marks[input.id, default: []]
            let before = list
            let distance = input.distance
            if list.last.map({ abs($0.distance - distance) >= 0.004 || now.timeIntervalSince($0.at) >= Self.heartbeat }) ?? true {
                list.append(Mark(at: now, distance: distance))
            }
            list.removeAll { $0.at < cutoff }
            if list.count > Self.capacity { list.removeFirst(list.count - Self.capacity) }
            if list != before {
                marks[input.id] = list
                changed = true
            }
        }
        let expired = marks.filter { !present.contains($0.key) && ($0.value.last?.at ?? .distantPast) < cutoff }.map(\.key)
        for id in expired { marks[id] = nil }
        return changed || !expired.isEmpty
    }

    /// Where the family sat at the start of the window, as a fraction of the radius.
    public func origin(of id: String) -> Double? {
        marks[id]?.first?.distance
    }
}
