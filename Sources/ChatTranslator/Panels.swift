// 旁边的翻译面板 + 框选区域。
// 全部是我们自己的窗口，由系统叠放在游戏上方或旁边；游戏本身不受影响。
// 悬浮在游戏上的窗口都设为“鼠标穿透”，点击会直接落到游戏上。
import AppKit
import TranslatorCore

struct Entry {
    let original: String
    let chinese: String
    var id: Int = -1
    var color: NSColor? = nil
}

func makePanel(clickThrough: Bool) -> NSPanel {
    let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    p.isOpaque = false
    p.backgroundColor = .clear
    p.hasShadow = false
    p.level = .floating
    p.ignoresMouseEvents = clickThrough
    p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    p.hidesOnDeactivate = false
    return p
}

// MARK: - 旁边：在游戏窗口右侧显示历史记录（不挡游戏，可以滚动）

final class SidePanel: NSObject {
    let panel = makePanel(clickThrough: false)
    private let textView: NSTextView
    private let scroll: NSScrollView
    var showOriginal = true
    let space = SideSpace()
    /// 先给聊天留够高度（至少三四条），剩下的才给顶部
    private func updateBudget() {
        let chat: CGFloat = chatTitle.isHidden ? 0 : MapleCardView.strip + 5 + max(150, actualFontSize * 13) + 5
        let b = max(100, panel.frame.height - (4 + Maple.titleBar) - 5 - chat - 8)
        if abs(space.budget - b) > 0.5 { space.budget = b }
    }
    /// 聊天翻译的中文字号（英文原文小 2 号）；0 = 自动：面板矮（800×600 窗口）用 11，高的用 14
    var chatFontSize: CGFloat = 0 { didSet { if chatFontSize != oldValue { refresh() } } }
    var actualFontSize: CGFloat { chatFontSize > 0 ? chatFontSize : panel.frame.height < 700 ? 11 : 14 }
    private var lastEntries: [Entry] = []
    private func refresh() {
        updateBudget()
        render(lastEntries)
    }
    private var scrollBelowStatus: NSLayoutConstraint!, scrollBelowTitle: NSLayoutConstraint!
    /// 正常运行时状态写在标题条里（不占一行）；需要操作时才单独显示一行橙字
    func setStatus(_ s: String, ok: Bool) {
        statusText = s; statusOK = ok
        statusLabel.stringValue = ok ? "" : s
        statusLabel.isHidden = ok || chatTitle.isHidden
        let t = NSMutableAttributedString(string: shopOn ? "店铺聊天" : "聊天翻译", attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .bold), .foregroundColor: NSColor.white])
        if ok { t.append(NSAttributedString(string: "   " + s, attributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.white.withAlphaComponent(0.9)])) }
        chatTitle.attributedStringValue = t
        (ok ? scrollBelowStatus : scrollBelowTitle).isActive = false
        (ok ? scrollBelowTitle : scrollBelowStatus).isActive = true
    }
    let statusLabel = NSTextField(wrappingLabelWithString: "正在寻找游戏窗口…")
    let selectButton = MapleButton(title: "框选聊天区域", target: nil, action: nil)
    /// 切换：聊天 / 店铺聊天
    private let shopButton = MapleButton(title: "店铺聊天", target: nil, action: nil)
    private var shopOn = false, chatEntries: [Entry] = [], shopEntries: [Entry] = [], statusText = "", statusOK = true
    @objc private func toggleShop() {
        shopOn.toggle(); pinned = true
        shopButton.title = shopOn ? "回到聊天" : "店铺聊天"
        selectButton.isHidden = shopOn || chatCard.isHidden
        setStatus(statusText, ok: statusOK)
        rerender()
    }
    private func rerender() { render(shopOn ? shopEntries : chatEntries) }
    /// 店铺里的聊天（有新的、又没在看时按钮上加个点）
    func showShop(_ e: [Entry]) {
        let new = e.map(\.original) != shopEntries.map(\.original) && !e.isEmpty
        shopEntries = e
        if shopOn { rerender() } else if new { shopButton.title = "店铺聊天 •" }
    }
    func show(_ entries: [Entry]) { chatEntries = entries; if !shopOn { rerender() } }
    /// 顶部的角色信息（名字、等级、经验统计）；经验统计关掉时高度为 0
    private let header = NSView()
    private var headerHeight: NSLayoutConstraint!
    private var headerContent: NSView?
    private var chatCard = NSView()
    private let chatTitle = NSTextField(labelWithString: "聊天翻译")

    override init() {
        // 冒险岛窗口样式；固定浅色外观（系统深色模式下文字不能变白）
        let root = MapleFrameView()
        panel.appearance = NSAppearance(named: .aqua)

        scroll = NSTextView.scrollableTextView()
        textView = scroll.documentView as! NSTextView
        super.init()
        textView.isEditable = false
        textView.drawsBackground = false
        _ = textView.layoutManager
        textView.minSize = .zero          // 内容少时不要撑高（否则没内容也能往下滚出一块空白）
        textView.textContainerInset = NSSize(width: 6, height: 4)
        scroll.drawsBackground = false
        // 游戏样式的滚动条（一直显示）
        scroll.scrollerStyle = .legacy
        scroll.autohidesScrollers = false
        scroll.hasVerticalScroller = true
        let bar = MapleScroller()
        scroll.verticalScroller = bar

        let title = chatTitle

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = Maple.warn
        selectButton.isBordered = false
        // 聊天翻译放在一块白底内板上（和顶部的角色、收益一样）
        chatCard = MapleCardView()
        title.font = .systemFont(ofSize: 11, weight: .bold); title.textColor = .white
        chatCard.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(chatCard)
        shopButton.isBordered = false; shopButton.target = self; shopButton.action = #selector(toggleShop)
        for v in [header, scroll, title, statusLabel, selectButton, shopButton] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        headerHeight = header.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 4 + Maple.titleBar),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            headerHeight,
            chatCard.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 5),
            chatCard.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            chatCard.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            title.centerYAnchor.constraint(equalTo: chatCard.topAnchor, constant: MapleCardView.strip / 2),
            title.leadingAnchor.constraint(equalTo: chatCard.leadingAnchor, constant: 10),
            selectButton.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            selectButton.trailingAnchor.constraint(equalTo: shopButton.leadingAnchor, constant: -6),
            shopButton.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            shopButton.trailingAnchor.constraint(equalTo: chatCard.trailingAnchor, constant: -8),
            statusLabel.topAnchor.constraint(equalTo: chatCard.topAnchor, constant: MapleCardView.strip + 4),
            statusLabel.leadingAnchor.constraint(equalTo: chatCard.leadingAnchor, constant: 10),
            statusLabel.trailingAnchor.constraint(equalTo: chatCard.trailingAnchor, constant: -10),
            scroll.leadingAnchor.constraint(equalTo: chatCard.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: chatCard.trailingAnchor, constant: -4),
            scroll.bottomAnchor.constraint(equalTo: chatCard.bottomAnchor, constant: -4),
            chatCard.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
        ])
        scrollBelowStatus = scroll.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 2)
        scrollBelowTitle = scroll.topAnchor.constraint(equalTo: chatCard.topAnchor, constant: MapleCardView.strip + 1)
        scrollBelowStatus.isActive = true
        chatTitle.lineBreakMode = .byTruncatingTail
        chatTitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        chatTitle.trailingAnchor.constraint(lessThanOrEqualTo: selectButton.leadingAnchor, constant: -6).isActive = true
        panel.contentView = root
        // 一直停在最新；只有用户自己往上滚才停，滚回底部又继续。上面的内容变高变矮（聊天框跟着变）也不能丢
        bar.onUser = { [weak self] in self?.userScrolled() }
        NotificationCenter.default.addObserver(forName: NSScrollView.didLiveScrollNotification, object: scroll, queue: .main) { [weak self] _ in self?.userScrolled() }
        scroll.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in self?.stick() }
        textView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: textView, queue: .main) { [weak self] _ in self?.stick() }
    }
    /// 跟着最新
    private var pinned = true
    private func userScrolled() { pinned = scroll.contentView.bounds.maxY >= textView.frame.height - 30 }
    private func stick() {
        guard pinned else { return }
        let y = max(0, textView.frame.height - scroll.contentView.bounds.height)
        if abs(scroll.contentView.bounds.minY - y) > 0.5 { scroll.contentView.scroll(to: NSPoint(x: 0, y: y)) }
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    /// 聊天翻译关着时，面板里只放角色、经验、任务（聊天卡片收起）
    func setChatVisible(_ on: Bool) {
        for v in [chatCard, scroll, shopButton] as [NSView] { v.isHidden = !on }
        selectButton.isHidden = !on || shopOn
        statusLabel.isHidden = !on || statusLabel.stringValue.isEmpty
        chatTitle.isHidden = !on
        updateBudget()
    }

    /// 顶部放一块内容（nil 就收起）
    func setHeader(_ v: NSView?) {
        headerContent?.removeFromSuperview()
        headerContent = v
        if let v {
            v.translatesAutoresizingMaskIntoConstraints = false
            header.addSubview(v)
            NSLayoutConstraint.activate([
                v.topAnchor.constraint(equalTo: header.topAnchor), v.bottomAnchor.constraint(equalTo: header.bottomAnchor),
                v.leadingAnchor.constraint(equalTo: header.leadingAnchor), v.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            ])
        }
        // 高度由内容量好了告诉我们（setHeaderHeight）：靠 NSHostingView 自己报的高度不算文字折行，会少报、居中溢出盖住标题和聊天
        headerHeight.constant = v == nil ? 0 : max(headerHeight.constant, 1)
        headerHeight.isActive = true
    }
    /// 内容的实际高度（宽度固定、文字折行以后）
    func setHeaderHeight(_ h: CGFloat) {
        guard headerContent != nil, h > 0, abs(headerHeight.constant - h) > 0.5 else { return }
        headerHeight.constant = h.rounded(.up)
    }

    func place(beside game: CGRect) {
        let g = Coords.toAppKit(game)
        let screen = NSScreen.screens.first { $0.frame.intersects(g) } ?? NSScreen.main!
        let vis = screen.visibleFrame
        var w = min(480, vis.maxX - g.maxX - 4)
        var x = g.maxX + 4
        if w < 220 {                      // 右边放不下，就放左边
            w = min(480, g.minX - vis.minX - 4)
            x = g.minX - 4 - w
        }
        if w < 220 { w = 300; x = vis.maxX - w }   // 两边都放不下，贴屏幕右边（会盖住一点游戏）
        let h = min(max(g.height, 400), vis.height)
        let y = max(vis.minY, min(g.maxY - h, vis.maxY - h))
        let f = CGRect(x: x, y: y, width: w, height: h)
        if panel.frame != f { panel.setFrame(f, display: true); refresh() }   // 窗口大小变了，自动字号跟着变
    }

    private var shownKey = ""
    private func render(_ list: [Entry]) {
        let entries = list.isEmpty && shopOn ? [Entry(original: "", chinese: "打开个人商店后，店里的聊天会记在这里。")] : list
        // 内容没变就不重排（每秒都重排，正在看的位置会跳）
        lastEntries = list
        let size = actualFontSize
        let key = "\(showOriginal) \(size)\n" + entries.map { $0.original + "\t" + $0.chinese + ($0.color == nil ? "" : "*") }.joined(separator: "\n")
        guard key != shownKey else { return }
        shownKey = key
        let s = NSMutableAttributedString()
        let p = NSMutableParagraphStyle(); p.paragraphSpacing = size < 13 ? 3 : 6
        for e in entries {
            if showOriginal, !e.original.isEmpty {
                s.append(NSAttributedString(string: e.original + "\n", attributes: [
                    .font: NSFont.systemFont(ofSize: max(8, size - 2)), .foregroundColor: Maple.sub]))
            }
            s.append(NSAttributedString(string: e.chinese + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: size), .foregroundColor: e.color ?? Maple.text, .paragraphStyle: p]))
        }
        if s.string.hasSuffix("\n") { s.deleteCharacters(in: NSRange(location: s.length - 1, length: 1)) }   // 末尾别空一行
        textView.textStorage?.setAttributedString(s)
        // 取 layoutManager 就用老的排版方式：高度是准的（新的只估算，滚动条会跳、滚不到底）
        if let lm = textView.layoutManager, let tc = textView.textContainer { lm.ensureLayout(for: tc) }
        textView.sizeToFit()
        stick()
        scroll.reflectScrolledClipView(scroll.contentView)
    }
}

