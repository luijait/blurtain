import AppKit
import CoreGraphics
import ScreenCaptureKit
import Vision

// ── Config (editable without recompiling: ~/.config/blurtain/config.json) ────
struct Config: Codable {
    var blurBundleIDs = ["com.googlecode.iterm2", "com.mitchellh.ghostty", "com.apple.Terminal", "com.tinyspeck.slackmacgap"]
    var terminalBundleIDs = ["com.googlecode.iterm2", "com.mitchellh.ghostty", "com.apple.Terminal"]
    var colorAlpha: Double = 1.0 // 1.0 = fully opaque bars (true redaction; lower = translucent, recoverable in theory)
    var colorFromText: Bool = true // tint bars with the censored text's average color; false = neutral gray
    var padX: Double = 2
    var padY: Double = 1
    var rowDiffThreshold: Int = 90
    var minRowPixels: Int = 2
    var mergeGapX: Double = 24
    var detectInterval: Double = 0.25
    var captureScale: Double = 2
    var debug: Bool = true

    init() {}

    enum CodingKeys: String, CodingKey {
        case blurBundleIDs, terminalBundleIDs, colorAlpha, colorFromText, padX, padY,
             rowDiffThreshold, minRowPixels, mergeGapX, detectInterval, captureScale, debug
    }

    init(from decoder: Decoder) throws {
        let d = Config()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        blurBundleIDs = try c.decodeIfPresent([String].self, forKey: .blurBundleIDs) ?? d.blurBundleIDs
        terminalBundleIDs = try c.decodeIfPresent([String].self, forKey: .terminalBundleIDs) ?? d.terminalBundleIDs
        colorAlpha = try c.decodeIfPresent(Double.self, forKey: .colorAlpha) ?? d.colorAlpha
        colorFromText = try c.decodeIfPresent(Bool.self, forKey: .colorFromText) ?? d.colorFromText
        padX = try c.decodeIfPresent(Double.self, forKey: .padX) ?? d.padX
        padY = try c.decodeIfPresent(Double.self, forKey: .padY) ?? d.padY
        rowDiffThreshold = try c.decodeIfPresent(Int.self, forKey: .rowDiffThreshold) ?? d.rowDiffThreshold
        minRowPixels = try c.decodeIfPresent(Int.self, forKey: .minRowPixels) ?? d.minRowPixels
        mergeGapX = try c.decodeIfPresent(Double.self, forKey: .mergeGapX) ?? d.mergeGapX
        detectInterval = try c.decodeIfPresent(Double.self, forKey: .detectInterval) ?? d.detectInterval
        captureScale = try c.decodeIfPresent(Double.self, forKey: .captureScale) ?? d.captureScale
        debug = try c.decodeIfPresent(Bool.self, forKey: .debug) ?? d.debug
    }
}

let configURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".config/blurtain/config.json")
let logURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Logs/Blurtain.log")
let dumpDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Logs/Blurtain")

func loadConfig() -> Config {
    if let d = try? Data(contentsOf: configURL), let c = try? JSONDecoder().decode(Config.self, from: d) {
        return c
    }
    let c = Config()
    try? FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let d = try? enc.encode(c) { try? d.write(to: configURL) }
    return c
}

var cfg = loadConfig()

let logFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f }()
func log(_ s: String) {
    guard cfg.debug else { return }
    let line = "[\(logFmt.string(from: Date()))] \(s)\n"
    if let h = FileHandle(forWritingAtPath: logURL.path) {
        h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
    } else {
        try? line.data(using: .utf8)?.write(to: logURL)
    }
}

struct WinRect { let id: CGWindowID; let bid: String; let rect: CGRect }

var pidToBundle: [pid_t: String] = [:]
func bundleID(forPID pid: pid_t) -> String {
    if let b = pidToBundle[pid] { return b }
    let b = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "?"
    pidToBundle[pid] = b
    return b
}

