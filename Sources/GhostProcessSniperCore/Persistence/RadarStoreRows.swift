import Foundation

/// JSON columns use seconds-since-1970 dates and sorted keys, so an unchanged
/// value always encodes to the same text.
final class StoreCodec {
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init() {
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = .sortedKeys
        decoder.dateDecodingStrategy = .secondsSince1970
    }

    func encode<T: Encodable>(_ value: T) throws -> String {
        let data = try encoder.encode(value)
        return String(decoding: data, as: UTF8.self)
    }

    func decode<T: Decodable>(_ type: T.Type, from json: String?) -> T? {
        guard let data = json?.data(using: .utf8) else {
            return nil
        }
        return try? decoder.decode(type, from: data)
    }
}

enum RadarStoreRows {
    static let baselineColumns = """
        signature_id, display_name, canonical_path, command_fingerprint, sample_count,
        mean_memory_bytes, peak_memory_bytes, mean_cpu_percent, peak_cpu_percent,
        mean_leak_velocity, incident_count, first_seen_at, last_seen_at, measurement_version,
        memory_variance, cpu_variance, observed_seconds, session_count
        """

    static func baseline(from row: SQLiteRow) -> FamilyBaseline {
        let signature = ProcessSignature(
            id: row.string(0) ?? "",
            displayName: row.string(1) ?? "Process",
            canonicalPath: row.string(2) ?? "",
            commandFingerprint: row.string(3) ?? ""
        )
        return FamilyBaseline(
            signature: signature,
            sampleCount: row.int(4),
            meanMemoryBytes: row.double(5),
            peakMemoryBytes: row.bytes(6),
            meanCPUPercent: row.double(7),
            peakCPUPercent: row.double(8),
            meanLeakVelocityMegabytesPerMinute: row.double(9),
            incidentCount: row.int(10),
            firstSeenAt: row.date(11),
            lastSeenAt: row.date(12),
            measurementVersion: row.int(13),
            memoryVariance: row.double(14),
            cpuVariance: row.double(15),
            observedSeconds: row.double(16),
            sessionCount: row.int(17)
        )
    }

    static func incident(from row: SQLiteRow, codec: StoreCodec) -> RadarIncident {
        let signature = ProcessSignature(
            id: row.string(1) ?? "",
            displayName: row.string(2) ?? "Process",
            canonicalPath: row.string(3) ?? "",
            commandFingerprint: row.string(4) ?? ""
        )
        return RadarIncident(
            id: UUID(uuidString: row.string(0) ?? "") ?? UUID(),
            signature: signature,
            familyName: row.string(5) ?? signature.displayName,
            level: GhostLevel.allCases.first { $0.label == row.string(6) } ?? .watch,
            maxScore: row.double(7),
            memoryBytes: row.bytes(8),
            cpuPercent: row.double(9),
            leakVelocityMegabytesPerMinute: row.double(10),
            reasons: codec.decode([String].self, from: row.string(11)) ?? [],
            startedAt: row.date(12),
            lastSeenAt: row.date(13),
            resolvedAt: row.isNull(14) ? nil : row.date(14),
            occurrenceCount: row.int(15)
        )
    }
}
