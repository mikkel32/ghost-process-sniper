import Foundation

/// The incident table read past the newest rows the refresh publishes, for
/// the Incidents page's search and filters. Everything else keeps using the
/// published list, which every publish hashes and every store flush may re-read.
public struct IncidentHistory: Equatable, Sendable {
    /// The newest incidents the refresh publishes to every surface.
    public static let publishedWindow = 80
    /// The most rows one history read returns. Retention keeps 90 days, and a
    /// busy developer Mac can log more than this in that time, so a read says
    /// when it left rows out.
    public static let readLimit = 2_000

    /// Newest first, like the published list.
    public let incidents: [RadarIncident]
    /// Numbers the reads of one store, so two reads of an unchanged table
    /// still differ. Never zero: zero stands for "no history" in a request.
    public let revision: UInt64
    /// The store's incident write count when the rows were read, taken in the
    /// same actor turn, so a reader can tell whether a later write made it stale.
    public let writeCount: Int
    /// The table held more rows than this read returned.
    public let isTruncated: Bool

    public init(incidents: [RadarIncident], revision: UInt64, writeCount: Int, isTruncated: Bool) {
        self.incidents = incidents
        self.revision = revision
        self.writeCount = writeCount
        self.isTruncated = isTruncated
    }
}
