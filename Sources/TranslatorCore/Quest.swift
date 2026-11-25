// 任务窗口（QUEST）：找窗口位置、整理识别结果、滚动时把看到的说明拼成完整一段。
// 只处理截图像素，不接触游戏，也不替用户滚动。
import Foundation
import CoreGraphics

/// 任务窗口里各块区域在截图中的位置（像素，左上原点）
public struct QuestLayout: Sendable, Equatable {
    /// 左侧任务列表（分类 + 任务名）
    public var list: CGRect
    /// 右侧详情顶部蓝色标题区（任务名、等级），只取左边文字部分，右边是 NPC 头像
    public var header: CGRect?
    /// 右侧详情正文（任务目标 + 说明），带滚动条
    public var content: CGRect?
}

/// 任务窗口上面的页签
public enum QuestTab: Int, Sendable { case available, inProgress, completed }

public enum QuestDetector {
    /// 选中的页签是粉红的；看不出（被挡住）返回 nil
    public static func tab(in im: CGImage, scale s: Int, list: CGRect) -> QuestTab? {
        guard let p = MiniMap.Pix(im) else { return nil }
        let x0 = Int(list.minX) - 4 * s, y0 = Int(list.minY) - 28 * s, y1 = Int(list.minY) - 11 * s
        guard y0 >= 0, y1 <= p.h else { return nil }
        let share = (0..<3).map { t -> Double in
            var n = 0, all = 0
            for y in y0..<y1 { for x in stride(from: max(0, x0 + (t * 72 + 6) * s), to: min(p.w, x0 + (t * 72 + 66) * s), by: 1) {
                let c = p.rgb(x, y); all += 1
                if c.0 > 180, c.1 < 150, c.2 > 80, c.2 < 175, c.0 - c.1 > 70 { n += 1 }
            } }
            return all > 0 ? Double(n) / Double(all) : 0
        }
        let best = share.indices.max { share[$0] < share[$1] }!
        guard share[best] > 0.3, share.indices.allSatisfy({ $0 == best || share[$0] < 0.1 }) else { return nil }
        return QuestTab(rawValue: best)
    }

    /// 窗口边框颜色（实测 (85,119,153)）
    @inline(__always) static func isFrame(_ r: Int, _ g: Int, _ b: Int, tol: Int = 16) -> Bool {
        abs(r - 85) <= tol && abs(g - 119) <= tol && abs(b - 153) <= tol
    }

