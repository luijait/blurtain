import AppKit
import CoreGraphics
import ScreenCaptureKit
import Vision

// Standalone harness: captures each sensitive window, runs the SAME detector
// as the app, writes annotated PNGs to the given directory (default: CWD).
// Usage: ./debugviz [outdir]

@main
enum DebugViz {
    static func main() async {
        let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
        let blurIDs: Set<String> = ["com.googlecode.iterm2", "com.mitchellh.ghostty", "com.apple.Terminal", "com.tinyspeck.slackmacgap"]
        let terminalIDs: Set<String> = ["com.googlecode.iterm2", "com.mitchellh.ghostty", "com.apple.Terminal"]

        print("preflight=\(CGPreflightScreenCaptureAccess())")
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let targets = content.windows.filter {
                guard let app = $0.owningApplication else { return false }
                return blurIDs.contains(app.bundleIdentifier) && $0.windowLayer == 0 && $0.frame.width >= 40
            }
            print("targets=\(targets.count)")
            let p = DetectorParams()
            for win in targets {
                let bid = win.owningApplication?.bundleIdentifier ?? "?"
                let sz = CGSize(width: win.frame.width, height: win.frame.height)
                let filter = SCContentFilter(desktopIndependentWindow: win)
                let cfg = SCStreamConfiguration()
                cfg.width = max(64, Int(sz.width * 2))
                cfg.height = max(64, Int(sz.height * 2))
                cfg.showsCursor = false
                guard let img = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg) else {
                    print("\(bid)#\(win.windowID): capture FAILED")
                    continue
                }
                let (dets, method, workImg) = detectTextRects(img: img, size: sz, isTerminal: terminalIDs.contains(bid), p: p)
                let name = bid.split(separator: ".").last.map(String.init) ?? bid
                let url = outDir.appendingPathComponent("viz_\(name)_\(win.windowID).png")
                saveAnnotated(workImg, dets: dets, size: sz, to: url)
                print("\(bid)#\(win.windowID) [\(Int(sz.width))x\(Int(sz.height))]: \(method) → \(url.lastPathComponent)")
            }
        } catch {
            print("ERR: \(error)")
        }
    }
}
