import Foundation

public struct SMCSensorMapping: Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        /// Keys confirmed against real hardware of this family.
        case verified
        /// Keys published for this chip generation but not yet confirmed by this project.
        case catalog
        /// Keys found on this Mac by enumerating the SMC and checking plausible readings.
        case discovered
    }

    public let cpuKeys: [String]
    public let gpuKeys: [String]
    public let source: Source
}

/// A key reused on another chip can represent a different sensor, so every
/// table is chosen by chip generation, never by a substring of the brand.
enum SMCSensorCatalog {
    /// "Apple M1 Pro" -> 1, "Apple M10" -> 10; nil for Intel or unknown brands.
    static func generation(fromBrand brand: String) -> Int? {
        guard let marker = brand.range(of: "Apple M") else { return nil }
        let digits = brand[marker.upperBound...].prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty else { return nil }
        let rest = brand[digits.endIndex...]
        if let next = rest.first, next.isLetter || next.isNumber || next == "_" { return nil }
        return Int(digits)
    }

    static func mapping(forBrand brand: String) -> SMCSensorMapping? {
        switch generation(fromBrand: brand) {
        case 1:
            SMCSensorMapping(cpuKeys: ["Tp09", "Tp0T", "Tp01", "Tp05", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0X", "Tp0b"],
                             gpuKeys: ["Tg05", "Tg0D", "Tg0L", "Tg0T"], source: .verified)
        case 2:
            SMCSensorMapping(cpuKeys: ["Tp1h", "Tp1t", "Tp1p", "Tp1l", "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0X", "Tp0b",
                                       "Tp0f", "Tp0j"],
                             gpuKeys: ["Tg0f", "Tg0j"], source: .verified)
        case 3:
            SMCSensorMapping(cpuKeys: ["Te05", "Te0L", "Te0P", "Te0S", "Tf04", "Tf09", "Tf0A", "Tf0B", "Tf0D", "Tf0E",
                                       "Tf44", "Tf49", "Tf4A", "Tf4B", "Tf4D", "Tf4E"],
                             gpuKeys: ["Tf14", "Tf18", "Tf19", "Tf1A", "Tf24", "Tf28", "Tf29", "Tf2A"], source: .catalog)
        case 4:
            SMCSensorMapping(cpuKeys: ["Te05", "Te09", "Te0H", "Te0S", "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0V", "Tp0Y",
                                       "Tp0b", "Tp0e"],
                             gpuKeys: ["Tg0G", "Tg0H", "Tg0K", "Tg0L", "Tg0d", "Tg0e", "Tg0j", "Tg0k", "Tg1U", "Tg1k"],
                             source: .catalog)
        case .some:
            nil
        case nil:
            brand.contains("Intel")
                ? SMCSensorMapping(cpuKeys: ["TC0D", "TC0P"], gpuKeys: ["TG0D", "TG0P"], source: .verified)
                : nil
        }
    }
}
