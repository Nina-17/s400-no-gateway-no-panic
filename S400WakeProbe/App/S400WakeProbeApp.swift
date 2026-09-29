import SwiftUI
import UIKit

@main
struct S400WakeProbeApp: App {
    @UIApplicationDelegateAdaptor(ProbeAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if CaptureAnalyzer.requested {
                Text("离线协议分析\n未连接体脂秤").multilineTextAlignment(.center)
            } else {
                ProbeView(probe: WakeProbe.shared)
            }
            #else
            ProbeView(probe: WakeProbe.shared)
            #endif
        }
    }
}

final class ProbeAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        #if DEBUG
        if CaptureAnalyzer.requested {
            CaptureAnalyzer.run()
            return true
        }
        #endif
        WakeProbe.shared.launched(restorationIdentifiers: launchOptions?[.bluetoothCentrals] as? [String] ?? [])
        // SwiftUI uses scenes, so use application notifications rather than relying
        // only on legacy app-delegate background/foreground callbacks.
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(background), name: UIApplication.didEnterBackgroundNotification, object: nil)
        center.addObserver(self, selector: #selector(active), name: UIApplication.didBecomeActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(protectedAvailable), name: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil)
        center.addObserver(self, selector: #selector(protectedUnavailable), name: UIApplication.protectedDataWillBecomeUnavailableNotification, object: nil)
        return true
    }

    @objc private func background() { WakeProbe.shared.didEnterBackground() }
    @objc private func active() { WakeProbe.shared.didBecomeActive() }
    @objc private func protectedAvailable() { WakeProbe.shared.protectedDataChanged(available: true) }
    @objc private func protectedUnavailable() { WakeProbe.shared.protectedDataChanged(available: false) }
}
