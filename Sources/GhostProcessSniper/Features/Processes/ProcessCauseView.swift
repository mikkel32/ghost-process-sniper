import SwiftUI
import GhostProcessSniperCore

struct ProcessCauseView: View {
    let family: ProcessFamily

    var body: some View {
        let assessment = ProcessAssessment(family: family)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: assessment.systemImage)
                    .font(.title2)
                    .foregroundStyle(RadarTheme.brand)
                    .frame(width: 42, height: 42)
                    .background(RadarTheme.brand.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text("WHAT THE READINGS SHOW")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(RadarTheme.brand)
                    Text(assessment.cause)
                        .font(.title2.weight(.semibold))
                }
                Spacer(minLength: 8)
                RadarStatusPill(title: assessment.status, level: family.score.level)
            }
            Text(assessment.evidence).font(.body)
            Text(assessment.recommendation).font(.callout).foregroundStyle(.secondary)
            Label(assessment.measurementText, systemImage: "clock")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .radarSurface(tint: RadarTheme.accent(for: family.score.level))
    }
}
