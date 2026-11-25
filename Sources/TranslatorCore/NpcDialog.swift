// NPC 对话框（和 NPC 说话、接 / 交任务、组队任务出题时弹出的大框）：找位置、把识别出的行分块、翻译。
// 只处理截图像素，不接触游戏，不替用户点 NEXT / 选项。
import Foundation
import CoreGraphics

public enum NpcDialogDetector {
    /// 在游戏截图里找 NPC 对话框右边的白色文字区（像素，左上原点）。scale：每点多少像素。
    /// 特征（实测，单位点）：上边框是一条约 515 点长的边框色 (85,119,153) 横线；框里右边是 (244,244,244) 的白色文字区，
    /// 左边约 145 点处开始、约 355 点宽，从上边框往下约 19 点开始；高度随内容变（选项多就高）。
    public static func find(in img: CGImage, scale s: CGFloat) -> CGRect? {
        guard let (buf, w, h) = TooltipDetector.rgba(img) else { return nil }
        let tol = s < 1.5 ? 45 : 16
        @inline(__always) func px(_ x: Int, _ y: Int) -> (Int, Int, Int) {
            let i = (y * w + x) * 4
            return (Int(buf[i]), Int(buf[i + 1]), Int(buf[i + 2]))
        }
        @inline(__always) func frame(_ x: Int, _ y: Int) -> Bool {
            guard x >= 0, y >= 0, x < w, y < h else { return false }
            let (r, g, b) = px(x, y)
            return QuestDetector.isFrame(r, g, b, tol: tol)
        }
        @inline(__always) func white(_ x: Int, _ y: Int) -> Bool {
            guard x >= 0, y >= 0, x < w, y < h else { return false }
            let (r, g, b) = px(x, y)
            return abs(r - 244) <= 6 && abs(g - 244) <= 6 && abs(b - 244) <= 6
        }
        let pt = { (v: CGFloat) in Int((v * s).rounded()) }
        let minLen = pt(460), maxLen = pt(530)     // 输入数量的对话框窄一些（约 475 点）
        for y in 0..<h {
            var x = 0
            while x < w {
                guard frame(x, y) else { x += 1; continue }
                var len = 0
                while x + len < w, frame(x + len, y) { len += 1 }
                defer { x += max(len, 1) }
                guard len >= minLen, len <= maxLen else { continue }
                // 白色文字区：上边框往下 21 点那一行（白色区从约 19 点开始，第一行字约 30 点，这一行没有字），找一段 ≥ 300 点的白色
                let ry = y + pt(21)
                guard ry < h else { continue }
                var bx = x + pt(4), best: (Int, Int) = (0, 0)     // 文字区可能在左（头像在右，活动 NPC）也可能在右
                while bx < min(w, x + len) {
                    guard white(bx, ry) else { bx += 1; continue }
                    var n = 0
                    while bx + n < w, white(bx + n, ry) { n += 1 }
                    if n > best.1 { best = (bx, n) }
                    bx += max(n, 1)
                }
                guard best.1 >= pt(300) else { continue }
                // 上下边界：沿白色区左边留白那一列（文字不会到这里）往上、往下走
                // 左边留白很窄，物品图标（活动 NPC 的材料列表）可能贴得很近：试几列，取最长的
                var top = ry, bottom = ry
                // 右边留白也量（文字、图标都不会到最右边）
                let rx = best.0 + best.1 - 1
                for cx in [best.0 + 1, best.0 + pt(2), best.0 + pt(4), rx - 1, rx - pt(2), rx - pt(4)] {
                    var t = ry, b = ry
                    while t > y, white(cx, t - 1) { t -= 1 }
                    while b + 1 < h, white(cx, b + 1) { b += 1 }
                    if b - t > bottom - top { top = t; bottom = b }
                }
                guard bottom - top >= pt(60) else { continue }
                return CGRect(x: best.0, y: top, width: best.1, height: bottom - top + 1)
            }
        }
        return nil
    }
}

/// 对话框里的一块文字：一段说明（几行拼起来）、一个选项、或一行橙色小标题。位置是在文字区截图里的比例（0~1，左上原点）
public struct NpcBlock: Sendable {
    public enum Kind: Sendable { case body, option, heading }
    public var kind: Kind
    public var text: String
    public var minX: Double, maxX: Double, minY: Double, maxY: Double
    /// 选项折到下一行时，下一行顶格开始的位置（比选项第一行靠左；那一截要另外盖住）
    public var wrapMinX: Double? = nil
    public var wrapMinY: Double? = nil
}

