// 把识别出的文字行整理成一条条聊天消息：去掉背景碎片、把折行拼回一句。
import Foundation

public enum MessageKind: String, Sendable {
    case chat      // 玩家发言：名字 : 内容
    case notice    // [Notice] 公告
    case system    // 其他系统消息
}

public struct ChatMessage: Sendable, Hashable {
    public var kind: MessageKind
    public var speaker: String?   // 玩家名（不翻译）
    public var body: String       // 要翻译的内容
    public var raw: String        // 整理后的原文
    public var minY: Double       // 在聊天框里的位置（0~1，用于原地覆盖）
    public var maxY: Double
    public var maxX: Double = 0      // 原文最右边（原地覆盖时要盖住整段英文）
    /// 喇叭：在哪个频道喊的
    public var channel: Int? = nil
    public var lineCount: Int = 1    // 占几行（算单行高度、字号用）

    public init(kind: MessageKind, speaker: String?, body: String, raw: String, minY: Double, maxY: Double) {
        self.kind = kind; self.speaker = speaker; self.body = body; self.raw = raw; self.minY = minY; self.maxY = maxY
    }
}

public enum ChatParser {
    /// 聊天文字都从聊天框左边缘开始；不从左边开始的多半是背景里的名牌、伤害数字等。
    static let leftMarginLimit = 0.06
    /// 上一行写到接近右边缘，下一行才可能是折行。
    static let wrapRightEdge = 0.80

