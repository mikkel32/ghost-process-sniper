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

    func testFiltersReadNumbersTheWayTheAppPrintsThem() {
        let gibibyte = 1_073_741_824.0
        // A decimal comma, and the space the app puts before a unit ("1.5 GB", "0,5 W").
        for text in ["mem>1,5gb", "mem>1,5 GB", "mem>1.5 gb", "MEM > 1,5 Gb", "memory>1,5 GiB"] {
            let query = ProcessSearchQuery(text)
            XCTAssertEqual(query.metrics.map(\.value), [1.5 * gibibyte], text)
            XCTAssertEqual(query.metrics.map(\.comparison), [.greater], text)
            XCTAssertTrue(query.terms.isEmpty, "\(text): the unit is part of the filter, not a search word")
        }
        XCTAssertEqual(ProcessSearchQuery("watts>0,5").metrics.map(\.value), [0.5])
        XCTAssertEqual(ProcessSearchQuery("watts>0,5 W").metrics.map(\.value), [0.5])
        XCTAssertEqual(ProcessSearchQuery("cpu>12,5").metrics.map(\.value), [12.5])
        XCTAssertEqual(ProcessSearchQuery("writes>1,5 MB/s").metrics.map(\.value), [1.5 * 1_048_576])
        XCTAssertEqual(ProcessSearchQuery("leak>2 MB/min").metrics.map(\.value), [2])
        XCTAssertTrue(ProcessSearchQuery("writes>1,5 MB/s watts>2 W leak>2 MB/min").terms.isEmpty)
        XCTAssertEqual(ProcessSearchQuery("mem>1,5 chrome").terms.map(\.text), ["chrome"], "other words still search")
        // The same number in a comma-decimal locale is still a plain number elsewhere.
        XCTAssertEqual(ProcessSearchQuery("pid:1,2 port:3000,3001").pids.first?.values, [1, 2])
        XCTAssertEqual(ProcessSearchQuery("pid:1,2 port:3000,3001").ports.first?.values, [3000, 3001])
    }

    func testAUnitWordJoinsOnlyTheFiltersThatTakeOne() {
        // `cpu` has no unit words, so `gb` stays something to search for.
        let cpu = ProcessSearchQuery("cpu>5 gb")
        XCTAssertEqual(cpu.metrics.map(\.value), [5])
        XCTAssertEqual(cpu.terms.map(\.text), ["gb"])
        // A metric name inside a longer word is not a filter.
        XCTAssertEqual(ProcessSearchQuery("somemem>5 gb").terms.map(\.text), ["somemem>5", "gb"])
        // Half typed stays quiet: no unit yet, or a unit still being typed.
        let halfTyped = ProcessSearchQuery("cpu>1, mem>1, writes>5mb/")
        XCTAssertTrue(halfTyped.metrics.isEmpty && halfTyped.terms.isEmpty && halfTyped.tokens.isEmpty)
        // Without a unit, memory still means MB.
        XCTAssertEqual(ProcessSearchQuery("mem>1,5").metrics.map(\.value), [1.5 * 1_048_576])
    }

    func testDoubleDashFlagsAreLiteralTermsNotNegations() {
        // Smart dashes turn a typed `--` into an em dash before the search sees it.
        for text in ["--inspect", "\u{2014}inspect"] {
            let query = ProcessSearchQuery(text)
            XCTAssertEqual(query.terms.map(\.text), ["--inspect"], text)
            XCTAssertEqual(query.terms.map(\.isNegated), [false], text)
        }
        XCTAssertEqual(ProcessSearchQuery("--type=renderer").terms.map(\.text), ["--type=renderer"])
        // Exclusions keep working, including for a flag.
        for text in ["!--inspect", "-\"--inspect\""] {
            let query = ProcessSearchQuery(text)
            XCTAssertEqual(query.terms.map(\.text), ["--inspect"], text)
            XCTAssertEqual(query.terms.map(\.isNegated), [true], text)
        }
        for text in ["-helper", "!helper"] {
            XCTAssertEqual(ProcessSearchQuery(text).terms.map(\.text), ["helper"], text)
            XCTAssertEqual(ProcessSearchQuery(text).terms.map(\.isNegated), [true], text)
        }
        let plain = ProcessSearchQuery("chrome -helper")
        XCTAssertEqual(plain.terms.map(\.text), ["chrome", "helper"])
        XCTAssertEqual(plain.terms.map(\.isNegated), [false, true])
    }

    func testCommaNumbersAndDoubleDashFlagsFilterTheRealList() {
        XCTAssertEqual(names("mem>1,5gb").families, ["Google Chrome"])
        XCTAssertEqual(names("mem>1,5 GB").families, names("mem>1.5gb").families)
        XCTAssertTrue(names("mem>2,5 gb").families.isEmpty, "2 GB is under 2.5 GiB")
        // `--type=renderer` used to exclude exactly the process that has it.
        XCTAssertEqual(names("--type=renderer").families, ["Google Chrome"])
        XCTAssertEqual(Set(names("--type").families), ["Google Chrome", "Code Helper"])

        let quiet = subject(process(600, "quiet"), watts: 0.3)
        let busy = subject(process(601, "busy"), watts: 0.8)
        for text in ["watts>0,5", "watts>0,5 w", "watts>0.5"] {
            let outcome = ProcessSearchEngine.search(ProcessSearchQuery(text), families: [quiet, busy], processes: [])
            XCTAssertEqual(Set(outcome.families.keys), [1], text)
        }
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
    watts: Double? = nil,
    flags: Set<ProcessSearchQuery.Flag> = [.tracked]
) -> SearchSubject {
    SearchSubject(
        root: root,
        helpers: helpers,
        kindLabel: kind,
        measurements: SearchMeasurements(cpuPercent: cpu, memoryBytes: memory, gpuPercent: 0, threads: 4,
                                         leakMegabytesPerMinute: leak, children: Double(helpers.count),
                                         energyWatts: watts),
        flags: flags
    )
}
