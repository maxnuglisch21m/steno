import FluidAudio
import Foundation
import Sparkle
import StenoCore

/// Touches one symbol from each dependency, so that a build failure here is what a
/// broken package pin looks like — rather than a link error in the first milestone
/// that happens to need transcription or updates.
///
/// The real users of these packages arrive later: `Update/UpdaterController` (M7)
/// and `Transcription/`.
enum Dependencies {
    /// The updater controller class Sparkle exposes to app code.
    static let updaterControllerType: any AnyObject.Type = SPUStandardUpdaterController.self

    /// The recognizer configuration FluidAudio exposes. `seamGapRepair` stays on, its
    /// default, because Parakeet's 15 s decoding windows drop and duplicate words at
    /// the seams without it.
    static let asrConfiguration = ASRConfig.default

    /// The framework-free logic package.
    static let coreScreenshotThresholds = ScreenshotGateConfig.default

    /// A one-line description of what the app is built against, for the settings
    /// window and for bug reports.
    static var summary: String {
        """
        Steno \(AppVersion.marketing) (\(AppVersion.build)) · \
        FluidAudio \(fluidAudioVersion) · Sparkle \(sparkleVersion)
        """
    }

    /// Sparkle's version, read off the framework that is actually loaded.
    ///
    /// Read rather than written down, because a version string that has to be kept in
    /// step by hand is a version string that is eventually wrong — and this one appears
    /// in bug reports, where being wrong is worse than being absent. `Sparkle.framework`
    /// is inside the app bundle and carries its own `CFBundleShortVersionString`; the
    /// pinned literal is only the fallback for a build where the bundle cannot be found.
    static let sparkleVersion: String = {
        let bundle = Bundle(for: SPUStandardUpdaterController.self)
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return version ?? pinnedSparkleVersion
    }()

    /// FluidAudio's version.
    ///
    /// A literal, unlike Sparkle's. FluidAudio is a static SwiftPM product rather than a
    /// framework: it has no bundle of its own inside the app, and it exposes no version
    /// constant to read — searched for, and there is none as of 0.15.6. `Package.resolved`
    /// has the number but is not copied into the app. So this is kept in step with
    /// `project.yml`'s `exactVersion` by hand, and the pin being exact is what makes that
    /// safe: changing it is a deliberate edit in one file, which is the moment to change
    /// this one too.
    static let fluidAudioVersion = "0.15.6"

    /// What `project.yml` pins Sparkle to. Only used when the framework cannot be read.
    static let pinnedSparkleVersion = "2.9.6"
}
