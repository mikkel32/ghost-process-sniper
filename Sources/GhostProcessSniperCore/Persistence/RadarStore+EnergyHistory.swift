import Foundation

/// Each day's energy per app and job, so the Energy page can say what used
/// the battery today and this week across restarts.
extension RadarStore {
    /// Adds the increments to their day's rows in one transaction.
    public func recordEnergy(_ increments: [EnergyUsage], day: String, now: Date = Date()) throws {
        guard !increments.isEmpty else { return }
        try transaction {
            for usage in increments {
                try execute(
                    "INSERT INTO energy_days(day, group_key, display_name, application_path, joules, wakeups, " +
                        "disk_bytes, cpu_seconds, updated_at) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?) " +
                        "ON CONFLICT(day, group_key) DO UPDATE SET display_name = excluded.display_name, " +
                        "application_path = excluded.application_path, joules = joules + excluded.joules, " +
                        "wakeups = wakeups + excluded.wakeups, disk_bytes = disk_bytes + excluded.disk_bytes, " +
                        "cpu_seconds = cpu_seconds + excluded.cpu_seconds, updated_at = excluded.updated_at",
                    .text(day), .text(usage.key), .text(usage.displayName),
                    usage.applicationPath.map { .text($0) } ?? .null,
                    .double(usage.joules), .double(usage.wakeups), .double(usage.diskBytesWritten),
                    .double(usage.cpuSeconds), .double(now.timeIntervalSince1970)
                )
            }
        }
    }

    /// Rows for `days` local days ending today, oldest first.
    public func energyHistory(days: Int, now: Date = Date()) throws -> [EnergyDayUsage] {
        let first = EnergyHistory.dayKey(for: now.addingTimeInterval(-Double(max(0, days - 1)) * 86_400))
        var rows: [EnergyDayUsage] = []
        try query("SELECT day, group_key, display_name, application_path, joules, wakeups, disk_bytes, cpu_seconds " +
                  "FROM energy_days WHERE day >= ? ORDER BY day, group_key", [.text(first)]) { row in
            rows.append(EnergyDayUsage(
                day: row.string(0) ?? "",
                usage: EnergyUsage(key: row.string(1) ?? "", displayName: row.string(2) ?? "",
                                   applicationPath: row.isNull(3) ? nil : row.string(3),
                                   joules: row.double(4), wakeups: row.double(5), diskBytesWritten: row.double(6),
                                   cpuSeconds: row.double(7))))
        }
        return rows
    }
}
