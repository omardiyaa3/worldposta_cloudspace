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
    self.title = "CloudSpace"

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }

  override public func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
    super.order(place, relativeTo: otherWin)
    hiddenWindowAtLaunch()
  }
}