public enum NpcDialog {
    /// 识别行 → 块。说明文字贴左边；选项、小标题往右缩进（前面有小箭头 / 图标）。
    public static func blocks(_ lines: [OCRLine]) -> [NpcBlock] {
        let ls = lines.filter { $0.text.filter(\.isLetter).count >= 2 }.sorted { $0.minY < $1.minY }
        guard let left = ls.map(\.minX).min() else { return [] }
        let lineH = ls.map { $0.maxY - $0.minY }.sorted()[ls.count / 2]
        var out: [NpcBlock] = []
        for l in ls {
            // 右下角的 NEXT / OK 按钮文字（像素字体，常认成乱码）不翻
            if l.minX > 0.7, l.text.count <= 8 { continue }
            // 选项前面的小箭头常被认成 “»”“•” 之类，去掉
            let raw = l.text.trimmingCharacters(in: .whitespaces)
            var t = raw
            while let f = t.first, !f.isLetter, !f.isNumber, f != "(", f != "[" { t.removeFirst() }
            t = t.trimmingCharacters(in: .whitespaces)
            // 去掉的小箭头占这一行多宽：覆盖从文字开始，箭头露出来
            let junkFrac = raw.isEmpty ? 0 : Double(raw.count - t.count) / Double(raw.count)
            // 像素字体的大写 I 常被认成 T / l / |（“T really need…”）
            t = t.replacingOccurrences(of: "^[Tl|] (?=[a-z])", with: "I ", options: .regularExpression)
                .replacingOccurrences(of: "^Ive\\b", with: "I've", options: .regularExpression)
                .replacingOccurrences(of: "\\bnere\\b", with: "here", options: .regularExpression)
            // 前面有小圆点 / 箭头的是选项（这种行的识别框连圆点一起算，缩进看起来很小）
            let bullet = raw.first.map { "•·»>▸►*".contains($0) } ?? false
            let indented = l.minX - left > 0.04 || bullet
            let kind: NpcBlock.Kind
            // 橙色小标题（QUEST IN PROGRESS 等）：前面的小图标常被认成 “KA” 之类，按结尾认
            if headingKey(t) != nil {
                kind = .heading
            } else if t.range(of: "^\\(\\s*Lv", options: [.regularExpression, .caseInsensitive]) != nil
                        || t.range(of: "\\((In Progress|Completable|Available|Complete)\\)\\s*$", options: [.regularExpression, .caseInsensitive]) != nil {
                // 任务选项“(Lv.22) xxx (In Progress)”：按写法认，不靠缩进（低分辨率下缩进量不准）
                kind = .option
            } else if indented {
                let letters = t.filter(\.isLetter)
                kind = !letters.isEmpty && letters.allSatisfy(\.isUppercase) ? .heading : .option
            } else { kind = .body }
            // 太长的选项会折到下一行（“…the Town Resident (In” / “progress)”），下一行顶格写：接回选项
            if kind == .body, var p = out.last, p.kind == .option, !p.text.hasSuffix(")"), !p.text.hasSuffix("?"),
               l.minY - p.maxY < lineH * 0.9 {
                p.text = ChatParser.joinWrapped(p.text, t)
                if l.minX < p.minX { p.wrapMinX = min(p.wrapMinX ?? 1, l.minX); p.wrapMinY = p.wrapMinY ?? l.minY }
                p.maxX = max(p.maxX, l.maxX); p.maxY = l.maxY
                out[out.count - 1] = p
                continue
            }
            if kind == .body, var p = out.last, p.kind == .body, l.minY - p.maxY < lineH * 0.9 {
                p.text = ChatParser.joinWrapped(p.text, t)
                p.maxX = max(p.maxX, l.maxX); p.maxY = l.maxY
                out[out.count - 1] = p
                continue
            }
            var x0 = l.minX
            if kind == .option { x0 += (l.maxX - l.minX) * junkFrac }
            // 小标题前面的图标被认成字（“KA QUEST…”）：覆盖从真正的文字开始，图标露出来
            if kind == .heading, let r = t.range(of: "QUEST", options: .caseInsensitive), r.lowerBound > t.startIndex {
                let junk = Double(t.distance(from: t.startIndex, to: r.lowerBound)) / Double(max(1, t.count))
                x0 += (l.maxX - l.minX) * junk
                t = String(t[r.lowerBound...])
            }
            out.append(NpcBlock(kind: kind, text: t, minX: x0, maxX: l.maxX, minY: l.minY, maxY: l.maxY))
        }
        // 选项的字都从同一个位置开始；识别框有的把前面的小箭头算进去、有的没算，统一对齐到中间值（箭头都露出来）
        let optX = out.filter { $0.kind == .option }.map(\.minX).sorted()
        if !optX.isEmpty, optX.last! - optX.first! < 0.08 {
            let mid = optX[optX.count / 2]
            for i in out.indices where out[i].kind == .option { out[i].minX = mid }
        }
        return out
    }

