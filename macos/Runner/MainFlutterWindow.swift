import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController

    // A full-height window: the sidebar runs under the traffic lights, like
    // Xcode and Finder, instead of a grey title bar above everything.
    self.styleMask.insert(.fullSizeContentView)
    self.titlebarAppearsTransparent = true
    self.titleVisibility = .hidden
    self.isMovableByWindowBackground = true
    self.minSize = NSSize(width: 980, height: 640)
    self.setFrame(NSRect(x: 0, y: 0, width: 1280, height: 820), display: true)
    self.center()

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
