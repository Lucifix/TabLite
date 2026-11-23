// TabLite — a tiny window switcher with live window previews (default shortcut: Option+Tab).
//
// Design goals: instant response on old Intel Macs.
//  - one CGEventTap (no polling, no timers while idle)
//  - window list comes from CGWindowListCopyWindowInfo, which is already front-to-back
//  - panel is shown immediately with cached thumbnails, fresh ones are captured on a
//    background queue and swapped in; a quick tap of the shortcut never shows the panel at all
//  - plain CALayers, no animations; the glass blur is done by the system on the GPU

import Cocoa
import ApplicationServices
import ScreenCaptureKit   // weak-linked (see build.sh): only used on macOS 14+
import ServiceManagement  // SMAppService (macOS 13+) for Launch at Login

// Private but long-stable API: AXUIElement -> CGWindowID
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ out: UnsafeMutablePointer<CGWindowID>) -> AXError

// MARK: - Windows

struct Win {
    let id: CGWindowID
    let pid: pid_t
    let app: String
    let title: String
    var caption: String { title.isEmpty ? app : title }
}

/// A display's bounds in the same coordinates as kCGWindowBounds (origin: top-left of the main display).
func displayBounds(_ s: NSScreen) -> CGRect? {
    guard let n = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
    return CGDisplayBounds(CGDirectDisplayID(n.uint32Value))
}

/// Index of the display that holds the largest part of `r`, or -1 if it's on none of them.
func homeDisplay(_ r: CGRect, _ displays: [CGRect]) -> Int {
    var best = -1, bestArea: CGFloat = 0
    for (i, d) in displays.enumerated() {
        let x = r.intersection(d)
        if x.isNull { continue }
        if x.width * x.height > bestArea { best = i; bestArea = x.width * x.height }
    }
    return best
}

/// Visible windows, front to back. With `screen`, only the windows mostly on that display.
func listWindows(on screen: NSScreen? = nil) -> [Win] {
    let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let arr = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { return [] }
    let me = getpid()
    var displays: [CGRect] = []
    var target = -1
    if let screen = screen, NSScreen.screens.count > 1, let tb = displayBounds(screen) {
        displays = NSScreen.screens.map { displayBounds($0) ?? .null }
        target = displays.firstIndex(of: tb) ?? -1
    }
    var regular: [pid_t: Bool] = [:]
    var out: [Win] = []
    for d in arr {
        guard (d[kCGWindowLayer as String] as? Int) == 0,
              let pidN = d[kCGWindowOwnerPID as String] as? Int,
              let num = d[kCGWindowNumber as String] as? Int,
              let b = d[kCGWindowBounds as String] as? [String: CGFloat],
              let w = b["Width"], let h = b["Height"] else { continue }
        let pid = pid_t(pidN)
        if pid == me || w < 90 || h < 60 { continue }
        if target >= 0 && homeDisplay(CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: w, height: h), displays) != target { continue }
        if let a = d[kCGWindowAlpha as String] as? Double, a < 0.01 { continue }
        let isRegular: Bool
        if let c = regular[pid] { isRegular = c } else {
            isRegular = NSRunningApplication(processIdentifier: pid)?.activationPolicy == .regular
            regular[pid] = isRegular
        }
        if !isRegular { continue }
        out.append(Win(id: CGWindowID(num), pid: pid,
                       app: d[kCGWindowOwnerName as String] as? String ?? "",
                       title: d[kCGWindowName as String] as? String ?? ""))
        if out.count >= 48 { break }
    }
    return out
}

/// Capture one window at 1x and shrink it to at most maxW x maxH pixels.
func captureThumb(_ id: CGWindowID, maxW: Int, maxH: Int) -> CGImage? {
    guard let img = CGWindowListCreateImage(.null, .optionIncludingWindow, id,
                                            [.boundsIgnoreFraming, .nominalResolution]),
          img.width > 1, img.height > 1 else { return nil }
    let s = min(CGFloat(maxW) / CGFloat(img.width), CGFloat(maxH) / CGFloat(img.height), 1)
    let w = max(1, Int(CGFloat(img.width) * s)), h = max(1, Int(CGFloat(img.height) * s))
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    else { return img }
    ctx.interpolationQuality = .low
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    return ctx.makeImage()
}

