import Foundation

/// What a family is, as its bearing on the Live Radar: a quarter each,
/// clockwise from 12 o'clock, so an app never sits among build tools.
public enum LiveRadarSector: Int, CaseIterable, Sendable {
    case apps
    case services
    case tools
    case background

    public var label: String {
        switch self {
        case .apps: "Apps"
        case .services: "Servers"
        case .tools: "Tools"
        case .background: "Background"
        }
    }

    /// Screen radians, clockwise from 3 o'clock.
    public var startAngle: Double { -Double.pi / 2 + Double(rawValue) * Double.pi / 2 }
    public var midAngle: Double { startAngle + Double.pi / 4 }

    public static func of(kind: DevProcessKind, path: String) -> LiveRadarSector {
        switch kind {
        case .electronApp, .editorApp:
            .apps
        case .nodeServer, .pythonService, .containerRuntime, .localModelRunner, .javaServer, .rubyServer, .goService,
             .rustService, .bunServer, .denoServer, .phpService, .elixirService, .dotnetService, .dataStore:
            .services
        case .swiftBuild, .testRunner, .buildWatcher, .languageServer, .ideService, .simulator, .cliTool:
            .tools
        case .unknownHeavy:
            path.contains(".app/Contents/") && !SentinelCatalog.isSystemLocation(path) ? .apps : .background
        }
    }
}

/// Rings are verdicts: Critical at the center, then Hot, Watch and Quiet.
/// Within its ring a hotter family sits further in, so distance never
/// contradicts the verdict (a big app held at Watch stays in the Watch ring).
public enum LiveRadarBands {
    /// Fractions of the scope radius, center outward.
    public static func band(_ level: GhostLevel) -> ClosedRange<Double> {
        switch level {
        case .critical: 0.08...0.30
        case .hot: 0.30...0.52
        case .watch: 0.52...0.74
        case .quiet: 0.74...0.95
        }
    }

    /// The ring's name, as the scope prints it.
    public static func name(_ level: GhostLevel) -> String {
        switch level {
        case .critical: "CRITICAL"
        case .hot: "HOT"
        case .watch: "WATCH"
        case .quiet: "QUIET"
        }
    }

    /// The heat each level spans, from the heat model's thresholds.
    static func heat(_ level: GhostLevel) -> ClosedRange<Double> {
        switch level {
        case .critical: 80...100
        case .hot: 58...80
        case .watch: 30...58
        case .quiet: 0...30
        }
    }

    /// Blips keep clear of the ring lines, so none reads as between verdicts.
    static let inset = 0.025

    public static func distance(level: GhostLevel, heat: Double) -> Double {
        let band = band(level)
        let (inner, outer) = (band.lowerBound + inset, band.upperBound - inset)
        let span = self.heat(level)
        let heat = heat.isFinite ? heat : span.lowerBound
        let depth = min(1, max(0, (heat - span.lowerBound) / (span.upperBound - span.lowerBound)))
        return outer - depth * (outer - inner)
    }
}

/// Getting worse (moving in, or forecast to), easing off (moving out), or neither.
public enum LiveRadarTrend: Sendable {
    case steady
    case closing
    case easing
}

/// What the scope needs to know about one family.
public struct LiveRadarInput: Equatable, Sendable {
    public let id: String
    public let title: String
    public let level: GhostLevel
    public let heat: Double
    public let memoryBytes: UInt64
    public let sector: LiveRadarSector
    public let forecastState: ForecastState

    public init(id: String, title: String, level: GhostLevel, heat: Double, memoryBytes: UInt64,
                sector: LiveRadarSector, forecastState: ForecastState = .quiet) {
        self.id = id
        self.title = title
        self.level = level
        self.heat = heat
        self.memoryBytes = memoryBytes
        self.sector = sector
        self.forecastState = forecastState
    }

    public init(row: CompactSidebarRowModel) {
        self.init(id: row.id, title: row.title, level: row.level, heat: row.heatValue, memoryBytes: row.memoryBytes,
                  sector: row.radarSector, forecastState: row.forecastState)
    }

    /// In steps under a point: heat wavers every scan, and a blip should
    /// move (and animate) only when it visibly moves.
    var distance: Double { (LiveRadarBands.distance(level: level, heat: heat) * 250).rounded() / 250 }

