import CryptoKit
import Darwin
import Foundation

/// A file as the kernel knows it. The change time moves on every write and
/// every metadata change, back-dating with `touch -r` included, so a file
/// copied over in place (same inode) still reads as a different file.
public struct FileStamp: Hashable, Codable, Sendable {
    public let device: Int64
    public let inode: UInt64
    public let size: Int64
    public let changedSeconds: Int64
    public let changedNanoseconds: Int64

    public static func read(_ path: String) -> FileStamp? {
        var info = stat()
        guard stat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        return FileStamp(device: Int64(info.st_dev), inode: UInt64(info.st_ino), size: Int64(info.st_size),
                         changedSeconds: Int64(info.st_ctimespec.tv_sec), changedNanoseconds: Int64(info.st_ctimespec.tv_nsec))
    }
}

/// Something the user vouched for, bound to what made it trustworthy. A path
/// alone never is: a different file at a trusted path is news.
public struct SentinelTrustEntry: Hashable, Codable, Sendable, Identifiable {
    public enum Anchor: Hashable, Codable, Sendable {
        /// Any build signed by this Developer ID or App Store team with this identifier.
        case signer(team: String, identifier: String)
        /// Apple's signature outside the system folders, with this identifier.
        case apple(identifier: String)
        /// One exact build: its code directory hash (ad hoc, other certificates).
        case build(cdHash: String)
        /// One exact unsigned file.
        case file(FileStamp)
        /// A shell or interpreter running this script while the script is unchanged.
        case script(path: String, stamp: FileStamp)
        /// A shell, interpreter or system tool running this exact command, by its SHA-256.
        case command(sha256: String)
        /// Trusted by path in an earlier version: bound to the first signature read.
        case earlierVersion
    }

    public let path: String
    public let name: String
    public let anchor: Anchor
    public let added: Date

    public init(path: String, name: String, anchor: Anchor, added: Date) {
        self.path = path
        self.name = name
        self.anchor = anchor
        self.added = added
    }

    public var id: String {
        switch anchor {
        case .signer(let team, let identifier): "\(path)|signer|\(team)|\(identifier)"
        case .apple(let identifier): "\(path)|apple|\(identifier)"
        case .build(let hash): "\(path)|build|\(hash)"
        case .file(let stamp): "\(path)|file|\(stamp.inode)|\(stamp.changedSeconds).\(stamp.changedNanoseconds)"
        case .script(let script, let stamp): "\(path)|script|\(script)|\(stamp.changedSeconds).\(stamp.changedNanoseconds)"
        case .command(let hash): "\(path)|command|\(hash)"
        case .earlierVersion: "\(path)|earlier"
        }
    }

    /// Trusts the program whatever it runs, as opposed to one script or command.
    var coversProgram: Bool {
        switch anchor {
        case .script, .command: false
        default: true
        }
    }

    /// The Trust menu item: exactly what will be trusted.
    public var title: String {
        switch anchor {
        case .signer(let team, _): "Trust \(name) (Team \(team))"
        case .apple: "Trust \(name) (Apple)"
        case .build: "Trust This Build of \(name)"
        case .file: "Trust This Copy of \(name)"
        case .script(let script, _): "Trust \(name) Running \((script as NSString).lastPathComponent)"
        case .command: "Trust This Exact Command"
        case .earlierVersion: "Trust \(name)"
        }
    }

    /// One line for the list of trusted programs.
    public var scope: String {
        switch anchor {
        case .signer(let team, _): "Any version signed by team \(team)"
        case .apple: "Any version signed by Apple"
        case .build: "This exact build; a rebuild or update asks again"
        case .file: "This exact file; any change asks again"
        case .script(let script, _): "Only while running \(script), unchanged"
        case .command: "Only this exact command line"
        case .earlierVersion: "Checks its signature the next time it runs"
        }
    }