/// Captures window previews in the given (priority) order and calls `deliver` on the main queue
/// as each one is ready. macOS 14+: ScreenCaptureKit. Older: CGWindowListCreateImage on `queue`.
func capturePreviews(_ ids: [CGWindowID], maxW: Int, maxH: Int, queue: DispatchQueue,
                     stillWanted: @escaping () -> Bool,
                     deliver: @escaping (CGWindowID, CGImage) -> Void) {
    if #available(macOS 14.0, *) {
        captureWithScreenCaptureKit(ids, maxW: maxW, maxH: maxH, stillWanted: stillWanted, deliver: deliver)
        return
    }
    queue.async {
        for id in ids {
            guard stillWanted() else { return }
            guard let img = captureThumb(id, maxW: maxW, maxH: maxH) else { continue }
            DispatchQueue.main.async { deliver(id, img) }
        }
    }
}

/// UNTESTED: needs a macOS 14+ Mac. ScreenCaptureKit renders each window straight at the tile
/// size, so there is no full-size capture to shrink afterwards.
@available(macOS 14.0, *)
func captureWithScreenCaptureKit(_ ids: [CGWindowID], maxW: Int, maxH: Int,
                                 stillWanted: @escaping () -> Bool,
                                 deliver: @escaping (CGWindowID, CGImage) -> Void) {
    SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: true) { content, _ in
        guard let content = content, stillWanted() else { return }
        var byID: [CGWindowID: SCWindow] = [:]
        for w in content.windows { byID[w.windowID] = w }
        for id in ids {   // requested in priority order; they complete concurrently
            guard stillWanted(), let w = byID[id], w.frame.width > 1, w.frame.height > 1 else { continue }
            let s = min(CGFloat(maxW) / w.frame.width, CGFloat(maxH) / w.frame.height)
            let cfg = SCStreamConfiguration()
            cfg.width = max(1, Int(w.frame.width * s))
            cfg.height = max(1, Int(w.frame.height * s))
            cfg.showsCursor = false
            SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: w),
                                             configuration: cfg) { img, _ in
                guard let img = img else { return }
                DispatchQueue.main.async { if stillWanted() { deliver(id, img) } }
            }
        }
    }
}

/// Private SkyLight framework, opened once. Its functions are looked up at runtime, so a future
/// macOS that drops one only disables the feature that needs it.
let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
func privateSymbol<T>(_ name: String, as _: T.Type) -> T? {
    guard let sym = dlsym(skyLight ?? UnsafeMutableRawPointer(bitPattern: -2), name)
            ?? dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { return nil }   // -2 = RTLD_DEFAULT
    return unsafeBitCast(sym, to: T.self)
}

// Bring an app to the front exactly like clicking one of its windows does (same calls as AltTab
// and Hammerspoon). Needed because macOS 14+ often ignores NSRunningApplication.activate from a
// background app like TabLite ("cooperative activation"), which made quick switches do nothing.
private typealias GetPSNFn = @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus
private typealias SetFrontFn = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, CGWindowID, UInt32) -> CGError
private typealias PostRecordFn = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> CGError
private let getProcessForPID = privateSymbol("GetProcessForPID", as: GetPSNFn.self)
private let setFrontProcess = privateSymbol("_SLPSSetFrontProcessWithOptions", as: SetFrontFn.self)
private let postEventRecord = privateSymbol("SLPSPostEventRecordTo", as: PostRecordFn.self)

/// Returns false if the private calls are unavailable, so the caller can fall back to the public API.
private func bringToFront(_ pid: pid_t, _ wid: CGWindowID) -> Bool {
    guard let getPSN = getProcessForPID, let setFront = setFrontProcess else { return false }
    var psn = ProcessSerialNumber()
    guard getPSN(pid, &psn) == 0 else { return false }
    _ = setFront(&psn, wid, 0x200)   // 0x200 = kCPSUserGenerated: treated like a user click
    // Make that window the key window (synthesized window-server event record, as in AltTab).
    if let post = postEventRecord {
        var bytes = [UInt8](repeating: 0, count: 0xf8)
        bytes[0x04] = 0xf8
        bytes[0x3a] = 0x10
        withUnsafeBytes(of: wid) { for (i, b) in $0.enumerated() { bytes[0x3c + i] = b } }
        for i in 0x20..<0x30 { bytes[i] = 0xff }
        bytes[0x08] = 0x01; _ = post(&psn, &bytes)
        bytes[0x08] = 0x02; _ = post(&psn, &bytes)
    }
    return true
}

