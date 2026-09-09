import Foundation

/// What kind of process this is.
///
/// The test bundle is hosted by the app itself, so `applicationDidFinishLaunching`
/// runs before the first test does and every side effect the app has at launch would
/// happen on the machine running the tests. Two of those are worth refusing outright:
/// creating the user's recording folder and registering global hotkeys — and, since
/// M4, capturing the tester's screen.
enum RunningEnvironment {
    /// Whether this process was launched to run the test bundle.
    static var isUnitTesting: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }
}