    /// 玩家发言“名字 : 内容”。名字可能被认成中间带空格（“Player One”），所以允许名字里有一个空格；名字部分一律不翻译。
    static let chatPattern = try! NSRegularExpression(pattern: #"^([A-Za-z0-9]{1,13}(?: [A-Za-z0-9]{1,13})?(?:\(?\))?)\s?[:;]\s?(\S.*)$"#)

    /// 喇叭“名字 CH02 : 内容”，数字常认成字母
    static let megaPattern = try! NSRegularExpression(pattern: #"^([A-Za-z0-9]{1,13}(?: [A-Za-z0-9]{1,13})?(?:\(?\))?)\s+[_e.\-]?\s?(?:[CcGO6(][Hh]|d)\s?([0-9OoQDIlSsBZ]\s?[0-9OoQDIlSsBZ]?)\s*(?:E?[:;]|(?=\[|[\\/|1lI]?[SBTR]\s?>))\s*(\S.*)$"#)
    /// 见过的玩家名。新识别的名字和见过的只差一两个字母时，统一成见过的写法（“Playerone”“Player One” → “PlayerOne”）。
    nonisolated(unsafe) static var knownNames: [String: Int] = [:]
    /// 只查不记：和见过的玩家名只差一两个字母（“Play/rOne” → “PlayerOne”）就返回见过的写法
    /// 自己的角色名（菜单里设置）：NPC 对话里叫到你时，认花的名字按它纠正
    nonisolated(unsafe) public static var playerName = ""
    static func knownName(like raw: String) -> String? {
        let n = Array(raw.replacingOccurrences(of: " ", with: "").lowercased())
        if !playerName.isEmpty {
            // 只比字母：认花了、中间多了符号的名字，和真名差 1 个字母
            let a = Array(playerName.lowercased().filter(\.isLetter)), b = n.filter(\.isLetter)
            let lim = max(1, a.count / 3)
            if Fuzzy.distance(a, b, limit: lim) <= lim { return playerName }
        }
        return knownNames.filter { $0.value >= 2 }.first { k, _ in
            let lim = k.count >= 6 ? 2 : 1
            return Fuzzy.distance(Array(k.lowercased()), n, limit: lim) <= lim
        }?.key
    }
    nonisolated(unsafe) static var bracketNames: Set<String> = []
    public static func canonicalName(_ raw: String) -> String {
        var name = raw.replacingOccurrences(of: " ", with: "")
        // 名字带括号（“Fartacus()”）：左括号常被认成 t、l、f 等，补回来；和不带括号的名字不混在一起
        if name.hasSuffix(")") {
            if !name.hasSuffix("()"), name.count > 2 {
                let stem = name.dropLast()
                name = (stem.last.map { "tlficI1".contains($0) } == true ? String(stem.dropLast()) : String(stem)) + "()"
            }
            bracketNames.insert(name)
            return name
        }
        // 个别帧把“()”认成一两个字母（Fartacust、Fartacuso）：见过带括号的写法就统一回去
        if let b = bracketNames.first(where: { b in
            let base = b.dropLast(2), rest = name.dropFirst(base.count)
            return name.hasPrefix(base) && (1...2).contains(rest.count) && rest.allSatisfy { "tlficI1oOn0".contains($0) }
        }) { return b }
        // 自己的名字：和菜单里设置的只差一点（Playerone、God ish、Godivish）就按设置的写
        let nameLimit = playerName.count >= 7 ? 2 : 1
        if playerName.count >= 5, Fuzzy.distance(Array(name.lowercased()), Array(playerName.lowercased()), limit: nameLimit) <= nameLimit { return playerName }
        if knownNames[name] != nil { knownNames[name]! += 1; return name }
        let n = Array(name.lowercased())
        if let best = knownNames.filter({ $0.value >= 2 })
            .first(where: { k, _ in
                let lim = k.count >= 6 ? 2 : 1
                return Fuzzy.distance(Array(k.lowercased()), n, limit: lim) <= lim
            }) {
            knownNames[best.key]! += 1
            return best.key
        }
        knownNames[name] = 1
        if knownNames.count > 300 { knownNames = knownNames.filter { $0.value >= 2 } }
        return name
    }
    /// 频道标签：[Notice] [Friend] [Party] [Guild] 等。识别时左括号常丢失或认错，前面也可能混进一两个杂字。
    static let tagNames = ["Notice": "公告", "Friend": "好友", "Buddy": "好友", "Party": "队伍", "Guild": "家族",
                           "Alliance": "联盟", "Whisper": "悄悄话", "Megaphone": "喇叭", "System": "系统", "Event": "活动", "GM": "GM"]
    static let noticePattern = try! NSRegularExpression(
        pattern: #"^.{0,3}?[\[\(¡|{]?\s?(Notic[e]?|Friend|Buddy|Party|Guild|Alliance|Whisper|Megaphone|System|Event|GM)(?:[\]\)jl|}1I]\s*|\s+)(.*)$"#,
        options: .caseInsensitive)
    static func canonicalTag(_ t: String) -> String {
        tagNames.keys.first { $0.lowercased() == t.lowercased() || (t.lowercased().hasPrefix("notic") && $0 == "Notice") } ?? t
    }

    public static func parse(_ lines: [OCRLine], systemStarts: [NSRegularExpression] = [], fullRight: Double? = nil) -> [ChatMessage] {
        // fullRight：框宽固定时，超过这个位置才算“写满”（不给就按这一屏最长的一行算）
        let heights = lines.map { $0.maxY - $0.minY }.sorted()
        let medianH = heights.isEmpty ? 0 : heights[heights.count / 2]
        var kept = lines
            .filter { $0.minX < leftMarginLimit }
            .filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
            .filter { $0.confidence >= 0.5 }   // 识别把握太低的行不要
            // 贴着区域上下边缘、而且明显比正常行矮的，是被切掉一半的行，识别不可靠
            .filter { l in
                let h = l.maxY - l.minY
                let atEdge = l.minY < 0.01 || l.maxY > 0.99
                return !(atEdge && h < medianH * 0.75)
            }
            .sorted { $0.minY < $1.minY }

        var msgs: [ChatMessage] = []
        var lastMaxX = 0.0
        // 区域最上面如果是一句话的后半截（小写字母开头、又不是消息开头），前半截已经看不到了，丢掉
        while let first = kept.first, first.text.first?.isLowercase == true,
              !isMessageStart(first.text, systemStarts: systemStarts) {
            kept.removeFirst()
        }
        let rightMost = kept.map(\.maxX).max() ?? 1
        // 喇叭的折行往里缩：缩了的一定接上一条，没缩的一定是新的一条
        let base = kept.map(\.minX).min() ?? 0
        func indented(_ l: OCRLine) -> Bool { l.minX > base + 0.02 }
        while kept.count > 1, indented(kept[0]), !isMessageStart(kept[0].text, systemStarts: systemStarts) { kept.removeFirst() }
        for line in kept {
            let text = line.text.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "≥", with: ">").replacingOccurrences(of: "≤", with: "<")   // “b>”“s>” 常认成 ≥
                .replacingOccurrences(of: "^×(?=[A-Za-z0-9]+\\s?[:;])", with: "x", options: .regularExpression)   // 名字开头的 x 认成 ×，会被接到上一句后面
            let startsNew = isMessageStart(text, systemStarts: systemStarts)
            let prevWasFull = lastMaxX > (fullRight ?? rightMost * wrapRightEdge)
            // 上一行已经以句号/感叹号/问号结尾、这一行又是大写开头：是新的一条，不是折行
            let prevEndsSentence = msgs.last.map { m in
                let t = m.raw.trimmingCharacters(in: .whitespaces)
                return t.hasSuffix(".") || t.hasSuffix("!") || t.hasSuffix("?")
            } ?? false
            // 上一行本身就是一条完整的系统提示（“Egg x3 earned. (Use)”），这一行大写开头：也是新的一条
            let prevWhole = msgs.last.map { m in
                let t = m.raw.trimmingCharacters(in: .whitespaces)
                return m.kind == .system && systemStarts.contains { $0.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) != nil }
            } ?? false
            let newSentence = (prevEndsSentence || prevWhole) && text.first?.isUppercase == true
            // 小写字母开头又不是消息开头的，一定是半截话（系统提示都是大写开头）：上一条是公告就接上去（上一行右边被挡住、没认全），
            // 否则前半截已经看不到了（“tally use your”“formation for m”），丢掉
            let fragment = !startsNew && text.first?.isLowercase == true
            if fragment, !(msgs.last?.channel != nil && indented(line)), !prevWasFull || msgs.isEmpty, msgs.last?.kind != .notice { continue }
            let mega = msgs.last?.channel != nil
            if !startsNew, mega ? indented(line) : prevWasFull || fragment, mega || !newSentence, var last = msgs.popLast() {
                last.raw = joinWrapped(last.raw, text)
                last.body = joinWrapped(last.body, text)
                last.maxY = line.maxY
                last.maxX = max(last.maxX, line.maxX)
                last.lineCount += 1
                msgs.append(last)
            } else {
                var m = classify(text, minY: line.minY, maxY: line.maxY)
                m.maxX = line.maxX
                msgs.append(m)
            }
            lastMaxX = line.maxX
        }
        return msgs
    }

