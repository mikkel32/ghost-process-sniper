import GhostProcessSniperCore
import SwiftUI

struct RadarBrandMark: View {
    let level: GhostLevel
    var size: CGFloat = 38

    var body: some View {
        ZStack {
            Circle()
                .stroke(RadarTheme.accent(for: level).opacity(0.2), lineWidth: 1)
                .padding(3)
            Circle()
                .stroke(RadarTheme.accent(for: level).opacity(0.5), lineWidth: 1)
                .padding(size * 0.22)
            Image(systemName: "scope")
                .font(.system(size: size * 0.43, weight: .semibold))
                .foregroundStyle(RadarTheme.accent(for: level).gradient)
        }
        .frame(width: size, height: size)
        .background(RadarTheme.accent(for: level).opacity(0.09), in: Circle())
        .overlay(Circle().strokeBorder(RadarTheme.accent(for: level).opacity(0.22), lineWidth: 0.75))
        .accessibilityHidden(true)
    }
}

struct RadarStatusPill: View {
    let title: String
    let level: GhostLevel
    var systemImage: String? = nil

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(RadarTheme.accent(for: level))
                .frame(width: 6, height: 6)
            if let systemImage {
                Image(systemName: systemImage)
            }
            Text(title)
        }
        .font(.caption2.weight(.bold))
        .foregroundStyle(RadarTheme.accent(for: level))
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(RadarTheme.accent(for: level).opacity(0.1), in: Capsule())
        .overlay(Capsule().strokeBorder(RadarTheme.accent(for: level).opacity(0.22), lineWidth: 0.75))
    }
}

struct RadarPageHeader<Actions: View>: View {
    let eyebrow: String
    let title: String
    let subtitle: String
    let systemImage: String
    let accent: Color
    @ViewBuilder let actions: Actions

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 19, weight: .bold))
                .foregroundStyle(accent.gradient)
                .frame(width: 42, height: 42)
                .background(accent.opacity(0.11), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(accent.opacity(0.22), lineWidth: 0.75)
                }

            VStack(alignment: .leading, spacing: 3) {
                Text(eyebrow.uppercased())
                    .font(.system(size: 9, weight: .black))
                    .tracking(1.2)
                    .foregroundStyle(accent)
                Text(title)
                    .font(.system(size: 25, weight: .bold, design: .rounded))
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 16)
            actions
        }
        .padding(14)
        .radarSurface(tint: accent, cornerRadius: 16)
    }
}

struct RadarChip: View {
    let title: String
    let value: String
    var systemImage: String?
    var level: GhostLevel = .quiet

    var body: some View {
        HStack(spacing: 7) {
            if let systemImage {
                Image(systemName: systemImage)
                    .foregroundStyle(RadarStyle.color(for: level))
                    .frame(width: 14)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title.uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

struct CompactRadarChip: View {
    let title: String
    let value: String
    var systemImage: String?
    var level: GhostLevel = .quiet

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(RadarTheme.accent(for: level))
                        .frame(width: 19, height: 19)
                        .background(RadarTheme.accent(for: level).opacity(0.1), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
                Text(title.uppercased())
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .tracking(0.5)
                    .lineLimit(1)
                    .minimumScaleFactor(0.76)
            }
            Text(value)
                .font(.caption.monospacedDigit().weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(minHeight: 38, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

struct ScoreCapsuleBadge: View {
    let scoreText: String
    let level: GhostLevel

    var body: some View {
        Text(scoreText)
            .font(.caption2.monospacedDigit().weight(.semibold))
            .foregroundStyle(level == .quiet ? AnyShapeStyle(.secondary) : AnyShapeStyle(RadarStyle.color(for: level)))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RadarStyle.color(for: level).opacity(level == .quiet ? 0.07 : 0.14),
                in: Capsule()
            )
    }
}

struct RadarSection<Content: View>: View {
    let title: String
    var subtitle: String?
    var systemImage: String?
    var tip: RadarTip?
    var accent: Color = RadarTheme.brand
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(accent)
                        .frame(width: 28, height: 28)
                        .background(accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                Text(title)
                    .font(.headline)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let tip {
                    InfoTip(tip: tip)
                }
                Spacer()
            }
            content
        }
        .padding(14)
        .radarSurface(tint: accent)
    }
}

struct CompactRadarSection<Content: View>: View {
    let title: String
    var subtitle: String?
    var systemImage: String?
    var tip: RadarTip?
    var accent: Color = RadarTheme.brand
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(accent)
                        .frame(width: 24, height: 24)
                        .background(accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                Text(title)
                    .font(.subheadline.weight(.semibold))
                if let subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let tip {
                    InfoTip(tip: tip)
                }
                Spacer()
            }
            content
        }
        .padding(13)
        .radarSurface(tint: accent, cornerRadius: 14)
    }
}

struct ScoreComponentView: View {
    let component: GhostScoreComponent

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .foregroundStyle(RadarStyle.color(for: component.level))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(component.title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text(component.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Text("+\(Int(component.impact.rounded()))")
                .font(.caption2.monospacedDigit().weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(9)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private var icon: String {
        switch component.kind {
        case .memory: "memorychip"
        case .cpu: "cpu"
        case .gpu: "display"
        case .leak: "chart.line.uptrend.xyaxis"
        case .baseline: "ruler"
        case .fanout: "point.3.connected.trianglepath.dotted"
        case .background: "moon"
        case .recurrence: "repeat"
        case .forecast: "clock.badge.exclamationmark"
        case .rules: "slider.horizontal.3"
        case .system: "gearshape.2"
        }
    }
}

struct RadarToastView: View {
    let toast: RadarToast

    var body: some View {
        HStack(spacing: 12) {
            Label(toast.message, systemImage: toast.systemImage)
                .lineLimit(2)
            if let action = toast.action {
                Button(action.title, action: action.perform)
                    .buttonStyle(.link)
            }
        }
        .font(.callout.weight(.medium))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(RadarTheme.elevatedPanel, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.16), lineWidth: 0.75))
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        .padding(.bottom, 16)
        .accessibilityElement(children: .contain)
    }
}
