// 翻译：先查固定句式和黑话词表，剩下的交给 macOS 自带的本地翻译（离线，不外传）。
import Foundation
import Translation
import AppKit

enum SpellCheck {
    static func isCorrect(_ w: String) -> Bool {
        let checker = NSSpellChecker.shared
        let r = checker.checkSpelling(of: w, startingAt: 0, language: "en", wrap: false, inSpellDocumentWithTag: 0, wordCount: nil)
        return r.location == NSNotFound
    }
}

public struct Glossary: Sendable {
    public var customWords: [String]
    var wholeMessage: [String: String]
    var abbreviations: [(NSRegularExpression, String)]
    var postfix: [(String, String)]
    var templates: [(NSRegularExpression, String)]
    var fixed: [(norm: [Character], zh: String)]
    var fixedNumbered: [(norm: [Character], zh: String)] = []
    /// 物品说明框用的固定词典：属性名、属性值、职业、橙色提示
    /// 冒险岛专有词（地名、怪物、道具、职业、玩家用语）：翻译前换成占位符，翻译后换成标准中文
    var terms: [(NSRegularExpression, String)] = []
    /// 任务窗口用：terms + QuestNames.json
    var questTerms: [(NSRegularExpression, String)] = []
    /// 任务原文表里没有的标题（归一化英文 → 中文）
    var questTitles: [(String, String)] = []
    /// QuestNames.json 里的怪物、物品英文名
    var questNames: [String] = []
    public var tipLabels: [String: String] = [:]
    public var tipValues: [String: String] = [:]
    public var tipJobs: [String: String] = [:]
    public var tipFlags: [String: String] = [:]
    public var tipSkills: [String: String] = [:]

    public static func load() throws -> Glossary {
        // 打包成 .app 时词表放在 Contents/Resources；命令行测试时用 SwiftPM 资源包
        guard let url = Bundle.main.url(forResource: "Glossary", withExtension: "json")
                ?? Bundle.module.url(forResource: "Glossary", withExtension: "json") else {
            throw NSError(domain: "Glossary", code: 1, userInfo: [NSLocalizedDescriptionKey: "找不到词表"])
        }
        let j = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        // 以符号结尾的缩写（b>、s>、w/）后面可以直接跟字母（“B>fame”）
        let abbr = (j["abbreviations"] as! [String: String]).sorted { $0.key.count > $1.key.count }.map { k, v in
            let tail = k.last!.isLetter || k.last!.isNumber ? "(?![A-Za-z])" : ""
            return (try! NSRegularExpression(pattern: "(?<![A-Za-z])" + NSRegularExpression.escapedPattern(for: k) + tail, options: .caseInsensitive),
                    k.last!.isLetter || k.last!.isNumber ? v : v + " ")
        }
        // 长的先替换，避免“党”抢在“党的领导人”之前
        let post = (j["postfix"] as! [String: String]).sorted { $0.key.count > $1.key.count }.map { ($0.key, $0.value) }
        let tpl = (j["templates"] as! [[String]]).map { (try! NSRegularExpression(pattern: $0[0], options: .caseInsensitive), $0[1]) }
        let allFixed = j["fixedSentences"] as? [[String]] ?? []
        let fixed = allFixed.filter { !$0[0].contains("{n}") }.map { (norm: Fuzzy.normalize($0[0]), zh: $0[1]) }
        let numbered = allFixed.filter { $0[0].contains("{n}") }.map { (norm: Fuzzy.normalize($0[0].replacingOccurrences(of: "{n}", with: "")), zh: $0[1]) }
        var g = Glossary(customWords: j["customWords"] as! [String],
                         wholeMessage: j["wholeMessage"] as! [String: String],
                         abbreviations: abbr, postfix: post, templates: tpl, fixed: fixed)
        g.fixedNumbered = numbered
        let baseTerms = j["terms"] as? [String: String] ?? [:]
        g.terms = termRegexes(baseTerms)
        // 任务翻译专用名字表（QuestNames.json）：NPC 名保留英文、怪物/物品/地图用定好的中文；只在翻译任务窗口时叠加
        if let qurl = GameData.url("QuestNames") ?? Bundle.main.url(forResource: "QuestNames", withExtension: "json") ?? Bundle.module.url(forResource: "QuestNames", withExtension: "json"),
           let q = try? JSONSerialization.jsonObject(with: Data(contentsOf: qurl)) as? [String: Any] {
            var all = baseTerms
            for n in q["npc"] as? [String] ?? [] { all[n.lowercased()] = n }
            for sec in ["mob", "item", "map"] {
                for (k, v) in q[sec] as? [String: String] ?? [:] { all[k.lowercased()] = v }
            }
            for sec in ["mob", "item"] { g.questNames += (q[sec] as? [String: String] ?? [:]).keys }
            g.questTerms = termRegexes(all)
            g.questTitles = (q["titles"] as? [String: String] ?? [:]).map { (QuestDB.norm($0.key), $0.value) }
        } else {
            g.questTerms = g.terms
        }
        if let t = j["tooltip"] as? [String: [String: String]] {
            g.tipLabels = t["labels"] ?? [:]; g.tipValues = t["values"] ?? [:]
            g.tipJobs = t["jobs"] ?? [:]; g.tipFlags = t["flags"] ?? [:]
            // 技能名（只用在说明框标题；Slow、Heal 这种单词不放进 terms，免得聊天里误换）
            for (k, v) in t["skills"] ?? [:] { g.tipSkills[k.lowercased()] = v }
        }
        return g
    }