// MARK: - 框选聊天区域：在游戏窗口上铺一层半透明遮罩，用鼠标拖一个框（只在我们自己的窗口里接收鼠标）

final class RegionSelector: NSObject {
    private var panel: NSPanel?
    private var onDone: ((CGRect?) -> Void)?

    /// game：游戏窗口（屏幕左上原点）。回调返回窗口内左上原点的矩形。
    func begin(game: CGRect, onDone: @escaping (CGRect?) -> Void) {
        self.onDone = onDone
        let p = KeyPanel(contentRect: Coords.toAppKit(game), styleMask: [.borderless], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = .popUpMenu
        let v = SelectView(frame: CGRect(origin: .zero, size: game.size))
        v.onFinish = { [weak self] r in self?.finish(r) }
        p.contentView = v
        panel = p
        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)
        p.makeFirstResponder(v)
    }

    private func finish(_ r: CGRect?) {
        panel?.orderOut(nil)
        panel = nil
        onDone?(r)
        onDone = nil
    }
}

final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class SelectView: NSView {
    var onFinish: ((CGRect?) -> Void)?
    private var start: CGPoint?
    private var current: CGRect?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.35).setFill()
        bounds.fill()
        let tip = "拖动鼠标，框出聊天文字区域（从最上面一行到最下面一行，左边贴着聊天框左边）\n按 Esc 取消"
        NSAttributedString(string: tip, attributes: [.font: NSFont.boldSystemFont(ofSize: 14), .foregroundColor: NSColor.white])
            .draw(in: CGRect(x: 16, y: 40, width: bounds.width - 32, height: 60))
        if let r = current {
            NSColor.systemYellow.withAlphaComponent(0.15).setFill()
            r.fill(using: .sourceOver)
            NSColor.systemYellow.setStroke()
            let path = NSBezierPath(rect: r); path.lineWidth = 2; path.stroke()
        }
    }
    override func mouseDown(with e: NSEvent) { start = convert(e.locationInWindow, from: nil) }
    override func mouseDragged(with e: NSEvent) {
        guard let s = start else { return }
        let p = convert(e.locationInWindow, from: nil)
        current = CGRect(x: min(s.x, p.x), y: min(s.y, p.y), width: abs(p.x - s.x), height: abs(p.y - s.y))
        needsDisplay = true
    }
    override func mouseUp(with e: NSEvent) {
        if let r = current, r.width > 40, r.height > 20 { onFinish?(r) }
    }
    override func keyDown(with e: NSEvent) {
        if e.keyCode == 53 { onFinish?(nil) }   // Esc
    }
}

