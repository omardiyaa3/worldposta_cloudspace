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
/// and Flutter only knows the safe area. Two things happen here:
///  - the safe area's top edge moves below the bubble, so nothing is drawn
///    under it (the app's bars sit below it, as Apple's toolbars do);
///  - the bubble's frame is sent to Flutter ("posta/reserved_regions"), so the
///    app can use the space beside it (a large page title) instead of leaving
///    it empty.
/// No-op on devices without such a region.
class RunnerViewController: FlutterViewController {
  private var channel: FlutterMethodChannel?
  private var lastSent: [String: Double] = [:]

  override func viewDidLoad() {
    super.viewDidLoad()
    channel = FlutterMethodChannel(name: "posta/reserved_regions", binaryMessenger: binaryMessenger)
    channel?.setMethodCallHandler { [weak self] call, result in
      if call.method == "current" { result(self?.lastSent.isEmpty == false ? self?.lastSent : nil) } else { result(FlutterMethodNotImplemented) }
    }
  }

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
    var region: CGRect?
    for r in view.reservedRegions(kind: .occlusion) where r.isActive {
      // Only regions at the top of the screen (status / camera bubble).
      guard r.frame.minY < bounds.height * 0.25 else { continue }
      region = region.map { $0.union(r.frame) } ?? r.frame
    }
    let extra = max(0, ((region?.maxY ?? systemTop) - systemTop).rounded(.up))
    if abs(additionalSafeAreaInsets.top - extra) > 0.5 {
      additionalSafeAreaInsets.top = extra
    }
    var info: [String: Double] = [:]
    if let r = region, extra > 0 {
      info = ["left": r.minX, "top": r.minY, "right": r.maxX, "bottom": r.maxY,
              "systemTop": systemTop, "extraTop": extra, "width": bounds.width, "height": bounds.height]
    }
    if info != lastSent {
      lastSent = info
      channel?.invokeMethod("changed", arguments: info.isEmpty ? nil : info)
    }
  }
}