    /// 专有词 → 正则（长的先替换；英文词允许复数：jr wraiths、zombie mushrooms）
    static func termRegexes(_ t: [String: String]) -> [(NSRegularExpression, String)] {
        t.sorted { $0.key.count > $1.key.count }.map { k, v in
            let plural = k.last!.isLetter && k.count > 3 ? "(?:e?s)?" : ""
            return (try! NSRegularExpression(pattern: "(?<![A-Za-z0-9])" + NSRegularExpression.escapedPattern(for: k) + plural + "(?![A-Za-z0-9])", options: .caseInsensitive), v)
        }
    }

    public var templateRegexes: [NSRegularExpression] { templates.map(\.0) }

    /// 识别质量检查时当作“认识”的词：玩家常用缩写、游戏用词
    public var knownWords: Set<String> {
        Set(customWords.map { $0.lowercased() }).union(wholeMessage.keys.flatMap { $0.split(separator: " ").map(String.init) })
    }

    public func matchTemplate(_ raw: String) -> String? {
        let s = HuntLog.fixItemLine(raw)
        let r = NSRange(s.startIndex..., in: s)
        for (re, zh) in templates {
            if let m = re.firstMatch(in: s, range: r) {
                // 句式里抓出来的英文（道具名等）按 terms 换成中文
                var out = re.replacementString(for: m, in: s, offset: 0, template: zh)
                // 抓出来的正好是物品名：用物品表的译名
                for g in 1..<max(1, m.numberOfRanges) {
                    guard let gr = Range(m.range(at: g), in: s), let it = ItemDB.shared.exact(String(s[gr])), !it.zh.isEmpty else { continue }
                    out = out.replacingOccurrences(of: String(s[gr]), with: it.zh)
                }
                for (tre, tzh) in terms {
                    out = tre.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: NSRegularExpression.escapedTemplate(for: tzh))
                }
                return out
            }
        }
        return nil
    }

    /// 固定系统句子：允许少量识别错字，并忽略句尾串进来的背景文字。
    func matchFixed(_ s: String) -> String? {
        // 带数字的固定句子（{n}）：比对时去掉数字，匹配上后把原文里的第一个数字填回去
        let digits = Fuzzy.normalize(s).filter { !$0.isNumber }
        for f in fixedNumbered where digits.count >= Int(Double(f.norm.count) * 0.92) {
            let head = Array(digits.prefix(f.norm.count))
            let allowed = max(2, f.norm.count / 8)
            if Fuzzy.distance(head, f.norm, limit: allowed) <= allowed {
                let n = s.range(of: "[0-9]+", options: .regularExpression).map { String(s[$0]) } ?? "?"
                return f.zh.replacingOccurrences(of: "{n}", with: n)
            }
        }
        let m = Fuzzy.normalize(s)
        for f in fixed where m.count >= Int(Double(f.norm.count) * 0.92) {
            let head = Array(m.prefix(f.norm.count))
            let allowed = max(2, f.norm.count / 8)
            if Fuzzy.distance(head, f.norm, limit: allowed) <= allowed { return f.zh }
        }
        return nil
    }

    /// 停服、维护之类的公告：就算隐藏公告也要显示
    private static let importantNotice = try! NSRegularExpression(
        pattern: #"maint[ea]nance|\bservers?\b|shut ?down|shutting down|restart|reboot|\bpatch|\bupdates?\b|\bchannels?\b.*\bclos"#, options: .caseInsensitive)

    /// 可以隐藏的游戏公告：[Notice]（停服维护类除外）和游戏定时弹的健康提示。
    /// 好友、队伍、家族、活动等也是 kind == .notice，要看标签，不能按 kind 隐藏。
    public func isHideableNotice(kind: MessageKind, speaker: String?, raw: String) -> Bool {
        guard kind != .chat else { return false }
        // 对得上的固定句子（标签没认出来也行）：都是反复播的
        if kind == .system || speaker == "Notice", let zh = matchFixed(raw) ?? matchFixed("[Notice] " + raw),
           ["【公告】", "不要让游戏", "你已经玩了"].contains(where: zh.hasPrefix) { return true }
        guard kind == .notice, speaker == "Notice" else { return false }
        return Self.importantNotice.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)) == nil
    }

    public func matchesFixed(_ s: String) -> Bool { matchFixed(s) != nil || matchTemplate(s) != nil }

    func matchWhole(_ s: String) -> String? {
        let lower = s.lowercased().trimmingCharacters(in: .whitespaces)
        if let exact = wholeMessage[lower] { return exact }          // 带问号的先精确匹配（party? → 组队吗？）
        let key = lower.trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
        return wholeMessage[key].map { Self.keepQuestion(s, $0) }
    }

    /// 原文以问号结尾（后面可以跟 ! . 之类），译文也要有问号
    static func keepQuestion(_ en: String, _ zh: String) -> String {
        guard ChatParser.isQuestion(en), !zh.contains("？"), !zh.contains("?"), !zh.isEmpty else { return zh }
        return zh.trimmingCharacters(in: CharacterSet(charactersIn: "。.！! ")) + "？"
    }

    func expandAbbreviations(_ s: String) -> String {
        // 去掉刷屏用的符号串（@@@@@、*****、~~~~~ 等），只留文字内容
        // 问号、感叹号是语气，不能删：一串只留一个
        var out = s.replacingOccurrences(of: "？", with: "?").replacingOccurrences(of: "！", with: "!")
            .replacingOccurrences(of: "\\s*([?!])(\\s*\\1)+", with: "$1", options: .regularExpression)
            .replacingOccurrences(of: "([^A-Za-z0-9\\s])\\1{2,}", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        // 交易里的“34 ea” = 单价 34：改写成机器翻译能看懂的说法
        out = out.replacingOccurrences(of: "(?i)\\b([0-9][0-9.,]*)\\s*(ea|each)\\b", with: "at a price of $1 each,", options: .regularExpression)
        for (re, en) in abbreviations {
            out = re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: en)
        }
        return out
    }

    /// “999k ea” → “单价 99.9 万”，“5k” → “5000”，“1.2M” → “120 万”
    static func money(_ t: String) -> String? {
        let low = t.lowercased(), num = low.prefix { $0.isNumber || $0 == "." }
        guard let v = Double(num), let unit = low.dropFirst(num.count).first(where: { $0 == "k" || $0 == "m" }) else { return nil }
        let n = v * (unit == "k" ? 1_000 : 1_000_000)
        func txt(_ d: Double) -> String { d == d.rounded() ? String(Int(d)) : String(format: "%.4f", d).replacingOccurrences(of: "0+$", with: "", options: .regularExpression) }
        guard n < 1e12 else { return nil }
        return (low.hasSuffix("ea") || low.hasSuffix("each") ? "单价 " : "") + (n >= 1e8 ? txt(n / 1e8) + " 亿" : n >= 1e4 ? txt(n / 1e4) + " 万" : txt(n))
    }
    /// 把专有词换成占位符（ZQXA、ZQXB…，系统翻译会原样保留），返回替换后的英文和占位符对照表
    func protectTerms(_ s: String, quest: Bool = false) -> (String, [(String, String)]) {
        var out = s
        var map: [(String, String)] = []
        let letters = Array("ABCDEFGHJKLMNPRSTUVWY")
        // 金额整个占位，数字不交给机器翻（1.2M 会被拼成 1.2,000,000）
        while !quest, map.count < 8, let r = out.range(of: "(?i)(?<![A-Za-z0-9.,])[0-9]+(\\.[0-9]+)?\\s?[km](\\s*(ea|each))?\\b", options: .regularExpression), let zh = Self.money(String(out[r])) {
            let ph = "ZQX" + String(letters[map.count])
            out.replaceSubrange(r, with: ph); map.append((ph, zh))
        }
        for (re, zh) in quest ? questTerms : terms {
            guard map.count < letters.count else { break }
            let range = NSRange(out.startIndex..., in: out)
            guard re.firstMatch(in: out, range: range) != nil else { continue }
            let ph = "ZQX" + String(letters[map.count])
            out = re.stringByReplacingMatches(in: out, range: range, withTemplate: ph)
            map.append((ph, zh))
        }
        return (out, map)
    }

    func restoreTerms(_ zh: String, _ map: [(String, String)]) -> String {
        var out = zh
        for (ph, term) in map {
            out = out.replacingOccurrences(of: ph, with: term)
            out = out.replacingOccurrences(of: ph.lowercased(), with: term)
            out = out.replacingOccurrences(of: ph.capitalized, with: term)
        }
        return out
    }

    func fixUp(_ zh: String) -> String {
        var out = zh.applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? zh
        for (a, b) in postfix { out = out.replacingOccurrences(of: a, with: b) }
        return out.trimmingCharacters(in: CharacterSet(charactersIn: "，, "))
    }
}