    /// Forecast to get worse; a forgotten family is not getting worse.
    var isForecastToWorsen: Bool {
        [.leaking, .runaway, .critical].contains(forecastState)
    }
}

/// A name drawn beside its blip, wherever there is room.
public struct LiveRadarLabel: Equatable, Sendable {
    /// Which part of the text sits at `x`.
    public enum Anchor: Sendable {
        case start
        case end
        case middle
    }

    public let text: String
    public let anchor: Anchor
    /// The anchor's point and the text's vertical center, in the scope's points.
    public let x: Double
    public let y: Double
    /// Set in the margin beside the rim, with a line to its blip, when
    /// there was no room next to it.
    public var hasLeader = false

    /// The text's left edge, for a text `width` wide.
    public func minX(width: Double) -> Double {
        switch anchor {
        case .start: x
        case .end: x - width
        case .middle: x - width / 2
        }
    }
}

public struct LiveRadarContact: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let level: GhostLevel
    public let sector: LiveRadarSector
    /// Fraction of the radius from the center.
    public let distance: Double
    /// Screen radians, clockwise from 3 o'clock.
    public let bearing: Double
    /// The blip's center, in the scope's points.
    public let x: Double
    public let y: Double
    /// Grows with memory, so a big family reads big.
    public let diameter: Double
    public let trend: LiveRadarTrend
    /// Where it was a few minutes ago, in the scope's points, when it has moved.
    public let trailX: Double?
    public let trailY: Double?
    public let label: LiveRadarLabel?
}

public struct LiveRadarScene: Equatable, Sendable {
    public let width: Double
    public let height: Double
    public let centerX: Double
    public let centerY: Double
    public let radius: Double
    /// Drawn in this order: quiet first, so the worst sit on top.
    public let contacts: [LiveRadarContact]

    public static let empty = LiveRadarScene(width: 0, height: 0, centerX: 0, centerY: 0, radius: 0, contacts: [])

    /// Room outside the rim for ticks and sector names.
    static let rimMargin = 20.0
    static let labelFontWidth = 5.9
    static let labelHeight = 13.0
    static let maximumLabels = 8
    static let labelCharacters = 18

    /// Plots at most `limit` families: everything elevated or forecast to
    /// worsen, then the rest in the order given (riskiest first).
    public static func build(_ inputs: [LiveRadarInput], history: LiveRadarHistory = LiveRadarHistory(),
                             width: Double, height: Double, limit: Int = 40) -> LiveRadarScene {
        let width = width.isFinite ? max(0, width) : 0
        let height = height.isFinite ? max(0, height) : 0
        let radius = max(0, min(width, height) / 2 - rimMargin)
        guard radius > 24 else {
            return LiveRadarScene(width: width, height: height, centerX: width / 2, centerY: height / 2, radius: radius, contacts: [])
        }
        let urgent = inputs.filter { $0.level >= .watch || $0.forecastState >= .warming }
        let urgentIDs = Set(urgent.map(\.id))
        let plotted = (urgent + inputs.filter { !urgentIDs.contains($0.id) }).prefix(max(0, limit))
        let geometry = Geometry(centerX: width / 2, centerY: height / 2, radius: radius)
        let bearings = spread(Array(plotted), geometry: geometry)
        let labels = placeLabels(Array(plotted), bearings: bearings, geometry: geometry, width: width, height: height,
                                 history: history)

        let contacts = plotted.enumerated().map { index, input in
            let bearing = bearings[index]
            let point = geometry.point(distance: input.distance, bearing: bearing)
            let origin = history.origin(of: input.id)
            let trend = trend(input, origin: origin)
            // A streak only for a move that means something, from where it began.
            let trail = origin.flatMap { trend != .steady && abs($0 - input.distance) >= 0.03
                ? geometry.point(distance: $0, bearing: bearing) : nil }
            return LiveRadarContact(
                id: input.id, title: input.title, level: input.level, sector: input.sector, distance: input.distance,
                bearing: bearing, x: point.x, y: point.y, diameter: diameter(for: input.memoryBytes),
                trend: trend, trailX: trail?.x, trailY: trail?.y, label: labels[input.id])
        }
        // Stable within a level: blips do not swap drawing order every refresh.
        let ordered = contacts.enumerated().sorted {
            $0.element.level == $1.element.level ? $0.offset > $1.offset : $0.element.level < $1.element.level
        }.map(\.element)
        return LiveRadarScene(width: width, height: height, centerX: width / 2, centerY: height / 2, radius: radius,
                              contacts: ordered)
    }

