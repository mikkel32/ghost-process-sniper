import GhostProcessSniperCore
import SwiftUI

struct MemoryShare: Identifiable, Equatable {
    let id: String
    let name: String
    let bytes: UInt64
    let color: Color
}

extension MemoryShare {
    private static let palette: [Color] = [.blue, .teal, .purple, .orange, .pink, .gray]

    // Bytes quantized to 16 MB buckets: the ranking only re-renders when a
    // family actually moves, not on every few-hundred-KB jitter.
    static func build(from families: [ProcessFamily]) -> [MemoryShare] {
        func quantized(_ bytes: UInt64) -> UInt64 {
            max(16_777_216, bytes - bytes % 16_777_216)
        }
        let sorted = families.sorted { $0.totalPhysicalFootprintBytes > $1.totalPhysicalFootprintBytes }
        var result = sorted.prefix(5).enumerated().map { index, family in
            MemoryShare(
                id: family.familyKey,
                name: family.displayName,
                bytes: quantized(family.totalPhysicalFootprintBytes),
                color: palette[index]
            )
        }
        let restBytes = sorted.dropFirst(5).reduce(0 as UInt64) { $0 + $1.totalPhysicalFootprintBytes }
        if restBytes > 0 {
            result.append(MemoryShare(id: "other", name: "Other", bytes: quantized(restBytes), color: palette[5]))
        }
        return result
    }
}

struct MemoryShareRanking: View, Equatable {
    let shares: [MemoryShare]

    var body: some View {
        let shares = shares
        if shares.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "chart.pie")
                    .font(.title3)
                    .foregroundStyle(.tertiary)
                Text("No tracked families yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let total = max(1, shares.reduce(0) { $0 + $1.bytes })
            VStack(alignment: .leading, spacing: 13) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Largest consumer")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(shares.first?.name ?? "—")
                            .font(.headline)
                            .lineLimit(1)
                    }
                    Spacer()
                    Text(RadarFormat.bytes(shares.first?.bytes ?? 0))
                        .font(.headline.monospacedDigit())
                }

                ForEach(shares.prefix(6)) { share in
                    let fraction = Double(share.bytes) / Double(total)
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(share.color)
                                .frame(width: 7, height: 7)
                            Text(share.name)
                                .font(.caption.weight(.medium))
                                .lineLimit(1)
                            Spacer(minLength: 6)
                            Text("\(Int((fraction * 100).rounded()))%")
                                .font(.caption2.monospacedDigit().weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(RadarFormat.bytes(share.bytes))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 58, alignment: .trailing)
                        }

                        GeometryReader { proxy in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.primary.opacity(0.055))
                                Capsule()
                                    .fill(share.color)
                                    .frame(width: max(3, proxy.size.width * fraction))
                            }
                        }
                        .frame(height: 5)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(.top, 4)
        }
    }
}
