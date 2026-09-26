import XCTest
@testable import GhostProcessSniperCore

final class ProcessSearchEngineTests: XCTestCase {
    func testFoldingIgnoresCaseAccentsAndFindsWordStarts() {
        let folded = FoldedText("Café ÉLAN")
        XCTAssertEqual(String(decoding: folded.bytes, as: UTF8.self), "cafe elan")
        XCTAssertEqual(FoldedText("GoogleChromeHelper").wordStarts, [0, 6, 12])
    }

    func testParserUnderstandsTermsFiltersAndPhrases() {
        let query = ProcessSearchQuery("chrome -helper cpu>20 mem>1.5gb is:leak pid:12,34 port:3000 name:\"google chrome\" \"exact phrase\"")
        XCTAssertEqual(query.terms.map(\.text), ["chrome", "helper", "google chrome", "exact phrase"])
        XCTAssertTrue(query.terms[1].isNegated)
        XCTAssertEqual(query.terms[2].field, .name)
        XCTAssertEqual(query.metrics.map(\.metric), [.cpu, .memory])
        XCTAssertEqual(query.metrics[1].value, 1.5 * 1_073_741_824)
        XCTAssertEqual(query.flags, [.init(flag: .leaking, isNegated: false)])
        XCTAssertEqual(query.pids.first?.values, [12, 34])
        XCTAssertEqual(query.ports.first?.values, [3000])
    }

    func testHalfTypedFiltersNeverBlankTheList() {
        let query = ProcessSearchQuery("cpu > 5 mem:500 cpu> mem: is: pid:")
        XCTAssertTrue(query.terms.isEmpty)
        XCTAssertTrue(query.flags.isEmpty)
        XCTAssertEqual(query.metrics.count, 2)
        XCTAssertEqual(query.metrics[1].value, 500 * 1_048_576, "memory without a unit means MB")
        XCTAssertEqual(ProcessSearchQuery("is:zzz").tokens.first?.kind, .ignored)
    }

    func testCurlyQuotesUrlsAndNegatedPhrases() {
        let query = ProcessSearchQuery("\u{201c}google chrome\u{201d} http://localhost:3000 -\"code helper\"")
        XCTAssertEqual(query.terms.map(\.text), ["google chrome", "http://localhost:3000", "code helper"])
        XCTAssertTrue(query.terms[2].isNegated)
    }

    func testHelpersCommandsPortsAndPidsFindTheirFamily() {
        XCTAssertEqual(names("node").families, ["npm"], "a helper's name finds its family")
        XCTAssertEqual(names("vite").families, ["npm"], "a helper's command line finds its family")
        XCTAssertEqual(names("5173").families, ["npm"], "a listening port finds its family")
        XCTAssertEqual(names("201").families, ["npm"], "a helper PID finds its family")
        XCTAssertEqual(names("renderer chrome").families, ["Google Chrome"], "words match in any order")
        XCTAssertEqual(names("safari").processes, ["Safari"], "untracked processes are searchable")
    }

    func testNegationAndRankingAvoidNoise() {
        XCTAssertTrue(names("chrome -gpu").families.isEmpty)
        XCTAssertEqual(names("code").families.first, "Code Helper", "a prefix match outranks a substring")
        XCTAssertFalse(names("code").families.contains("com.docker.backend"), "no fuzzy guesses while exact matches exist")
        XCTAssertFalse(names("node").families.contains("Code Helper"), "typos keep their first letter")
    }

    func testApproximateMatchesOnlyWhenNothingMatchesExactly() {
        let acronym = names("vsc")
        XCTAssertEqual(acronym.families.first, "Visual Studio Code")
        XCTAssertTrue(acronym.approximate)
        let typo = names("crhome")
        XCTAssertEqual(typo.families, ["Google Chrome"])
        XCTAssertTrue(typo.approximate)
        XCTAssertTrue(names("spotfy").families.isEmpty)
    }

    func testMeasurementsAndFlagsFilter() {
        XCTAssertEqual(names("cpu>20").families, ["Google Chrome"])
        XCTAssertEqual(names("mem>1gb").families, ["Google Chrome"])
        XCTAssertEqual(names("leak>1").families, ["npm"])
        XCTAssertTrue(names("leak>1").processes.isEmpty, "growth is only known for tracked families")
        XCTAssertEqual(names("is:mine").processes, ["Finder"])
        XCTAssertEqual(names("kind:electron").families, ["Code Helper"])
        XCTAssertEqual(names("path:applications").processes, ["Safari"])
    }

