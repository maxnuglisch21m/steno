#if DEBUG
import AppKit
import Foundation
import StenoCore

/// Launch arguments that drive the app from the outside, so the M0 flow can be checked
/// without a meeting, a microphone, or a click.
///
/// Debug builds only. They exist because the interesting part of M0 — folder created,
/// `meta.json` written at every state change, the icon and the clock, the hotkey path
/// — is otherwise only reachable by hand, and a release build has no business
/// accepting instructions from its command line.
///
/// ```sh
/// open build/Build/Products/Debug/Steno.app --args --simulate-recording 3 onsite
/// open build/Build/Products/Debug/Steno.app --args --open-settings
/// open build/Build/Products/Debug/Steno.app --args --open-onboarding
/// ```
struct DebugLaunchArguments {
    var openSettings = false
    var openOnboarding = false
    /// Seconds to record, and in which mode, before quitting.
    var simulate: (seconds: Double, mode: MeetingMode)?

    var isActive: Bool { openSettings || openOnboarding || simulate != nil }

    init(_ arguments: [String]) {
        var index = 1
        while index < arguments.count {
            switch arguments[index] {
            case "--open-settings":
                openSettings = true
            case "--open-onboarding":
                openOnboarding = true
            case "--simulate-recording":
                let seconds = Double(arguments[safe: index + 1] ?? "") ?? 3
                let mode = MeetingMode(rawValue: arguments[safe: index + 2] ?? "") ?? .onsite
                simulate = (seconds, mode)
                index += 2
            default:
                break
            }
            index += 1
        }
    }

    @MainActor
    func run(in environment: AppEnvironment) {
        if openOnboarding {
            OnboardingWindowController.shared.show(environment: environment)
        }
        if openSettings {
            SettingsWindowController.shared.show(environment: environment)
        }
        if openSettings || openOnboarding {
            // Report what actually appeared, so the verification does not depend on
            // being able to look at the screen.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                // Class name, title, and size, because a status item brings windows
                // of its own along and only the size tells them apart at a glance.
                let described = NSApp.windows
                    .filter(\.isVisible)
                    .map { "\(type(of: $0))“\($0.title)”\(Int($0.frame.width))x\(Int($0.frame.height))" }
                let line = "steno-debug: windows: \(described.joined(separator: " | "))\n"
                Log.app.notice("debug: \(line, privacy: .public)")
                FileHandle.standardError.write(Data(line.utf8))
            }
        }
        guard let simulate else { return }
        runSimulation(simulate, in: environment)
    }

    @MainActor
    private func runSimulation(
        _ simulate: (seconds: Double, mode: MeetingMode),
        in environment: AppEnvironment
    ) {
        Task { @MainActor in
            // The permission snapshot has to be in before `canStart` is asked, or the
            // simulation would refuse itself.
            await environment.permissions.refresh()
            environment.appState.permissions = environment.permissions.snapshot

            // The simulation exercises the flow, not the permission gate; the gate has
            // its own tests. Pretending the three TCC answers are in place is what
            // makes this runnable on a machine that has never been asked.
            var snapshot = environment.appState.permissions
            snapshot.microphone = .granted
            snapshot.systemAudio = .granted
            snapshot.screenRecording = .granted
            environment.appState.permissions = snapshot

            environment.coordinator.start(mode: simulate.mode, trigger: .manual)
            try? await Task.sleep(for: .seconds(simulate.seconds))
            let folder = environment.appState.phase.isRecording
                ? nil
                : environment.appState.lastMeetingURL
            environment.coordinator.stop()
            // Give the stop path its turn on the main actor before quitting.
            try? await Task.sleep(for: .milliseconds(500))

            let result = environment.appState.lastMeetingURL ?? folder
            let line = "steno-debug: simulated \(simulate.mode.rawValue) recording → \(result?.stenoPath ?? "nothing")\n"
            Log.app.notice("debug: \(line, privacy: .public)")
            FileHandle.standardError.write(Data(line.utf8))
            NSApp.terminate(nil)
        }
    }
}

private extension Array where Element == String {
    subscript(safe index: Int) -> String? {
        indices.contains(index) ? self[index] : nil
    }
}
#endif