// MARK: - 物品说明框翻译（正下方 / 覆盖）。鼠标穿透，不挡游戏操作。

enum TipMode: String, CaseIterable {
    case below = "正下方"
    case overlay = "原地替换（保留图标）"
    case side = "旁边翻译窗"
}

final class TooltipPanel {
    let panel = makePanel(clickThrough: true)
    private let view = TooltipView()

    init() { panel.contentView = view }

    /// box：游戏里说明框在屏幕上的位置（左上原点）；game：游戏窗口（左上原点）
    func show(_ zh: TooltipZh, box: CGRect, game: CGRect, mode: TipMode) {
        view.zh = zh
        let screenBox = Coords.toAppKit(box)
        var f: CGRect
        switch mode {
        case .overlay:
            view.fitHeight = screenBox.height
            f = screenBox
        default:
            view.fitHeight = nil
            let size = view.fittingSize(width: max(box.width, 240))
            let g = Coords.toAppKit(game)
            let vis = NSScreen.screens.first { $0.frame.intersects(g) }?.visibleFrame ?? g
            // 先放正下方；放不下就放上方；再不行放右边、左边；都不行就盖在原框上
            let below = CGRect(x: screenBox.minX, y: screenBox.minY - size.height - 2, width: size.width, height: size.height)
            let above = CGRect(x: screenBox.minX, y: screenBox.maxY + 2, width: size.width, height: size.height)
            let right = CGRect(x: screenBox.maxX + 2, y: screenBox.maxY - size.height, width: size.width, height: size.height)
            let left = CGRect(x: screenBox.minX - size.width - 2, y: screenBox.maxY - size.height, width: size.width, height: size.height)
            if let fit = [below, above, right, left].first(where: { vis.contains($0) }) {
                f = fit
            } else {
                view.fitHeight = screenBox.height
                f = screenBox
            }
        }
        if panel.frame != f { panel.setFrame(f, display: true) }
        view.needsDisplay = true
        panel.orderFrontRegardless()
    }