    static func isMessageStart(_ s: String, systemStarts: [NSRegularExpression]) -> Bool {
        let r = NSRange(s.startIndex..., in: s)
        if megaPattern.firstMatch(in: s, range: r) != nil { return true }
        if chatPattern.firstMatch(in: s, range: r) != nil { return true }
        if noticePattern.firstMatch(in: s, range: r) != nil { return true }
        if s.hasPrefix("'") || s.hasPrefix("You ") { return true }
        return systemStarts.contains { $0.firstMatch(in: s, range: r) != nil }
    }

    /// 整句只有一个短黑话时的常见错认（游戏字体里 g 像 O/q、b 像 L/D、y 像 v）
    static let shortFixes = ["oz": "gz", "0z": "gz", "qz": "gz", "9z": "gz", "tv": "ty", "lak": "bak", "dak": "bak", "laak": "bak",
                             "wub": "wb", "vub": "wb", "vb": "wb"]
    static func fixBody(_ b: String) -> String {
        // 游戏里只有英文：带声调、重音的字母（ự、ć）都是认错，去掉符号
        let t = b.folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US"))
        let key = t.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
        if let f = shortFixes[key] { return t.lowercased().replacingOccurrences(of: key, with: f) }
        return t
    }

    /// 刷屏的一长串 @：每次认得都不一样（da@d@a@、taaaaaaa、RUSHara），去掉，免得同一句反复当成新的、译文跟着乱。
    /// 只剩符号、去完没字的不动
    static func despam(_ s: String) -> String {
        func rep(_ t: String, _ p: String, _ w: String = "") -> String { t.replacingOccurrences(of: p, with: w, options: .regularExpression) }
        var out: [String] = []
        for w in s.split(separator: " ").map(String.init) {
            var t = w
            let at = t.filter { $0 == "@" }.count
            // 两个以上 @，别的字都是 @ 常被认成的那几个小写字母：整个是刷屏的；前面粘着正经的字就只留字
            if at >= 2 { t = rep(t, "[@adortciq]*@[@adortciq]*(@[@adortciq]*)+") }
            if t != "@" { t = rep(t, "@+$") }
            t = rep(t, "^[a-z]?a{6,}$")
            t = rep(t, "^([A-Z]{3,})a{4,}$", "$1")
            t = rep(t, "^([A-Z]{3,})(ara|ada|ana)$", "$1")
            if !t.isEmpty { out.append(t) }
        }
        if out.last == "@" { out.removeLast() }      // 折到下一行的
        let r = rep(out.joined(separator: " "), "\\b([KLHC]P)O\\b", "$1Q")      // KPQ 的 Q 认成 O
        return r.contains(where: { $0.isLetter || $0.isNumber }) ? r : s
    }

