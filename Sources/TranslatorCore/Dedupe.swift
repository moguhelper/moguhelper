// 去重：聊天框每秒截一次，同一条消息会反复出现，而且每次识别可能有一两个字不同。
import Foundation

public final class MessageDeduper {
    private var recent: [[Character]] = []
    private let keep: Int

    public init(keep: Int = 300) { self.keep = keep }

    /// 一条消息的处理结果：新消息，或者“补全”了之前只看到一半的消息（例如折行的第二行后来才出现）
    public struct Update {
        public let message: ChatMessage
        public let replaces: Int?   // 被补全的那条在“近期消息”里的序号（从 0 开始，按出现顺序）
    }
    private var counter = 0
    private var ids: [Int] = []

    /// 和 newMessages 一样，但能识别“补全”：之前记下的是半句，现在看到了更长的完整句子。
    public func updates(_ msgs: [ChatMessage]) -> [Update] {
        var out: [Update] = []
        for m in msgs {
            let n = Fuzzy.normalize(m.raw)
            if n.count < 2 { continue }
            // 补全：新句子开头和最近某条一致，而且明显更长
            if let i = recent.indices.reversed().prefix(30).first(where: { i in
                let r = recent[i]
                guard r.count >= 15, n.count > r.count else { return false }
                let lim = max(1, r.count / 10)
                return Fuzzy.distance(Array(n.prefix(r.count)), r, limit: lim) <= lim
            }) {
                recent[i] = n
                out.append(Update(message: m, replaces: ids[i]))
                continue
            }
            let atEdge = m.minY < 0.04 || m.maxY > 0.96
            if isSeen(n, atEdge: atEdge) { continue }
            recent.append(n); ids.append(counter)
            out.append(Update(message: m, replaces: nil))
            counter += 1
        }
        if recent.count > keep { recent.removeFirst(recent.count - keep); ids.removeFirst(ids.count - keep) }
        return out
    }

    /// 这条新消息分到的序号（updates 返回 replaces == nil 时，序号 = 调用后 counter - 1 按顺序递增）
    public var nextID: Int { counter }

    /// 返回这一帧里“新出现”的消息，并记住它们。
    public func newMessages(_ msgs: [ChatMessage]) -> [ChatMessage] {
        var out: [ChatMessage] = []
        for m in msgs {
            let n = Fuzzy.normalize(m.raw)
            if n.count < 2 { continue }
            let atEdge = m.minY < 0.04 || m.maxY > 0.96
            if isSeen(n, atEdge: atEdge) { continue }
            recent.append(n); ids.append(counter); counter += 1
            out.append(m)
        }
        if recent.count > keep { recent.removeFirst(recent.count - keep); ids.removeFirst(ids.count - keep) }
        return out
    }

    /// atEdge：消息贴着区域上下边缘，可能被切掉一半，才允许“包含关系”算重复；
    /// 否则只按相似度判断（避免 “Bob : hi” 之后的 “Bob : hi everyone” 被误判为重复）。
    private func isSeen(_ n: [Character], atEdge: Bool) -> Bool {
        let s = String(n)
        for r in recent.reversed() {
            // 被聊天框边缘截掉一半的消息：是已有消息的一部分
            if atEdge, n.count < r.count, String(r).contains(s) { return true }
            let allowed = max(1, max(n.count, r.count) / 7)
            if Fuzzy.distance(n, r, limit: allowed) <= allowed { return true }
            // 之前在边缘只看到一半、现在看到完整的：算已见
            if atEdge, r.count < n.count, s.contains(String(r)), r.count * 2 > n.count { return true }
        }
        return false
    }
}
