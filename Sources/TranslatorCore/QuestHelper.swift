// 游戏右上角的任务追踪（Quest Helper）：任务名 + “26 / 40 Charm of the Undead”。一直显示着，用来看进度。
import CoreGraphics
import Foundation

public struct QuestHelperItem: Sendable {
    public var title: String
    public var objectives: [(name: String, count: String)]
    public init(title: String, objectives: [(name: String, count: String)]) { self.title = title; self.objectives = objectives }
}

public enum QuestHelper {
    /// 识别出的行 → 追踪的任务。没看到“Quest Helper”标题返回 nil（没开、收起或被挡住）
    public static func parse(_ lines: [OCRLine]) -> [QuestHelperItem]? {
        let ls = lines.sorted { $0.minY < $1.minY }
        guard let head = ls.first(where: { l in
            let n = l.text.lowercased().filter(\.isLetter)
            return n.hasPrefix("questhelper") || Fuzzy.similar(String(n.prefix(11)), "questhelper", tolerance: 0.2)
        }) else { return nil }
        var out: [QuestHelperItem] = []
        for l in ls where l.minY > head.minY + (head.maxY - head.minY) * 0.6 && l.minX > head.minX - 0.04 {
            let t = fixLine(l.text.trimmingCharacters(in: .whitespaces))
            // “26 / 40 Charm of the Undead”；0 常认成 O
            if let r = t.range(of: "^[0-9Oo]+\\s*/\\s*[0-9]+\\s*", options: .regularExpression) {
                let c = t[r].replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "[Oo]", with: "0", options: .regularExpression)
                let name = ItemNames.clean(t[r.upperBound...].trimmingCharacters(in: .whitespaces))
                if !out.isEmpty, name.count >= 3 { out[out.count - 1].objectives.append((name, c)) }
            } else if t.range(of: "^[^A-Za-z]*[0-9]", options: .regularExpression) != nil {
                // 数字开头却拆不出数量：认花的目标行，别当成新任务（后面的目标会全挂到它下面）
                continue
            } else if t.hasSuffix(":") || t.contains(where: { $0.isLetter && !$0.isASCII }) {
                // 头上聊天气泡的“Noona :”、认花的外文字母：不是任务名
                continue
            } else if t.filter(\.isLetter).count >= 4 {
                // 右边的关闭按钮可能连成 “Arcon's Blood? X”
                out.append(QuestHelperItem(title: t.replacingOccurrences(of: "\\s+[^A-Za-z0-9]?[xX®Ⓧ⊗]?[^A-Za-z0-9]?$", with: "", options: .regularExpression), objectives: []))
            }
        }
        return out
    }

    /// “50 730 Squishy Liquid”“078 Plant Sample”：斜杠认成了 7、1；前面可能有杂点
    static func fixLine(_ s: String) -> String {
        let t = s.replacingOccurrences(of: "^[^A-Za-z0-9]+(?=[0-9])", with: "", options: .regularExpression)
        guard !t.contains("/"), let r = t.range(of: "^[0-9Oo][0-9Oo lI|]*\\s+(?=[A-Za-z])", options: .regularExpression) else { return t }
        let num = t[r].trimmingCharacters(in: .whitespaces), name = String(t[r.upperBound...])
        let f = NavDB.shared.fixCount("\(name) \(num)")
        guard f.contains("/"), f.hasPrefix(name) else { return t }
        return "\(f.dropFirst(name.count).trimmingCharacters(in: .whitespaces)) \(name)"
    }

    /// 资料里没有的任务，目标名字只能照屏幕记：认花的（HUShroom Cap、norange mushroom Cap、ph Pig、y Citizen's Reques a）不要
    public static func plausible(_ name: String) -> Bool {
        let w = name.split(separator: " ").map(String.init)
        guard let a = w.first, let z = w.last, let c = a.first, c.isUppercase || c.isNumber, name.filter(\.isLetter).count >= 3 else { return false }
        if w.count > 1, z.count == 1, z.first!.isLowercase { return false }
        return !w.contains { $0.range(of: "[A-Z]{2,}[a-z]", options: .regularExpression) != nil || $0.range(of: "^[a-z]+[A-Z]", options: .regularExpression) != nil }
    }

    /// 没有资料的任务：目标名一两个字母认花的（Orange Moshroom Cap、Tree Dranch）并到一个。要的数量一样才算
    public static func unify(_ read: [String: [Int]], with old: [String: [Int]]) -> (read: [String: [Int]], drop: [String]) {
        var out: [String: [Int]] = [:], drop: [String] = []
        // 以前记下的认花的名字（经验里有正确写法的）去掉
        for o in old.keys { if let c = QuestTips.snap(o), c != o { drop.append(o) } }
        for (k0, v) in read.sorted(by: { $0.key < $1.key }) {
            let k = QuestTips.snap(k0) ?? k0
            var name = k
            for (o, w) in old.merging(out, uniquingKeysWith: { a, _ in a }).sorted(by: { $0.key < $1.key }) where o != k && w.count == 2 && v.count == 2 && w[1] == v[1] {
                if let b = ItemDB.better(k, o) { if b == o { name = o } else { drop.append(o); out[o] = nil } }
                else if old[o] != nil, old[k] == nil, k.count >= 4, Fuzzy.distance(Array(k.lowercased()), Array(o.lowercased()), limit: 1) <= 1 { name = o }
            }
            // 同一个目标认成了两种写法：数大的那次读得准
            if let w = out[name], w.count == 2, v.count == 2 { if v[0] > w[0] { out[name] = v } } else if out[name] == nil { out[name] = v }
        }
        // 同一个名字可能在上面两处都被记成要删的
        var seen = Set<String>()
        return (out, drop.filter { seen.insert($0).inserted })
    }

    /// 半透明深灰底上的黑字，和背后颜色接近：提亮拉开对比
    public static func boost(_ img: CGImage) -> CGImage {
        guard let (buf, w, h) = TooltipDetector.rgba(img) else { return img }
        var out = [UInt8](repeating: 0, count: w * h)
        for i in 0..<(w * h) { out[i] = UInt8(min(255, (Int(buf[i * 4]) + Int(buf[i * 4 + 1]) + Int(buf[i * 4 + 2])) * 9 / 10)) }
        guard let p = CGDataProvider(data: Data(out) as CFData) else { return img }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: p, decode: nil, shouldInterpolate: false, intent: .defaultIntent) ?? img
    }

    /// 现在导航的已经接了、但不在追踪里，而紧接着的下一个任务（编号 +1、同一个 NPC 给的、上一个也交给它）在追踪里：换成它
    public static func nextStep(_ items: [QuestHelperItem], target: NavTarget?, db: NavDB = .shared) -> (NavTarget, QuestHelperItem)? {
        guard let cur = target, cur.accepted == true, let id = cur.questId, let now = db.quest(id), let next = db.quest(id + 1),
              next.start != nil, next.start == now.end, pick(items, target: cur, db: db) == nil else { return nil }
        for it in items {
            guard !it.objectives.isEmpty, var t = db.target(title: it.title, paragraphs: [it.title], summary: ""), t.questId == id + 1 else { continue }
            t.accepted = true; t.notStarted = false
            return (t, it)
        }
        return nil
    }

    /// 追踪的任务里，哪个是现在导航的；没在导航（target 为 nil）就取第一个认得出的
    public static func pick(_ items: [QuestHelperItem], target: NavTarget?, db: NavDB = .shared) -> (NavTarget, QuestHelperItem)? {
        for it in items {
            guard let t = db.target(title: it.title, paragraphs: [it.title], summary: "") else { continue }
            guard let cur = target else { return (t, it) }
            if t.title == cur.title || (t.questId != nil && t.questId == cur.questId) { return (cur, it) }
        }
        return nil
    }
}

/// 追踪框是半透明的，背景会让数字认错（1/8 → 11/8）。变了的读数要连续两次一样才算；
/// 只是前面多出一位的（1 → 11、9 → 19、0 → 10）一律不信——真涨上去会先看到中间的数，或打开任务详情时读到
public struct ProgressGuard {
    private var pending: [String: [Int]] = [:]
    public init() {}
    /// now：已经确认的进度；read：这次读到的。返回可以采用的
    public mutating func accept(_ read: [String: [Int]], now: [String: [Int]]) -> [String: [Int]] {
        var out: [String: [Int]] = [:]
        for (k, v) in read {
            if now[k] == v { pending[k] = nil; continue }
            if let o = now[k]?.first, let n = v.first, String(n).count == String(o).count + 1, String(n).hasSuffix(String(o)) { pending[k] = nil; continue }
            if pending[k] == v { out[k] = v; pending[k] = nil } else { pending[k] = v }
        }
        return out
    }
}