    /// "signed by team ABC123", for the finding when the file changed.
    var trustedAs: String {
        switch anchor {
        case .signer(let team, _): "as signed by team \(team)"
        case .apple: "as signed by Apple"
        case .build: "as one exact build"
        case .file: "as one exact file"
        case .script(let script, _): "running \((script as NSString).lastPathComponent)"
        case .command: "for one exact command"
        case .earlierVersion: "by its path"
        }
    }
}

/// What trust says about a process.
enum SentinelTrustMatch: Equatable {
    case none
    case trusted
    /// Trusted only if its signature matches, which is not read yet: the
    /// finding waits rather than flashing an alarm for a trusted program.
    case pending
    /// Trusted once, but what is there now is not what was trusted.
    case changed(SentinelTrustEntry)
}

/// The user's trust decisions, looked up by executable path.
struct SentinelTrust: Sendable {
    private(set) var entries: [SentinelTrustEntry] = []

    init(_ entries: [SentinelTrustEntry] = []) {
        self.entries = entries
    }

    func hasEntries(for path: String) -> Bool {
        entries.contains { $0.path == path }
    }

    /// A newer whole-program entry replaces the old one for the path (the
    /// user trusted an update); script and command entries add up.
    mutating func insert(_ entry: SentinelTrustEntry) {
        entries.removeAll { $0.id == entry.id || ($0.path == entry.path && $0.coversProgram && entry.coversProgram) }
        entries.append(entry)
        entries.sort { ($0.name.lowercased(), $0.id) < ($1.name.lowercased(), $1.id) }
    }

    @discardableResult
    mutating func remove(id: String) -> Bool {
        let before = entries.count
        entries.removeAll { $0.id == id }
        return entries.count != before
    }

    /// Binds an entry carried over from path-only trust to the signature
    /// read now; one that cannot be bound safely is dropped.
    mutating func bindEarlierVersion(path: String, provenance: ExecutableProvenance, now: Date) -> Bool {
        guard let old = entries.first(where: { $0.path == path && $0.anchor == .earlierVersion }) else { return false }
        remove(id: old.id)
        if let anchor = Self.programAnchor(provenance) {
            insert(SentinelTrustEntry(path: path, name: old.name, anchor: anchor, added: old.added))
        }
        return true
    }

    /// `provenance` is the signature of the file at the path now, nil until read.
    func match(_ subject: SentinelSubject, provenance: ExecutableProvenance?,
               stamp: (String) -> FileStamp? = FileStamp.read) -> SentinelTrustMatch {
        let candidates = entries.filter { $0.path == subject.executablePath }
        guard !candidates.isEmpty else { return .none }
        if !Self.allowsWholeProgram(subject) {
            // A shell or tool is trusted for one script or command only.
            let digest = Self.digest(subject.commandLine)
            for entry in candidates {
                switch entry.anchor {
                case .command(let hash) where hash == digest:
                    return .trusted
                case .script(let script, let scriptStamp) where Self.script(of: subject, stamp: stamp)?.path == script:
                    return stamp(script) == scriptStamp ? .trusted : .changed(entry)
                default:
                    continue
                }
            }
            return .none
        }
        guard let entry = candidates.first(where: \.coversProgram) else { return .none }
        guard let provenance else { return .pending }
        if entry.anchor == .earlierVersion { return provenance.signing.authority == .invalid ? .changed(entry) : .trusted }
        return Self.admits(entry.anchor, provenance) ? .trusted : .changed(entry)
    }

    static func admits(_ anchor: SentinelTrustEntry.Anchor, _ provenance: ExecutableProvenance) -> Bool {
        let signing = provenance.signing
        switch anchor {
        case .signer(let team, let identifier):
            return [.developerID, .appStore].contains(signing.authority) && signing.teamIdentifier == team &&
                signing.signingIdentifier == identifier
        case .apple(let identifier):
            return signing.authority == .apple && signing.signingIdentifier == identifier
        case .build(let hash):
            return signing.authority != .invalid && signing.cdHash == hash
        case .file(let stamp):
            return provenance.file == stamp
        case .script, .command, .earlierVersion:
            return false
        }
    }

