// 冒险岛风格的界面零件：全部用代码画（不用游戏贴图、不用游戏字体），颜色照着游戏窗口截图取的。
// 窗口 = 深蓝细边 + 白边 + 浅蓝灰底；标题条白色；内容是白底深色字；选中的页签是粉红；按钮是亮蓝色。
import AppKit
import SwiftUI

enum Maple {
    static func rgb(_ r: Int, _ g: Int, _ b: Int) -> NSColor {
        NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }
    static let edge = rgb(85, 119, 153)        // 窗口、内板的深蓝细边
    static let face = rgb(153, 187, 204)       // 窗口底色
    static let strip = rgb(119, 148, 184)      // 卡片标题条（游戏里是 156,176,200，白字看不清，压深了）
    static let beige = rgb(225, 223, 213)      // 背包格子底
    static let slotEdge = rgb(206, 201, 190)   // 背包格子左上的暗边
    static let bag = rgb(245, 246, 247)        // 背包格子外面的底
    static let text = rgb(34, 34, 40)
    static let sub = rgb(92, 96, 106)
    static let pink = rgb(222, 84, 116)
    static let tabGrey = rgb(150, 150, 154)
    static let red = rgb(204, 0, 0)
    static let done = rgb(22, 138, 58)         // 已经够了的目标
    static let warn = rgb(200, 80, 0)
    static let orange = rgb(221, 102, 0)
    static let titleBar: CGFloat = 24

    static let mushroom: NSImage? = Bundle.main.url(forResource: "Mushroom", withExtension: "png").flatMap { NSImage(contentsOf: $0) }

    /// 缩到指定点数的小图（菜单栏、标题条用）；保留 2 倍像素
    static func smallMushroom(_ side: CGFloat) -> NSImage? {
        guard let src = mushroom else { return nil }
        let img = NSImage(size: NSSize(width: side, height: side), flipped: false) { r in
            NSGraphicsContext.current?.imageInterpolation = .high
            src.draw(in: r); return true
        }
        img.isTemplate = false
        return img
    }
}

extension Color {
    static let mText = Color(nsColor: Maple.text)
    static let mSub = Color(nsColor: Maple.sub)
    static let mEdge = Color(nsColor: Maple.edge)
}

/// 整个窗口的外框 + 顶部白色标题条
final class MapleFrameView: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        func fill(_ inset: CGFloat, _ radius: CGFloat, _ c: NSColor) {
            c.setFill(); NSBezierPath(roundedRect: bounds.insetBy(dx: inset, dy: inset), xRadius: radius, yRadius: radius).fill()
        }
        fill(0, 5, Maple.edge); fill(1, 4, .white); fill(2.5, 3, Maple.edge); fill(3.5, 2.5, Maple.face)
        let bar = CGRect(x: 5, y: 5, width: bounds.width - 10, height: Maple.titleBar - 2)
        NSColor.white.setFill(); NSBezierPath(roundedRect: bar, xRadius: 2, yRadius: 2).fill()
        Maple.smallMushroom(18)?.draw(in: CGRect(x: 10, y: 7, width: 18, height: 18), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        let s = NSAttributedString(string: "MoguHelper", attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .heavy), .foregroundColor: Maple.text])
        s.draw(at: CGPoint(x: 33, y: 5 + (bar.height - s.size().height) / 2))
    }
}

/// 白色内板 + 蓝色标题条（标题文字由外面放）
final class MapleCardView: NSView {
    static let strip: CGFloat = 20
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let p = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
        NSGraphicsContext.saveGraphicsState()
        p.addClip()
        NSColor.white.setFill(); bounds.fill()
        Maple.strip.setFill(); CGRect(x: 0, y: 0, width: bounds.width, height: Self.strip).fill()
        NSGraphicsContext.restoreGraphicsState()
        Maple.edge.setStroke(); p.lineWidth = 1; p.stroke()
    }
}

