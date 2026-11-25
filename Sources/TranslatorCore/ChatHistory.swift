// 翻译记录：始终和游戏聊天框的顺序保持一致。
//
// 做法：每次识别得到“聊天框里现在能看到的消息”（按从上到下的顺序），和记录末尾做整段顺序对齐：
// 对上的是同一条，只在读法确实更好、或多次都这么读时才改字（改过的不再改回去）；
// 某一帧漏认的那条留着不删；多出来的才是新消息。这样背景在动、识别有误差时，记录不会来回跳。
import Foundation

public struct HistoryItem: Sendable, Equatable {
    public var raw: String          // 英文原文（整理后）
    public var chinese: String?     // 中文翻译（nil 表示还没翻译）
    public var kind: MessageKind = .system
    public var speaker: String? = nil
    /// 去掉“名字 : ”的内容
    /// 各种读法分别看到几次、已经换下来的读法（不再换回去，不会来回跳）、连续几次没看到
    var votes: [String: Int] = [:]
    var rejected: Set<String> = []
    var seen = 1
    var missed = 0
    var body: String { if let r = raw.range(of: " CH[0-9]{2} : ", options: .regularExpression) { return String(raw[r.upperBound...]) }
        return speaker.map { n in raw.hasPrefix("\(n) : ") ? String(raw.dropFirst(n.count + 3)) : raw } ?? raw }
    public init(raw: String, chinese: String? = nil, kind: MessageKind = .system, speaker: String? = nil) {
        self.raw = raw; self.chinese = chinese; self.kind = kind; self.speaker = speaker
    }
    init(_ m: ChatMessage) { self.init(raw: m.raw, chinese: nil, kind: m.kind, speaker: m.speaker) }
}

public final class ChatHistory {
    public private(set) var items: [HistoryItem] = []
    private let limit: Int
    /// 对齐时最多往回看多少条
    private let lookBack = 60

    public init(limit: Int = 200) { self.limit = limit }

    public func clear() { items.removeAll() }

    /// 用聊天框当前这一屏更新记录。garbled[i] 为 true 表示第 i 条识别得不可靠。
    /// 返回需要翻译的序号（在 items 里的下标）。
    @discardableResult
    public func sync(visible: [ChatMessage], garbled: [Bool]) -> [Int] {
        guard !visible.isEmpty else { return [] }
        let base = max(0, items.count - lookBack)
        let tail = Array(items[base...])
        let n = tail.count, m = visible.count

        // 第 i 条记录和第 j 条可见消息配成一对的得分（nil = 不能配）
        func pair(_ i: Int, _ j: Int) -> Double? {
            if garbled[j] { return 0.5 }
            if ChatParser.sameMessage(tail[i].raw, visible[j].raw) || tail[i].votes[visible[j].raw] != nil { return 4 }
            return Fuzzy.similar(tail[i].raw, visible[j].raw) ? 1 : nil
        }
        // best[i][j]：从记录第 i 条、可见第 j 条往后的最高分；move：1 配对，2 跳过记录（这一帧漏认），3 跳过可见（新消息）
        var best = [[Double]](repeating: [Double](repeating: 0, count: m + 1), count: n + 1)
        var move = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n, through: 0, by: -1) {
            for j in stride(from: m, through: 0, by: -1) {
                if i == n { move[i][j] = j == m ? 0 : 3; continue }          // 记录到头：剩下的都是新消息
                if j == m { best[i][j] = -0.2 * Double(n - i); move[i][j] = 2; continue }
                var b = best[i + 1][j] - 1, mv = 2
                if best[i][j + 1] - 1.5 > b { b = best[i][j + 1] - 1.5; mv = 3 }
                if let p = pair(i, j), p + best[i + 1][j + 1] >= b { b = p + best[i + 1][j + 1]; mv = 1 }
                best[i][j] = b; move[i][j] = mv
            }
        }
        // 从哪条记录开始对：分最高的；一样高取靠后的（同一条公告会隔一会儿重复出现）
        var start = n, top = 0.0
        for i in stride(from: n - 1, through: 0, by: -1) where best[i][0] > top { top = best[i][0]; start = i }

        var out = Array(tail[..<start])
        var i = start, j = 0, matched = false
        let noAnchor = start == n
        while i < n || j < m {
            switch move[i][j] {
            case 1:
                var it = tail[i]
                it.seen += 1; it.missed = 0
                if !garbled[j] { Self.update(&it, with: visible[j]) }
                out.append(it); matched = true; i += 1; j += 1
            case 2:
                var it = tail[i]
                if j < m || matched { it.missed += 1 }
                // 只闪过一下的（背景碎片认成的一行）连续 3 次没再出现才去掉；看到过多次的留着
                if !(it.missed >= 3 && it.seen <= 2) { out.append(it) }
                i += 1
            default:
                // 第一条对上之前多出来的（最上面露半截的旧消息）不要
                if !garbled[j], matched || noAnchor {
                    var it = HistoryItem(visible[j]); it.votes[it.raw] = 1
                    out.append(it)
                }
                j += 1
            }
        }
        items = Array(items[..<base]) + out
        if items.count > limit { items.removeFirst(items.count - limit) }
        return items.indices.filter { items[$0].chinese == nil }
    }

    /// 同一条消息又看到一次：要不要换成这次的读法
    private static func update(_ it: inout HistoryItem, with m: ChatMessage) {
        guard m.raw != it.raw else { it.votes[it.raw, default: 0] += 1; return }
        it.votes[m.raw, default: 0] += 1
        guard !it.rejected.contains(m.raw) else { return }
        let a = Fuzzy.normalize(it.raw).count, b = Fuzzy.normalize(m.raw).count
        let badOld = ChatParser.badWords(it.body), badNew = ChatParser.badWords(m.body)
        let qOld = ChatParser.isQuestion(it.raw), qNew = ChatParser.isQuestion(m.raw)
        let better: Bool
        if (m.kind == .chat) != (it.kind == .chat) { better = m.kind == .chat }   // 之前漏了“名字 :”
        else if abs(a - b) > 3 { better = b > a }                                 // 之前只看到半句
        else if badOld != badNew { better = badNew < badOld }                     // 认得更干净
        else if qOld != qNew { better = qNew }                                    // 之前没认出问号
        else { better = false }
        // 差不多好的读法：要比现在的多看到 3 次以上才换
        guard better || it.votes[m.raw]! >= it.votes[it.raw, default: 0] + 3 else { return }
        it.rejected.insert(it.raw)
        // 旧译文先留着显示，译好再换（不闪“…”）：内容一样只是名字变，也重新拼一次
        it.raw = m.raw; it.kind = m.kind; it.speaker = m.speaker; it.chinese = nil
    }

    public func setChinese(_ zh: String, at i: Int, ifRaw raw: String) {
        guard items.indices.contains(i), items[i].raw == raw else { return }
        items[i].chinese = zh
    }
}
