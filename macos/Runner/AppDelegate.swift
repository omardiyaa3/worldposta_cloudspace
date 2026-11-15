import Cocoa
import FlutterMacOS
import app_links

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  // Closing the window only hides it (sync keeps running); clicking the Dock
  // icon brings it back, as Mac users expect.
  override func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    if !flag, let window = mainFlutterWindow {
      window.makeKeyAndOrderFront(self)
      NSApp.activate(ignoringOtherApps: true)
    }
    return true
  }

  // Drive file links (https://drive.worldposta.com/file/<id>) from Safari,
  // Mail, Link…: macOS delivers them here as a "browsing web" activity, which
  // the app_links plugin doesn't receive on its own. Hand the link over (the
  // app opens the file) and show the window if it was closed to the menu bar.
  override func application(_ application: NSApplication, continue userActivity: NSUserActivity,
                            restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void) -> Bool {
    guard let url = AppLinks.shared.getUniversalLink(userActivity) else { return false }
    AppLinks.shared.handleLink(link: url.absoluteString)
    if let window = mainFlutterWindow, !window.isVisible {
      window.makeKeyAndOrderFront(self)
    }
    NSApp.activate(ignoringOtherApps: true)
    return true
  }
}