    func testReasonsAndHighlightsExplainEachMatch() {
        let vite = names("vite").outcome.families.values.first?.reason ?? ""
        XCTAssertTrue(vite.contains("node (PID 201)") && vite.contains("vite"), vite)
        XCTAssertEqual(names("node").outcome.families.values.first?.reason, "Includes node \u{00b7} PID 201")
        XCTAssertEqual(names("5173").outcome.families.values.first?.reason, "node listens on port 5173")
        XCTAssertEqual(names("chrome").outcome.families.values.first?.nameHighlights, [7..<13])
        XCTAssertEqual(names("vsc").outcome.families.values.first?.nameHighlights, [0..<1, 7..<8, 14..<15])
    }

    func testSnippetsKeepContextAroundTheMatch() {
        for text in [
            String(repeating: "x", count: 200) + " --port 9999 " + String(repeating: "y", count: 200),
            String(repeating: "\u{00e9}", count: 120) + " --port 9999 " + String(repeating: "\u{00fc}", count: 120)
        ] {
            let offsets = TextMatcher.literalMatch(FoldedText("9999").bytes, in: FoldedText(text))?.byteOffsets ?? []
            let snippet = ProcessSearchEngine.snippet(text, around: offsets)
            XCTAssertTrue(snippet.hasPrefix("\u{2026}") && snippet.hasSuffix("\u{2026}") && snippet.contains("--port 9999"), snippet)
        }
        XCTAssertEqual(ProcessSearchEngine.snippet("short", around: [0]), "short")
    }

    func testPlainTextMatchingForIncidentsAndDuplicates() {
        XCTAssertTrue(ProcessSearchQuery("slack -helper").matchesText(["Slack"]))
        XCTAssertFalse(ProcessSearchQuery("slack -helper").matchesText(["Slack Helper"]))
        XCTAssertTrue(ProcessSearchQuery("helper slack").matchesText(["Slack Helper (Renderer)"]))
    }

    // MARK: - Fixtures

    private let families = [
        subject(process(100, "Google Chrome", path: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"),
                helpers: [process(101, "Google Chrome Helper (Renderer)", command: "Google Chrome Helper (Renderer) --type=renderer"),
                          process(102, "Google Chrome Helper (GPU)")],
                kind: "Heavy process", cpu: 30, memory: 2e9),
        subject(process(200, "npm", command: "npm run dev"),
                helpers: [process(201, "node", command: "node /Users/me/app/node_modules/.bin/vite --port 5173", ports: [5173])],
                kind: "Node server", cpu: 5, memory: 3e8, leak: 3),
        subject(process(300, "Code Helper", command: "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper.app --type=utility"),
                kind: "Electron app"),
        subject(process(310, "Visual Studio Code")),
        subject(process(400, "com.docker.backend"), kind: "Docker helper")
    ]

    private let processes = [
        subject(process(500, "Safari", path: "/Applications/Safari.app/Contents/MacOS/Safari"), flags: [.untracked]),
        subject(process(501, "Finder"), flags: [.untracked, .mine])
    ]

    private func names(_ text: String) -> (families: [String], processes: [String], approximate: Bool, outcome: ProcessSearchOutcome) {
        let outcome = ProcessSearchEngine.search(ProcessSearchQuery(text), families: families, processes: processes)
        func ranked(_ matches: [Int: ProcessSearchMatch], _ subjects: [SearchSubject]) -> [String] {
            matches.sorted { $0.value.score != $1.value.score ? $0.value.score > $1.value.score : $0.key < $1.key }
                .map { subjects[$0.key].root.displayName }
        }
        return (ranked(outcome.families, families), ranked(outcome.processes, processes), outcome.isApproximate, outcome)
    }
}

private func process(_ pid: Int32, _ name: String, command: String = "", path: String = "", ports: [Int] = []) -> SearchableProcess {
    SearchableProcess(pid: pid, name: name, commandLine: command.isEmpty ? name : command,
                      executablePath: path, ownerName: "me", listeningPorts: ports)
}

private func subject(
    _ root: SearchableProcess,
    helpers: [SearchableProcess] = [],
    kind: String = "",
    cpu: Double = 0,
    memory: Double = 0,
    leak: Double? = nil,
    flags: Set<ProcessSearchQuery.Flag> = [.tracked]
) -> SearchSubject {
    SearchSubject(
        root: root,
        helpers: helpers,
        kindLabel: kind,
        measurements: SearchMeasurements(cpuPercent: cpu, memoryBytes: memory, gpuPercent: 0, threads: 4,
                                         leakMegabytesPerMinute: leak, children: Double(helpers.count)),
        flags: flags
    )
}