/// Focusing talks to other apps (AX calls can wait up to 0.25 s), so it runs here rather than
/// inside the keyboard event tap, which must return immediately.
let focusQueue = DispatchQueue(label: "tablite.focus", qos: .userInteractive)

func focus(_ w: Win) {
    if !bringToFront(w.pid, w.id) {
        NSRunningApplication(processIdentifier: w.pid)?.activate(options: [.activateIgnoringOtherApps])
    }
    let ax = AXUIElementCreateApplication(w.pid)
    AXUIElementSetMessagingTimeout(ax, 0.25)
    var ref: CFTypeRef?
    guard AXUIElementCopyAttributeValue(ax, kAXWindowsAttribute as CFString, &ref) == .success,
          let list = ref as? [AXUIElement] else { return }
    for win in list {
        var id: CGWindowID = 0
        if _AXUIElementGetWindow(win, &id) == .success, id == w.id {
            AXUIElementSetAttributeValue(win, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            AXUIElementPerformAction(win, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(win, kAXMainAttribute as CFString, kCFBooleanTrue)
            break
        }
    }
}

// MARK: - Layout & view

struct Layout {
    var cols = 1, rows = 1
    var s: CGFloat = 1
    var cw: CGFloat = 220, ch: CGFloat = 170
    var gap: CGFloat = 10, pad: CGFloat = 18
    var size = CGSize(width: 260, height: 210)
    var thumbW: CGFloat { (cw - 20 * s) }
    var thumbH: CGFloat { 112 * s }

    static func make(count n: Int, screen: NSScreen) -> Layout {
        let vf = screen.visibleFrame
        let maxW = vf.width * 0.92, maxH = vf.height * 0.85
        var l = Layout()
        for s in [CGFloat(1), 0.8, 0.65, 0.5] {
            l.s = s; l.cw = 220 * s; l.ch = 170 * s
            l.cols = max(1, min(n, Int((maxW - 2 * l.pad + l.gap) / (l.cw + l.gap))))
            l.rows = (n + l.cols - 1) / l.cols
            l.size = CGSize(width: CGFloat(l.cols) * (l.cw + l.gap) - l.gap + 2 * l.pad,
                            height: CGFloat(l.rows) * (l.ch + l.gap) - l.gap + 2 * l.pad)
            if l.size.height <= maxH { break }
        }
        return l
    }
}

/// Colors resolved once per show for the current system appearance (cheap, no dynamic lookups per frame).
let panelRadius: CGFloat = 24

struct Theme {
    let text, selFill, selBorder, edge, rimTop, rimBottom: CGColor
    static func current() -> Theme {
        // NSApp is still nil while globals are being set up at launch, so fall back to the current appearance.
        let appearance = NSApp?.effectiveAppearance ?? NSAppearance.current ?? NSAppearance(named: .aqua)!
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return dark
            ? Theme(text: NSColor(white: 1, alpha: 0.92).cgColor,
                    selFill: NSColor(white: 1, alpha: 0.14).cgColor, selBorder: NSColor(white: 1, alpha: 0.35).cgColor,
                    edge: NSColor(white: 0, alpha: 0.35).cgColor,
                    rimTop: NSColor(white: 1, alpha: 0.45).cgColor, rimBottom: NSColor(white: 1, alpha: 0.06).cgColor)
            : Theme(text: NSColor(white: 0, alpha: 0.85).cgColor,
                    selFill: NSColor(white: 1, alpha: 0.55).cgColor, selBorder: NSColor(white: 0, alpha: 0.12).cgColor,
                    edge: NSColor(white: 0, alpha: 0.10).cgColor,
                    rimTop: NSColor(white: 1, alpha: 0.95).cgColor, rimBottom: NSColor(white: 1, alpha: 0.35).cgColor)
    }
}

/// Resizable rounded-rect mask for the glass view (cheaper than masking layers with cornerRadius).
func roundedMask(_ r: CGFloat) -> NSImage {
    let edge = 2 * r + 1
    let img = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
        NSColor.black.setFill()
        NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
        return true
    }
    img.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
    img.resizingMode = .stretch
    return img
}

final class Cell {
    let bg = CALayer(), thumb = CALayer(), bigIcon = CALayer(), icon = CALayer(), text = CATextLayer()
    var frame = CGRect.zero
}

final class SwitcherView: NSView {
    var cells: [Cell] = []
    var onClick: ((Int) -> Void)?
    var theme = Theme.current()
    /// true when macOS 26 Liquid Glass draws the background (and its own edge highlights)
    var liquidGlass = false
    let content = CALayer()              // holds the cells; rebuilt on every show
    let rim = CAGradientLayer()          // 1px edge, bright at the top like light catching the rim
    let rimShape = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        let l = layer!
        l.backgroundColor = nil          // the glass view behind us provides the background
        l.cornerRadius = panelRadius
        l.addSublayer(content)
        rimShape.fillColor = nil
        rimShape.strokeColor = NSColor.black.cgColor
        rimShape.lineWidth = 1
        rim.mask = rimShape
        rim.startPoint = CGPoint(x: 0.5, y: 1)   // y points up in this view: 1 = top edge
        rim.endPoint = CGPoint(x: 0.5, y: 0)
        l.addSublayer(rim)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func rebuild(wins: [Win], layout L: Layout, backing: CGFloat,
                 icon: (pid_t) -> CGImage?, cache: [CGWindowID: CGImage]) {
        content.sublayers = nil
        content.frame = bounds
        // Glass edge: faint outer line for definition plus the gradient rim. Liquid Glass draws its own.
        layer!.borderWidth = liquidGlass ? 0 : 1
        layer!.borderColor = theme.edge
        rim.isHidden = liquidGlass
        rim.frame = bounds
        rimShape.frame = bounds
        rimShape.path = CGPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5),
                               cornerWidth: panelRadius - 1.5, cornerHeight: panelRadius - 1.5, transform: nil)
        rim.colors = [theme.rimTop, theme.rimBottom]
        cells = []
        let font = NSFont.systemFont(ofSize: 12)
        let inset = 10 * L.s
        let bottomH = L.ch - 2 * inset - L.thumbH
        let iconSz = max(12, min(22, bottomH - 4))
        for (i, w) in wins.enumerated() {
            let c = Cell()
            let col = i % L.cols, row = i / L.cols
            let x = L.pad + CGFloat(col) * (L.cw + L.gap)
            let y = L.size.height - L.pad - CGFloat(row + 1) * L.ch - CGFloat(row) * L.gap
            c.frame = CGRect(x: x, y: y, width: L.cw, height: L.ch)

            c.bg.frame = c.frame
            c.bg.cornerRadius = 14 * L.s

            let tf = CGRect(x: x + inset, y: y + L.ch - inset - L.thumbH, width: L.thumbW, height: L.thumbH)
            c.thumb.frame = tf
            c.thumb.contentsGravity = .resizeAspect
            c.thumb.magnificationFilter = .linear
            c.thumb.minificationFilter = .linear
            c.thumb.contentsScale = backing

            let big: CGFloat = min(48, tf.height - 8)
            c.bigIcon.frame = CGRect(x: tf.midX - big / 2, y: tf.midY - big / 2, width: big, height: big)
            c.bigIcon.contentsGravity = .resizeAspect

            let ic = icon(w.pid)
            c.bigIcon.contents = ic
            c.icon.frame = CGRect(x: x + inset, y: y + (bottomH - iconSz) / 2 + 2, width: iconSz, height: iconSz)
            c.icon.contents = ic
            c.icon.contentsGravity = .resizeAspect

            let tx = x + inset + iconSz + 6
            c.text.frame = CGRect(x: tx, y: y + (bottomH - 16) / 2 + 2, width: x + L.cw - inset - tx, height: 16)
            c.text.string = w.caption
            c.text.font = font
            c.text.fontSize = 12
            c.text.foregroundColor = theme.text
            c.text.truncationMode = .end
            c.text.alignmentMode = .left
            c.text.contentsScale = backing

            if let img = cache[w.id] { c.thumb.contents = img; c.bigIcon.isHidden = true }

            for sub in [c.bg, c.thumb, c.bigIcon, c.icon, c.text] { content.addSublayer(sub) }
            cells.append(c)
        }
    }

    func setThumb(_ i: Int, _ img: CGImage) {
        guard i < cells.count else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        cells[i].thumb.contents = img
        cells[i].bigIcon.isHidden = true
        CATransaction.commit()
    }

    func setSelected(_ sel: Int) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for (i, c) in cells.enumerated() {
            let on = i == sel
            c.bg.backgroundColor = on ? theme.selFill : nil
            c.bg.borderWidth = on ? 1 : 0
            c.bg.borderColor = theme.selBorder
        }
        CATransaction.commit()
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let i = cells.firstIndex(where: { $0.frame.contains(p) }) { onClick?(i) }
    }
}

