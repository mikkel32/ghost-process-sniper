import XCTest
@testable import GhostProcessSniperCore

final class DuplicateFamilyResolverTests: XCTestCase {
    func testMatchesLegacyProjectionAcrossPopulationSizes() {
        for count in [2, 10, 64, 250] {
            let fixture = RefreshPerformanceFixture.population(count)
            XCTAssertEqual(DuplicateFamilyResolver.resolve(fixture.clusters, families: fixture.families),
                RefreshPerformanceFixture.legacyResolve(fixture.clusters, families: fixture.families))
        }
    }

    func testOverlappingFamiliesAndRepeatedMembersPreserveContainment() {
        let a = RefreshPerformanceFixture.process(0)
        let b = RefreshPerformanceFixture.process(1)
        let c = RefreshPerformanceFixture.process(2)
        let families = [
            RefreshPerformanceFixture.family(a, members: [a, a, b]),
            RefreshPerformanceFixture.family(b, members: [b, c])
        ]
        let clusters = [RefreshPerformanceFixture.cluster(0, members: [a, b, b]),
                        RefreshPerformanceFixture.cluster(1, members: [a, c])]
        let result = DuplicateFamilyResolver.resolve(clusters, families: families)
        XCTAssertEqual(result, RefreshPerformanceFixture.legacyResolve(clusters, families: families))
        XCTAssertTrue(result.first { $0.id == clusters[0].id }!.isInternalToSingleFamily)
        XCTAssertFalse(result.first { $0.id == clusters[1].id }!.isInternalToSingleFamily)
    }

    func testRecycledPIDAndUnknownMembersDoNotCreateOwnership() {
        let old = RefreshPerformanceFixture.process(0)
        let replacement = RefreshPerformanceFixture.process(0, start: 1_999_999_000)
        let other = RefreshPerformanceFixture.process(1)
        let families = [RefreshPerformanceFixture.family(replacement), RefreshPerformanceFixture.family(other)]
        let cluster = RefreshPerformanceFixture.cluster(0, members: [old, other])
        let result = DuplicateFamilyResolver.resolve([cluster], families: families)
        XCTAssertEqual(result[0].relatedFamilyKeys, [families[1].familyKey])
        XCTAssertFalse(result[0].isInternalToSingleFamily)
    }

    func testResolutionDoesNotRetainExitedFamilies() {
        let fixture = RefreshPerformanceFixture.population(4)
        let first = DuplicateFamilyResolver.resolve(fixture.clusters, families: fixture.families)
        XCTAssertTrue(first.allSatisfy { !$0.relatedFamilyKeys.isEmpty })
        let next = DuplicateFamilyResolver.resolve(fixture.clusters, families: [])
        XCTAssertTrue(next.allSatisfy { $0.relatedFamilyKeys.isEmpty && !$0.isInternalToSingleFamily })
    }

    func testEmptyInputsMatchLegacySemantics() {
        let family = RefreshPerformanceFixture.family(RefreshPerformanceFixture.process(0))
        XCTAssertTrue(DuplicateFamilyResolver.resolve([], families: [family]).isEmpty)
        let empty = RefreshPerformanceFixture.cluster(0, members: [])
        XCTAssertEqual(DuplicateFamilyResolver.resolve([empty], families: [family]),
            RefreshPerformanceFixture.legacyResolve([empty], families: [family]))
    }

    func testValueProjectionReusesMeasurementsWithoutMutatingOriginal() {
        let fixture = RefreshPerformanceFixture.population(4)
        let original = fixture.clusters[0]
        let resolved = original.resolving(relatedFamilyKeys: ["z", "a"], isInternalToSingleFamily: true)
        let expected = DuplicateProcessCluster(key: original.key, displayName: original.displayName,
            members: original.members, independentRootCount: original.independentRootCount,
            likelyKind: original.likelyKind, classificationReason: original.classificationReason,
            relatedFamilyKeys: ["a", "z"], isInternalToSingleFamily: true)
        XCTAssertEqual(resolved, expected)
        XCTAssertTrue(original.relatedFamilyKeys.isEmpty)
        XCTAssertFalse(original.isInternalToSingleFamily)
    }

    func testDeterministicMixedOwnershipMatchesLegacyExactly() {
        let processes = (0..<40).map { RefreshPerformanceFixture.process($0) }
        for seed in 0..<40 {
            let families = (0..<16).map { index in
                let members = (0..<4).map { processes[(index + $0 * 7 + seed) % 32] }
                return RefreshPerformanceFixture.family(members[0], members: members)
            }
            let clusters = (0..<12).map { index in
                RefreshPerformanceFixture.cluster(index,
                    members: (0..<3).map { processes[(index * 3 + $0 * 11 + seed) % 40] })
            }
            XCTAssertEqual(DuplicateFamilyResolver.resolve(clusters, families: families),
                RefreshPerformanceFixture.legacyResolve(clusters, families: families), "Seed \(seed)")
        }
    }

    func testBuilderIntegratesResolutionWithoutDroppingFamilies() {
        let processes = (0..<20).map { RefreshPerformanceFixture.process($0) }
        var settings = ThresholdSettings.aggressive
        settings.radarMode = .all
        settings.groupFamilies = false
        var trends = TrendWindow()
        let result = ProcessFamilyBuilder(currentUserID: 501).buildFamiliesWithDuplicates(
            from: processes, settings: settings, trendWindow: &trends, now: RefreshPerformanceFixture.now)
        XCTAssertEqual(Set(result.families.map(\.root.identity)), Set(processes.map(\.identity)))
        XCTAssertFalse(result.duplicateClusters.isEmpty)
        XCTAssertTrue(result.duplicateClusters.allSatisfy { $0.relatedFamilyKeys.count == 2 })
        XCTAssertTrue(result.duplicateClusters.allSatisfy { !$0.isInternalToSingleFamily })
    }
}
