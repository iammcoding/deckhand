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
    self.minSize = NSSize(width: 980, height: 640)
    self.setFrame(NSRect(x: 0, y: 0, width: 1280, height: 820), display: true)
    self.center()

    RegisterGeneratedPlugins(registry: flutterViewController)

    // The title bar is drawn by Flutter, so it asks the window to move.
    let channel = FlutterMethodChannel(name: "deckhand/window", binaryMessenger: flutterViewController.engine.binaryMessenger)
    channel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "drag":
        if let e = NSApp.currentEvent { self?.performDrag(with: e) }
        result(nil)
      case "zoom":
        self?.zoom(nil)
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    super.awakeFromNib()
  }
}