    public static func classify(_ s: String, minY: Double, maxY: Double) -> ChatMessage {
        let r = NSRange(s.startIndex..., in: s)
        if let m = noticePattern.firstMatch(in: s, range: r), let tg = Range(m.range(at: 1), in: s), let body = Range(m.range(at: 2), in: s) {
            let b = String(s[body]), tag = canonicalTag(String(s[tg]))
            return ChatMessage(kind: .notice, speaker: tag, body: b, raw: "[\(tag)] " + b, minY: minY, maxY: maxY)
        }
        if let m = megaPattern.firstMatch(in: s, range: r), let n = Range(m.range(at: 1), in: s), let c = Range(m.range(at: 2), in: s), let b = Range(m.range(at: 3), in: s) {
            let digits = String(s[c].filter { $0 != " " }.map { ["O": "0", "o": "0", "Q": "0", "D": "0", "I": "1", "l": "1", "S": "5", "s": "5", "B": "8", "Z": "2"][$0] ?? $0 })
            if let ch = Int(digits), (1...60).contains(ch) {
                let name = canonicalName(String(s[n])), body = despam(fixBody(String(s[b]))).replacingOccurrences(of: "^[\\\\/|1lI]+(?=[SBRT]\\s?>)", with: "", options: .regularExpression)
                var out = ChatMessage(kind: .chat, speaker: name, body: body, raw: "\(name) CH\(ch < 10 ? "0" : "")\(ch) : \(body)", minY: minY, maxY: maxY)
                out.channel = ch
                return out
            }
        }
        if let m = chatPattern.firstMatch(in: s, range: r),
           let n = Range(m.range(at: 1), in: s), let b = Range(m.range(at: 2), in: s) {
            let name = canonicalName(String(s[n])), body = despam(fixBody(String(s[b])))
            return ChatMessage(kind: .chat, speaker: name, body: body, raw: "\(name) : \(body)", minY: minY, maxY: maxY)
        }
        return ChatMessage(kind: .system, speaker: nil, body: s, raw: s, minY: minY, maxY: maxY)
    }