/// 游戏里那种亮蓝小按钮：深色边、上半亮下半深
final class MapleButton: NSButton {
    override var intrinsicContentSize: NSSize {
        let s = label.size(); return NSSize(width: ceil(s.width) + 16, height: 16)
    }
    private var label: NSAttributedString {
        NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 10, weight: .bold), .foregroundColor: NSColor.white])
    }
    override var title: String { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        let p = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 2.5, yRadius: 2.5)
        let top = Maple.rgb(60, 160, 225), low = Maple.rgb(26, 106, 170)
        NSGradient(starting: isHighlighted ? low : top, ending: low)?.draw(in: p, angle: isFlipped ? 90 : -90)
        Maple.rgb(30, 50, 80).setStroke(); p.stroke()
        let s = label.size()
        label.draw(at: CGPoint(x: bounds.midX - s.width / 2, y: bounds.midY - s.height / 2))
    }
}

/// 和 MapleButton 一样的蓝按钮（SwiftUI 用）
struct MapleButtonStyle: ButtonStyle {
    func makeBody(configuration c: Configuration) -> some View {
        let top = Color(nsColor: Maple.rgb(60, 160, 225)), low = Color(nsColor: Maple.rgb(26, 106, 170))
        c.label.font(.system(size: 10, weight: .bold)).foregroundStyle(.white).lineLimit(1).fixedSize()
            .padding(.horizontal, 8).frame(height: 16)
            .background(RoundedRectangle(cornerRadius: 2.5).fill(LinearGradient(colors: [c.isPressed ? low : top, low], startPoint: .top, endPoint: .bottom)))
            .overlay(RoundedRectangle(cornerRadius: 2.5).strokeBorder(Color(nsColor: Maple.rgb(30, 50, 80)), lineWidth: 1))
            .contentShape(Rectangle())
    }
}

/// 页签：选中粉红、其余灰，下面一条红线（和背包、任务窗口一样）
struct MapleTabs<T: Hashable>: View {
    let items: [(T, String)]
    @Binding var selection: T
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                ForEach(items, id: \.0) { v, name in
                    let on = v == selection
                    Text(name).font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                        .frame(maxWidth: .infinity).frame(height: 18)
                        .background(UnevenRoundedRectangle(topLeadingRadius: 4, topTrailingRadius: 4)
                            .fill(Color(nsColor: on ? Maple.pink : Maple.tabGrey)))
                        .contentShape(Rectangle())
                        .onTapGesture { selection = v }
                        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
                }
            }
            Rectangle().fill(Color(nsColor: Maple.red)).frame(height: 2)
        }
    }
}

/// 滚动条：和游戏里一样——上下蓝色箭头按钮、浅灰滑槽、固定高度的蓝滑块；内容不够长时按钮变灰、没有滑块。
/// 系统滚动条没有箭头了，所以画法和鼠标操作都自己来（滚轮、触控板照常由滚动视图处理）。
final class MapleScroller: NSScroller {
    static let width: CGFloat = 15
    private let btn: CGFloat = 13, knobH: CGFloat = 25
    override class var isCompatibleWithOverlayScrollers: Bool { false }
    override class func scrollerWidth(for controlSize: NSControl.ControlSize, scrollerStyle: NSScroller.Style) -> CGFloat { width }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// 滚动条是滚动视图的直接子视图，enclosingScrollView 取不到
    private var host: NSScrollView? { superview as? NSScrollView }
    private var active: Bool { docMax > 0.5 }
    private var slot: CGRect { CGRect(x: 0, y: btn, width: bounds.width, height: max(0, bounds.height - btn * 2)) }
    private var knob: CGRect {
        let h = min(knobH, slot.height)
        return CGRect(x: 1, y: (slot.minY + CGFloat(doubleValue) * (slot.height - h)).rounded(), width: 13, height: h)
    }
    override var doubleValue: Double { didSet { needsDisplay = true } }
    override var knobProportion: CGFloat { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.shouldAntialias = false
        // 滑槽：两边深、中间浅
        for (inset, g) in [(0, 215), (2, 219), (3, 227), (4, 231)] {
            Maple.rgb(g, g, g).setFill(); CGRect(x: CGFloat(inset), y: 0, width: bounds.width - CGFloat(inset * 2), height: bounds.height).fill()
        }
        button(CGRect(x: 1, y: 0, width: 13, height: btn), up: true)
        button(CGRect(x: 1, y: bounds.height - btn, width: 13, height: btn), up: false)
        if active, slot.height > 12 { drawKnob(knob) }
    }

