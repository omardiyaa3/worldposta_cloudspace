import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }
}

/// The app's Flutter view controller (Main.storyboard). On the iPhone Duo's
/// outer screen the status bar and front camera sit in a bubble in the top
/// corner; iOS reports it as an "occlusion" reserved region, not as safe area,
/// and Flutter only knows the safe area. Move the safe area's top edge below
/// any active occlusion at the top, so the app's bars sit under the bubble —
/// where Apple's own toolbars go on this device. No-op on other iPhones/iPads.
class RunnerViewController: FlutterViewController {
  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    avoidTopOcclusions()
  }

  override func viewSafeAreaInsetsDidChange() {
    super.viewSafeAreaInsetsDidChange()
    avoidTopOcclusions()
  }

  private func avoidTopOcclusions() {
    guard #available(iOS 27.1, *) else { return }
    let bounds = view.bounds
    guard bounds.height > 0 else { return }
    // The system's own top inset, without what we added last time.
    let systemTop = view.safeAreaInsets.top - additionalSafeAreaInsets.top
    var bottom = systemTop
    for region in view.reservedRegions(kind: .occlusion) where region.isActive {
      // Only regions at the top of the screen (status / camera bubble).
      guard region.frame.minY < bounds.height * 0.25 else { continue }
      bottom = max(bottom, region.frame.maxY)
    }
    let extra = max(0, (bottom - systemTop).rounded(.up))
    if abs(additionalSafeAreaInsets.top - extra) > 0.5 {
      additionalSafeAreaInsets.top = extra
    }
  }
}
