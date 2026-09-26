import GhostProcessSniperCore
import SwiftUI

enum KillPreviewStep: Int, CaseIterable, Identifiable {
    case scope
    case targets
    case confirm

    var id: Self { self }

    var label: String {
        switch self {
        case .scope: "1. Plan"
        case .targets: "2. Targets"
        case .confirm: "3. Confirm"
        }
    }

    var systemImage: String {
        switch self {
        case .scope: "list.bullet.clipboard"
        case .targets: "list.bullet.rectangle"
        case .confirm: "scope"
        }
    }

    var next: Self {
        Self(rawValue: min(Self.confirm.rawValue, rawValue + 1)) ?? .confirm
    }

    var previous: Self {
        Self(rawValue: max(Self.scope.rawValue, rawValue - 1)) ?? .scope
    }
}

struct KillTargetRow: View {
    let target: KillTarget

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(target.name)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    if target.isRoot {
                        Text("root")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                    }
                }
                Text(target.reason)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Text("PID \(target.pid)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .trailing)

            Text(target.state.label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(color)
                .frame(width: 78, alignment: .trailing)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
    }

    private var icon: String {
        switch target.state {
        case .ready: "checkmark.circle"
        case .locked: "lock"
        case .stale: "clock.badge.xmark"
        case .recycled: "arrow.triangle.2.circlepath"
        case .terminated: "checkmark.seal"
        case .forceKilled: "bolt"
        case .survived: "exclamationmark.triangle"
        case .exitedBeforeSignal: "figure.run"
        case .failed: "xmark.octagon"
        }
    }

    private var color: Color {
        switch target.state {
        case .ready, .terminated: .green
        case .locked, .stale, .recycled: .orange
        case .forceKilled: .red
        case .exitedBeforeSignal: .secondary
        case .survived, .failed: .red
        }
    }
}

enum KillFactorStyle {
    static func icon(for factor: KillDecisionFactorKind) -> String {
        switch factor {
        case .whyKill: "checkmark.seal"
        case .whyWait: "exclamationmark.triangle"
        case .blocking: "xmark.octagon"
        }
    }

    static func color(for factor: KillDecisionFactorKind) -> Color {
        switch factor {
        case .whyKill: .green
        case .whyWait: .orange
        case .blocking: .red
        }
    }
}
