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

    static let fluidAudioVersion = "0.15.6"
    static let sparkleVersion = "2.9.6"
}