    // MARK: - Offers

    /// What a finding's Trust item would trust, or nil when nothing can be
    /// trusted safely (an invalid signature, or one not read yet).
    static func offer(for subject: SentinelSubject, provenance: ExecutableProvenance?, now: Date,
                      stamp: (String) -> FileStamp? = FileStamp.read) -> SentinelTrustEntry? {
        let path = subject.executablePath
        guard path.hasPrefix("/") else { return nil }
        if !allowsWholeProgram(subject) {
            guard !subject.commandLine.isEmpty else { return nil }
            let anchor: SentinelTrustEntry.Anchor = script(of: subject, stamp: stamp)
                .map { .script(path: $0.path, stamp: $0.stamp) } ?? .command(sha256: digest(subject.commandLine))
            return SentinelTrustEntry(path: path, name: subject.program, anchor: anchor, added: now)
        }
        guard let provenance, let anchor = programAnchor(provenance) else { return nil }
        let name = SentinelCatalog.appName(forPath: path) ?? (path as NSString).lastPathComponent
        return SentinelTrustEntry(path: path, name: name, anchor: anchor, added: now)
    }

    /// Shells, interpreters, download and system tools run whatever they are
    /// given: trusting one whole would hide every later attack through it.
    static func allowsWholeProgram(_ subject: SentinelSubject) -> Bool {
        !subject.isCommandRunner && !subject.isSystemLocation
    }

    /// The widest anchor that still names who made the code: its signer when
    /// a checked team or Apple stands behind it, else this exact build or file.
    static func programAnchor(_ provenance: ExecutableProvenance) -> SentinelTrustEntry.Anchor? {
        let signing = provenance.signing
        switch signing.authority {
        case .developerID, .appStore:
            if let team = signing.teamIdentifier, let identifier = signing.signingIdentifier {
                return .signer(team: team, identifier: identifier)
            }
        case .apple:
            if let identifier = signing.signingIdentifier { return .apple(identifier: identifier) }
        case .invalid:
            return nil
        case .otherCertificate, .adHoc, .unsigned:
            break
        }
        if let hash = signing.cdHash { return .build(cdHash: hash) }
        return provenance.file.map { .file($0) }
    }

    /// The script a shell or interpreter runs (`bash /path/host.sh --flag`):
    /// its first operand that is a file. Arguments arrive joined by spaces,
    /// so a path containing spaces is found by trying longer runs of words.
    static func script(of subject: SentinelSubject, stamp: (String) -> FileStamp?) -> (path: String, stamp: FileStamp)? {
        let words = subject.commandLine.split(separator: " ").map(String.init)
        guard words.count >= 2 else { return nil }
        var index = 1
        while index < words.count, words[index].hasPrefix("-") {
            // An inline program (`-c`, `-e`) has no script file to bind to.
            if ["-c", "-e", "-E", "-m", "-r", "--eval", "--command"].contains(words[index]) { return nil }
            index += 1
        }
        guard index < words.count, words[index].hasPrefix("/") else { return nil }
        var candidate = ""
        for word in words[index...].prefix(8) {
            candidate += candidate.isEmpty ? word : " " + word
            if let found = stamp(candidate) { return (candidate, found) }
        }
        return nil
    }

    /// What is at a trusted path now, for the finding that says it changed.
    static func describe(_ provenance: ExecutableProvenance?) -> String {
        guard let signing = provenance?.signing else { return "the file there has changed" }
        return switch signing.authority {
        case .developerID, .appStore: "the file there now is signed by team \(signing.teamIdentifier ?? "unknown")"
        case .apple: "the file there now is signed by Apple as \(signing.signingIdentifier ?? "another program")"
        case .adHoc, .otherCertificate: "the file there now is a different build"
        case .unsigned: "the file there now is unsigned"
        case .invalid: "the file there now has a signature that does not verify"
        }
    }

    static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
