import Charts
import GhostProcessSniperCore
import SwiftUI

/// What used energy today, across restarts, and the week's daily totals.
struct EnergyTodaySection: View {
    let today: EnergyToday

    private var subtitle: String {
        var text = "\(EnergyFormat.wattHours(today.wattHours)) measured"
        if let share = today.shareOfFullCharge, share >= 0.01 {
            text += " · about \(RadarFormat.percent(share * 100)) of a full charge"
        }
        return text
    }

    var body: some View {
        RadarSection(title: "Today", subtitle: subtitle, systemImage: "calendar", accent: .yellow) {
            if today.entries.isEmpty {
                Text("Today\u{2019}s totals build up as apps use energy, and carry over when Ghost restarts.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                AdaptivePairLayout(breakpoint: 620) {
                    VStack(spacing: 6) {
                        ForEach(today.entries.prefix(6), id: \.key) { entry in
                            row(entry, maximum: today.entries.first?.joules ?? 1)
                        }
                    }
                    if today.days.count >= 2 { week }
                }
            }
        }
    }

    private func row(_ entry: EnergyUsage, maximum: Double) -> some View {
        HStack(spacing: 10) {
            ThermalAppIcon(path: entry.applicationPath, size: 20)
            Text(entry.displayName)
                .font(.callout)
                .lineLimit(1)
            Spacer(minLength: 8)
            GeometryReader { proxy in
                Capsule()
                    .fill(.yellow.gradient)
                    .frame(width: max(2, proxy.size.width * min(1, entry.joules / max(maximum, 0.001))))
            }
            .frame(width: 80, height: 4)
            .background(Color.primary.opacity(0.06), in: Capsule())
            Text(EnergyFormat.wattHours(entry.wattHours))
                .font(.caption.monospacedDigit().weight(.semibold))
                .frame(width: 56, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
    }

    private var week: some View {
        VStack(alignment: .leading, spacing: 4) {
            Chart(today.days, id: \.day) { day in
                BarMark(x: .value("Day", Self.label(day.day)), y: .value("Wh", day.wattHours))
                    .foregroundStyle(day.day == today.days.last?.day ? AnyShapeStyle(.yellow.gradient)
                                                                      : AnyShapeStyle(.yellow.opacity(0.4)))
                    .cornerRadius(3)
            }
            .chartYAxis(.hidden)
            .frame(height: 110)
            Text("Measured energy per day")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .accessibilityLabel("Measured energy for the last \(today.days.count) days")
    }

    /// "Mon" from "2026-09-28", in the reader's language.
    private static func label(_ day: String) -> String {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3,
              let date = Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
        else { return day }
        return date.formatted(.dateTime.weekday(.abbreviated))
    }
}
