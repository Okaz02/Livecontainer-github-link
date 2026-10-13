import SwiftUI

@main
struct LiveContainerSwiftUIApp: SwiftUI.App {
    init() {
        // iOS が更新されたら、中核の dyld フックが使うシンボル位置のキャッシュを消す
        let defaults = UserDefaults(suiteName: LCSharedUtils.appGroupID()) ?? .standard
        let build = UIDevice.current.buildVersion
        if defaults.string(forKey: "LCLastIOSBuildVersion") != build {
            defaults.removeObject(forKey: "symbolOffsetCache")
            defaults.set(build, forKey: "LCLastIOSBuildVersion")
        }
    }

    var body: some Scene {
        WindowGroup {
            GHRootView()
        }
    }
}