    static let headings: [String: String] = [
        "questinprogress": "进行中的任务",
        "availablequest": "可接的任务", "availablequests": "可接的任务",
        "questcompletable": "可完成的任务", "completablequest": "可完成的任务", "completablequests": "可完成的任务",
        "questcomplete": "任务完成", "questavailable": "可接的任务",
    ]
    static func headingKey(_ t: String) -> String? {
        let k = QuestDB.letters(t)
        return headings.keys.filter { k.hasSuffix($0) && k.count - $0.count <= 3 }.max(by: { $0.count < $1.count })
    }
    static let status: [String: String] = [
        "in progress": "进行中", "completable": "可完成", "available": "可接", "complete": "可完成", "completed": "已完成",
    ]
}

extension NpcDialog {
    /// 很短的选项（人名、地名、颜色，考题常见）：英文差一个字母意思就不同，不盖住原文，中文写在右边
    public static func isShort(_ b: NpcBlock) -> Bool {
        b.kind == .option && b.wrapMinX == nil && b.text.count <= 18 && b.text.split(separator: " ").count <= 2 && !b.text.hasPrefix("(")
    }
    /// 选项去掉自带的编号（面板上另外编了），认错一个字母的名字改回来
    public static func optionText(_ s: String) -> String {
        let t = s.replacingOccurrences(of: "^[0-9]{1,2}\\s*[.)、]\\s*(?=[A-Za-z])", with: "", options: .regularExpression)
        return t.hasPrefix("(") ? t : NavDB.shared.fixName(t)
    }
    static let colors = ["black": "黑色", "blue": "蓝色", "red": "红色", "yellow": "黄色", "white": "白色", "green": "绿色", "brown": "棕色", "pink": "粉色",
                         "purple": "紫色", "orange": "橙色", "gray": "灰色", "grey": "灰色", "gold": "金色", "silver": "银色"]
}

extension ChatTranslator {
    /// 翻译对话框里的一块
    public func translateNpc(_ b0: NpcBlock, db: QuestDB = .shared) async -> String {
        // 材料数量 “Pie Flourx3”“Pumpkin Piece х3”（х 是认成西里尔字母的 x）：数量前补空格、统一成 ×
        var b = b0
        b.text = b.text.replacingOccurrences(of: "\\s*[xхX×]\\s*([0-9]+)\\s*$", with: " ×$1", options: .regularExpression)
        switch b.kind {
        case .heading:
            if let k = NpcDialog.headingKey(b.text), let z = NpcDialog.headings[k] { return z }
            return await plain(b.text, quest: true)
        case .option:
            // “(Lv.22) Cutthroat Manny's Request (In Progress)”：任务名查任务表，状态查表
            var t = b.text
            var lv = "", st = ""
            if let r = t.range(of: "^\\(\\s*Lv\\.?\\s*([0-9]+)\\s*\\)\\s*", options: [.regularExpression, .caseInsensitive]) {
                lv = t[r].filter(\.isNumber); t.removeSubrange(r)
            }
            if let r = t.range(of: "\\s*\\(([A-Za-z ]+)\\)\\s*$", options: .regularExpression) {
                let s = t[r].lowercased().trimmingCharacters(in: CharacterSet(charactersIn: " ()"))
                if let z = NpcDialog.status[s] { st = z; t.removeSubrange(r) }
            }
            let prefix = lv.isEmpty ? "" : "(Lv.\(lv)) "
            let suffix = st.isEmpty ? "" : "（\(st)）"
            if !lv.isEmpty || !st.isEmpty, let e = db.entry(forHeading: t) {
                return prefix + (await questName(e)) + suffix
            }
            if !lv.isEmpty || !st.isEmpty { return prefix + (await translateQuestName(t)) + suffix }
            if let c = NpcDialog.colors[t.lowercased()] { return c }
            return await plain(t, quest: true)
        case .body:
            // 对话里会叫玩家的角色名（“Oh, by the way, PlayerOne, aren't you…”）：大小写混写的单词当名字，原样保留不翻
            var t = b.text
            var names: [String] = []
            let re = try! NSRegularExpression(pattern: "\\b[A-Z][a-z]+[A-Z][A-Za-z0-9]*\\b|\\b[a-z]+[A-Z][A-Za-z0-9]*\\b|\\b[A-Za-z]+/[A-Za-z]+\\b")
            for m in re.matches(in: t, range: NSRange(t.startIndex..., in: t)).reversed() {
                guard let r = Range(m.range, in: t) else { continue }
                // 名字被认花（“Play/rOne”）：和聊天里见过的玩家名对一下
                let n = String(t[r])
                names.append(ChatParser.knownName(like: n) ?? n)
                t.replaceSubrange(r, with: "ZQXP\(names.count - 1)Q")
            }
            var z = await plain(t, quest: true)
            for (i, n) in names.enumerated() { z = z.replacingOccurrences(of: "ZQXP\(i)Q", with: " \(n) ") }
            return z.replacingOccurrences(of: "  +", with: " ", options: .regularExpression)
                .replacingOccurrences(of: "([，。！？；：、（）])\\s+", with: "$1", options: .regularExpression)
                .replacingOccurrences(of: "\\s+([，。！？；：、（）])", with: "$1", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
        }
    }
}