    func hide() { panel.orderOut(nil) }
}

final class TooltipView: NSView {
    var zh: TooltipZh?
    /// 覆盖模式：必须放进原框的高度，放不下就缩小字号
    var fitHeight: CGFloat?
    override var isFlipped: Bool { true }

    private func text(scale: CGFloat) -> NSAttributedString {
        guard let z = zh else { return NSAttributedString() }
        let s = NSMutableAttributedString()
        let para = NSMutableParagraphStyle(); para.lineBreakMode = .byCharWrapping; para.paragraphSpacing = 2 * scale
        func add(_ t: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .white) {
            s.append(NSAttributedString(string: t + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: size * scale, weight: weight), .foregroundColor: color, .paragraphStyle: para]))
        }
        add(z.title + (z.isEquipped ? "（已装备）" : ""), size: 15, weight: .bold)
        for f in z.flags { add(f, size: 12, color: NSColor.systemOrange) }
        if let r = z.reqLine { add(r, size: 12, color: NSColor(white: 0.85, alpha: 1)) }
        // 职业名中间加“不断行”字符，换行时不会把“飞侠”拆成两行
        if let j = z.jobLine { add(j.split(separator: " ").map { $0.map(String.init).joined(separator: "\u{2060}") }.joined(separator: " "), size: 12, color: NSColor.systemOrange) }
        if !z.stats.isEmpty {
            add("──────────", size: 9, color: NSColor(white: 0.6, alpha: 1))
            for st in z.stats { add("· " + st, size: 12.5) }
        }
        for d in z.desc { add(d, size: 12.5) }
        if s.length > 0 { s.deleteCharacters(in: NSRange(location: s.length - 1, length: 1)) }
        return s
    }

    func fittingSize(width: CGFloat) -> CGSize {
        let t = text(scale: 1)
        let r = t.boundingRect(with: CGSize(width: width - 16, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin])
        return CGSize(width: width, height: ceil(r.height) + 14)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedRed: 0.10, green: 0.12, blue: 0.30, alpha: 1).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
        NSColor(calibratedRed: 0.45, green: 0.5, blue: 0.85, alpha: 0.9).setStroke()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4).stroke()
        var scale: CGFloat = 1
        var t = text(scale: scale)
        var r = t.boundingRect(with: CGSize(width: bounds.width - 16, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin])
        if let fh = fitHeight {
            while r.height + 14 > fh, scale > 0.6 {
                scale -= 0.05
                t = text(scale: scale)
                r = t.boundingRect(with: CGSize(width: bounds.width - 16, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin])
            }
        }
        t.draw(with: CGRect(x: 8, y: 7, width: bounds.width - 16, height: r.height), options: [.usesLineFragmentOrigin])
    }
}