    /// 判断一条消息是不是“认花了”（背景里的角色、特效刚好压在字上时会出现）：
    /// 4 个词以上、而且超过 3 成都不是英文单词（玩家常用缩写、玩家名除外），就当作识别失败，等下一帧。
    public static func looksGarbled(_ m: ChatMessage, knownWords: Set<String>) -> Bool {
        let tokens = m.body.split(whereSeparator: { !$0.isLetter && $0 != "'" })
            .map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "'")) }
            .filter { $0.count >= 3 }
        guard tokens.count >= 4 else { return false }
        let good = tokens.filter { knownWords.contains($0) || Words.isWord($0) }.count
        return Double(good) / Double(tokens.count) < 0.7
    }

    /// 聊天框里单独一行只有一个像名字的词（JUcyr、PICAT、MiD4ng）：多半是名牌或认残的半行，不是消息，别拿去翻
    public static func lonelyName(_ m: ChatMessage) -> Bool {
        guard m.kind == .system else { return false }
        let t = m.raw.trimmingCharacters(in: .whitespaces)
        guard t.range(of: "^[A-Za-z][A-Za-z0-9_]{1,13}$", options: .regularExpression) != nil else { return false }
        let odd = t.dropFirst().contains { $0.isUppercase || $0.isNumber || $0 == "_" }
        return odd || !Words.isWord(t.lowercased())
    }

    /// 以问号结尾（后面可以再跟 ! . 等）
    public static func isQuestion(_ s: String) -> Bool {
        s.range(of: "[?？][\\s?？!！.。~)）\"']*$", options: .regularExpression) != nil
    }

    /// 两次看到的是不是同一句话（容许识别误差）。短句单独比内容：“名字 : ?”“名字 : ok”“名字 : hi”不能当成一句
    public static func sameMessage(_ a: String, _ b: String) -> Bool {
        guard Fuzzy.similar(a, b) else { return false }
        func body(_ s: String) -> [Character] { Fuzzy.normalize(s.range(of: " : ").map { String(s[$0.upperBound...]) } ?? s) }
        let x = body(a), y = body(b)
        return min(x.count, y.count) > 3 || x == y
    }

    /// 一句话里有几个不像英文的词（数字、常见符号不算；用来比较两次识别哪次更可靠）
    static func badWords(_ s: String) -> Int {
        s.split(separator: " ").filter { w in
            if w.contains(where: { $0.isLetter && !$0.isASCII }) { return true }
            let t = w.trimmingCharacters(in: .punctuationCharacters)
            if t.contains(where: \.isLetter), t.contains(where: \.isNumber) { return true }
            return t.count >= 3 && t.allSatisfy(\.isLetter) && !Words.isWord(t)
        }.count
    }

    /// 游戏按字符折行，单词可能被拆开（“a b” + “an.” = “a ban.”）。
    /// 上一行最后的碎片和下一行开头拼起来是个常见词、而碎片本身不像单词时，就不加空格直接拼。
    public static func joinWrapped(_ a: String, _ b: String) -> String {
        guard let lastWord = a.split(separator: " ").last, let firstWord = b.split(separator: " ").first else {
            return a + " " + b
        }
        let tail = String(lastWord), head = String(firstWord)
        let tailIsLetters = tail.allSatisfy(\.isLetter), headStartsLower = head.first?.isLowercase == true
        if tailIsLetters, headStartsLower {
            let merged = (tail + head).trimmingCharacters(in: .punctuationCharacters)
            let headClean = head.trimmingCharacters(in: .punctuationCharacters)
            // 拼起来是个词，且两半里至少一半不是词（“com”+“pensated”、“b”+“an”）
            if Words.isWord(merged), !Words.isWord(tail) || !Words.isWord(headClean) {
                return a + b
            }
            if !Words.isWord(tail), !Words.isWord(headClean) {
                return a + b
            }
        }
        return a + " " + b
    }
}

/// 简单判断是不是英文单词（用系统拼写检查，离线）。
enum Words {
    nonisolated(unsafe) static var cache: [String: Bool] = [:]
    static let shortWords: Set<String> = ["a", "i", "an", "am", "as", "at", "be", "by", "do", "go", "he", "if", "in", "is", "it", "me", "my", "no", "of", "ok", "on", "or", "so", "to", "up", "us", "we"]
    static func isWord(_ w: String) -> Bool {
        let l = w.lowercased()
        if l.count <= 2 { return shortWords.contains(l) }
        if let c = cache[l] { return c }
        let ok = SpellCheck.isCorrect(l)
        cache[l] = ok
        return ok
    }
}
