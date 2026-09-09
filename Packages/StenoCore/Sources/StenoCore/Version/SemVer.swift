import Foundation

/// A semantic version, as used for the app version, the Sparkle appcast, and the
/// `CHANGELOG.md` section headings.
///
/// Parsing accepts an optional `v` prefix (`v1.2.3` as well as `1.2.3`), because
/// git tags carry it and `MARKETING_VERSION` does not. Ordering follows
/// [Semantic Versioning 2.0.0](https://semver.org) precedence: build metadata is
/// ignored, a prerelease sorts before its release, and prerelease identifiers are
/// compared field by field, numerically where both fields are numeric.
public struct SemVer: Sendable, Hashable, Comparable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int
    /// Dot-separated prerelease identifiers, without the leading `-`. Empty for a release.
    public let prerelease: [String]
    /// Dot-separated build-metadata identifiers, without the leading `+`. Ignored in comparisons.
    public let build: [String]

    public init(
        major: Int,
        minor: Int,
        patch: Int,
        prerelease: [String] = [],
        build: [String] = []
    ) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
        self.build = build
    }

    public var isPrerelease: Bool { !prerelease.isEmpty }

    /// The version without prerelease or build metadata — `1.2.3-beta.1+ci` becomes `1.2.3`.
    public var release: SemVer { SemVer(major: major, minor: minor, patch: patch) }

    /// The canonical string form, without a `v` prefix.
    public var description: String {
        var s = "\(major).\(minor).\(patch)"
        if !prerelease.isEmpty { s += "-" + prerelease.joined(separator: ".") }
        if !build.isEmpty { s += "+" + build.joined(separator: ".") }
        return s
    }

    // MARK: - Parsing

    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case empty
        case malformed(String)
        case invalidNumericComponent(String)
        case invalidIdentifier(String)

        public var description: String {
            switch self {
            case .empty:
                return "the version string is empty"
            case .malformed(let s):
                return "\"\(s)\" is not of the form major.minor.patch"
            case .invalidNumericComponent(let s):
                return "\"\(s)\" is not a valid version number"
            case .invalidIdentifier(let s):
                return "\"\(s)\" is not a valid prerelease or build identifier"
            }
        }
    }

    /// Parses a semantic version, tolerating a leading `v` and surrounding whitespace.
    public init(parsing string: String) throws {
        var text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ParseError.empty }
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        guard !text.isEmpty else { throw ParseError.empty }

        // Split off build metadata first: it may legally contain a `-`.
        // `nil` means the separator was absent; `""` means it was there with nothing
        // after it, which is malformed rather than empty.
        var core = text
        var buildPart: String?
        if let plus = core.firstIndex(of: "+") {
            buildPart = String(core[core.index(after: plus)...])
            core = String(core[..<plus])
        }

        var prereleasePart: String?
        if let dash = core.firstIndex(of: "-") {
            prereleasePart = String(core[core.index(after: dash)...])
            core = String(core[..<dash])
        }

        let numbers = core.split(separator: ".", omittingEmptySubsequences: false)
        guard numbers.count == 3 else { throw ParseError.malformed(text) }
        var parsed: [Int] = []
        for component in numbers {
            // Reject "01", "+1", " 1", and anything non-numeric.
            guard !component.isEmpty,
                  component.allSatisfy(\.isASCII),
                  component.allSatisfy(\.isNumber),
                  component == "0" || !component.hasPrefix("0"),
                  let value = Int(component)
            else { throw ParseError.invalidNumericComponent(String(component)) }
            parsed.append(value)
        }

        self.major = parsed[0]
        self.minor = parsed[1]
        self.patch = parsed[2]
        self.prerelease = try Self.identifiers(from: prereleasePart, allowLeadingZeroNumbers: false)
        self.build = try Self.identifiers(from: buildPart, allowLeadingZeroNumbers: true)
    }

    /// Parses a version, returning `nil` instead of throwing.
    public init?(_ string: String) {
        guard let parsed = try? SemVer(parsing: string) else { return nil }
        self = parsed
    }

    private static func identifiers(
        from part: String?,
        allowLeadingZeroNumbers: Bool
    ) throws -> [String] {
        // No separator at all: nothing to parse.
        guard let part else { return [] }
        // A separator with nothing after it — `1.2.3-` or `1.2.3+` — is malformed.
        guard !part.isEmpty else { throw ParseError.invalidIdentifier(part) }
        let fields = part.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        for field in fields {
            guard !field.isEmpty else { throw ParseError.invalidIdentifier(part) }
            let allowed = field.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
            guard allowed else { throw ParseError.invalidIdentifier(field) }
            if !allowLeadingZeroNumbers,
               field.allSatisfy(\.isNumber),
               field.count > 1,
               field.hasPrefix("0") {
                throw ParseError.invalidIdentifier(field)
            }
        }
        return fields
    }

    // MARK: - Comparable

    public static func < (lhs: SemVer, rhs: SemVer) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }

        // A prerelease has lower precedence than the release it precedes.
        switch (lhs.prerelease.isEmpty, rhs.prerelease.isEmpty) {
        case (true, true): return false
        case (true, false): return false
        case (false, true): return true
        case (false, false): break
        }

        for (l, r) in zip(lhs.prerelease, rhs.prerelease) {
            if l == r { continue }
            let lNumber = Int(l), rNumber = Int(r)
            switch (lNumber, rNumber) {
            case let (l?, r?): return l < r
            case (.some, .none): return true   // numeric identifiers rank below alphanumeric ones
            case (.none, .some): return false
            case (.none, .none): return l < r
            }
        }
        // A shorter set of identifiers ranks lower when the common prefix is equal.
        return lhs.prerelease.count < rhs.prerelease.count
    }

    /// Precedence equality: equal core version and prerelease, ignoring build metadata.
    /// `Equatable` is stricter and does compare build metadata, so that `1.0.0+a` and
    /// `1.0.0+b` remain distinguishable values.
    public func hasSamePrecedence(as other: SemVer) -> Bool {
        !(self < other) && !(other < self)
    }
}

extension SemVer: Codable {
    public init(from decoder: any Decoder) throws {
        let string = try decoder.singleValueContainer().decode(String.self)
        do {
            try self.init(parsing: string)
        } catch let error as ParseError {
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "invalid semantic version: \(error.description)"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

extension SemVer: LosslessStringConvertible {}