// MARK: - 任务窗口翻译：在指定区域上画几块“底色 + 中文”（鼠标穿透）

struct OverlayItem {
    var rect: CGRect          // 面板内位置（点，左上原点）
    var text: String
    var bg: NSColor
    /// 底图：按行取原画面最多的颜色拼成的背景（保留渐变、高光线，颜色和原画面完全一样）；有就画它，没有才用 bg 纯色
    var bgImage: CGImage? = nil
    var fg: NSColor
    var fontSize: CGFloat
    var bold = false
    var wrap = false          // 多行自动换行（正文）；否则单行，放不下就缩小字号
    var padX: CGFloat = 3     // 文字离左右边的距离（灰框里要让开边框）
    var center = false        // 文字在格子里居中（职业行五个职业等距排开）
    /// 文字末尾这一段用另一种颜色（“+6 (5 +1)” 里的 “+1)”，和游戏里一样）
    var accentSuffix: String? = nil
    var accentColor: NSColor? = nil
    /// 文字里所有符合这个正则的片段用 accentColor（对话框里红色的 “5%的折扣”、蓝色的数字）
    var accentPattern: String? = nil
    /// 第一行往右缩进（前面留给原画面里的名字）
    var firstIndent: CGFloat = 0
    /// 第一行汉字的中线（面板内 y）：和旁边保留的英文名字对齐用
    var glyphCenterY: CGFloat? = nil
}