    /// 切角的方块
    private func plate(_ r: CGRect, _ c: NSColor) {
        c.setFill()
        r.insetBy(dx: 1, dy: 0).fill(); r.insetBy(dx: 0, dy: 1).fill()
    }
    private func shade(_ r: CGRect, _ a: NSColor, _ b: NSColor) {
        NSGraphicsContext.saveGraphicsState()
        let p = NSBezierPath(rect: r.insetBy(dx: 1, dy: 0)); p.append(NSBezierPath(rect: r.insetBy(dx: 0, dy: 1)))
        p.addClip()
        NSGradient(starting: a, ending: b)?.draw(in: r, angle: 70)
        NSGraphicsContext.restoreGraphicsState()
    }

    private func button(_ r: CGRect, up: Bool) {
        plate(r, Maple.rgb(136, 153, 170))
        plate(r.insetBy(dx: 1, dy: 1), Maple.rgb(238, 238, 255))
        let face = r.insetBy(dx: 2, dy: 2)
        if active { shade(face, Maple.rgb(34, 119, 170), Maple.rgb(17, 68, 119)) }
        else { shade(face, Maple.rgb(190, 190, 194), Maple.rgb(160, 160, 166)) }
        // 箭头：5 行像素的折角
        (active ? Maple.rgb(178, 212, 224) : Maple.rgb(235, 235, 238)).setFill()
        let rows: [[Int]] = [[4], [3, 4, 5], [2, 3, 4, 5, 6], [1, 2, 3, 5, 6, 7]]
        for (i, xs) in rows.enumerated() {
            let y = up ? face.minY + 2 + CGFloat(i) : face.maxY - 3 - CGFloat(i)
            for x in xs { CGRect(x: face.minX + CGFloat(x), y: y, width: 1, height: 1).fill() }
        }
    }

    private func drawKnob(_ r: CGRect) {
        plate(r, Maple.rgb(119, 136, 153))
        plate(r.insetBy(dx: 1, dy: 1), Maple.rgb(238, 238, 255))
        let face = r.insetBy(dx: 2, dy: 2)
        shade(face, Maple.rgb(102, 153, 187), Maple.rgb(51, 92, 128))
        Maple.rgb(51, 85, 119).setFill()      // 底下两行深色
        CGRect(x: face.minX + 1, y: face.maxY - 2, width: face.width - 2, height: 2).fill()
        Maple.rgb(68, 100, 134).setFill()     // 中间三道防滑纹
        for i in -1...1 { CGRect(x: face.midX - 1.5, y: face.midY.rounded() + CGFloat(i * 2), width: 3, height: 1).fill() }
    }

    // MARK: 鼠标
    private var docMax: CGFloat {
        guard let s = host, let d = s.documentView else { return 0 }
        return max(0, d.frame.height - s.contentView.bounds.height)
    }
    private func scroll(to y: CGFloat) {
        guard let s = host else { return }
        s.contentView.scroll(to: NSPoint(x: s.contentView.bounds.minX, y: min(max(0, y), docMax)))
        s.reflectScrolledClipView(s.contentView)
        onUser?()
    }
    /// 用户拖、点了滚动条
    var onUser: (() -> Void)?
    override func mouseDown(with e: NSEvent) {
        guard active, let s = host, let window else { return }
        let p = convert(e.locationInWindow, from: nil)
        func step(_ d: CGFloat) { scroll(to: s.contentView.bounds.minY + d) }
        if slot.contains(p), slot.height > knob.height {
            // 点滑块拖动；点滑槽直接跳过去再拖
            let grab = knob.contains(p) ? p.y - knob.minY : knob.height / 2
            func drag(_ y: CGFloat) { scroll(to: (y - grab - slot.minY) / (slot.height - knob.height) * docMax) }
            if !knob.contains(p) { drag(p.y) }
            while let ev = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]), ev.type != .leftMouseUp {
                drag(convert(ev.locationInWindow, from: nil).y)
            }
        } else {
            // 箭头：点一下滚一点，按住连续滚
            let d: CGFloat = p.y < btn ? -24 : 24
            step(d)
            var wait = 0.35
            while window.nextEvent(matching: .leftMouseUp, until: Date(timeIntervalSinceNow: wait), inMode: .eventTracking, dequeue: true) == nil {
                // 兜底：松开事件丢了也不会一直卡在这里
                if NSEvent.pressedMouseButtons & 1 == 0 { break }
                step(d); wait = 0.06
            }
        }
    }
}