// MARK: - Switcher state machine

final class Gen {
    private var v = 0
    private let lock = NSLock()
    @discardableResult func bump() -> Int { lock.lock(); defer { lock.unlock() }; v += 1; return v }
    var value: Int { lock.lock(); defer { lock.unlock() }; return v }
}

final class Switcher {
    var active = false
    var shown = false
    var wins: [Win] = []
    var sel = 0
    var layout = Layout()
    var screen = NSScreen.main ?? NSScreen.screens[0]
    var cache: [CGWindowID: CGImage] = [:]
    var iconCache: [pid_t: CGImage] = [:]
    var pendingShow: DispatchWorkItem?
    let gen = Gen()
    let queue = DispatchQueue(label: "tablite.capture", qos: .userInitiated)
    // Screen Recording permission only takes effect after a relaunch, so checking once is enough.
    let canCapture = CGPreflightScreenCaptureAccess()
    let panel: NSPanel
    let background: NSView
    let view: SwitcherView

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let view = SwitcherView(frame: .zero)
        self.view = view

        // macOS 26+: Apple's Liquid Glass (NSGlassEffectView), looked up at runtime so the app
        // still builds with older SDKs and runs on older systems. UNTESTED: needs a macOS 26 Mac.
        if let cls = NSClassFromString("NSGlassEffectView") as? NSView.Type,
           case let g = cls.init(frame: .zero),
           g.responds(to: NSSelectorFromString("setContentView:")) {
            if g.responds(to: NSSelectorFromString("setCornerRadius:")) {
                g.setValue(NSNumber(value: Double(panelRadius)), forKey: "cornerRadius")
            }
            g.setValue(view, forKey: "contentView")
            view.liquidGlass = true
            background = g
        } else {
            // macOS 10.15–15: system frosted glass, blurred by the WindowServer on the GPU. Follows
            // dark/light automatically and turns solid when "Reduce transparency" is on.
            let fx = NSVisualEffectView()
            fx.material = .hudWindow         // clearer than .popover, closest to the glass look
            fx.blendingMode = .behindWindow
            fx.state = .active               // we never become the active app, so force the active look
            fx.maskImage = roundedMask(panelRadius)
            fx.addSubview(view)
            background = fx
        }
        panel.contentView = background
        view.onClick = { [weak self] i in self?.sel = i; self?.commit() }
    }

    func icon(_ pid: pid_t) -> CGImage? {
        if let c = iconCache[pid] { return c }
        guard let img = NSRunningApplication(processIdentifier: pid)?.icon else { return nil }
        var r = CGRect(x: 0, y: 0, width: 128, height: 128)
        let cg = img.cgImage(forProposedRect: &r, context: nil, hints: nil)
        iconCache[pid] = cg
        return cg
    }

    /// Pay the one-time costs at launch (WindowServer + LaunchServices setup, icons,
    /// first thumbnails) so the very first switch is as fast as every later one.
    func warmUp() {
        let list = listWindows()
        for w in list { _ = icon(w.pid) }
        guard canCapture else { return }
        let backing = (NSScreen.main ?? NSScreen.screens[0]).backingScaleFactor
        let tw = Int(Layout().thumbW * backing), th = Int(Layout().thumbH * backing)
        capturePreviews(list.map { $0.id }, maxW: tw, maxH: th, queue: queue, stillWanted: { true }) { [weak self] id, img in
            if self?.cache[id] == nil { self?.cache[id] = img }
        }
    }

    func begin(reverse: Bool) {
        let m = NSEvent.mouseLocation
        let here = NSScreen.screens.first { NSMouseInRect(m, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        let list = listWindows(on: currentDisplayOnly ? here : nil)
        guard !list.isEmpty else { return }
        wins = list
        screen = here
        // Keep thumbnails of windows on other displays too: switching displays shouldn't refetch them.
        let ids = Set((currentDisplayOnly ? listWindows() : list).map { $0.id })
        cache = cache.filter { ids.contains($0.key) }
        layout = Layout.make(count: wins.count, screen: screen)
        sel = reverse ? wins.count - 1 : min(1, wins.count - 1)
        active = true
        // Quick tap-and-release switches without ever drawing the panel.
        let work = DispatchWorkItem { [weak self] in self?.show() }
        pendingShow = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    func move(by d: Int) {
        guard active, !wins.isEmpty else { return }
        sel = ((sel + d) % wins.count + wins.count) % wins.count
        refreshSelection()
    }

    func moveRow(_ d: Int) {
        guard active else { return }
        let n = sel + d * layout.cols
        if n >= 0 && n < wins.count { sel = n }
        refreshSelection()
    }

    private func refreshSelection() {
        if shown { view.setSelected(sel) } else { show() }
    }

    func show() {
        guard active, !shown else { return }
        pendingShow?.cancel()
        shown = true
        let vf = screen.visibleFrame
        let size = layout.size
        panel.setFrame(NSRect(x: (vf.midX - size.width / 2).rounded(), y: (vf.midY - size.height / 2).rounded(),
                              width: size.width, height: size.height), display: false)
        view.frame = background.bounds
        view.theme = Theme.current()
        let backing = screen.backingScaleFactor
        CATransaction.begin(); CATransaction.setDisableActions(true)
        view.rebuild(wins: wins, layout: layout, backing: backing, icon: { self.icon($0) }, cache: cache)
        view.setSelected(sel)
        CATransaction.commit()
        panel.orderFrontRegardless()

        // Refresh thumbnails in the background, selected window first, progressively swapped in.
        let token = gen.bump()
        guard canCapture else { return }
        let tw = Int(layout.thumbW * backing), th = Int(layout.thumbH * backing)
        var order = Array(wins.indices)
        order.sort { a, b in (a == sel ? -1 : a) < (b == sel ? -1 : b) }
        let indexOf = Dictionary(wins.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        let gen = self.gen
        capturePreviews(order.map { wins[$0].id }, maxW: tw, maxH: th, queue: queue,
                        stillWanted: { gen.value == token }) { [weak self] id, img in
            guard let self = self, gen.value == token, self.shown, let i = indexOf[id] else { return }
            self.cache[id] = img
            self.view.setThumb(i, img)
        }
    }

    func hide() {
        pendingShow?.cancel()
        gen.bump()
        if shown { panel.orderOut(nil) }
        shown = false
        active = false
    }

    func cancel() { hide() }

    func commit() {
        guard active else { return }
        let target = wins.indices.contains(sel) ? wins[sel] : nil
        hide()
        if let t = target { focusQueue.async { focus(t) } }
    }
}

let switcher = Switcher()

// MARK: - Global key handling

private let kTab: Int64 = 48, kEsc: Int64 = 53
private let kLeft: Int64 = 123, kRight: Int64 = 124, kDown: Int64 = 125, kUp: Int64 = 126
private var swallowed = Set<Int64>()
private var tapPort: CFMachPort?

// MARK: - Shortcut (Option+Tab or Command+Tab)

enum Shortcut: String {
    case option, command
    var flag: CGEventFlags { self == .option ? .maskAlternate : .maskCommand }
    /// Modifiers that must not be held for the shortcut to fire (Shift is allowed: it goes backwards).
    var excluded: CGEventFlags { self == .option ? [.maskCommand, .maskControl] : [.maskAlternate, .maskControl] }
    var title: String { self == .option ? "Option+Tab" : "Command+Tab" }
    static var saved: Shortcut {
        get { Shortcut(rawValue: UserDefaults.standard.string(forKey: "shortcut") ?? "") ?? .option }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "shortcut") }
    }
}

/// Active shortcut, cached so the event tap never touches UserDefaults.
private var trigger = Shortcut.saved

/// Show only the windows on the display under the mouse (where the panel opens). Off by default.
var currentDisplayOnly = UserDefaults.standard.bool(forKey: "currentDisplayOnly") {
    didSet { UserDefaults.standard.set(currentDisplayOnly, forKey: "currentDisplayOnly") }
}

/// Private SkyLight function that turns macOS's own Command+Tab app switcher on or off
/// (symbolic hotkey 1 = Command+Tab, 2 = Command+Shift+Tab; lasts until logout).
/// Looked up at runtime: if a future macOS removes it, the Command+Tab option is simply unavailable.
private typealias SetHotKeyFn = @convention(c) (Int32, Bool) -> CGError
private let setSymbolicHotKeyEnabled = privateSymbol("CGSSetSymbolicHotKeyEnabled", as: SetHotKeyFn.self)
var commandTabAvailable: Bool { setSymbolicHotKeyEnabled != nil }

func setSystemCommandTab(enabled: Bool) {
    _ = setSymbolicHotKeyEnabled?(1, enabled)
    _ = setSymbolicHotKeyEnabled?(2, enabled)
}

/// Apply the saved shortcut. macOS's Command+Tab is only turned off once our event tap is
/// running, so Command+Tab never ends up doing nothing (e.g. before Accessibility is granted).
func applyShortcut() {
    trigger = commandTabAvailable ? Shortcut.saved : .option
    setSystemCommandTab(enabled: !(trigger == .command && tapPort != nil))
}

/// Hand Command+Tab back to macOS if TabLite is killed or crashes.
func installRestoreHandlers() {
    for sig in [SIGTERM, SIGINT, SIGHUP, SIGQUIT, SIGABRT, SIGILL, SIGTRAP, SIGSEGV, SIGBUS, SIGFPE] {
        signal(sig) { s in
            setSystemCommandTab(enabled: true)
            signal(s, SIG_DFL)
            raise(s)
        }
    }
}

private let tapCallback: CGEventTapCallBack = { _, type, event, _ in
    let pass = Unmanaged.passUnretained(event)
    switch type {
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        switcher.cancel()
        if let t = tapPort { CGEvent.tapEnable(tap: t, enable: true) }
        return pass

    case .keyDown:
        let key = event.getIntegerValueField(.keyboardEventKeycode)
        let f = event.flags
        let modHeld = f.contains(trigger.flag)
        let shift = f.contains(.maskShift)

        if !switcher.active {
            if key == kTab && modHeld && f.intersection(trigger.excluded).isEmpty {
                switcher.begin(reverse: shift)
                if switcher.active { swallowed.insert(key); return nil }
                return nil
            }
            return pass
        }
        if !modHeld { switcher.cancel(); return pass }   // missed the release; never get stuck
        switch key {
        case kTab:   switcher.move(by: shift ? -1 : 1)
        case kLeft:  switcher.move(by: -1)
        case kRight: switcher.move(by: 1)
        case kUp:    switcher.moveRow(-1)
        case kDown:  switcher.moveRow(1)
        case kEsc:   switcher.cancel()
        default: break
        }
        swallowed.insert(key)
        return nil   // swallow everything while the switcher is open

    case .keyUp:
        let key = event.getIntegerValueField(.keyboardEventKeycode)
        if swallowed.remove(key) != nil { return nil }
        return pass

    case .flagsChanged:
        if switcher.active && !event.flags.contains(trigger.flag) { switcher.commit() }
        return pass

    default:
        return pass
    }
}

func installTap() -> Bool {
    let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        | (1 << CGEventType.flagsChanged.rawValue)
    guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                      options: .defaultTap, eventsOfInterest: mask,
                                      callback: tapCallback, userInfo: nil) else { return false }
    tapPort = tap
    CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    return true
}