    static func trend(_ input: LiveRadarInput, origin: Double?) -> LiveRadarTrend {
        if input.isForecastToWorsen { return .closing }
        guard let origin else { return .steady }
        // Drifting within the Quiet ring is noise: closing in counts from Watch.
        if input.level >= .watch, origin - input.distance >= 0.03 { return .closing }
        // Easing off is leaving a worse ring behind.
        if origin < LiveRadarBands.band(input.level).lowerBound { return .easing }
        return .steady
    }

    /// 5 pt for a small process, 14 pt at 8 GB and up, growing with the
    /// square root so the extra area tracks the memory.
    static func diameter(for bytes: UInt64) -> Double {
        let gigabytes = Double(bytes) / 1_073_741_824
        return ((5 + 9 * min(1, (gigabytes / 8).squareRoot())) * 2).rounded() / 2
    }

    struct Geometry {
        let centerX: Double
        let centerY: Double
        let radius: Double

        func point(distance: Double, bearing: Double) -> (x: Double, y: Double) {
            (centerX + cos(bearing) * distance * radius, centerY + sin(bearing) * distance * radius)
        }
    }

    // MARK: - Bearings

    /// FNV-1a: the same across launches, unlike Swift's seeded hashing, so a
    /// family keeps its bearing within its sector.
    static func unitHash(_ key: String) -> Double {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in key.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return Double(hash % 10_000) / 10_000
    }

    /// Keeps blips off the quarter lines, where the rings are named.
    static let sectorMargin = 0.1

    static func sectorRange(_ sector: LiveRadarSector) -> ClosedRange<Double> {
        (sector.startAngle + sectorMargin)...(sector.startAngle + Double.pi / 2 - sectorMargin)
    }

    /// Each family's hashed bearing within its sector, then nudged sideways
    /// until no two blips overlap: only the bearing moves, never the distance.
    static func spread(_ inputs: [LiveRadarInput], geometry: Geometry) -> [Double] {
        var bearings = inputs.map { input in
            let range = sectorRange(input.sector)
            return range.lowerBound + unitHash(input.id) * (range.upperBound - range.lowerBound)
        }
        let sizes = inputs.map { diameter(for: $0.memoryBytes) }
        let names = GhostLevel.allCases.map { bandBox($0, geometry: geometry) }
        for _ in 0..<32 {
            var moved = false
            // Ring names on the 12 o'clock line are fixed: a blip over one
            // steps sideways, away from the line.
            for index in inputs.indices {
                let point = geometry.point(distance: inputs[index].distance, bearing: bearings[index])
                // Clear by a gap, so a blip never reads as the name's.
                let half = sizes[index] / 2 + 8
                let dot = Box(minX: point.x - half, minY: point.y - half, maxX: point.x + half, maxY: point.y + half)
                guard let name = names.first(where: dot.overlaps) else { continue }
                let clearance = point.x >= geometry.centerX ? name.maxX - dot.minX : dot.maxX - name.minX
                let arm = max(12, geometry.radius * inputs[index].distance)
                let step = (clearance / arm + 0.01) * (point.x >= geometry.centerX ? 1 : -1)
                bearings[index] = clamp(bearings[index] + step, to: sectorRange(inputs[index].sector))
                moved = true
            }
            for first in inputs.indices {
                for second in inputs.indices where second > first {
                    let a = geometry.point(distance: inputs[first].distance, bearing: bearings[first])
                    let b = geometry.point(distance: inputs[second].distance, bearing: bearings[second])
                    let apart = hypot(a.x - b.x, a.y - b.y)
                    let needed = (sizes[first] + sizes[second]) / 2 + 3
                    guard apart < needed else { continue }
                    let arm = max(12, geometry.radius * (inputs[first].distance + inputs[second].distance) / 2)
                    let step = (needed - apart) / arm / 2 + 0.002
                    let (low, high) = bearings[first] <= bearings[second] ? (first, second) : (second, first)
                    bearings[low] = clamp(bearings[low] - step, to: sectorRange(inputs[low].sector))
                    bearings[high] = clamp(bearings[high] + step, to: sectorRange(inputs[high].sector))
                    moved = true
                }
            }
            if !moved { break }
        }
        return bearings
    }

    static func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        min(range.upperBound, max(range.lowerBound, value))
    }
}
