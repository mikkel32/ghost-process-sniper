import XCTest
@testable import GhostProcessSniperCore

/// The Live Radar is read, not just watched: distance is the verdict,
/// bearing is what kind of thing it is, size is memory, and the names of
/// what matters are on the scope.
final class LiveRadarSceneTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_900_000_000)
    private let gigabyte: UInt64 = 1 << 30

    private func input(_ id: String, _ level: GhostLevel = .quiet, heat: Double? = nil, gigabytes: Double = 0.2,
                       sector: LiveRadarSector = .apps, forecast: ForecastState = .quiet) -> LiveRadarInput {
        let defaultHeat: Double = switch level {
        case .quiet: 5
        case .watch: 40
        case .hot: 65
        case .critical: 90
        }
        return LiveRadarInput(id: id, title: id, level: level, heat: heat ?? defaultHeat,
                              memoryBytes: UInt64(gigabytes * Double(gigabyte)), sector: sector, forecastState: forecast)
    }

    private func scene(_ inputs: [LiveRadarInput], history: LiveRadarHistory = LiveRadarHistory(),
                       width: Double = 340, height: Double = 300) -> LiveRadarScene {
        LiveRadarScene.build(inputs, history: history, width: width, height: height)
    }

    // MARK: - Distance is the verdict

    func testEveryLevelStaysInsideItsOwnRing() {
        for level in GhostLevel.allCases {
            for heat in [-50, 0, 29, 30, 57, 58, 79, 80, 100, 400, .nan] as [Double] {
                let distance = LiveRadarBands.distance(level: level, heat: heat)
                XCTAssertTrue(LiveRadarBands.band(level).contains(distance), "\(level) at heat \(heat): \(distance)")
            }
        }
        XCTAssertLessThan(LiveRadarBands.distance(level: .hot, heat: 75), LiveRadarBands.distance(level: .hot, heat: 60),
                          "hotter sits further in within its ring")
    }

    /// Before, distance was raw heat: a big app held at Watch with heat 100
    /// sat at the center, closer than the one family actually flagged.
    func testABigAppHeldAtWatchIsFurtherOutThanAnyHotFamily() {
        let held = LiveRadarBands.distance(level: .watch, heat: 100)
        let mildHot = LiveRadarBands.distance(level: .hot, heat: 58)
        XCTAssertGreaterThan(held, mildHot)
    }

    // MARK: - Bearing is what it is

    func testSectorsFollowWhatAFamilyIs() {
        XCTAssertEqual(LiveRadarSector.of(kind: .electronApp, path: "/Applications/Claude.app/Contents/MacOS/Claude"), .apps)
        XCTAssertEqual(LiveRadarSector.of(kind: .unknownHeavy, path: "/Applications/Spotify.app/Contents/MacOS/Spotify"), .apps)
        XCTAssertEqual(LiveRadarSector.of(kind: .unknownHeavy,
                                          path: "/System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter"),
                       .background)
        XCTAssertEqual(LiveRadarSector.of(kind: .unknownHeavy, path: "/usr/libexec/fileproviderd"), .background)
        XCTAssertEqual(LiveRadarSector.of(kind: .nodeServer, path: "/opt/homebrew/bin/node"), .services)
        XCTAssertEqual(LiveRadarSector.of(kind: .dataStore, path: "/opt/homebrew/bin/postgres"), .services)
        XCTAssertEqual(LiveRadarSector.of(kind: .languageServer, path: "/usr/local/bin/sourcekit-lsp"), .tools)
        XCTAssertEqual(LiveRadarSector.of(kind: .swiftBuild, path: "/usr/bin/swift-build"), .tools)
    }

    func testBlipsSitInTheirSectorAtTheirVerdictsDistance() {
        let inputs = LiveRadarSector.allCases.flatMap { sector in
            GhostLevel.allCases.map { input("\(sector)-\($0)", $0, sector: sector) }
        }
        let built = scene(inputs)
        XCTAssertEqual(built.contacts.count, inputs.count)
        for contact in built.contacts {
            let range = LiveRadarScene.sectorRange(contact.sector)
            XCTAssertTrue(range.contains(contact.bearing), "\(contact.id) at \(contact.bearing)")
            let reach = hypot(contact.x - built.centerX, contact.y - built.centerY) / built.radius
            XCTAssertEqual(reach, contact.distance, accuracy: 0.0001)
            XCTAssertTrue(LiveRadarBands.band(contact.level).contains(contact.distance))
        }
    }

    /// Memory and heat change a little on every scan; the scope must not
    /// animate every blip every second for it.
    func testSmallChangesDoNotMoveAnything() {
        let before = LiveRadarInput(id: "node", title: "node", level: .watch, heat: 44.1, memoryBytes: 700_000_000, sector: .services)
        let after = LiveRadarInput(id: "node", title: "node", level: .watch, heat: 44.15, memoryBytes: 700_400_000, sector: .services)
        XCTAssertEqual(scene([before]), scene([after]))
    }

    func testTheSameFamiliesAlwaysDrawTheSameScope() {
        let inputs = (0..<20).map { input("family-\($0)", $0 % 7 == 0 ? .watch : .quiet, sector: $0 % 2 == 0 ? .apps : .background) }
        XCTAssertEqual(scene(inputs), scene(inputs))
    }

    // MARK: - Readable

    /// Before, every quiet family piled onto the rim at hashed angles.
    func testCrowdedFamiliesDoNotOverlap() {
        let inputs = (0..<14).map { input("app-\($0)", gigabytes: 0.5) }
        let built = scene(inputs)
        for (index, first) in built.contacts.enumerated() {
            for second in built.contacts[(index + 1)...] {
                let apart = hypot(first.x - second.x, first.y - second.y)
                XCTAssertGreaterThanOrEqual(apart, (first.diameter + second.diameter) / 2 + 2, "\(first.id) and \(second.id)")
            }
        }
    }

    func testWhatMattersIsNamedAndNamesNeverCollide() {
        var inputs = (0..<16).map { input("quiet-\($0)", sector: LiveRadarSector.allCases[$0 % 4]) }
        inputs += [input("Spotify", .hot, gigabytes: 2.1), input("ChatGPT", .watch, gigabytes: 2.5),
                   input("Claude", .watch, gigabytes: 2.5, sector: .apps)]
        let built = scene(inputs)
        let named = built.contacts.filter { $0.label != nil }
        for name in ["Spotify", "ChatGPT", "Claude"] {
            XCTAssertNotNil(built.contacts.first { $0.id == name }?.label, "\(name) is elevated and must be named")
        }
        XCTAssertLessThanOrEqual(named.count, LiveRadarScene.maximumLabels)
        let boxes = named.compactMap { contact -> LiveRadarScene.Box? in
            guard let label = contact.label else { return nil }
            let width = Double(label.text.count) * LiveRadarScene.labelFontWidth + 2
            let minX = label.minX(width: width)
            XCTAssertGreaterThanOrEqual(minX, 0)
            XCTAssertLessThanOrEqual(minX + width, built.width)
            return LiveRadarScene.Box(minX: minX, minY: label.y - 6.5, maxX: minX + width, maxY: label.y + 6.5)
        }
        for (index, box) in boxes.enumerated() {
            XCTAssertFalse(boxes[(index + 1)...].contains(where: box.overlaps))
        }
    }

    /// Seen on real data: Claude turned Hot between Spotify and the
    /// "CRITICAL" ring name and went unnamed; a name may sit above or below.
    func testElevatedFamiliesInACrowdedQuarterAreAllNamed() {
        let names = ["Claude", "ChatGPT", "Spotify", "Slack", "Figma", "Xcode", "Safari", "Notion"]
        let inputs = names.enumerated().map { index, name in
            input(name, index.isMultiple(of: 2) ? .hot : .watch, heat: index.isMultiple(of: 2) ? 70 : 50,
                  gigabytes: 1 + Double(index) / 4)
        }
        let built = scene(inputs, width: 420, height: 320)
        let unnamed = built.contacts.filter { $0.label == nil }.map(\.id)
        XCTAssertEqual(unnamed, [], "every elevated family in a crowded quarter is named")
    }

    func testBiggerFamiliesDrawBiggerAndTheWorstDrawLast() {
        let built = scene([input("critical", .critical, gigabytes: 0.1), input("big", gigabytes: 6), input("small", gigabytes: 0.05)])
        let diameters = Dictionary(uniqueKeysWithValues: built.contacts.map { ($0.id, $0.diameter) })
        XCTAssertGreaterThan(diameters["big"] ?? 0, diameters["small"] ?? 0)
        XCTAssertEqual(built.contacts.last?.id, "critical")
    }

    func testElevatedFamiliesAreNeverCutByTheLimit() {
        let inputs = (0..<50).map { input("quiet-\($0)") } + [input("late", .hot)]
        let built = LiveRadarScene.build(inputs, width: 340, height: 300, limit: 10)
        XCTAssertEqual(built.contacts.count, 10)
        XCTAssertTrue(built.contacts.contains { $0.id == "late" })
    }

    func testTinyOrInvalidBoundsDrawNothing() {
        for (width, height) in [(1.0, 1.0), (.nan, 200), (-.infinity, 300), (60, 60)] {
            XCTAssertTrue(scene([input("a", .hot)], width: width, height: height).contacts.isEmpty)
        }
    }

    // MARK: - Where it came from

    func testMovingInLeavesATrailAndReadsAsClosing() throws {
        var history = LiveRadarHistory()
        history.record([input("node", .watch, sector: .services)], at: now)
        history.record([input("node", .hot, heat: 75, sector: .services)], at: now.addingTimeInterval(60))
        let contact = try XCTUnwrap(scene([input("node", .hot, heat: 75, sector: .services)], history: history).contacts.first)
        XCTAssertEqual(contact.trend, .closing)
        let trailX = try XCTUnwrap(contact.trailX)
        let trailY = try XCTUnwrap(contact.trailY)
        let built = scene([input("node", .hot, heat: 75, sector: .services)], history: history)
        XCTAssertGreaterThan(hypot(trailX - built.centerX, trailY - built.centerY), hypot(contact.x - built.centerX, contact.y - built.centerY),
                             "the trail starts further out, where it was")
    }

    func testEasingAndForecastsReadCorrectly() throws {
        var history = LiveRadarHistory()
        history.record([input("vm", .hot, sector: .services)], at: now)
        history.record([input("vm", .quiet, sector: .services)], at: now.addingTimeInterval(30))
        XCTAssertEqual(scene([input("vm", .quiet, sector: .services)], history: history).contacts.first?.trend, .easing)
        XCTAssertEqual(scene([input("leak", .watch, forecast: .leaking)]).contacts.first?.trend, .closing)
        let forgotten = try XCTUnwrap(scene([input("old", .watch, forecast: .stale)]).contacts.first)
        XCTAssertEqual(forgotten.trend, .steady, "forgotten is not getting worse")
        XCTAssertNil(forgotten.trailX)
    }

    /// Seen on real data: a quiet build tool drifting inside the Quiet ring
    /// read "closing in".
    func testDriftInsideTheQuietRingIsNotAMove() throws {
        var history = LiveRadarHistory()
        history.record([input("swift-driver", heat: 2, sector: .tools)], at: now)
        let drifted = input("swift-driver", heat: 20, sector: .tools)
        history.record([drifted], at: now.addingTimeInterval(60))
        let contact = try XCTUnwrap(scene([drifted], history: history).contacts.first)
        XCTAssertEqual(contact.trend, .steady)
        XCTAssertNil(contact.trailX)
    }

    /// Seen on real data: a Hot blip beside the "CRITICAL" ring name read as Critical.
    func testNoBlipCoversARingName() {
        var inputs: [LiveRadarInput] = []
        for sector in [LiveRadarSector.apps, .background] {
            for (index, heat) in stride(from: 0.0, through: 100, by: 4).enumerated() {
                let level: GhostLevel = heat >= 80 ? .critical : heat >= 58 ? .hot : heat >= 30 ? .watch : .quiet
                inputs.append(input("\(sector)-\(index)", level, heat: heat, gigabytes: Double(index % 5), sector: sector))
            }
        }
        let built = scene(inputs, width: 420, height: 320)
        let geometry = LiveRadarScene.Geometry(centerX: built.centerX, centerY: built.centerY, radius: built.radius)
        let names = GhostLevel.allCases.map { LiveRadarScene.bandBox($0, geometry: geometry) }
        for contact in built.contacts {
            let half = contact.diameter / 2
            let dot = LiveRadarScene.Box(minX: contact.x - half, minY: contact.y - half, maxX: contact.x + half, maxY: contact.y + half)
            XCTAssertFalse(names.contains(where: dot.overlaps), "\(contact.id) covers a ring name")
        }
    }

    func testHistoryForgetsAfterItsWindowAndStaysQuietWhenNothingMoves() {
        var history = LiveRadarHistory()
        XCTAssertTrue(history.record([input("a", .watch)], at: now))
        XCTAssertFalse(history.record([input("a", .watch)], at: now.addingTimeInterval(5)), "nothing moved")
        XCTAssertTrue(history.record([input("a", .hot)], at: now.addingTimeInterval(10)))
        XCTAssertEqual(history.origin(of: "a"), input("a", .watch).distance)
        // Still there, never moving: the heartbeat keeps its start inside the window.
        var later = now.addingTimeInterval(10)
        for _ in 0..<20 {
            later = later.addingTimeInterval(30)
            history.record([input("a", .hot)], at: later)
        }
        XCTAssertEqual(history.origin(of: "a"), input("a", .hot).distance)
        // Gone for the whole window: forgotten.
        XCTAssertTrue(history.record([], at: later.addingTimeInterval(LiveRadarHistory.window + 1)))
        XCTAssertNil(history.origin(of: "a"))
    }
}