    /// 在整张游戏截图里找任务窗口。scale：每点多少像素。
    /// 特征（实测，单位点）：左窗口上边框是一条约 235 点长的边框色横线，正下方 366 点处还有一条同样长的横线；
    /// 详情面板打开时，右边 247 点处（同一高度往下 366 点）还有一条约 295 点长的横线。
    public static func find(in img: CGImage, scale s: CGFloat) -> QuestLayout? {
        guard let (buf, w, h) = TooltipDetector.rgba(img) else { return nil }
        // 低分辨率截图里 1 像素的边框线会和旁边的白色混一点，放宽颜色范围（靠上下两条线相距 366 点来排除误认）
        let tol = s < 1.5 ? 45 : 16
        @inline(__always) func frame(_ x: Int, _ y: Int) -> Bool {
            guard x >= 0, y >= 0, x < w, y < h else { return false }
            let i = (y * w + x) * 4
            return isFrame(Int(buf[i]), Int(buf[i + 1]), Int(buf[i + 2]), tol: tol)
        }
        /// 从 (x, y) 往右连续是边框色的长度
        func run(_ x: Int, _ y: Int) -> Int {
            var n = 0
            while x + n < w, frame(x + n, y) { n += 1 }
            return n
        }
        let pt = { (v: CGFloat) in Int((v * s).rounded()) }
        let minLen = pt(225), maxLen = pt(245)
        let gap = pt(366)
        for y in 0..<max(0, h - gap) {
            var x = 0
            while x < w {
                guard frame(x, y) else { x += 1; continue }
                let len = run(x, y)
                defer { x += max(len, 1) }
                guard len >= minLen, len <= maxLen else { continue }
                // 下边对应位置也要有一条（外框比上边框左右各宽 3 点）
                let y2 = y + gap
                var bottomOK = false
                for dy in -pt(3)...pt(3) {
                    let bx = x - pt(3)
                    if run(max(0, bx - pt(2)), y2 + dy) >= minLen || run(x, y2 + dy) >= minLen { bottomOK = true; break }
                }
                guard bottomOK else { continue }
                // 上边框下面是白色标题条（QUEST）。小地图的下边框可能正好一样宽、下面 366 点又是状态栏边线，但它下面是游戏画面。
                // 小地图压在标题条上时是浅蓝灰 / 白色，也算
                var titleN = 0, titleOK = 0
                for dy in [pt(7), pt(10), pt(13)] where y + dy < h {
                    for tx in stride(from: x + len / 3, to: x + len * 17 / 20, by: max(1, pt(2))) {
                        let i = ((y + dy) * w + tx) * 4, c = (Int(buf[i]), Int(buf[i + 1]), Int(buf[i + 2]))
                        titleN += 1
                        if min(c.0, c.1, c.2) > 225 || MiniMap.strip(c) { titleOK += 1 }
                    }
                }
                guard titleN > 0, titleOK * 2 >= titleN else { continue }
                // 找到了。以上边框起点往左 3 点为窗口左边
                let ax = CGFloat(x) - 3 * s, ay = CGFloat(y)
                func r(_ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat) -> CGRect {
                    CGRect(x: ax + x0 * s, y: ay + y0 * s, width: (x1 - x0) * s, height: (y1 - y0) * s)
                        .intersection(CGRect(x: 0, y: 0, width: w, height: h))
                }
                var layout = QuestLayout(list: r(7, 50, 222, 346))
                // 详情面板：右边同一高度往下 366 点处有一条长横线
                let rx = Int(ax) + pt(247)
                var hasDetail = false
                for dy in -pt(3)...pt(3) where run(rx, y2 + dy) >= pt(250) || run(rx + pt(3), y2 + dy) >= pt(250) { hasDetail = true; break }
                if hasDetail {
                    // 右边到蓝框里那根竖线内侧为止（竖线约在 427 点处，再往右是 NPC 头像的底色）
                    layout.header = r(255, 23, 425, 101)
                    layout.content = r(255, 106, 523, 364)
                }
                return layout
            }
        }
        return nil
    }

    /// 正文区顶部的灰色框（任务摘要 / 目标框）：返回它占的上下范围（0~1，左上原点）。
    /// 做法：每行取最多的颜色，白底是最常见的那种近白色（不能取最常见的颜色：目标多时灰框占一大半）；从顶部附近开始连续“不是白底”的那段行就是灰框（含边框）。
    public static func summaryBand(in img: CGImage) -> (top: Double, bottom: Double)? {
        guard let (buf, w, h) = TooltipDetector.rgba(img), h > 20 else { return nil }
        var rows = [UInt32](repeating: 0, count: h)
        for y in 0..<h {
            var count: [UInt32: Int] = [:]
            for x in stride(from: 0, to: w, by: 2) {
                let i = (y * w + x) * 4
                count[UInt32(buf[i]) << 16 | UInt32(buf[i + 1]) << 8 | UInt32(buf[i + 2]), default: 0] += 1
            }
            rows[y] = count.max(by: { $0.value < $1.value })?.key ?? 0
        }
        var freq: [UInt32: Int] = [:]
        for r in rows { freq[r, default: 0] += 1 }
        // 灰框是 (225,222,213) 左右，白底三个通道都在 240 以上；整屏都是灰框时没有白底
        let white = freq.filter { $0.key >> 16 >= 240 && ($0.key >> 8) & 255 >= 240 && $0.key & 255 >= 240 }
        let body = white.max(by: { $0.value < $1.value })?.key ?? 0xFFFFFF
        guard let start = (0..<Int(Double(h) * 0.15)).first(where: { rows[$0] != body }) else { return nil }
        var end = start
        while end + 1 < h, !(rows[end + 1] == body && (end + 2 >= h || rows[end + 2] == body)) { end += 1 }
        guard Double(end - start + 1) >= Double(h) * 0.06 else { return nil }
        return (Double(start) / Double(h), Double(end + 1) / Double(h))
    }

