// NPC 考题：记住自己上次选了第几个、后来是继续了还是被说“错了”，下次在选项上标出来。只看屏幕，不替用户选。
import Foundation

public struct QuizMemory: Codable, Sendable {
    public enum Mark: Sendable, Equatable { case right, wrong }
    struct Entry: Codable, Sendable {
        var question: String
        var options: [String]
        var right: Int?
        var wrong: [Int] = []
        /// 这一串里出现过“答错了”，才算考题（平时的菜单、出租车不标）
        var quiz = false
    }
    var entries: [Entry] = []
    private enum CodingKeys: String, CodingKey { case entries }
    private var cur: Int?, sel: Int?, session: [Int] = []
    private var curBody = ""
    /// 这一串答过的：题 → 选了第几个、什么时候（同一题又问一遍 = 上次答错）
    private var answered: [Int: (sel: Int, t: Date)] = [:]
    /// 这一轮依次问过的题：又回到问过的题 = 最后那题答错、从头再来
    private var run: [Int] = [], runAt = Date.distantPast
    private var closedAt: Date?
    /// 问答里最近问的一题（对话框关了、题目没来得及再认时，靠回答的那句话接上）
    private var asked: (i: Int, t: Date)?
    public init() {}

    static func isWrong(_ s: String) -> Bool {
        s.range(of: "\\b(you'?re wrong|wrong|incorrect|stranger|not right|try again|not the (right|correct) answer|that'?s not it|that'?s not|think (again|carefully|harder)|once more|not quite|oops|hmm+|nope|liar|lying)\\b", options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// 现在这页的选项列表里，第 i 个和记录里第 k 个是同一个（顺序可能打乱；字可能认错一两个）
    static func map(_ old: [String], _ new: [String]) -> [Int]? {
        guard old.count == new.count else { return nil }
        func n(_ s: String) -> String { String(Fuzzy.normalize(s)) }
        let o = old.map(n), w = new.map(n)
        // 每一个都能一字不差对上：按文字（打乱顺序也对）
        if Set(o).count == o.count, Set(o) == Set(w) { return w.map { x in o.firstIndex(of: x)! } }
        // 有认错的：对得上的那些位置都没变，就按位置
        let moved = w.indices.contains { i in o.firstIndex(of: w[i]).map { $0 != i } ?? false }
        return moved ? nil : Array(w.indices)
    }

    private func find(_ q: String, _ opts: [String]) -> Int? {
        entries.firstIndex { Fuzzy.similar($0.question, q, tolerance: 0.15) && Self.map($0.options, opts) != nil }
    }

    /// 看到一页对话。有新的对错记录返回 true
    /// quiz：正在做问答任务，同一题又问一遍就算上次答错（对话框答错后可能直接关掉、也可能不说“错”字）
    public mutating func page(_ body: String, options: [String], quiz: Bool = false, now: Date = Date()) -> Bool {
        // 对话框关过一会儿了：没答完的不算
        if let c = closedAt {
            closedAt = nil
            if !quiz || now.timeIntervalSince(c) > 4 { cur = nil; sel = nil; session = [] }
            curBody = ""
        }
        guard body.filter(\.isLetter).count >= 6 else { return false }      // 没打完的半句、认花的
        // 还是同一页（重新识别了一次）
        if !curBody.isEmpty, Fuzzy.similar(curBody, body, tolerance: 0.15), cur == nil ? options.count < 2 : entries[cur!].options.count == options.count { return false }
        var learned = false
        if now.timeIntervalSince(runAt) > 600 { run = [] }
        let next = options.count >= 2 ? find(body, options) : nil
        let restart = next.map { i in run.last != i && run.contains(i) } ?? false
        // 问答：答完说的那句话里常常就有选的那项（“In Item Inventory, you can…”）。对不对先不定：给了经验才算对，又问同一题就是错
        if quiz, options.count < 2, let a = cur ?? asked.flatMap({ now.timeIntervalSince($0.t) < 300 ? $0.i : nil }) {
            let named = Self.named(body, entries[a].options)
            if let p = named ?? (cur == a ? sel : nil), p < entries[a].options.count { answered[a] = (p, now) }
            if Self.isWrong(body), let p = answered[a]?.sel {
                if !entries[a].wrong.contains(p) { entries[a].wrong.append(p) }
                entries[a].quiz = true; learned = true
            }
            cur = nil; sel = nil; curBody = body
            return learned
        }
        // 关掉又打开、还是同一题：按了没按看不出来，交给下面“又问一遍”
        if let c = cur, let s = sel, s < entries[c].options.count, !(options.count >= 2 && find(body, options) == c) {
            learned = true
            // 直接问下一题 = 这题过了，别留着等“又问一遍”
            answered[c] = options.count >= 2 ? nil : (s, now)
            if options.count < 2 && Self.isWrong(body) || restart && (quiz || entries[c].quiz) {
                if !entries[c].wrong.contains(s) { entries[c].wrong.append(s) }
                if entries[c].right == s { entries[c].right = nil }
                for i in session + [c] { entries[i].quiz = true }
            } else {
                entries[c].right = s
                if quiz { entries[c].quiz = true }
                entries[c].wrong.removeAll { $0 == s }
                if !session.contains(c) { session.append(c) }
            }
        }
        // 中间隔着一句话才问到别的题：问的是新题 = 上一题对；回到问过的题 = 上一题错
        if quiz, options.count >= 2, body.contains("?"), let l = run.last, l != next, let a = answered[l], a.sel < entries[l].options.count {
            answered[l] = nil; learned = true
            entries[l].quiz = true
            if restart {
                if !entries[l].wrong.contains(a.sel) { entries[l].wrong.append(a.sel) }
                if entries[l].right == a.sel { entries[l].right = nil }
            } else if !entries[l].wrong.contains(a.sel) { entries[l].right = a.sel }
        }
        cur = nil; sel = nil; curBody = body
        // 任务列表（(Lv.22) …）不算题
        if options.count >= 2, options.count <= 8, body.contains("?"), !options.contains(where: { $0.lowercased().hasPrefix("(lv") }) {
            if let i = find(body, options) {
                // 选项换了顺序：按新的顺序重排记录
                if let m = Self.map(entries[i].options, options) {
                    let e = entries[i]
                    entries[i].right = e.right.flatMap { r in m.firstIndex(of: r) }
                    entries[i].wrong = e.wrong.compactMap { r in m.firstIndex(of: r) }
                    entries[i].options = options
                    if let a = answered[i] { answered[i] = m.firstIndex(of: a.sel).map { ($0, a.t) } }
                }
                cur = i
                if quiz, let a = answered.removeValue(forKey: i), now.timeIntervalSince(a.t) < 600, a.sel < entries[i].options.count {
                    // 记录里的顺序可能刚重排过：选项没变才能按位置认
                    if Self.map(entries[i].options, options) == Array(options.indices) {
                        if !entries[i].wrong.contains(a.sel) { entries[i].wrong.append(a.sel) }
                        if entries[i].right == a.sel { entries[i].right = nil }
                        entries[i].quiz = true; learned = true
                    }
                }
            } else {
                entries.append(Entry(question: body, options: options))
                cur = entries.count - 1
            }
            if let c = cur {
                if restart { run = [] }
                if run.last != c { run.append(c) }
                runAt = now
            }
            if quiz, let c = cur { asked = (c, now) }
        }
        return learned
    }
    /// 现在箭头停在第几个（按下去之前一直更新）
    public mutating func select(_ i: Int) { if cur != nil { sel = i } }
    /// 这句话里提到的是哪个选项（只提到一个才算；名字套名字时取长的）
    static func named(_ body: String, _ options: [String]) -> Int? {
        func n(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }
        let b = n(body)
        let hit = options.indices.filter { n(options[$0]).count >= 4 && b.contains(n(options[$0])) }
        let best = hit.filter { k in !hit.contains { $0 != k && n(options[$0]).contains(n(options[k])) } }
        return best.count == 1 ? best[0] : nil
    }
    /// 答题后得了经验：刚才选的是对的
    public mutating func reward(now: Date = Date()) -> Bool {
        guard let a = asked, now.timeIntervalSince(a.t) < 60 else { return false }
        guard let p = answered[a.i].flatMap({ now.timeIntervalSince($0.t) < 6 ? $0.sel : nil }) ?? (cur == a.i ? sel : nil), p < entries[a.i].options.count else { return false }
        answered[a.i] = nil; asked = nil
        entries[a.i].right = p; entries[a.i].quiz = true
        entries[a.i].wrong.removeAll { $0 == p }
        return true
    }
    /// 选了、对话框直接关掉（没看到下一页）：先记着，同一题又问一遍就知道选错了
    public mutating func answer(now: Date = Date()) { if let c = cur, let s = sel, s < entries[c].options.count { answered[c] = (s, now) } }
    /// 对话框关了
    public mutating func close(now: Date = Date()) { if closedAt == nil { closedAt = now } }

    /// 这一页每个选项的标记
    public func marks(_ body: String, options: [String]) -> [Int: Mark] {
        guard let i = find(body, options), entries[i].quiz, let m = Self.map(entries[i].options, options) else { return [:] }
        var out: [Int: Mark] = [:]
        for (k, o) in m.enumerated() { if entries[i].right == o { out[k] = .right } else if entries[i].wrong.contains(o) { out[k] = .wrong } }
        return out
    }
}