// MARK: - App

/// Menu bar glyph matching the app icon: three window tiles, the middle one selected.
/// Template image, so macOS tints it for light/dark menu bars. Independent of the shortcut.
func menuBarIcon() -> NSImage {
    let img = NSImage(size: NSSize(width: 20, height: 14), flipped: false) { _ in
        NSColor.black.set()
        for x in [CGFloat(0.75), 14.25] {
            let side = NSBezierPath(roundedRect: NSRect(x: x, y: 3.5, width: 5, height: 7), xRadius: 1.2, yRadius: 1.2)
            side.lineWidth = 1.2
            side.stroke()
        }
        NSBezierPath(roundedRect: NSRect(x: 7, y: 2, width: 6, height: 10), xRadius: 1.5, yRadius: 1.5).fill()
        return true
    }
    img.isTemplate = true
    return img
}

// MARK: - Launch at Login

/// Opens TabLite when you log in. macOS 13+: the system's own login item (SMAppService), which
/// shows up in System Settings → General → Login Items. Older macOS: a per-user LaunchAgent.
enum LaunchAtLogin {
    private static let label = "io.github.lucifix.tablite"
    private static var agentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isEnabled: Bool {
        if #available(macOS 13.0, *) { return SMAppService.mainApp.status == .enabled }
        return FileManager.default.fileExists(atPath: agentURL.path)
    }

