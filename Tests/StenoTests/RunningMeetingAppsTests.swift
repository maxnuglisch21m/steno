import Foundation
import StenoCore
import Testing

@testable import Steno

/// Choosing what an `online` recording taps.
///
/// The filter is pure, so all of it is tested against process lists written by hand.
/// Nothing here talks to Core Audio; `RunningMeetingApps.current()` is the only part
/// that does, and it has a Mac for a fixture.
@Suite("RunningMeetingApps")
struct RunningMeetingAppsTests {
    private static let watchlist: [WatchedApp] = [
        WatchedApp(bundleId: "com.microsoft.teams2", name: "Teams"),
        WatchedApp(bundleId: "us.zoom.xos", name: "Zoom"),
        WatchedApp(bundleId: "com.google.Chrome", name: "Chrome")
    ]

    private static func process(
        _ bundleId: String?,
        pid: pid_t = 100,
        input: Bool = true
    ) -> AudioProcessDescriptor {
        AudioProcessDescriptor(pid: pid, bundleId: bundleId, isRunningInput: input)
    }

    @Test("one watchlist app reading input is the target")
    func singleMatch() throws {
        let processes = [
            Self.process("com.apple.Music", pid: 10),
            Self.process("com.microsoft.teams2", pid: 42)
        ]
        let match = try #require(RunningMeetingApps.soleMatch(in: processes, watchlist: Self.watchlist))
        #expect(match.app.name == "Teams")
        #expect(match.process.pid == 42)
        #expect(
            RunningMeetingApps.target(in: processes, watchlist: Self.watchlist)
                == .process(pid: 42, bundleId: "com.microsoft.teams2", name: "Teams")
        )
    }

    @Test("an app that is not reading input is not in a meeting")
    func ignoresIdleApps() {
        let processes = [Self.process("com.microsoft.teams2", pid: 42, input: false)]
        #expect(RunningMeetingApps.matches(in: processes, watchlist: Self.watchlist).isEmpty)
        #expect(RunningMeetingApps.target(in: processes, watchlist: Self.watchlist) == .systemWide)
    }

    @Test("an app that is not on the watchlist is not in a meeting either")
    func ignoresUnwatchedApps() {
        let processes = [Self.process("com.apple.FaceTime", pid: 7)]
        #expect(RunningMeetingApps.matches(in: processes, watchlist: Self.watchlist).isEmpty)
        #expect(RunningMeetingApps.target(in: processes, watchlist: Self.watchlist) == .systemWide)
    }

    @Test("two watchlist apps at once are ambiguous, so the tap goes system-wide")
    func ambiguityFallsBack() {
        let processes = [
            Self.process("com.microsoft.teams2", pid: 42),
            Self.process("us.zoom.xos", pid: 43)
        ]
        #expect(RunningMeetingApps.matches(in: processes, watchlist: Self.watchlist).count == 2)
        #expect(RunningMeetingApps.soleMatch(in: processes, watchlist: Self.watchlist) == nil)
        #expect(RunningMeetingApps.target(in: processes, watchlist: Self.watchlist) == .systemWide)
    }

    @Test("one app with several audio processes still counts once")
    func collapsesHelperProcesses() throws {
        // A browser runs its audio in a helper; both carry the same bundle identifier,
        // and both reading input is one meeting, not two.
        let processes = [
            Self.process("com.google.Chrome", pid: 500),
            Self.process("com.google.Chrome", pid: 501)
        ]
        let match = try #require(RunningMeetingApps.soleMatch(in: processes, watchlist: Self.watchlist))
        #expect(match.app.bundleId == "com.google.Chrome")
        #expect(match.process.pid == 500)
    }

    @Test("processes without a bundle identifier are skipped")
    func ignoresBundleLessProcesses() {
        let processes = [Self.process(nil, pid: 3), Self.process(nil, pid: 4)]
        #expect(RunningMeetingApps.matches(in: processes, watchlist: Self.watchlist).isEmpty)
    }

    @Test("an empty watchlist matches nothing")
    func emptyWatchlist() {
        let processes = [Self.process("com.microsoft.teams2", pid: 42)]
        #expect(RunningMeetingApps.target(in: processes, watchlist: []) == .systemWide)
    }

    @Test("matches come back in watchlist order, not process order")
    func watchlistOrder() {
        let processes = [
            Self.process("com.google.Chrome", pid: 3),
            Self.process("com.microsoft.teams2", pid: 1)
        ]
        let matches = RunningMeetingApps.matches(in: processes, watchlist: Self.watchlist)
        #expect(matches.map(\.app.bundleId) == ["com.microsoft.teams2", "com.google.Chrome"])
    }

    // MARK: - Forcing a target

    @Test("a forced target does not have to be reading input")
    func forcedTarget() {
        let processes = [Self.process("com.apple.Music", pid: 900, input: false)]
        #expect(
            RunningMeetingApps.target(forBundleId: "com.apple.Music", in: processes, watchlist: Self.watchlist)
                == .process(pid: 900, bundleId: "com.apple.Music", name: "Music")
        )
    }

    @Test("a forced target on the watchlist keeps the watchlist's name")
    func forcedTargetUsesWatchlistName() {
        let processes = [Self.process("us.zoom.xos", pid: 12, input: false)]
        #expect(
            RunningMeetingApps.target(forBundleId: "us.zoom.xos", in: processes, watchlist: Self.watchlist)
                == .process(pid: 12, bundleId: "us.zoom.xos", name: "Zoom")
        )
    }

    @Test("forcing a target that has no audio process at all fails rather than guessing")
    func forcedTargetMissing() {
        #expect(RunningMeetingApps.target(forBundleId: "com.example.nothing", in: [], watchlist: Self.watchlist) == nil)
    }

    // MARK: - The tap target itself

    @Test("a process target carries the app into the folder name and meta.trigger")
    func targetCarriesTheApp() {
        let target = TapTarget.process(pid: 1, bundleId: "com.microsoft.teams2", name: "Teams")
        #expect(target.appName == "Teams")
        #expect(target.bundleId == "com.microsoft.teams2")
        // No app name is what makes the folder `…_Online`.
        #expect(TapTarget.systemWide.appName == nil)
        #expect(TapTarget.systemWide.bundleId == nil)
        #expect(RecordingFolderName.label(mode: .online, appName: TapTarget.systemWide.appName) == "Online")
        #expect(RecordingFolderName.label(mode: .online, appName: target.appName) == "Teams")
    }

    @Test("the real process list can be read on this Mac")
    func readsTheRealList() {
        // Not an assertion about what is running — only that the HAL answers and the
        // property reads line up. A Mac always has audio processes.
        let processes = RunningMeetingApps.current()
        #expect(!processes.isEmpty)
        #expect(processes.allSatisfy { $0.pid > 0 })
    }
}
