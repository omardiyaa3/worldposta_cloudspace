import Cocoa
import FlutterMacOS
import window_manager

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = NSRect(x: 0, y: 0, width: 1280, height: 800)
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)
    self.center()
    self.minSize = NSSize(width: 400, height: 300)
    self.title = "Posta Drive"

    RegisterGeneratedPlugins(registry: flutterViewController)
    FolderAccess.register(with: flutterViewController.engine.binaryMessenger)

    super.awakeFromNib()
  }

  override public func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
    super.order(place, relativeTo: otherWin)
    hiddenWindowAtLaunch()
  }
}

/// Sandbox access to the user's chosen sync folder across launches
/// (security-scoped bookmarks). The app is sandboxed (Mac App Store), so a
/// folder picked in the open panel is only reachable until the app quits
/// unless we keep a bookmark to it.
enum FolderAccess {
  static func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "posta/folder_access", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      let arg = call.arguments as? String ?? ""
      switch call.method {
      case "bookmark":
        // Called right after the user picked the folder, while we hold access.
        do {
          let data = try URL(fileURLWithPath: arg).bookmarkData(
            options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
          result(data.base64EncodedString())
        } catch {
          result(FlutterError(code: "bookmark", message: error.localizedDescription, details: nil))
        }
      case "resolve":
        // Resolve a stored bookmark and start (and keep) access for this run.
        guard let data = Data(base64Encoded: arg) else { result(nil); return }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope,
                                 relativeTo: nil, bookmarkDataIsStale: &stale),
              url.startAccessingSecurityScopedResource() else { result(nil); return }
        var refreshed: String? = nil
        if stale {
          refreshed = (try? url.bookmarkData(options: .withSecurityScope,
            includingResourceValuesForKeys: nil, relativeTo: nil))?.base64EncodedString()
        }
        result(["path": url.path, "bookmark": refreshed ?? arg])
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}