    /// 快速确认窗口还在：截一条细横条（边框线所在位置），里面有没有一段足够长的边框色横线
    public static func hasFrameLine(in img: CGImage, minRun: Int) -> Bool {
        guard let (buf, w, h) = TooltipDetector.rgba(img) else { return false }
        for y in 0..<h {
            var run = 0
            for x in 0..<w {
                let i = (y * w + x) * 4
                if isFrame(Int(buf[i]), Int(buf[i + 1]), Int(buf[i + 2]), tol: 45) {
                    run += 1
                    if run >= minRun { return true }
                } else { run = 0 }
            }
        }
        return false
    }

    /// 截图里一块区域的指纹（判断列表 / 正文有没有变化）
    public static func fingerprint(_ img: CGImage, rect: CGRect, skip: CGRect? = nil) -> Int {
        guard let (buf, w, h) = TooltipDetector.rgba(img) else { return 0 }
        var hash = 5381
        let x0 = max(0, Int(rect.minX)), x1 = min(w, Int(rect.maxX)), y0 = max(0, Int(rect.minY)), y1 = min(h, Int(rect.maxY))
        for y in stride(from: y0, to: y1, by: 2) {
            for x in stride(from: x0, to: x1, by: 3) {
                if let skip, skip.contains(CGPoint(x: x, y: y)) { continue }
                let i = (y * w + x) * 4
                hash = (hash &* 33) &+ Int(buf[i] >> 3) &+ Int(buf[i + 1] >> 3) &* 7
            }
        }
        return hash
    }
}

/// 任务列表的一行（分类或任务名），位置是在列表区域里的比例（0~1，左上原点）
public struct QuestListLine: Sendable, Equatable {
    public var text: String
    public var minX: Double, maxX: Double, minY: Double, maxY: Double
    public var isCategory: Bool
}

extension QuestListLine {
    /// 分类行拆成 名字 + 数量。“Henesys (3)”，或数量认花了的 “Henesys i”“Kerning City t”（名字是已知地名时）
    public static func splitCategory(_ t: String) -> (name: String, count: String)? {
        if let r = t.range(of: "\\s*\\([0-9]+\\)$", options: .regularExpression) {
            return (String(t[..<r.lowerBound]), String(t[r]).trimmingCharacters(in: .whitespaces))
        }
        if let r = t.range(of: "\\s+\\S{1,3}$", options: .regularExpression) {
            let name = String(t[..<r.lowerBound])
            if knownCategories.contains(name.lowercased()) { return (name, "") }
        }
        return nil
    }
    /// 任务分类：地名和几个固定分类
    static let knownCategories: Set<String> = ["henesys", "ellinia", "perion", "kerning city", "lith harbor", "sleepywood", "ant tunnel",
        "orbis", "el nath", "ludibrium", "aqua road", "leafre", "mu lung", "nautilus", "maple island", "victoria island", "florina beach",
        "omega sector", "korean folk town", "herb town", "magatia", "ariant", "new leaf city", "amoria", "citizenship", "crafting", "event",
        "job", "free market", "zipangu", "showa", "singapore", "masteria", "edelstein", "ellin forest", "temple of time"]

    /// 识别结果整理成列表行：同一行被切成几段的拼回去；去掉行首复选框/减号图标被认成的 “1 ” “- ” “_ ”
    public static func parse(_ lines: [OCRLine]) -> [QuestListLine] {
        var rows: [QuestListLine] = []
        for l in lines.sorted(by: { ($0.minY, $0.minX) < ($1.minY, $1.minX) }) {
            let mid = (l.minY + l.maxY) / 2
            if let i = rows.firstIndex(where: { mid >= $0.minY && mid <= $0.maxY }) {
                // 同一行的另一段，按左右顺序拼起来
                var r = rows[i]
                r.text = l.minX < r.minX ? l.text + " " + r.text : r.text + " " + l.text
                r.minX = min(r.minX, l.minX); r.maxX = max(r.maxX, l.maxX)
                rows[i] = r
            } else {
                rows.append(QuestListLine(text: l.text, minX: l.minX, maxX: l.maxX, minY: l.minY, maxY: l.maxY, isCategory: false))
            }
        }
        return rows.compactMap { r in
            var r = r
            var t = latinize(r.text).trimmingCharacters(in: .whitespaces)
            t = t.replacingOccurrences(of: "^[-_1|lI=]\\s+", with: "", options: .regularExpression)
            t = t.replacingOccurrences(of: "\\(\\s*([0-9]+)\\s*[)}\\]]", with: "($1)", options: .regularExpression)
            guard t.filter(\.isLetter).count >= 2 else { return nil }
            r.text = t
            r.isCategory = splitCategory(t) != nil
            return r
        }
    }
}