final class LabelsPanel {
    let panel = makePanel(clickThrough: true)
    private let view = LabelsView()
    init() { panel.contentView = view }

    /// area：面板在屏幕上的位置（左上原点）
    func show(_ items: [OverlayItem], area: CGRect, level: NSWindow.Level) {
        view.items = items
        let f = Coords.toAppKit(area)
        if panel.frame != f { panel.setFrame(f, display: false) }
        if panel.level != level { panel.level = level }
        view.needsDisplay = true
        panel.orderFrontRegardless()
    }
    /// 只移动位置（游戏窗口被拖动、内容没变）
    func move(to area: CGRect) {
        let f = Coords.toAppKit(area)
        if panel.frame != f { panel.setFrame(f, display: true) }
    }
    func hide() { panel.orderOut(nil) }
    var isVisible: Bool { panel.isVisible }
}

final class LabelsView: NSView {
    var items: [OverlayItem] = []
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        // 先画完所有底色，再统一写字：行与行的底色有重叠，边画底色边写字时后一行的底色会盖掉前一行字的下沿
        for it in items {
            if let img = it.bgImage {
                NSGraphicsContext.current?.imageInterpolation = .none
                NSImage(cgImage: img, size: NSSize(width: img.width, height: img.height))
                    .draw(in: it.rect, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: [.interpolation: NSNumber(value: NSImageInterpolation.none.rawValue)])
            } else {
                it.bg.setFill()
                NSBezierPath(rect: it.rect).fill()
            }
        }
        for it in items {
            let inner = it.rect.insetBy(dx: it.padX, dy: 1)
            var size = it.fontSize
            let para = NSMutableParagraphStyle()
            para.lineBreakMode = it.wrap ? .byWordWrapping : .byClipping
            para.paragraphSpacing = it.wrap ? 4 : 0
            para.firstLineHeadIndent = it.firstIndent
            if it.center { para.alignment = .center }
            func attr(_ sz: CGFloat) -> NSAttributedString {
                let a = NSMutableAttributedString(string: it.text, attributes: [
                    .font: NSFont.systemFont(ofSize: sz, weight: it.bold ? .semibold : .regular),
                    .foregroundColor: it.fg, .paragraphStyle: para])
                if let suf = it.accentSuffix, let c = it.accentColor, let r = it.text.range(of: suf, options: .backwards) {
                    a.addAttribute(.foregroundColor, value: c, range: NSRange(r, in: it.text))
                }
                if let pat = it.accentPattern, let c = it.accentColor, let re = try? NSRegularExpression(pattern: pat) {
                    for m in re.matches(in: it.text, range: NSRange(it.text.startIndex..., in: it.text)) {
                        a.addAttribute(.foregroundColor, value: c, range: m.range)
                    }
                }
                return a
            }
            var a = attr(size)
            var r = a.boundingRect(with: CGSize(width: inner.width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin])
            // 放不下就缩小字号（单行看宽度，多行看高度）
            while size > 7, (it.wrap ? r.height > inner.height : a.size().width > inner.width) {
                size -= 0.5
                a = attr(size)
                r = a.boundingRect(with: CGSize(width: inner.width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin])
            }
            let h = it.wrap ? min(r.height, inner.height) : a.size().height
            var y = it.wrap ? inner.minY : inner.midY - h / 2
            if let cy = it.glyphCenterY {
                // 实测（11 号字）：这样画出来汉字笔画的中线正好落在 cy
                var asc: CGFloat = 0
                _ = CTLineGetTypographicBounds(CTLineCreateWithAttributedString(a), &asc, nil, nil)
                y = cy + size * 0.29 - asc
            }
            a.draw(with: CGRect(x: inner.minX, y: y, width: inner.width, height: it.wrap ? max(inner.height, r.height) : h), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
    }
}
