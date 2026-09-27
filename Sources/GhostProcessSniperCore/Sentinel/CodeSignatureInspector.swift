import Darwin
import Foundation
import Security

/// Who signed an executable, and where it was downloaded from.
public struct ExecutableProvenance: Hashable, Sendable {
    public let signing: CodeSigningSummary
    /// Download URLs macOS recorded (`kMDItemWhereFroms`), page first.
    public let downloadedFrom: [String]
    /// The file still carries the quarantine mark from its download.
    public let quarantined: Bool
}

/// Checks code signatures and download marks off the refresh path.
///
/// Each file is read once per (path, inode, modification time), so an update
/// is re-read and an unchanged binary never is. Validation is the basic kind:
/// the signature and its certificate chain, without hashing every page of a
/// large binary; the kernel already enforces page hashes for signed code. It
/// never uses the network (no revocation or online notarization checks).
actor CodeSignatureInspector {
    private struct FileKey: Hashable {
        let path: String
        let inode: UInt64
        let modified: Int
    }

    private var results: [String: (key: FileKey, provenance: ExecutableProvenance)] = [:]
    private var queue: [String] = []
    private var queued: Set<String> = []
    private var worker: Task<Void, Never>?
    /// Enough for every third-party program on a busy Mac.
    private let capacity = 2_000

    /// Adds paths to check. A file already read is read again only when it
    /// changed (an app update, or a binary swapped in place).
    func request(_ paths: [String]) {
        for path in paths where !queued.contains(path) {
            if let known = results[path], known.key == Self.fileKey(path) { continue }
            queue.append(path)
            queued.insert(path)
        }
        startIfNeeded()
    }

    func provenance(for path: String) -> ExecutableProvenance? {
        results[path]?.provenance
    }

    func snapshot(for paths: some Sequence<String>) -> [String: ExecutableProvenance] {
        var found: [String: ExecutableProvenance] = [:]
        for path in paths {
            if let result = results[path] { found[path] = result.provenance }
        }
        return found
    }

    private func startIfNeeded() {
        guard worker == nil, !queue.isEmpty else { return }
        worker = Task(priority: .utility) { [weak self] in
            await self?.drain()
        }
    }

    private func drain() async {
        while let path = queue.first {
            queue.removeFirst()
            queued.remove(path)
            if let key = Self.fileKey(path) {
                let provenance = Self.inspect(path)
                if results.count >= capacity, let evicted = results.keys.first { results[evicted] = nil }
                results[path] = (key, provenance)
            }
            // Yield between files so the checks never hold a core.
            try? await Task.sleep(for: .milliseconds(15))
        }
        worker = nil
    }

    private static func fileKey(_ path: String) -> FileKey? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return FileKey(path: path, inode: UInt64(info.st_ino), modified: Int(info.st_mtimespec.tv_sec))
    }

    // MARK: - Reading

    static func inspect(_ path: String) -> ExecutableProvenance {
        let bundle = bundleRoot(of: path)
        let signing = signingSummary(for: bundle ?? path)
        let markedPath = bundle ?? path
        return ExecutableProvenance(
            signing: signing,
            downloadedFrom: whereFroms(markedPath) ?? whereFroms(path) ?? [],
            quarantined: hasQuarantine(markedPath) || hasQuarantine(path)
        )
    }

    /// "/Applications/X.app" for "/Applications/X.app/Contents/MacOS/X".
    static func bundleRoot(of path: String) -> String? {
        guard let range = path.range(of: ".app/") else { return nil }
        return String(path[..<range.lowerBound]) + ".app"
    }

    private static let requirements: [(CodeSigningSummary.Authority, String)] = [
        (.apple, "anchor apple"),
        (.appStore, "anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.9] exists"),
        (.developerID, "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"),
    ]

    static func signingSummary(for path: String) -> CodeSigningSummary {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &staticCode) == errSecSuccess,
              let code = staticCode else {
            return CodeSigningSummary(authority: .unsigned, teamIdentifier: nil, signingIdentifier: nil)
        }
        // Never the network: no revocation or online notarization lookups.
        let basic = SecCSFlags(rawValue: kSecCSBasicValidateOnly).union(.noNetworkAccess)
        let status = SecStaticCodeCheckValidity(code, basic, nil)
        var information: CFDictionary?
        _ = SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
        let info = information as? [String: Any] ?? [:]
        let team = info[kSecCodeInfoTeamIdentifier as String] as? String
        let identifier = info[kSecCodeInfoIdentifier as String] as? String

        if status == errSecCSUnsigned {
            return CodeSigningSummary(authority: .unsigned, teamIdentifier: nil, signingIdentifier: identifier)
        }
        guard status == errSecSuccess else {
            return CodeSigningSummary(authority: .invalid, teamIdentifier: team, signingIdentifier: identifier)
        }
        if let flags = info[kSecCodeInfoFlags as String] as? UInt32, flags & 0x2 != 0 {  // kSecCodeSignatureAdhoc
            return CodeSigningSummary(authority: .adHoc, teamIdentifier: nil, signingIdentifier: identifier)
        }
        for (authority, text) in requirements {
            var requirement: SecRequirement?
            guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
                  let requirement else { continue }
            if SecStaticCodeCheckValidity(code, basic, requirement) == errSecSuccess {
                return CodeSigningSummary(authority: authority, teamIdentifier: team, signingIdentifier: identifier)
            }
        }
        return CodeSigningSummary(authority: .otherCertificate, teamIdentifier: team, signingIdentifier: identifier)
    }

    static func hasQuarantine(_ path: String) -> Bool {
        getxattr(path, "com.apple.quarantine", nil, 0, 0, 0) > 0
    }

    /// The download page and file URLs Safari, Chrome and Firefox record.
    static func whereFroms(_ path: String) -> [String]? {
        let name = "com.apple.metadata:kMDItemWhereFroms"
        let size = getxattr(path, name, nil, 0, 0, 0)
        guard size > 0, size < 64 * 1024 else { return nil }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { getxattr(path, name, $0.baseAddress, size, 0, 0) }
        guard read == size,
              let list = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String] else { return nil }
        let urls = list.filter { !$0.isEmpty }
        return urls.isEmpty ? nil : Array(urls.prefix(3))
    }
}

extension ExecutableProvenance {
    /// What the signature and download mark add to a finding.
    func signals(for subject: SentinelSubject, locatedOddly: Bool) -> [SentinelSignal] {
        var found: [SentinelSignal] = []
        switch signing.authority {
        case .invalid:
            found.append(SentinelSignal(.invalidSignature, .suspicious,
                "Its code signature does not verify: the program may have been modified after signing.",
                evidence: signing.signingIdentifier))
        case .unsigned:
            found.append(SentinelSignal(.unsigned, locatedOddly ? .suspicious : .notable,
                "Carries no code signature, so nobody vouches for who made it.", evidence: nil))
        case .adHoc:
            // Homebrew and anything you compile yourself are ad hoc signed;
            // that only matters for a program downloaded or hidden oddly.
            if locatedOddly || quarantined {
                found.append(SentinelSignal(.adHocSigned, .notable,
                    "Signed without a developer identity, so macOS cannot say who made it.", evidence: signing.signingIdentifier))
            }
        case .apple, .appStore, .developerID, .otherCertificate:
            break
        }
        if quarantined || !downloadedFrom.isEmpty {
            let source = downloadedFrom.first.map { " from \($0)" } ?? ""
            found.append(SentinelSignal(.downloadedExecutable, .info,
                "Downloaded from the internet\(source).", evidence: downloadedFrom.first))
        }
        return found
    }
}
