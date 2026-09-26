import Foundation
import GhostProcessSniperCore
import MetricKit

final class RadarMetricKitSubscriber: NSObject, MXMetricManagerSubscriber {
    func start() {
        MXMetricManager.shared.add(self)
    }

    func stop() {
        MXMetricManager.shared.remove(self)
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        RadarLogger.performance.info("MetricKit delivered \(payloads.count, privacy: .public) metric payloads")
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        RadarLogger.performance.info("MetricKit delivered \(payloads.count, privacy: .public) diagnostic payloads")
    }
}