    static func set(_ on: Bool) throws {
        if #available(macOS 13.0, *) {
            if on {
                try SMAppService.mainApp.register()
                // The user can block login items in System Settings; send them there to allow it.
                if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            } else {
                try SMAppService.mainApp.unregister()
            }
        } else if on {
            let plist: [String: Any] = ["Label": label,
                                        "ProgramArguments": ["/usr/bin/open", Bundle.main.bundlePath],
                                        "RunAtLoad": true]
            try FileManager.default.createDirectory(at: agentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: agentURL, options: .atomic)
        } else if FileManager.default.fileExists(atPath: agentURL.path) {
            try FileManager.default.removeItem(at: agentURL)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var item: NSStatusItem!
    var retry: Timer?

    func applicationDidFinishLaunching(_ n: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = menuBarIcon()
        item.button?.toolTip = "TabLite"
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu

        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        if !switcher.canCapture { CGRequestScreenCaptureAccess() }
        switcher.warmUp()

        installRestoreHandlers()
        if installTap() {
            applyShortcut()
        } else {
            applyShortcut()   // tap not running yet: makes sure macOS keeps its own Command+Tab
            // Accessibility not granted yet: keep trying so no relaunch is needed after granting.
            retry = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] t in
                if installTap() { t.invalidate(); self?.retry = nil; applyShortcut() }
            }
        }
    }

    func applicationWillTerminate(_ n: Notification) {
        setSystemCommandTab(enabled: true)   // always hand Command+Tab back to macOS
    }

    @objc func chooseShortcut(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let s = Shortcut(rawValue: raw) else { return }
        Shortcut.saved = s
        applyShortcut()
    }

    @objc func toggleCurrentDisplay() { currentDisplayOnly.toggle() }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let ax = AXIsProcessTrusted(), sr = CGPreflightScreenCaptureAccess()
        menu.addItem(withTitle: "Accessibility: \(ax ? "✓" : "✗ needed for hotkey + raising windows")", action: nil, keyEquivalent: "")
        menu.addItem(withTitle: "Screen Recording: \(sr ? "✓" : "✗ needed for thumbnails + titles")", action: nil, keyEquivalent: "")
        if !ax || !sr {
            let open = menu.addItem(withTitle: "Open Privacy Settings…", action: #selector(openPrivacy), keyEquivalent: "")
            open.target = self
            let re = menu.addItem(withTitle: "Restart TabLite (after granting)", action: #selector(restart), keyEquivalent: "r")
            re.target = self
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Shortcut", action: nil, keyEquivalent: "")
        for s in [Shortcut.option, .command] {
            let available = s == .option || commandTabAvailable
            let it = menu.addItem(withTitle: "Switch with \(s.title)\(available ? "" : " (not available)")",
                                  action: available ? #selector(chooseShortcut(_:)) : nil, keyEquivalent: "")
            it.target = self
            it.representedObject = s.rawValue
            it.state = trigger == s ? .on : .off
            it.indentationLevel = 1
        }
        menu.addItem(.separator())
        let disp = menu.addItem(withTitle: "Only show windows on the current display", action: #selector(toggleCurrentDisplay), keyEquivalent: "")
        disp.target = self
        disp.state = currentDisplayOnly ? .on : .off
        menu.addItem(.separator())
        let login = menu.addItem(withTitle: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        login.state = LaunchAtLogin.isEnabled ? .on : .off
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit TabLite", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    @objc func toggleLaunchAtLogin() {
        do {
            try LaunchAtLogin.set(!LaunchAtLogin.isEnabled)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't change Launch at Login"
            alert.informativeText = error.localizedDescription
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    @objc func openPrivacy() {
        let pane = CGPreflightScreenCaptureAccess() ? "Privacy_Accessibility" : "Privacy_ScreenCapture"
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
    }

    @objc func restart() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 0.5; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? p.run()
        NSApp.terminate(nil)
    }
}

if CommandLine.arguments.contains("--list") {   // debug: print what the switcher would show
    for w in listWindows() { print(w.id, w.pid, w.app, "|", w.title) }
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
