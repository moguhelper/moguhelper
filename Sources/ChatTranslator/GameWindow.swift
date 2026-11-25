// 找到游戏窗口并截图。
// 只用 macOS 系统截屏接口（ScreenCaptureKit，需要“屏幕录制”权限）：
// 系统把游戏窗口的画面复制一份给我们，不读取、不修改游戏进程。
// 截图只在内存中处理，用完即释放，不写入硬盘。
import AppKit
import ScreenCaptureKit

struct GameWindowInfo {
    let windowID: CGWindowID
    /// 游戏窗口当前的显示层级（游戏激活时会把自己提到较高层级，我们的悬浮窗要比它再高一级）
    var layer: Int = 0
    /// 窗口在屏幕上的位置（点，左上角为原点，含标题栏）
    var frameTopLeft: CGRect
    let scWindow: SCWindow
}

enum Coords {
    /// 主屏高度：系统截屏坐标（左上原点）↔ AppKit 窗口坐标（左下原点）换算用
    static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    static func toAppKit(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }
    static func toTopLeft(_ p: NSPoint) -> CGPoint {
        CGPoint(x: p.x, y: primaryHeight - p.y)
    }
}

/// 区域：相对游戏窗口，用“距窗口左边、距窗口底边”的点数记录（聊天框贴着底边，窗口大小变了也不会错位）
struct Region: Codable, Equatable {
    var x: CGFloat
    var bottom: CGFloat
    var width: CGFloat
    var height: CGFloat

    /// 换成窗口内左上原点的矩形（点）
    func rectInWindow(windowSize: CGSize) -> CGRect {
        // 取整：带小数的位置截出来是插值过的，字会糊
        CGRect(x: x.rounded(), y: (windowSize.height - bottom - height).rounded(), width: width.rounded(), height: height.rounded())
            .intersection(CGRect(origin: .zero, size: windowSize))
    }
    static func from(rectInWindow r: CGRect, windowSize: CGSize) -> Region {
        Region(x: r.minX, bottom: windowSize.height - r.maxY, width: r.width, height: r.height)
    }
}

@MainActor
final class GameWindowLocator {
    private(set) var current: GameWindowInfo?
    private var lastSearch = Date.distantPast
    private var loggedOnce = false

    /// 找游戏窗口（程序标识是 com.nexon.maplestory… 的最大窗口，启动器不算）。每 3 秒重新找一次，平时只更新位置。
    func refresh() async {
        if let c = current, Date().timeIntervalSince(lastSearch) < 3 {
            if let (f, layer) = Self.liveInfo(c.windowID) { current?.frameTopLeft = f; current?.layer = layer } else { current = nil }
            return
        }
        lastSearch = Date()
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) else {
            current = nil; return
        }
        let candidates = content.windows.filter { w in
            let app = w.owningApplication?.applicationName ?? ""
            let title = w.title ?? ""
            let bid = w.owningApplication?.bundleIdentifier ?? ""
            // 不看窗口标题：浏览器打开 maplestory 网页，标题里也有这个词，会截到网页（红线：只截游戏窗口）
            return (bid.lowercased().hasPrefix("com.nexon.maplestory") || (bid.isEmpty && app.lowercased().hasPrefix("maplestory")))
                && !app.localizedCaseInsensitiveContains("launcher") && !title.localizedCaseInsensitiveContains("launcher")
                && w.frame.width > 300 && w.frame.height > 300
        }
        if let w = candidates.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) {
            let live = Self.liveInfo(w.windowID)
            current = GameWindowInfo(windowID: w.windowID, layer: live?.1 ?? w.windowLayer, frameTopLeft: live?.0 ?? w.frame, scWindow: w)
        } else {
            current = nil
        }
    }

    /// 不需要截屏权限的找窗口方式：系统窗口列表里的程序名和位置（只用于摆放提示窗）
    static func gameFrameWithoutCapture() -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        return list.compactMap { info -> CGRect? in
            let owner = info[kCGWindowOwnerName as String] as? String ?? ""
            guard owner.localizedCaseInsensitiveContains("maplestory"),
                  let b = info[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: b), r.width > 300 else { return nil }
            return r
        }.max { $0.width * $0.height < $1.width * $1.height }
    }

    func restore(_ g: GameWindowInfo) { current = g }

    /// 当前窗口位置和层级（系统窗口列表，只读）
    /// 盖在游戏窗口前面的别的程序的窗口（普通窗口；不算自己的、系统菜单栏、很小的和全透明的）
    static func windowsInFront(of id: CGWindowID) -> [CGRect] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenAboveWindow, .excludeDesktopElements], id) as? [[String: Any]] else { return [] }
        let me = ProcessInfo.processInfo.processIdentifier
        let game = (CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]])?.first?[kCGWindowOwnerPID as String] as? Int32
        return list.compactMap { i in
            guard let pid = i[kCGWindowOwnerPID as String] as? Int32, pid != me, pid != game,
                  (i[kCGWindowLayer as String] as? Int ?? 99) == 0, (i[kCGWindowAlpha as String] as? Double ?? 1) > 0.2,
                  let b = i[kCGWindowBounds as String] as? NSDictionary, let r = CGRect(dictionaryRepresentation: b), r.width > 60, r.height > 40 else { return nil }
            return r
        }
    }
    static func liveInfo(_ id: CGWindowID) -> (CGRect, Int)? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]],
              let info = list.first, let b = info[kCGWindowBounds as String] as? NSDictionary,
              let r = CGRect(dictionaryRepresentation: b) else { return nil }
        if let onScreen = info[kCGWindowIsOnscreen as String] as? Bool, !onScreen { return nil }
        return (r, info[kCGWindowLayer as String] as? Int ?? 0)
    }

    /// 截取游戏窗口里的一块区域（rect：窗口内左上原点，点）。只截游戏窗口本身，我们自己的翻译窗不会被截进去。
    /// outputScale：输出每点几个像素（默认按屏幕，Retina 为 2）。查找任务窗口时用 1，像素少四倍，省显卡
    func capture(_ g: GameWindowInfo, rect: CGRect, outputScale: CGFloat? = nil) async -> CGImage? {
        let filter = SCContentFilter(desktopIndependentWindow: g.scWindow)
        if !loggedOnce {
            loggedOnce = true
            NSLog("ChatTranslator: contentRect=%@ windowBounds=%@ scale=%f", NSStringFromRect(filter.contentRect), NSStringFromRect(g.frameTopLeft), filter.pointPixelScale)
        }
        let scale = outputScale ?? CGFloat(filter.pointPixelScale)
        let cfg = SCStreamConfiguration()
        cfg.sourceRect = rect
        cfg.width = Int(rect.width * scale)
        cfg.height = Int(rect.height * scale)
        cfg.showsCursor = false
        cfg.ignoreShadowsSingleWindow = true
        // 系统的“正在共享屏幕”标记是挂在游戏窗口上的小窗口，连它一起截画面会整个偏掉
        cfg.includeChildWindows = false
        guard let shot = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg) else { return nil }
        return Self.ownedCopy(shot)
    }

    /// 系统给的截图使用共享显存，之后可能被回收复用；马上复制一份到自己的内存里再处理（用完随即释放）
    static func ownedCopy(_ img: CGImage) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return ctx.makeImage()
    }
}