public struct TranslatedMessage: Sendable {
    public var message: ChatMessage
    public var chinese: String       // 显示用的完整中文（含玩家名）
    public var source: String        // 来源：固定句式 / 词表 / 机器翻译
}

public actor ChatTranslator {
    let glossary: Glossary
    private var session: TranslationSession?
    private var cache: [String: String] = [:]
    private let cacheLimit = 2000

    public init(glossary: Glossary) { self.glossary = glossary }

    /// 清空翻译缓存，并重建翻译会话（内存保护用）
    public func reset() { cache.removeAll(); session = nil }

    private func getSession() -> TranslationSession {
        if let s = session { return s }
        let s = TranslationSession(installedSource: Locale.Language(identifier: "en"),
                                   target: Locale.Language(identifier: "zh-Hans"))
        session = s
        return s
    }

    /// 翻译一条英文；第一次调用偶尔会误报“未安装”，所以重试几次。
    func machineTranslate(_ en: String, quest: Bool = false) async -> String {
        let key = quest ? "任务\u{1}" + en : en
        if let c = cache[key] { return c }
        let (protected, map) = glossary.protectTerms(en, quest: quest)
        // 整句都是专有词（比如 “kpq?”）：不用机器翻译
        if !map.isEmpty, protected.trimmingCharacters(in: .punctuationCharacters.union(.whitespaces)).range(of: "^(ZQX[A-Z]\\s*)+$", options: .regularExpression) != nil {
            return glossary.restoreTerms(protected, map)
        }
        for attempt in 0..<3 {
            do {
                let r = try await getSession().translate(protected)
                var zh = glossary.fixUp(glossary.restoreTerms(r.targetText, map))
                // 任务窗口：中文和英文名之间加空格（和人工译文的写法一致：“带到 Pia 或”）
                if quest {
                    zh = zh.replacingOccurrences(of: "(\\p{Han})([A-Za-z0-9])", with: "$1 $2", options: .regularExpression)
                        .replacingOccurrences(of: "([A-Za-z0-9.!?])(\\p{Han})", with: "$1 $2", options: .regularExpression)
                        .replacingOccurrences(of: "([，。！？；：、）])\\s+", with: "$1", options: .regularExpression)
                }
                if cache.count >= cacheLimit { cache.removeAll(keepingCapacity: true) }
                cache[key] = zh
                return zh
            } catch {
                session = nil
                try? await Task.sleep(nanoseconds: UInt64(300_000_000 * (attempt + 1)))
            }
        }
        return "（翻译失败）" + en
    }

    /// 翻译一段普通英文（物品名、说明文字）：不按聊天格式拆名字，只做缩写展开 + 系统翻译 + 词表修正
    /// quest：任务窗口用，叠加任务名字表（NPC 名保留英文，怪物/物品/地图用定好的中文）
    public func plain(_ en: String, quest: Bool = false) async -> String {
        if let t = glossary.matchFixed(en) ?? glossary.matchTemplate(en) { return t }
        return await machineTranslate(glossary.expandAbbreviations(en), quest: quest)
    }

    private func trade(_ body: String) async -> String? {
        var rest = body, head = ""
        if let r = rest.range(of: "^\\[[^\\]]{3,40}\\]\\s*", options: .regularExpression) {
            let en = rest[r].trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
            head = "[" + (ItemDB.shared.find(en)?.zh ?? en) + "] "
            rest = String(rest[r.upperBound...])
        }
        // J> KPQ：想进别人的队
        if head.isEmpty, let j = rest.range(of: "^[Jj]\\s?>+\\s*(?=[A-Za-z])", options: .regularExpression) {
            return "想加入 " + (await machineTranslate(glossary.expandAbbreviations(String(rest[j.upperBound...]))))
        }
        guard let r = rest.range(of: "^[\\\\/|]?\\s?(S|B|T|WTS|WTB|selling|buying)\\s?>+\\s*", options: [.regularExpression, .caseInsensitive]) else {
            guard !head.isEmpty, !rest.isEmpty else { return head.isEmpty ? nil : head }
            if let w = glossary.matchWhole(rest) { return head + w }
            return head + Glossary.keepQuestion(rest, await machineTranslate(glossary.expandAbbreviations(rest)))
        }
        let low = rest[r].lowercased(), verb = low.contains("b") ? "收购 " : low.hasPrefix("t") ? "交换 " : "出售 "
        var out: [String] = [], plain: [String] = []
        func flush() async {
            guard !plain.isEmpty else { return }
            let s = plain.joined(separator: ", "); plain = []
            out.append(await machineTranslate(glossary.expandAbbreviations(s)))
        }
        // 没有一样在物品表里：整句翻，语气更顺
        var list = rest[r.upperBound...], tail = ""
        if let p = list.range(of: "(?i)[\\s,-]+(pm|pmo|pm me)\\W*$", options: .regularExpression) { tail = list[p].lowercased().contains("pmo") ? "，私聊出价" : "，私聊"; list = list[..<p.lowerBound] }
        // T> 甲 for 乙
        if low.hasPrefix("t"), let f = list.range(of: " for ", options: .caseInsensitive) {
            func one(_ x: Substring) async -> String {
                let p = x.trimmingCharacters(in: .whitespaces)
                if let e = ItemDB.shared.exact(p) { return e.zh }
                return await machineTranslate(glossary.expandAbbreviations(p))
            }
            let a = await one(list[..<f.lowerBound]), b = await one(list[f.upperBound...])
            return head + "用 " + a + " 换 " + b
        }
        let parts = list.split(whereSeparator: { $0 == "," || $0 == "+" }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        func item(_ p: String) -> String? {
            if p.count >= 4, let e = ItemDB.shared.exact(p) { return e.zh }
            // “Rower 400k”“chain 999k ea”
            guard let m = p.range(of: "(?i)\\s+[0-9]+(\\.[0-9]+)?\\s?[km](\\s*(ea|each))?$", options: .regularExpression), let zh = Glossary.money(String(p[m]).trimmingCharacters(in: .whitespaces)),
                  p[..<m.lowerBound].count >= 4, let e = ItemDB.shared.exact(String(p[..<m.lowerBound])) else { return nil }
            return e.zh + " " + zh
        }
        if head.isEmpty, !parts.contains(where: { item($0) != nil }) { return nil }
        for p in parts { if let zh = item(p) { await flush(); out.append(zh) } else { plain.append(p) } }
        await flush()
        return head + verb + out.joined(separator: "、") + tail
    }

    public func translate(_ m: ChatMessage) async -> TranslatedMessage {
        // 1. 固定系统句子 / 句式（最准）
        if let t = glossary.matchFixed(m.raw) ?? glossary.matchTemplate(m.raw) {
            return TranslatedMessage(message: m, chinese: t, source: "固定句式")
        }
        let prefix: String
        switch m.kind {
        case .chat: prefix = (m.speaker ?? "") + (m.channel.map { "（\($0) 频道喇叭）" } ?? "") + "："
        case .notice: prefix = "【" + (ChatParser.tagNames[m.speaker ?? "Notice"] ?? (m.speaker ?? "公告")) + "】"
        case .system: prefix = ""
        }
        // 整行就是一个物品名（鼠标指向商店、背包里的名字）
        if m.kind == .system, let e = ItemDB.shared.exact(m.raw) {
            return TranslatedMessage(message: m, chinese: e.zh, source: "物品表")
        }
        // 带频道标签的消息，内容部分也查一下固定句式（如 [Friend] xxx has logged in.）
        if m.kind != .system, let t = glossary.matchFixed(m.body) ?? glossary.matchTemplate(m.body) {
            return TranslatedMessage(message: m, chinese: prefix + t, source: "固定句式")
        }
        // 只有标点（别人只发了个“?”）：原样显示
        if !m.body.contains(where: { $0.isLetter || $0.isNumber }) {
            let t = m.body.replacingOccurrences(of: "?", with: "？").replacingOccurrences(of: "!", with: "！")
            return TranslatedMessage(message: m, chinese: prefix + t, source: "标点")
        }
        // 只有一个字母（玩家随手打的 f、x）：原样显示，别翻成“第六个罗马字母”
        if m.kind == .chat, m.body.filter({ $0.isLetter || $0.isNumber }).count == 1, m.body.contains(where: \.isLetter), glossary.matchWhole(m.body) == nil {
            return TranslatedMessage(message: m, chinese: prefix + m.body, source: "单个字母")
        }
        // 2. 整句黑话
        if let w = glossary.matchWhole(m.body) {
            return TranslatedMessage(message: m, chinese: prefix + w, source: "词表")
        }
        // 喇叭、喊话卖东西：开头的 [物品] 和逗号隔开的物品名查物品表，剩下的才机器翻
        if m.kind == .chat, let t = await trade(m.body) {
            return TranslatedMessage(message: m, chinese: prefix + t, source: "物品表")
        }
        // 3. 缩写展开成完整英文后，交给系统翻译
        let expanded = glossary.expandAbbreviations(m.body)
        let zh = Glossary.keepQuestion(m.body, await machineTranslate(expanded))
        return TranslatedMessage(message: m, chinese: prefix + zh, source: "机器翻译")
    }
}

public enum Fuzzy {
    /// 两段文字是否“基本一样”（识别误差以内）
    public static func similar(_ a: String, _ b: String, tolerance: Double = 0.18) -> Bool {
        let x = normalize(a), y = normalize(b)
        if x.isEmpty || y.isEmpty { return x.isEmpty && y.isEmpty }
        let limit = max(2, Int(Double(max(x.count, y.count)) * tolerance))
        return distance(x, y, limit: limit) <= limit
    }
    /// 只保留小写字母和数字，忽略空格标点（识别时最容易出错的部分）。
    public static func normalize(_ s: String) -> [Character] {
        Array(s.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) })
    }
    /// 编辑距离；超过 limit 提前结束。
    public static func distance(_ a: [Character], _ b: [Character], limit: Int) -> Int {
        if abs(a.count - b.count) > limit { return limit + 1 }
        var prev = Array(0...b.count), cur = [Int](repeating: 0, count: b.count + 1)
        for i in 1...max(a.count, 1) where !a.isEmpty {
            cur[0] = i
            var rowMin = cur[0]
            for j in 1...max(b.count, 1) where !b.isEmpty {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
                rowMin = min(rowMin, cur[j])
            }
            if rowMin > limit { return limit + 1 }
            swap(&prev, &cur)
        }
        return a.isEmpty ? b.count : prev[b.count]
    }
}
