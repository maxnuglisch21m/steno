import Foundation
import Testing

@testable import StenoCore

@Suite("SemVer")
struct SemVerTests {
    @Test(
        "parses plain and v-prefixed versions",
        arguments: [
            ("1.2.3", 1, 2, 3),
            ("v1.2.3", 1, 2, 3),
            ("V1.2.3", 1, 2, 3),
            ("0.1.0", 0, 1, 0),
            ("0.0.0", 0, 0, 0),
            ("10.20.30", 10, 20, 30),
            ("  v2.9.6  ", 2, 9, 6)
        ]
    )
    func parsesCore(input: String, major: Int, minor: Int, patch: Int) throws {
        let version = try SemVer(parsing: input)
        #expect(version.major == major)
        #expect(version.minor == minor)
        #expect(version.patch == patch)
        #expect(version.prerelease.isEmpty)
        #expect(version.build.isEmpty)
    }

    @Test("parses prerelease and build metadata")
    func parsesPrerelease() throws {
        let beta = try SemVer(parsing: "1.0.0-beta.1")
        #expect(beta.prerelease == ["beta", "1"])
        #expect(beta.isPrerelease)
        #expect(beta.description == "1.0.0-beta.1")
        #expect(beta.release == SemVer(major: 1, minor: 0, patch: 0))

        let full = try SemVer(parsing: "v2.10.0-rc.2+build.7")
        #expect(full.prerelease == ["rc", "2"])
        #expect(full.build == ["build", "7"])
        #expect(full.description == "2.10.0-rc.2+build.7")

        // A dash inside build metadata is legal and must not be read as a prerelease.
        let dashed = try SemVer(parsing: "1.0.0+exp-sha.5114f85")
        #expect(dashed.prerelease.isEmpty)
        #expect(dashed.build == ["exp-sha", "5114f85"])
    }

    @Test(
        "rejects malformed versions",
        arguments: [
            "", "   ", "v", "1", "1.2", "1.2.3.4", "1.2.x", "a.b.c",
            "01.2.3", "1.02.3", "-1.2.3", "1.2.-3", "1.2.3-", "1.2.3-beta..1",
            "1.2.3-beta.01", "1.2.3+", "1.2.3-bet a", "1.2.3 4"
        ]
    )
    func rejectsMalformed(input: String) {
        #expect(throws: (any Error).self) { try SemVer(parsing: input) }
        #expect(SemVer(input) == nil)
    }

    @Test("build metadata may carry leading zeroes")
    func buildAllowsLeadingZeroes() throws {
        let version = try SemVer(parsing: "1.0.0+007")
        #expect(version.build == ["007"])
    }

    @Test(
        "orders by precedence",
        arguments: [
            ("1.0.0", "2.0.0"),
            ("2.0.0", "2.1.0"),
            ("2.1.0", "2.1.1"),
            ("0.15.5", "0.15.6"),
            ("0.9.0", "0.10.0"),
            ("2.9.6", "2.10.0"),
            // A prerelease precedes its release.
            ("1.0.0-alpha", "1.0.0"),
            ("1.0.0-alpha", "1.0.0-alpha.1"),
            ("1.0.0-alpha.1", "1.0.0-alpha.beta"),
            ("1.0.0-alpha.beta", "1.0.0-beta"),
            ("1.0.0-beta", "1.0.0-beta.2"),
            ("1.0.0-beta.2", "1.0.0-beta.11"),
            ("1.0.0-beta.11", "1.0.0-rc.1"),
            ("1.0.0-rc.1", "1.0.0")
        ]
    )
    func ordersAscending(lower: String, higher: String) throws {
        let low = try SemVer(parsing: lower)
        let high = try SemVer(parsing: higher)
        #expect(low < high)
        #expect(high > low)
        #expect(!(high < low))
    }

    @Test("build metadata does not affect precedence")
    func buildIgnoredInPrecedence() throws {
        let a = try SemVer(parsing: "1.0.0+one")
        let b = try SemVer(parsing: "1.0.0+two")
        #expect(!(a < b))
        #expect(!(b < a))
        #expect(a.hasSamePrecedence(as: b))
        // Equatable is stricter on purpose: the values stay distinguishable.
        #expect(a != b)
    }

    @Test("sorts a release history")
    func sorts() throws {
        let input = ["v1.0.0", "0.1.0", "1.0.0-rc.1", "v0.15.6", "2.0.0", "0.9.1"]
        let sorted = input.compactMap(SemVer.init).sorted().map(\.description)
        #expect(sorted == ["0.1.0", "0.9.1", "0.15.6", "1.0.0-rc.1", "1.0.0", "2.0.0"])
    }

    @Test("round-trips through Codable")
    func codable() throws {
        let versions = ["0.1.0", "1.2.3-beta.1", "2.9.6+ci.4"].compactMap(SemVer.init)
        let data = try JSONEncoder().encode(versions)
        #expect(String(data: data, encoding: .utf8) == #"["0.1.0","1.2.3-beta.1","2.9.6+ci.4"]"#)
        #expect(try JSONDecoder().decode([SemVer].self, from: data) == versions)
    }

    @Test("rejects an invalid version when decoding")
    func codableRejectsInvalid() {
        let data = Data(#"["not a version"]"#.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode([SemVer].self, from: data)
        }
    }

    @Test("the versions this project pins are parseable and ordered")
    func pinnedDependencyVersions() throws {
        // Guards the assumption in project.yml: both pins are real releases, and the
        // app version is below them in neither a confusing nor a meaningful way.
        let fluidAudio = try SemVer(parsing: "v0.15.6")
        let sparkle = try SemVer(parsing: "2.9.6")
        #expect(fluidAudio.description == "0.15.6")
        #expect(sparkle.description == "2.9.6")
        #expect(try SemVer(parsing: "0.1.0") < fluidAudio)
    }
}
