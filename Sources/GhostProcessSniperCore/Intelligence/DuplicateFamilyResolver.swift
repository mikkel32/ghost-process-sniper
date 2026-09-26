import Foundation

/// Resolves duplicate ownership using exact process identities from one sample.
/// The index is local to this projection, so exited or recycled PIDs cannot linger.
enum DuplicateFamilyResolver {
    static func resolve(
        _ clusters: [DuplicateProcessCluster],
        families: [ProcessFamily]
    ) -> [DuplicateProcessCluster] {
        guard !clusters.isEmpty else { return [] }

        var owners: [ProcessIdentity: [Int]] = [:]
        owners.reserveCapacity(families.count)
        for (index, family) in families.enumerated() {
            // Overlapping families are supported, but a repeated member within
            // one family must not inflate the containment count.
            var seen = Set<ProcessIdentity>()
            for member in family.members where seen.insert(member.identity).inserted {
                owners[member.identity, default: []].append(index)
            }
        }

        return clusters.map { cluster in
            let identities = Set(cluster.members.map(\.identity))
            var matches: [Int: Int] = [:]
            for identity in identities {
                for owner in owners[identity, default: []] {
                    matches[owner, default: 0] += 1
                }
            }
            return cluster.resolving(
                relatedFamilyKeys: matches.keys.map { families[$0].familyKey },
                isInternalToSingleFamily: matches.values.contains(identities.count)
            )
        }.sorted { lhs, rhs in
            if lhs.memberCount != rhs.memberCount { return lhs.memberCount > rhs.memberCount }
            if lhs.totalPhysicalFootprintBytes != rhs.totalPhysicalFootprintBytes {
                return lhs.totalPhysicalFootprintBytes > rhs.totalPhysicalFootprintBytes
            }
            return lhs.totalCPUPercent > rhs.totalCPUPercent
        }
    }
}
