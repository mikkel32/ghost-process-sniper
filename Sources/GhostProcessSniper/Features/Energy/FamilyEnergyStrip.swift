import GhostProcessSniperCore
import SwiftUI

/// A family's energy, wake-ups and disk writes, averaged over about a
/// minute, and whether it keeps the Mac awake. Only this strip observes the
/// energy report on a family page.
struct FamilyEnergyStrip: View {
    let monitor: ProcessMonitor
    let familyKey: String

    var body: some View {
        let report = monitor.energy
        if let figures = report.families[familyKey] {
            HStack(spacing: 8) {
                if report.perProcessEnergy {
                    chip("Energy", EnergyFormat.watts(figures.watts), "bolt.fill", figures.watts >= 2 ? .watch : .quiet)
                }
                chip("Wake-ups", EnergyFormat.rate(figures.idleWakeupsPerSecond), "alarm",
                     figures.idleWakeupsPerSecond >= 150 ? .watch : .quiet)
                chip("Disk writes", EnergyFormat.bytes(figures.diskWriteBytesPerSecond) + "/s", "internaldrive",
                     figures.diskWriteBytesPerSecond >= 1_800_000 ? .watch : .quiet)
                chip("Sleep", sleepText(figures.keepsAwake), "moon.zzz", figures.keepsAwake == nil ? .quiet : .watch)
            }
        }
    }

    private func sleepText(_ effect: SleepAssertionEffect?) -> String {
        switch effect {
        case .systemSleep?: "Keeps Mac awake"
        case .displaySleep?: "Keeps display on"
        case nil: "Allows sleep"
        }
    }

    private func chip(_ title: String, _ value: String, _ systemImage: String, _ level: GhostLevel) -> some View {
        RadarChip(title: title, value: value, systemImage: systemImage, level: level)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