func sensitiveWindowRects() -> [WinRect] {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
    var out: [WinRect] = []
    for info in list {
        guard let pid = info[kCGWindowOwnerPID as String] as? Int,
              (info[kCGWindowLayer as String] as? Int) == 0,
              let num = info[kCGWindowNumber as String] as? Int,
              let b = info[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
        let bid = bundleID(forPID: pid_t(pid))
        guard cfg.blurBundleIDs.contains(bid) else { continue }
        let r = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
        if r.width < 40 || r.height < 40 { continue }
        out.append(WinRect(id: CGWindowID(num), bid: bid, rect: r))
    }
    return out
}

final class OverlayWindow: NSWindow {
    let blurView = NSVisualEffectView()
    let colorsView = NSView()

    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.floatingWindow)) + 1)

        blurView.frame = contentView!.bounds
        blurView.autoresizingMask = [.width, .height]
        blurView.material = .hudWindow
        blurView.blendingMode = .behindWindow
        blurView.state = .active
        contentView!.addSubview(blurView)

        colorsView.frame = contentView!.bounds
        colorsView.autoresizingMask = [.width, .height]
        colorsView.wantsLayer = true
        contentView!.addSubview(colorsView)
    }

    // Blur + color bars ONLY inside the given rects (local bottom-left coords).
    // Each bar is tinted with the average color of the text it hides.
    func applyBlurRects(_ items: [(CGRect, CGColor?)], alpha: CGFloat) {
        let size = frame.size
        let mask = NSImage(size: size, flipped: false) { _ in
            NSColor.black.setFill()
            for (r, _) in items { r.fill() }
            return true
        }
        mask.capInsets = NSEdgeInsetsZero
        blurView.maskImage = mask

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        colorsView.layer?.sublayers?.forEach { $0.removeFromSuperlayer() }
        let fallback = CGColor(gray: 0.4, alpha: 1)
        for (r, c) in items {
            let l = CALayer()
            l.frame = r
            // Rounded corners would leave sub-pixel slivers at the corners
            // where only blur covers the text; with opaque bars stay square
            // so coverage is exact.
            l.cornerRadius = alpha >= 0.999 ? 0 : min(4, r.height / 2)
            let base = c ?? fallback
            l.backgroundColor = base.copy(alpha: alpha) ?? base
            colorsView.layer?.addSublayer(l)
        }
        CATransaction.commit()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var overlays: [OverlayWindow] = []
    var timer: Timer?
    var active = false
    // Detected rects per window, relative to window top-left, in points.
    // Present-but-empty = analyzed, no text. Absent = not analyzed (fail closed).
    var textRects: [CGWindowID: [DetectedRect]] = [:]
    var detecting = false
    var lastDetect = Date.distantPast
    var lastToggle = Date.distantPast
    var warnedNoPermission = false
    var analyzed = false

    var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    func applicationDidFinishLaunching(_ n: Notification) {
        try? FileManager.default.createDirectory(at: dumpDir, withIntermediateDirectories: true)
        log("launch: permission=\(hasPermission) cfg=\(configURL.path)")
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let btn = statusItem.button {
            btn.action = #selector(clicked(_:))
            btn.target = self
            btn.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        updateIcon()
        if !hasPermission { CGRequestScreenCaptureAccess() }
    }

    func updateIcon() {
        var base = active ? "🙈" : "🙉"
        if active && !analyzed { base += "⏳" }
        statusItem.button?.title = hasPermission ? base : base + "⚠︎"
    }

    @objc func clicked(_ sender: Any?) {
        if let ev = NSApp.currentEvent, ev.type == .rightMouseUp {
            let menu = NSMenu()
            menu.addItem(withTitle: active ? "Desactivar censura" : "Activar censura", action: #selector(toggle), keyEquivalent: "")
            if !hasPermission {
                menu.addItem(withTitle: "⚠︎ Falta permiso de Grabación de pantalla…", action: #selector(openPrivacy), keyEquivalent: "")
            }
            menu.addItem(withTitle: "Reiniciar Blurtain", action: #selector(restartApp), keyEquivalent: "")
            menu.addItem(.separator())
            menu.addItem(withTitle: "Salir", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            for it in menu.items where it.action != #selector(NSApplication.terminate(_:)) { it.target = self }
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            toggle()
        }
    }

    @objc func openPrivacy() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    @objc func restartApp() {
        let path = Bundle.main.bundlePath
        let p = Process()
        p.launchPath = "/bin/sh"
        p.arguments = ["-c", "sleep 0.5; /usr/bin/open -n \"\(path)\""]
        try? p.run()
        NSApp.terminate(nil)
    }

    @objc func toggle() {
        // Debounce: a double-click would otherwise activate and instantly deactivate.
        guard Date().timeIntervalSince(lastToggle) > 0.5 else { return }
        lastToggle = Date()
        active ? deactivate() : activate()
    }

    func activate() {
        cfg = loadConfig()
        active = true
        analyzed = false
        textRects = [:]
        log("activate: permission=\(hasPermission)")
        if !hasPermission {
            CGRequestScreenCaptureAccess()
            if !warnedNoPermission {
                warnedNoPermission = true
                let a = NSAlert()
                a.messageText = "Blurtain no tiene permiso de Grabación de pantalla"
                a.informativeText = "Sin él no puede localizar el texto y cubre las ventanas ENTERAS (modo seguro).\n\n1. Abre Ajustes y activa Blurtain en «Grabación de pantalla y audio del sistema».\n2. Vuelve al icono → clic derecho → «Reiniciar Blurtain»."
                a.addButton(withTitle: "Abrir Ajustes")
                a.addButton(withTitle: "Seguir igualmente")
                NSApp.activate(ignoringOtherApps: true)
                if a.runModal() == .alertFirstButtonReturn { openPrivacy() }
            }
        }
        updateIcon()
        overlays = NSScreen.screens.map { OverlayWindow(screen: $0) }
        overlays.forEach { $0.orderFrontRegardless() }
        refreshOverlays()
        timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            self?.refreshOverlays()
            self?.runDetectionIfDue()
        }
        RunLoop.main.add(timer!, forMode: .common)
        runDetectionIfDue()
    }

    func deactivate() {
        active = false
        log("deactivate")
        updateIcon()
        timer?.invalidate(); timer = nil
        overlays.forEach { $0.orderOut(nil) }
        overlays = []
        textRects = [:]
    }

    // Fast path: reposition known rects to current window positions.
    func refreshOverlays() {
        let wins = sensitiveWindowRects()
        let mainH = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height ?? NSScreen.main?.frame.height ?? 0
        var global: [(CGRect, CGColor?)] = [] // CG top-left coords
        let useColors = cfg.colorFromText
        for w in wins {
            if let dets = textRects[w.id] {
                for d in dets {
                    global.append((CGRect(x: w.rect.origin.x + d.rect.origin.x,
                                          y: w.rect.origin.y + d.rect.origin.y,
                                          width: d.rect.width, height: d.rect.height),
                                   useColors ? d.color : nil))
                }
            } else {
                global.append((w.rect, nil)) // not analyzed yet: fail closed
            }
        }
        let alpha = CGFloat(cfg.colorAlpha)
        for ov in overlays {
            let sf = ov.frame
            var local: [(CGRect, CGColor?)] = []
            for (g, c) in global {
                let flipped = CGRect(x: g.origin.x, y: mainH - g.origin.y - g.height, width: g.width, height: g.height)
                let inter = flipped.intersection(sf)
                if !inter.isEmpty {
                    local.append((CGRect(x: inter.origin.x - sf.origin.x, y: inter.origin.y - sf.origin.y,
                                         width: inter.width, height: inter.height), c))
                }
            }
            ov.applyBlurRects(local, alpha: alpha)
        }
    }

    // Slow path: capture each sensitive window, detect text + colors, store.
    func runDetectionIfDue() {
        updateIcon()
        guard active, !detecting, hasPermission,
              Date().timeIntervalSince(lastDetect) > cfg.detectInterval else { return }
        detecting = true
        let params = DetectorParams(padX: cfg.padX, padY: cfg.padY,
                                    rowDiffThreshold: cfg.rowDiffThreshold,
                                    minRowPixels: cfg.minRowPixels, mergeGapX: cfg.mergeGapX)
        let terminals = Set(cfg.terminalBundleIDs)
        let blurIDs = Set(cfg.blurBundleIDs)
        let scale = cfg.captureScale
        let debug = cfg.debug
        Task.detached(priority: .userInitiated) { [weak self] in
            defer {
                Task { @MainActor in
                    self?.detecting = false
                    self?.lastDetect = Date()
                }
            }
            var content: SCShareableContent?
            do {
                content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            } catch {
                log("detect: SCShareableContent FAILED: \(error.localizedDescription)")
                return
            }
            guard let content else { return }
            let targets = content.windows.filter {
                guard let app = $0.owningApplication else { return false }
                return blurIDs.contains(app.bundleIdentifier) && $0.windowLayer == 0 && $0.frame.width >= 40
            }
            var results: [CGWindowID: [DetectedRect]] = [:]
            var summary: [String] = []
            for win in targets {
                let bid = win.owningApplication?.bundleIdentifier ?? "?"
                let filter = SCContentFilter(desktopIndependentWindow: win)
                let sz = CGSize(width: win.frame.width, height: win.frame.height)
                let scCfg = SCStreamConfiguration()
                scCfg.width = max(64, Int(sz.width * scale))
                scCfg.height = max(64, Int(sz.height * scale))
                scCfg.showsCursor = false
                guard let img = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: scCfg) else {
                    summary.append("\(bid)#\(win.windowID): capture FAILED")
                    continue
                }
                let (dets, method, workImg) = detectTextRects(img: img, size: sz,
                                                              isTerminal: terminals.contains(bid), p: params)
                results[CGWindowID(win.windowID)] = dets
                summary.append("\(bid)#\(win.windowID): \(method)")
                if debug {
                    let name = bid.split(separator: ".").last.map(String.init) ?? bid
                    saveAnnotated(workImg, dets: dets, size: sz,
                                  to: dumpDir.appendingPathComponent("win_\(name)_\(win.windowID).png"))
                }
            }
            log("detect: \(targets.count) targets — " + (summary.isEmpty ? "none" : summary.joined(separator: " | ")))
            let final = results
            await MainActor.run { [weak self] in
                guard let self, self.active else { return }
                self.textRects = final
                self.analyzed = true
                self.refreshOverlays()
                self.updateIcon()
            }
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