/// 任务详情整理后的内容
public struct QuestDoc: Sendable, Equatable {
    public var title = ""
    public var level = ""
    /// 任务目标：“Zombie Mushroom 75 / 75”
    public var objectives: [(name: String, count: String)] = []
    /// 说明段落（折行已拼回）
    public var paragraphs: [String] = []

    public init() {}

    public static func == (a: QuestDoc, b: QuestDoc) -> Bool {
        a.title == b.title && a.level == b.level && a.paragraphs == b.paragraphs
            && a.objectives.map { $0.name + $0.count } == b.objectives.map { $0.name + $0.count }
    }

    /// 标题区：任务名 + “Level 21+”
    public mutating func parseHeader(_ lines: [OCRLine]) {
        for l in lines.sorted(by: { $0.minY < $1.minY }) {
            let t = latinize(l.text).trimmingCharacters(in: CharacterSet(charactersIn: " •·o°*").union(.whitespaces))
            if let m = t.range(of: "(?i)^level\\s*([0-9]+)\\s*\\+?", options: .regularExpression) {
                level = String(t[m]).filter(\.isNumber)
            } else if title.isEmpty, t.filter(\.isLetter).count >= 2 {
                title = t
            }
        }
    }

    /// 正文：按从上到下的顺序，分成任务目标和说明段落。
    /// 段落：上下间距明显大于行距的地方分段；同一段里的折行拼回一句。
    public static func parseContent(_ lines: [OCRLine]) -> (objectives: [(String, String)], paragraphs: [String]) {
        let ls = lines.filter { $0.text.filter(\.isLetter).count >= 2 }.sorted { $0.minY < $1.minY }
        var objectives: [(String, String)] = []
        var paragraphs: [String] = []
        var current = ""
        var lastMaxY: Double? = nil
        var lastMaxX = 1.0
        // 最宽的一行大约就是“写满”的宽度；上一行明显没写满（如小标题 “Estelle's Request”），下一行就是新的一段
        let fullX = ls.map(\.maxX).max() ?? 1
        let lineH = ls.map { $0.maxY - $0.minY }.sorted().dropFirst(ls.count / 2).first ?? 0.05
        for l in ls {
            var t = latinize(l.text).trimmingCharacters(in: .whitespaces)
            // 灰色目标框的标题 “Quest Summary”，不用翻译
            if t.lowercased().replacingOccurrences(of: " ", with: "") == "questsummary" { continue }
            // 计数里的 O 认成了字母：“Garnet Ore O/ 1”
            t = t.replacingOccurrences(of: "\\b[Oo]\\s*/\\s*([0-9]+)$", with: "0 / $1", options: .regularExpression)
            if let m = t.range(of: "^(.*?[A-Za-z].*?)\\s+([0-9]+\\s*/\\s*[0-9]+)$", options: .regularExpression), t[m].count == t.count {
                let parts = t.components(separatedBy: " ")
                // 最后的 “75 / 75” 可能被拆成几个词
                var name = t, count = ""
                if let r = t.range(of: "[0-9]+\\s*/\\s*[0-9]+$", options: .regularExpression) {
                    name = String(t[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
                    count = t[r].replacingOccurrences(of: " ", with: "")
                }
                _ = parts
                objectives.append((name, count))
                lastMaxY = l.maxY; lastMaxX = 1
                continue
            }
            let bigGap = lastMaxY.map { l.minY - $0 > lineH * 0.9 } ?? true
            let shortPrev = lastMaxX < fullX * 0.65
            if current.isEmpty || bigGap || shortPrev {
                if !current.isEmpty { paragraphs.append(current) }
                current = t
            } else {
                current = ChatParser.joinWrapped(current, t)
            }
            lastMaxY = l.maxY; lastMaxX = l.maxX
        }
        if !current.isEmpty { paragraphs.append(current) }
        return (objectives, paragraphs)
    }
}

/// 灰框里的一块文字（一行目标，或几行拼成的一段），位置是在正文截图里的比例（0~1，左上原点）
public struct QuestBoxBlock: Sendable {
    public var text: String
    public var objective: (name: String, count: String)?
    public var isSummaryTitle = false
    public var minX: Double, maxX: Double, minY: Double, maxY: Double
}

extension QuestDoc {
    /// “Zombie Mushroom 75 / 75” → (名字, “75/75”)
    static func splitObjective(_ raw: String) -> (String, String)? {
        var t = raw.replacingOccurrences(of: "\\b[Oo]\\s*/\\s*([0-9]+)$", with: "0 / $1", options: .regularExpression)
        t = t.trimmingCharacters(in: .whitespaces)
        guard let r = t.range(of: "[0-9]+\\s*/\\s*[0-9]+$", options: .regularExpression) else { return nil }
        let name = String(t[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
        guard name.contains(where: \.isLetter) else { return nil }
        return (name, t[r].replacingOccurrences(of: " ", with: ""))
    }

    /// 灰框（摘要 / 目标框）里的行分成块：每行目标单独一块（旁边有道具图标，只换文字、图标保留）；
    /// 其余文字按“上一行写满、行距正常”拼成段，一段一块。
    public static func boxBlocks(_ lines: [OCRLine]) -> [QuestBoxBlock] {
        let ls = lines.filter { $0.text.filter(\.isLetter).count >= 2 }.sorted { $0.minY < $1.minY }
        guard !ls.isEmpty else { return [] }
        let lineH = ls.map { $0.maxY - $0.minY }.sorted()[ls.count / 2]
        let fullX = ls.map(\.maxX).max() ?? 1
        var out: [QuestBoxBlock] = []
        var lastWasPara = false
        for l in ls {
            let t = latinize(l.text).trimmingCharacters(in: .whitespaces)
            if t.lowercased().replacingOccurrences(of: " ", with: "") == "questsummary" {
                out.append(QuestBoxBlock(text: t, isSummaryTitle: true, minX: l.minX, maxX: l.maxX, minY: l.minY, maxY: l.maxY))
                lastWasPara = false; continue
            }
            if let o = splitObjective(t) {
                out.append(QuestBoxBlock(text: t, objective: o, minX: l.minX, maxX: l.maxX, minY: l.minY, maxY: l.maxY))
                lastWasPara = false; continue
            }
            if lastWasPara, var p = out.last, l.minY - p.maxY < lineH * 0.9, p.maxX >= fullX * 0.65 {
                p.text = ChatParser.joinWrapped(p.text, t)
                p.minX = min(p.minX, l.minX); p.maxX = max(p.maxX, l.maxX); p.maxY = l.maxY
                out[out.count - 1] = p
            } else {
                out.append(QuestBoxBlock(text: t, minX: l.minX, maxX: l.maxX, minY: l.minY, maxY: l.maxY))
            }
            lastWasPara = true
        }
        return out
    }
}

/// 滚动拼接：同一个任务，用户往下滚动时看到的是正文的不同部分，把它们按顺序拼成完整的行列表。
public final class QuestScrollMerger {
    public private(set) var title = ""
    public private(set) var lines: [OCRLine] = []

    public init() {}

    /// 用这次看到的行（已按从上到下排序）更新。返回合并后的全部行（y 坐标按拼接后的位置重排）。
    @discardableResult
    public func update(title: String, visible: [OCRLine]) -> [OCRLine] {
        let vis = visible.filter { $0.text.filter(\.isLetter).count >= 2 }.sorted { $0.minY < $1.minY }
        if title != self.title || lines.isEmpty {
            self.title = title
            lines = vis
            return lines
        }
        func same(_ a: OCRLine, _ b: OCRLine) -> Bool { Fuzzy.similar(a.text, b.text) }
        // 这屏第一行在已有记录里的位置：往下滚动了，从那里接上
        if let first = vis.first, let k = lines.firstIndex(where: { same($0, first) }) {
            let offset = lines[k].minY - first.minY
            var merged = Array(lines[..<k])
            for l in vis {
                var m = l; m.minY += offset; m.maxY += offset
                merged.append(m)
            }
            // 记录里还有比这屏更靠下的行（用户又往上滚了）：保留
            if let lastVis = vis.last, let j = lines.lastIndex(where: { same($0, lastVis) }), j + 1 < lines.count {
                merged += lines[(j + 1)...]
            }
            lines = merged
        } else if let last = vis.last, let k = lines.firstIndex(where: { same($0, last) }) {
            // 这屏最后一行是记录的开头附近：往上滚到了更前面的部分，接在前面
            let offset = lines[k].minY - last.minY
            var merged: [OCRLine] = []
            for l in vis {
                var m = l; m.minY += offset; m.maxY += offset
                merged.append(m)
            }
            merged += lines[(k + 1)...]
            lines = merged
        } else {
            // 对不上（换了内容）：以这屏为准
            lines = vis
        }
        return lines
    }
}

/// 任务详情的中文
public struct QuestZh: Sendable {
    public var title: String
    public var level: String
    public var objectives: [String]
    public var paragraphs: [String]

    public var plainText: String {
        var out = [title + (level.isEmpty ? "" : "（等级 \(level)+）")]
        if !objectives.isEmpty { out.append(objectives.joined(separator: "\n")) }
        out += paragraphs
        return out.joined(separator: "\n\n")
    }
}

extension ChatTranslator {
    /// 任务目标的名字。认错一两个字母（Leaf → Leat）时，只在这个任务原文提到的怪物、物品里找唯一最像的
    public func objectiveZh(_ name: String, title: String, context: [String], db: QuestDB = .shared) async -> String {
        await plain(objectiveName(name, title: title, context: context, db: db), quest: true)
    }
    /// “Leaf 0 / 30” 这种目标行
    private static func splitCount(_ s: String) -> Range<String.Index>? { s.range(of: "[0-9Oo]+\\s*/\\s*[0-9]+$", options: .regularExpression) }
    func objectiveName(_ name: String, title: String, context: [String], db: QuestDB = .shared) -> String {
        let key = Fuzzy.normalize(name)
        guard key.count >= 4, !glossary.questNames.contains(where: { Fuzzy.normalize($0) == key }) else { return name }
        var es = db.candidates(forTitle: title)
        // 上下文是识别出来的一行行碎片：单行太短对不上，连起来再找
        for c in context + [context.filter { Self.splitCount($0) == nil }.joined(separator: " ")] { if let m = db.message(for: c)?.entry { es.append(m) } }
        let text = " " + es.flatMap(\.en).joined(separator: " ").lowercased()
        let lim = key.count >= 10 ? 2 : 1
        let hits = Set(glossary.questNames.filter { abs($0.count - name.count) <= lim + 1 && text.contains(" " + $0.lowercased()) && Fuzzy.distance(key, Fuzzy.normalize($0), limit: lim) <= lim }.map { $0.lowercased() })
        return hits.count == 1 ? glossary.questNames.first { $0.lowercased() == hits.first! } ?? name : name
    }
    public func translateQuest(_ d: QuestDoc, db: QuestDB = .shared) async -> QuestZh {
        var objs: [String] = []
        for o in d.objectives { objs.append("\(await objectiveZh(o.name, title: d.title, context: d.paragraphs, db: db)) \(o.count)") }
        var paras: [String] = []
        var used = Set<String>()
        let titleCands = db.candidates(forTitle: d.title)
        var titled = titleCands.count == 1 ? titleCands[0] : nil
        // 第一遍：每段先找原文（游戏里的说明框、鼠标指针压在字上时，识别结果会混进杂字）
        // 短行先看是不是任务名（小标题），免得被当成正文对到别的原文上
        let headings = d.paragraphs.map { p in p.split(separator: " ").count <= 12 ? db.entry(forHeading: p) : nil }
        let hits = zip(d.paragraphs, headings).map { p, h in h == nil ? db.message(for: p, prefer: titled?.id) : nil }
        var matched: [QuestEntry] = []
        for h in hits.compactMap({ $0 }) where !matched.contains(where: { $0.id == h.entry.id }) { matched.append(h.entry) }
        if titled == nil, let t = titleCands.first(where: { c in matched.contains { $0.id == c.id } }) { titled = t }
        let related = matched + (titled.map { [$0] } ?? [])
        for (k, (p, hit)) in zip(d.paragraphs, hits).enumerated() {
            // 小标题就是某个任务名（“Estelle's Request”）；被遮挡认错一两个字（“Dentelle's Request”）也对得上
            if hit == nil {
                if let e = headings[k] ?? related.first(where: { Fuzzy.similar($0.name, p, tolerance: 0.25) }) {
                    paras.append(await questName(e)); continue
                }
            }
            // 说明文字：找到原文就用表里的中文 / 完整原文去翻译（识别错字、只看到半段都不影响）
            if let (e, i) = hit {
                guard used.insert("\(e.id)-\(i)").inserted else { continue }
                if let z = e.zh, i < z.count, !z[i].isEmpty { paras.append(z[i]) }
                else { paras.append(await plain(e.en[i], quest: true)) }
                continue
            }
            // 正文已经对上原文时，剩下对不上、又不是固定句式的短行，多半是说明框、鼠标造成的杂字：不显示
            let known = glossary.matchFixed(p) ?? glossary.matchTemplate(p)
            if !matched.isEmpty, known == nil, p.split(separator: " ").count < 8 { continue }
            // 已对上原文里的话被认花后又拼进来一遍（滚动拼接对不齐时）：大部分词都在原文里，不重复显示
            if !matched.isEmpty, known == nil, db.overlap(p, with: matched) >= 0.6 { continue }
            paras.append(await plain(p, quest: true))
        }
        let title: String
        if let e = titled { title = await questName(e) }
        else if let t = extraTitle(d.title) { title = t }
        else { title = await translateQuestName(d.title) }
        return QuestZh(title: title, level: d.level, objectives: objs, paragraphs: paras)
    }

    /// QuestNames.json 的 titles：完全一样，或截断后前缀唯一
    func extraTitle(_ s: String) -> String? {
        var t = s.trimmingCharacters(in: .whitespaces)
        var truncated = false
        while t.hasSuffix(".") || t.hasSuffix("…") { t.removeLast(); truncated = true }
        let key = QuestDB.norm(t)
        guard key.count >= 3 else { return nil }
        if let e = glossary.questTitles.first(where: { $0.0 == key }) { return e.1 }
        guard truncated else { return nil }
        let hits = glossary.questTitles.filter { $0.0.hasPrefix(key) }
        return hits.count == 1 ? hits[0].1 + "…" : nil
    }

    /// 表里任务的中文名：有手改的就用，没有就把完整英文名交给系统翻译
    func questName(_ e: QuestEntry) async -> String {
        if let z = e.zhName, !z.isEmpty { return z }
        var zh = await plain(e.name, quest: true)
        while zh.hasSuffix("。") || zh.hasSuffix(".") { zh.removeLast() }
        return zh
    }

    /// 任务名 / 分类名。被截断的名字（末尾 “...”）翻译后加 “…”；“Henesys (3)” 这种分类保留数量
    public func translateQuestName(_ s: String) async -> String {
        var t = s.trimmingCharacters(in: .whitespaces)
        var count = ""
        if let r = t.range(of: "\\s*\\(([0-9]+)\\)$", options: .regularExpression) {
            count = String(t[r]).trimmingCharacters(in: .whitespaces)
            t = String(t[..<r.lowerBound])
        }
        var truncated = false
        while t.hasSuffix(".") || t.hasSuffix("…") { t.removeLast(); truncated = true }
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
        // 被截断时最后一个词多半只剩半个（“Weird Me...”），去掉再翻译
        if truncated {
            var words = t.split(separator: " ").map(String.init)
            if words.count >= 3, let last = words.last, last.count <= 4 || !Words.isWord(last) {
                words.removeLast()
                if let l = words.last, ["the", "a", "an", "of", "and", "to", "in", "for"].contains(l.lowercased()) { words.removeLast() }
                t = words.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
            }
        }
        guard !t.isEmpty else { return s }
        var zh = await plain(t, quest: true)
        while zh.hasSuffix("。") || zh.hasSuffix(".") { zh.removeLast() }
        return zh + (truncated ? "…" : "") + (count.isEmpty ? "" : " " + count)
    }
}
