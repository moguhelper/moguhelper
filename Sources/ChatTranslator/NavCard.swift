// 任务导航：打开任务详情时记住这个任务；识别小地图标题知道在哪张图；在侧边面板显示怎么走。只显示文字，不操作游戏。
import AppKit
import SwiftUI
import TranslatorCore

@MainActor
final class NavModel: ObservableObject {
    @Published private(set) var target: NavTarget? = UserDefaults.standard.data(forKey: "navTarget").flatMap { try? JSONDecoder().decode(NavTarget.self, from: $0) }
    /// find：还差这样东西，但没有哪里出的资料
    enum Goal: Equatable { case start, mob(String), find(String), end }
    @Published var goal: Goal = .end { didSet { if goal != oldValue { update() } } }
    /// 箭头要指的方向和话
    @Published private(set) var hint: NavHint?
    /// 正在拖动导航条
    @Published var moving = false
    // 采集向导：开着时箭头带路去采下一个门，任务导航先让开
    weak var collect: MapCollectModel? { didSet { collect?.onChange = { [weak self] in self?.updateGuide() }; onEnter = { [weak self] a, b in self?.collect?.entered(from: a, to: b) } } }
    /// 任务追踪里东西的数量（双复核用）
    var onCounts: (([(String, Int)]) -> Void)?
    @Published private(set) var guide: GuideStep?
    @Published private(set) var guideGoal: Int?
    @Published var guideOn = UserDefaults.standard.bool(forKey: "guideOn") && !NavDB.shared.maps.isEmpty { didSet { if guideOn != oldValue { UserDefaults.standard.set(guideOn, forKey: "guideOn"); if !guideOn { guideGoal = nil }; updateGuide(); updateHint(); onQuestChange?() } } }
    var playerName: () -> String = { "" }
    var myLevel: () -> Int? = { nil }
    /// 还差等级：要几级才能交 / 才能接（够了、不知道自己几级就是 nil）
    var lackLevel: Int? {
        guard let t = target, let me = myLevel() else { return nil }
        let need = t.accepted == true ? t.level : t.notStarted ? t.questId.flatMap { NavDB.shared.quest($0)?.slevel } : nil
        return need.flatMap { me < $0 ? $0 : nil }
    }
    /// 现在只差等级：别指着去找 NPC
    var waitLevel: Int? { goal == .start || goal == .end ? lackLevel : nil }
    var client: OCRClient?
    private var nameTry = Date.distantPast, nameOCR = Date.distantPast
    private var tag: TagShape?, tagTwice: TagShape?, tagName = ""
    private var seenMini = true, mapSeen = Date.distantPast
    /// 换图了：从哪张来（刚离开的才有）、到哪张
    var onEnter: ((Int?, Int) -> Void)?
    /// 挑这一步时知不知道自己在哪；不知道时挑的不算数，认出位置后重挑最近的
    private var guideHadPos = false
    func startGuide(to id: Int) { guideGoal = id; guideOn = true; updateGuide() }
    func skipGuideMap(_ id: Int) { if guideGoal == id { guideGoal = nil }; collect?.skip(map: id) }
    /// 在导航：有任务，或开着采集向导
    /// 组队任务的这一关；试过的组合
    var stage: StageGuide? { mapStale ? nil : mapId.flatMap { NavDB.shared.maps[$0] }.flatMap { QuestTips.guide(map: $0.name) } }
    @Published var tried: Set<String> = []
    private var idleAt = Date.distantPast
    /// NPC 让选的几项（带答案、✗），说完就清空
    @Published private(set) var choices: [Entry] = []
    func setChoices(_ c: [Entry]) {
        guard c.map(\.chinese) != choices.map(\.chinese) else { return }
        choices = c; onQuestChange?()
    }
    // MARK: 没有地图资料时带路（自己走过的、朋友传的）
    @Published private(set) var walkGoals: [WalkNav.Goal] = []
    @Published private(set) var walkGoal: WalkNav.Goal?
    @Published private(set) var walkUnknown: [String] = []
    private var walkHint: NavHint?
    func setWalk(goals: [WalkNav.Goal], unknown: [String]) {
        if walkGoals != goals { walkGoals = goals }
        if walkUnknown != unknown { walkUnknown = unknown }
    }
    /// 打开任务就自动带路；自己点过别的就按点的，换了任务再自动
    private var walkPicked: String?
    func autoWalk() {
        guard let t = target, walkPicked != QuestOpen.key(t) else { return }
        let done = !progress.isEmpty && progress.values.allSatisfy { $0.count == 2 && $0[0] >= $0[1] }
        // 知道找谁接、找谁交的：按点中的这一步；点的那样没去过就不带，别带到别处
        let g = endNpc != nil || fromNpc != nil ? walkFor(goal) : WalkNav.auto(walkGoals, accepted: t.accepted == true, ready: done)
        if g != walkGoal { walkGoal = g; walkHint = nil; updateHint() }
    }
    func setWalk(goal: WalkNav.Goal?) { walkPicked = target.map { QuestOpen.key($0) }; walkGoal = goal; walkHint = nil; onWalk?(); updateHint() }
    func setWalk(hint: NavHint?) { guard walkHint != hint else { return }; walkHint = hint; updateHint() }
    var onWalk: (() -> Void)?
    var active: Bool { walkGoal != nil || target != nil || guideOn || listOnly || stage != nil || mobFocus != nil }
    private var liveRoute: NavRoute? { mobRoute ?? (guideOn ? guide?.route : route) }
    /// 本图怪物里点了哪种：箭头先带去它的刷新点，再点一下、换图就取消
    @Published private(set) var mobFocus: String?
    private var mobRoute: NavRoute? { mobFocus.flatMap { n in mapId.flatMap { MobBook.shared.route(in: $0, mob: n) } } }
    func focus(_ mob: String) { mobFocus = mobFocus == mob ? nil : mob; updateHint() }
    /// 本图里任务要打、还没打够的怪（用户定：不列全部，没任务就不显示）；正在带路的留着
    var mobsHere: [(name: String, n: Int)] {
        (mapId.map { MobBook.shared.list(in: $0) } ?? []).filter { m in
            mobFocus == m.name || mobTask(m.name).map { !$0.done } ?? (target?.accepted == true && target?.mobs.contains(m.name) == true)
        }
    }
    /// 已接的任务要打它（或它掉的东西）：没够的 “7/8”，没读到数的 “任务”，都够了 “✓”
    func mobTask(_ mob: String) -> (text: String, done: Bool)? {
        var all = book.open.map { ($0.target, $0.progress) }
        if let t = target, t.accepted == true {
            all.removeAll { QuestOpen.key($0.0) == QuestOpen.key(t) }
            all.insert((t, progress), at: 0)
        }
        var done = false, want = false
        for (t, p) in all {
            let mine = p.filter { $0.value.count == 2 && ($0.key == mob || NavDB.shared.mob(forObjective: $0.key, target: t) == mob) }
            if let l = mine.filter({ $0.value[0] < $0.value[1] }).min(by: { ($0.key == mob ? 0 : 1, $0.key) < ($1.key == mob ? 0 : 1, $1.key) }) { return ("任务 \(l.value[0])/\(l.value[1])", false) }
            if !mine.isEmpty { done = true } else if t.mobs.contains(mob), !t.mobGuess { want = true }
        }
        return want ? ("任务", false) : done ? ("任务 ✓", true) : nil
    }
    private func updateGuide() {
        guard guideOn, let c = collect, let m = mapId else { if guide != nil { guide = nil }; return }
        if guideGoal == m { guideGoal = nil }
        let at = me.flatMap { r in r.y.map { NavPoint(x: r.x, y: $0) } }
        var s = NavDB.shared.guide(from: m, me: at, done: c.done.union(c.skipped), goal: guideGoal, skipMaps: c.skippedMaps)
        // 走动中不换来换去：原来那一项还没采就继续指它
        if guideHadPos || at == nil, let old = guide, old.goalMap == m, old.key != nil, s?.goalMap == m, let k = old.key, !c.done.contains(k), !c.skipped.contains(k), !c.skippedMaps.contains(m) { var o = old; o.left = s!.left; s = o }
        guideHadPos = at != nil
        if s != guide { guide = s; trace("guide: \(s?.title ?? "没有能走到的了")"); updateHint() }
    }
    private var me: MiniMapReading?
    /// 游戏画面大小（不含标题栏）
    private var view: CGSize?
    /// 小地图窗口的位置（窗口内的点）
    private var miniRect: CGRect?
    private var meMisses = 0
    private var posBusy = false
    @Published private(set) var mapId: Int? { didSet { if mapId != oldValue { mapSince = Date(); if mobFocus != nil { mobFocus = nil } } } }
    private var mapSince = Date()
    /// 自己在哪张图捡到过什么
    private var finds = FindLog()
    private let findsURL = dataDir.appendingPathComponent("myfinds.json")
    /// 店里卖的（去过的 NPC 商店自己记下的）：东西 → 哪张图
    private var sales: [String: [String]] = UserDefaults.standard.dictionary(forKey: "shopSales") as? [String: [String]] ?? [:]
    func shopSells(_ names: [String]) {
        guard !mapStale, let m = mapId, let key = NavDB.shared.mapKey(m), Date().timeIntervalSince(mapSince) > 3 else { return }
        var new = 0
        for n in names where !(sales[n] ?? []).contains(key) { sales[n, default: []].append(key); new += 1 }
        guard new > 0 else { return }
        UserDefaults.standard.set(sales, forKey: "shopSales")
        trace("nav: \(key) 卖 \(new) 样新东西"); update()
    }
    /// 买得到的图里走最近的
    private func saleMap(_ item: String) -> Int? {
        let ids = (sales[item] ?? []).compactMap { NavDB.shared.mapId(key: $0) }
        guard let m = mapId else { return ids.first }
        return ids.min { (NavDB.shared.route(from: m, map: $0, item: item)?.hops ?? 99) < (NavDB.shared.route(from: m, map: $1, item: item)?.hops ?? 99) }
    }
    private func foundMap(_ item: String) -> Int? { finds.best(item).flatMap { NavDB.shared.mapId(key: $0) } ?? huntMap(item) ?? saleMap(item) }
    /// 打怪记录里捡到过的图（没接任务时捡的也算）
    var huntMap: (String) -> Int? = { _ in nil }
    @Published private(set) var mapStale = false
    @Published private(set) var route: NavRoute?
    /// 坐车 / 回城卷更快时的说明
    @Published private(set) var shortcut: String?
    /// 要的东西都够了，可以交
    var ready: Bool { target.map { NavDB.shared.next(progress, target: $0) == .end } ?? false }
    private var misses = 0
    private var busy = false
    private var pending: Int?
    var onQuestChange: (() -> Void)?
    /// 一下到了不相邻的图（坐车、回城卷、NPC 送）
    var onJump: ((Int, Int) -> Void)?
    /// 预览、测试用
    func setMap(_ id: Int) { mapId = id; update() }

    var npc: Int? {
        switch goal { case .start: return target?.start; case .end: return target?.end; case .mob, .find: return nil }
    }
    /// 任务目标的进度（名字 → [已有, 要几个]），打开任务详情时更新
    @Published private(set) var progress: [String: [Int]] = UserDefaults.standard.dictionary(forKey: "navProgress") as? [String: [Int]] ?? [:]
    init() {
        if let d = try? Data(contentsOf: findsURL), let f = try? JSONDecoder().decode(FindLog.self, from: d) { finds = f }
        // 以前存下的任务没有怪：任务原文写了谁掉的就补上
        if var t = target, t.mobs.isEmpty, let q = t.questId {
            let told = NavDB.shared.itemMobs(q)
            t.mobs = (NavDB.shared.quest(q)?.items ?? []).compactMap { told[$0.name] ?? NavDB.shared.describedMob($0.name) }
            if !t.mobs.isEmpty { t.mobGuess = true; target = t }
        }
        goal = Self.firstGoal(target); applyProgress(); updateHint()
    }

    /// 看到新的进度：打够了自动换下一个目标。进度没变就不动（不跟用户手动点的抢）
    /// sure：任务详情（不透明，读得准）；追踪框的要核对过才用
    private var progressGuard = ProgressGuard()
    func setProgress(_ objectives: [(name: String, count: String)], sure: Bool = true) {
        guard let t = target else { return }
        var read = NavDB.shared.progress(objectives, target: t)
        if !sure { read = progressGuard.accept(read, now: progress) }
        // 追踪框里某样东西的数量在这张图涨了：记下这里捡到过
        if !sure, !mapStale, let m = mapId, let key = NavDB.shared.mapKey(m) {
            let items = Set(t.questId.flatMap { NavDB.shared.quest($0) }?.items.map(\.name) ?? [])
            var learned = false
            for (k, v) in read where items.contains(k) {
                guard let n = FindLog.gained(old: progress[k], new: v, secondsInMap: Date().timeIntervalSince(mapSince)) else { continue }
                finds.add(k, map: key, n: n); learned = true
                trace("nav: 捡到 \(k) ×\(n) 在 \(key)")
            }
            if learned, let d = try? JSONEncoder().encode(finds) {
                try? FileManager.default.createDirectory(at: findsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? d.write(to: findsURL, options: .atomic)
                update()
            }
        }
        var old = progress
        if t.questId == nil { let u = QuestHelper.unify(read, with: progress); read = u.read; for k in u.drop { old[k] = nil } }
        let new = old.merging(read) { _, b in b }
        if !new.isEmpty, t.accepted == nil { var x = t; x.accepted = true; x.notStarted = false; setTarget(x) }
        guard new != progress else { return }
        progress = new
        UserDefaults.standard.set(new, forKey: "navProgress")
        applyProgress()
        updateHint()
        if let t = target, t.accepted == true { note(t, new) }
        trace("nav: 进度 \(new) → \(goal)")
    }
    private func applyProgress() {
        guard let t = target, !t.notStarted else { return }
        switch NavDB.shared.next(progress, target: t) {
        case .mob(let m): goal = .mob(m)
        case .end: if t.end != nil || t.questId == nil { goal = .end }
        case .keep:
            // 现在这种怪的已经够了，剩下的不知道哪里出：别再指着已经打完的怪
            // 东西没齐也别指着去交
            var stuck = goal == .end || goal == .start && t.accepted == true
            if case .mob(let m) = goal { stuck = mobDone(m) }
            if case .find(let n) = goal, tipMob(n) == n ? tipLeft(n) == nil : progress[n].map({ $0[0] >= $0[1] }) ?? false { stuck = true }
            // 东西换成打哪种怪（按钮是怪）
            if case .find(let n) = goal, let m = tipMob(n), m != n { goal = .find(m) }
            if stuck, let n = progress.filter({ $0.value[0] < $0.value[1] }).keys.sorted().first { goal = .find(tipMob(n) ?? n) }
        }
    }
    /// 按钮上的进度：“ 75/75”
    func progressText(_ mob: String) -> String {
        // 打它本身的数在前（0/50），没有才看它掉的东西（0/30）
        let ns = (progress[mob].map { [$0] } ?? []) + counts(mob)
        if mobDone(mob) { return " ✓" }
        return ns.first { $0[0] < $0[1] }.map { " \($0[0])/\($0[1])" } ?? ""
    }
    /// 和这种怪有关的目标（打它本身，或它掉的东西）的进度
    private func counts(_ mob: String) -> [[Int]] {
        guard let t = target else { return [] }
        return progress.filter { $0.key == mob || NavDB.shared.mob(forObjective: $0.key, target: t) == mob }.map(\.value)
    }
    func mobDone(_ mob: String) -> Bool { let c = counts(mob); return !c.isEmpty && c.allSatisfy { $0[0] >= $0[1] } }
    enum State { case todo, doing, done
        var color: Color { switch self { case .todo: return .mSub; case .doing: return Color(nsColor: Maple.warn); case .done: return Color(nsColor: Maple.done) } }
    }
    /// 这样东西是去买的
    func bought(_ n: String) -> Bool { finds.best(n) == nil && huntMap(n) == nil && sales[n] != nil }
    var startState: State { target?.accepted == true ? .done : target?.notStarted == true ? .doing : .todo }
    func mobState(_ m: String) -> State { mobDone(m) ? .done : target?.accepted == true ? .doing : .todo }
    /// 一样东西：没有进度或 0 个 = 没开始
    func itemState(_ n: String) -> State { progress[n].map { $0[0] >= $0[1] ? .done : $0[0] > 0 ? .doing : .todo } ?? .todo }
    func countText(_ n: String) -> String { progress[n].map { " \($0[0])/\($0[1])" } ?? "" }
    /// 还没够、又没有哪里出的资料的东西
    var unknownItems: [String] {
        guard let t = target else { return [] }
        return progress.filter { $0.value[0] < $0.value[1] && NavDB.shared.mob(forObjective: $0.key, target: t) == nil }.keys.sorted()
    }
    /// 现在要找的东西从哪来（按资料表；自己捡到过的不用）
    var sourceNote: String? {
        guard case .find(let n) = goal, foundMap(n) == nil else { return nil }
        return NavDB.shared.sourceText(n)
    }
    func useUp(_ n: String) -> Bool { target.map { NavDB.shared.useUp(n, target: $0) } ?? false }
    /// 目标的名字：资料里没有的任务用屏幕上认到、系统翻译的
    func name(_ n: String) -> String { target?.zh?[n] ?? (target?.questId == nil ? QuestTips.mobZh(n) : nil) ?? (NavDB.shared.hasMob(n) ? NavDB.shared.mobName(n) : NavDB.shared.itemName(n)) }
    /// 资料里没有的任务：怎么做（经验）
    var tip: String? { target.flatMap { $0.questId == nil ? QuestTips.note(text: $0.en ?? "", items: progress.keys.sorted()) : nil } }
    private var tipItems: [String] { progress.keys.sorted() }
    /// 找谁接、找谁交（经验里有的，或刚和谁说完话接的）
    var fromText: String? { target.flatMap { t in QuestTips.from(text: t.en ?? "", items: tipItems) ?? t.giver.map { g in g + (walkNpc?(g).map { "（\($0)）" } ?? "") } } }
    var walkHere: (() -> String?)?
    /// 走过的图（按名字）→ 可以带去
    var walkMap: ((String) -> WalkNav.Goal?)?
    var tipTitle: String? { target.flatMap { $0.questId == nil ? QuestTips.title(text: $0.en ?? "", items: tipItems) : nil } }
    /// 没有资料表：这一样要打谁
    func tipMob(_ n: String) -> String? { target?.questId == nil && NavDB.shared.maps.isEmpty ? QuestTips.mob(n) : nil }
    /// 没有资料表、知道交给谁：点哪个按钮，下面只写哪个（用户定，别混在一起）
    var stepwise: Bool { target?.questId == nil && NavDB.shared.maps.isEmpty && endNpc != nil }
    var stepLines: [(String, State)] {
        guard let t = target else { return [] }
        func line(_ n: String, _ verb: String) -> (String, State) { (verb + " " + name(n) + countText(n) + (itemState(n) == .done ? " ✓" : ""), itemState(n)) }
        switch goal {
        case .start: return [(t.accepted == true ? "已经接了 ✓" : "找 \(fromText ?? "") 接任务", t.accepted == true ? .done : .doing)]
        case .find(let g):
            if tipMob(g) == nil { return [line(g, "收集")] }
            let drops = progress.keys.sorted().filter { $0 != g && tipMob($0) == g }
            return (progress[g] != nil ? [line(g, "打")] : []) + drops.map { line($0, "收集") }
        default:
            let left = tipMobs.map { "打 " + name($0) + tipCount($0) } + unknownItems.filter { tipMob($0) == nil }.map { "找 " + name($0) + countText($0) }
            return [left.isEmpty ? ("东西齐了，可以交了 ✓", .done) : ("还不能交，先去" + left.joined(separator: "、"), .todo)]
        }
    }
    var stepTip: String? {
        let k: String
        switch goal { case .start: k = "start"; case .find(let n): k = n; default: k = "end" }
        return QuestTips.part(k, text: target?.en ?? "", items: tipItems)
    }
    /// 这个任务要打的怪，打够的也在
    var tipAll: [String] { Array(Set(progress.keys.compactMap { tipMob($0) })).sorted() }
    /// 还要打的怪（打它本身、它掉的东西合成一个）
    var tipMobs: [String] { Array(Set(unknownItems.compactMap { tipMob($0) })).sorted() }
    private func tipLeft(_ m: String) -> [Int]? { (progress[m].map { [$0] } ?? []).first { $0[0] < $0[1] } ?? progress.filter { tipMob($0.key) == m && $0.value[0] < $0.value[1] }.sorted { $0.key < $1.key }.first?.value }
    func tipCount(_ m: String) -> String { tipLeft(m).map { " \($0[0])/\($0[1])" } ?? "" }
    var fromNpc: String? { fromText?.components(separatedBy: "（")[0] }
    var endNpc: String? { target.flatMap { QuestTips.npc(text: $0.en ?? "", items: tipItems) ?? $0.giver } }
    private var endTown: String? { endNpc.flatMap { n in walkNpc?(n) ?? target.flatMap { QuestTips.town(text: $0.en ?? "", items: tipItems) } } }
    var endText: String? { endNpc.map { n in n + (endTown.map { "（\($0)）" } ?? "") } }
    func pick(_ g: Goal) {
        goal = g
        if NavDB.shared.maps.isEmpty { walkPicked = nil; onWalk?() }
    }
    /// 点中的这一步要去哪张图
    var tipDest: String? {
        guard NavDB.shared.maps.isEmpty, target != nil else { return nil }
        func at(_ who: String, _ p: String) -> String? {
            let h = walkHops?(p)
            return h == 0 ? nil : "目的地：\(who) 在「\(p)」" + (h.map { "，走路 \($0) 张图" } ?? (QuestTips.way(p).last.map { "，从 \($0) 进" + (QuestTips.hiddenDoor(p) ? "（隐藏门）" : "") } ?? "，还没走过"))
        }
        switch goal {
        case .start:
            guard let t = fromText, let n = fromNpc, let i = t.firstIndex(of: "（") else { return nil }
            return at(n, String(t[t.index(after: i)...].dropLast()))
        case .find(let n):
            let l = seenPlaces?(n) ?? []
            return (l.first { walkHops?($0) != nil } ?? l.first).flatMap { at(name(n), $0) }
        case .end: return endNpc.flatMap { n in endTown.flatMap { at(n, $0) } }
        default: return nil
        }
    }
    /// 点中的这一步，箭头带去哪
    private func walkFor(_ g: Goal) -> WalkNav.Goal? {
        switch g {
        case .start: fromNpc.flatMap { n in walkGoals.first { $0.label.hasPrefix("找 \(n)（") } }
        case .find(let n): walkGoals.first { $0.label.hasPrefix("捡 \(n)（") } ?? (seenPlaces?(n) ?? []).lazy.compactMap { self.walkMap?($0) }.first
        case .end: endNpc.flatMap { n in walkGoals.first { $0.label.hasPrefix("找 \(n)（") } ?? endTown.flatMap { walkMap?($0) } }
        default: nil
        }
    }
    /// 没有资料表：东西捡到过的图、NPC 在哪张图、走过的图要走几张
    var walkNpc: ((String) -> String?)?
    var walkHops: ((String) -> Int?)?
    /// 还差什么、没资料
    var missing: String? {
        // 没有资料时，差几个上面按钮、步骤里都写了，不再说一遍
        if NavDB.shared.maps.isEmpty { return nil }
        guard case .find(let n) = goal, foundMap(n) == nil, route == nil else { return nil }
        // 有资料、只是没路线（要 NPC 送、或还没认出地图）
        if let s = NavDB.shared.sourceText(n) { return "还差 \(name(n))，" + s }
        return "还差 \(name(n))" + (progress[n].map { " \($0[0])/\($0[1])" } ?? "") + "，这样东西还没有资料"
    }
    /// 还没接 → 去接；要打怪 → 先去打怪；否则去交
    private static func firstGoal(_ t: NavTarget?) -> Goal {
        if t?.notStarted == true, t?.start != nil || t?.questId == nil { return .start }
        if let m = t?.mobs.first { return .mob(m) }
        return .end
    }

    func setTarget(_ t: NavTarget?) {
        guard t != target else { return }
        // 同一个任务、只是这次识别略有出入：进度和手动选的目标留着
        // 已经接了的不会变回没接（这次没看到进度而已）
        var t = t
        // accepted == false：在“可接”页看到的（放弃了又能接），以它为准
        if t != nil, t?.title == target?.title, target?.accepted == true, t?.accepted == nil { t?.accepted = true; t?.notStarted = false }
        guard t != target else { return }
        let same = t != nil && t?.title == target?.title && t?.notStarted == target?.notStarted && t?.mobs == target?.mobs
        if t != nil, closed { closed = false; UserDefaults.standard.set(false, forKey: "navClosed") }
        target = t
        UserDefaults.standard.set(t.flatMap { try? JSONEncoder().encode($0) }, forKey: "navTarget")
        if !same {
            progress = [:]; progressGuard = ProgressGuard(); UserDefaults.standard.removeObject(forKey: "navProgress")
            goal = Self.firstGoal(t)
            // 换回以前接着的：进度还在
            if let t, t.accepted == true, let o = book[QuestOpen.key(t)], !o.progress.isEmpty { progress = o.progress; UserDefaults.standard.set(progress, forKey: "navProgress"); applyProgress() }
            // 聊天框里说过得到的东西（NPC 给的信）直接算上
            if let t, t.accepted == true, progress.isEmpty {
                let have = (t.questId.flatMap { NavDB.shared.quest($0) }?.items ?? []).compactMap { i in i.count > 0 ? given[i.name].map { (name: i.name, count: "\(min($0, i.count))/\(i.count)") } : nil }
                if !have.isEmpty { progress = NavDB.shared.progress(have, target: t); applyProgress() }
            }
        }
        if let t { if t.accepted == true { note(t, progress) } else if t.accepted == false { drop(QuestOpen.key(t)) } }
        update()
        trace("nav: 目标 \(t.map { "\($0.title) \($0.questId ?? 0)" } ?? "无")")
        onQuestChange?()
    }
    private func update() {
        var r: NavRoute?
        if let m = mapId {
            if case .mob(let n) = goal { r = NavDB.shared.route(from: m, mob: n) }
            else if case .find(let n) = goal { r = foundMap(n).flatMap { NavDB.shared.route(from: m, map: $0, item: n) } ?? NavDB.shared.sourceRoute(from: m, item: n) }
            else if let n = npc { r = NavDB.shared.route(from: m, npc: n) }
        }
        if r != route { route = r }
        var mob: String?
        if case .mob(let n) = goal { mob = n }
        updateGuide()
        let s = mapId.flatMap { NavDB.shared.shortcut(from: $0, npc: npc, mob: mob, walk: r) }
        if s != shortcut { shortcut = s }
        updateHint()
    }
    /// 到了打怪的图：后面写上还差多少
    private func withRemaining(_ h: NavHint) -> NavHint {
        guard route?.kind == .mob, let left = progress.filter({ $0.value[0] < $0.value[1] }).sorted(by: { $0.key < $1.key }).first else { return h }
        let name = NavDB.shared.hasMob(left.key) ? NavDB.shared.mobName(left.key) : NavDB.shared.itemName(left.key)
        return NavHint(dir: h.dir, text: h.text + "（\(h.text.hasSuffix(name) ? "" : name + " ")\(left.value[0])/\(left.value[1])）")
    }
    private func updateHint() {
        var h: NavHint?
        // 有任务就一定显示点什么：认不出地图、没路线也要说清楚原因
        if let r = mobRoute, let m = mapId.flatMap({ NavDB.shared.maps[$0] }), !mapStale {
            h = NavHint.make(r, me: me, map: m, view: view)
        } else if guideOn {
            if let m = mapId.flatMap({ NavDB.shared.maps[$0] }), !mapStale {
                h = guide.map { NavHint.make($0.route, me: me, map: m, view: view) } ?? NavHint(dir: .none, text: "走得到的都采好了")
            } else { h = NavHint(dir: .none, text: ocrNotice ?? "没认出当前地图，正在重试") }
        } else if walkGoal != nil, NavDB.shared.maps.isEmpty {
            h = walkHint ?? NavHint(dir: .none, text: "走过的门还连不到那里")
        } else if stepwise {
            // 没走过的地方也要有一句，不然像坏了
            switch goal {
            case .find(let n):
                let p = seenPlaces?(n).first
                h = NavHint(dir: .none, text: p.map { "\(name(n)) 在 \($0)，这张图还没走过" } ?? "还不知道 \(name(n)) 在哪")
            case .start: h = target?.accepted == true ? nil : fromText.map { NavHint(dir: .none, text: "找 \($0)，还没见过") }
            default: h = endText.map { NavHint(dir: .none, text: "找 \($0)，还没见过") }
            }
        } else if target != nil, !NavDB.shared.maps.isEmpty {      // 没有地图资料（公开版）：只在面板上写怎么做，不显示箭头条
            if case .find(let n) = goal, useUp(n) { h = NavHint(dir: .none, text: "打开背包（I）→ Use，双击 \(name(n))") }
            else if let n = waitLevel { h = NavHint(dir: .none, text: "先升到 \(n) 级，再找 \(npc.map { NavDB.shared.npcName($0) } ?? "NPC")（现在 \(myLevel() ?? 0) 级）") }
            else if let s = missing { h = NavHint(dir: .none, text: s) }
            else if let m = mapId.flatMap({ NavDB.shared.maps[$0] }), !mapStale {
                h = route.map { withRemaining(NavHint.make($0, me: me, map: m, view: view)) } ?? NavHint(dir: .none, text: "没有去那里的路线资料")
            } else { h = NavHint(dir: .none, text: ocrNotice ?? "没认出当前地图，正在重试") }
        }
        if h != hint { hint = h; trace("nav: 箭头 \(h.map { "\($0.dir) \($0.text)" } ?? "无")，自己 \(me.map { "\(Int($0.x)),\($0.y.map { String(Int($0)) } ?? "?")" } ?? "没认出")") }
    }

    /// 每 0.4 秒：看小地图上的黄点（不识别文字）
    func positionTick(locator: GameWindowLocator, g: GameWindowInfo) async {
        view = CGSize(width: g.frameTopLeft.width, height: g.frameTopLeft.height - 28)
        guard active, !posBusy, let m = mapId.flatMap({ NavDB.shared.maps[$0] }), liveRoute?.next.isEmpty == false || NavDB.shared.unplaced(m.id) else { return }
        posBusy = true; defer { posBusy = false }
        // 室内没有小地图：图不比窗口宽时画面居中不动，认自己脚下的名牌就知道站在哪
        if m.mini.isEmpty {
            let win = g.frameTopLeft.size, name = playerName()
            guard let client, !name.isEmpty, m.box[2] - m.box[0] <= win.width + 2, Date().timeIntervalSince(nameTry) > (tag == nil ? 0.9 : 0.35) else { return }
            if tagName != name { tagName = name; tagTwice = nil; tag = UserDefaults.standard.data(forKey: "nameTag@\(name)").flatMap { try? JSONDecoder().decode(TagShape.self, from: $0) } }
            nameTry = Date()
            let w = min(win.width, m.box[2] - m.box[0]), r = CGRect(x: ((win.width - w) / 2).rounded(), y: 100, width: w.rounded(), height: win.height - 265)
            guard r.height > 100, let img = await withTimeout(2, { await locator.capture(g, rect: r, outputScale: 2) }) else { return }
            // 先按字形表拼出名字找，连聊天框后面变灰的也找（状态栏里也有名字，截到聊天框底下为止）
            let low = CGRect(x: r.minX, y: r.minY, width: r.width, height: win.height - 100 - 66)
            if let t = TagShape.make(name), let big = await withTimeout(2, { await locator.capture(g, rect: low, outputScale: 2) }),
               let f = await Task.detached(operation: { t.find(big, scale: 2) }).value {
                guard mapId == m.id else { return }
                me = MiniMapReading(x: m.box[0] + f * (m.box[2] - m.box[0]), y: nil); meMisses = 0; updateHint(); return
            }
            // 名牌的笔画每次都一样：认准过就照图案找，不认字
            if let t = tag, let f = await Task.detached(operation: { t.find(img, scale: 2) }).value {
                guard mapId == m.id else { return }
                me = MiniMapReading(x: m.box[0] + f * (m.box[2] - m.box[0]), y: nil); meMisses = 0; updateHint(); return
            }
            if tag != nil, Date().timeIntervalSince(nameOCR) < 2 { meMisses += 1; if meMisses > 25 { me = nil; updateHint() }; return }
            nameOCR = Date()
            guard let lines = await withTimeout(3, { client.recognize(img) }), mapId == m.id else { return }
            // 整行正好就是自己的名字：记下笔画，连着两次一样才用
            if let l = lines.first(where: { $0.text.trimmingCharacters(in: .whitespaces) == name }),
               let t = TagShape.learn(img, box: CGRect(x: l.minX, y: l.minY, width: l.maxX - l.minX, height: l.maxY - l.minY), scale: 2) {
                if t == tagTwice, t != tag { tag = t; if let d = try? JSONEncoder().encode(t) { UserDefaults.standard.set(d, forKey: "nameTag@\(name)") }; trace("nav: 记住名牌 \(name) \(t.w)x\(t.h) \(t.on.count) 点") }
                tagTwice = t
            }
            if let f = NameTag.find(lines, name: name) {
                me = MiniMapReading(x: m.box[0] + f * (m.box[2] - m.box[0]), y: nil); meMisses = 0
            } else { meMisses += 1; if meMisses < 10 { return }; me = nil }
            updateHint()
            return
        }
        let b = miniRect ?? CGRect(x: 0, y: 28, width: 300, height: 290)
        let r = CGRect(x: b.minX - 4, y: b.minY - 2, width: b.width + 8, height: 300).intersection(CGRect(origin: .zero, size: g.frameTopLeft.size))
        guard let img = await withTimeout(2, { await locator.capture(g, rect: r, outputScale: 2) }) else { return }
        let v = await Task.detached { MiniMap.read(img, scale: 2, map: m) }.value
        // 调试：CT_DEBUG_DUMP 时存下没认出位置的小地图
        if v == nil, let dir = ProcessInfo.processInfo.environment["CT_DEBUG_DUMP"],
           let d = CGImageDestinationCreateWithURL(URL(fileURLWithPath: dir + "/nav-miss.png") as CFURL, "public.png" as CFString, 1, nil) {
            CGImageDestinationAddImage(d, img, nil); CGImageDestinationFinalize(d); trace("nav: 没算出位置 \(m.name) \(MiniMap.canvas(in: img, scale: 2).map { "\($0)" } ?? "没找到画面")")
        }
        guard mapId == m.id else { return }
        if let v {
            me = v; meMisses = 0; watchOffer(v, m); watchDoors(v, m)
            if guideOn, !guideHadPos, v.y != nil { updateGuide() }
        } else {
            // 黄点偶尔被别的点盖住：先沿用刚才的，连续 5 次（2 秒）都没有才算认不出
            meMisses += 1
            if meMisses < 5 { return }
            me = nil
        }
        updateHint()
    }

    /// 识别还没准备好 / 卡住了：认不出地图时写这个原因
    @Published private(set) var ocrNotice: String?
    private func setNotice(_ s: String?) {
        guard s != ocrNotice else { return }
        ocrNotice = s
        updateHint()
    }
    private var helperBusy = false
    private var helperLog = ""
    /// 用户点 × 结束导航后，不自动从追踪里再选上（打开任务详情才重新开始）
    private var closed = UserDefaults.standard.bool(forKey: "navClosed")
    func close() { closed = true; UserDefaults.standard.set(true, forKey: "navClosed"); if target == nil { objectWillChange.send(); onQuestChange?() }; setTarget(nil) }

    private var helperStep: Int?
    /// 每 3 秒：看右上角的 Quest Helper，更新进度；没在导航时自动导航第一个追踪的任务
    func helperTick(locator: GameWindowLocator, g: GameWindowInfo, client: OCRClient) async {
        loadBook()
        guard !helperBusy, target != nil || !closed else { return }
        helperBusy = true; defer { helperBusy = false }
        let win = g.frameTopLeft.size
        let r = CGRect(x: win.width - 240, y: 28, width: 240, height: 250).intersection(CGRect(origin: .zero, size: win))
        guard let img = await withTimeout(2, { await locator.capture(g, rect: r, outputScale: 2) }),
              let raw = await withTimeout(3, { client.recognize(img) }) else { return }
        guard var items = QuestHelper.parse(raw) else { return }
        // 背包压在这块上时，它的页签会被当成任务
        items.removeAll { $0.objectives.isEmpty && ["equip", "use", "setup", "etc", "cash", "deco"].contains($0.title.lowercased().filter(\.isLetter)) }
        if items.allSatisfy({ $0.objectives.isEmpty }),
           let b = await withTimeout(3, { client.recognize(QuestHelper.boost(img)) }), let again = QuestHelper.parse(b), !again.isEmpty { items = again }
        let log = items.map { "\($0.title): " + $0.objectives.map { "\($0.name) \($0.count)" }.joined(separator: ", ") }.joined(separator: " | ")
        if log != helperLog { helperLog = log; trace("nav: 追踪 \(log)") }
        onCounts?(items.flatMap { $0.objectives.compactMap { o in Int(o.count.split(separator: "/").first ?? "").map { (o.name, $0) } } })
        // 系列任务做到下一步了（这一步不在追踪里、下一步在）：跟着换，不用再打开任务详情。连着看到两次才换
        let step = QuestHelper.nextStep(items, target: target)
        if let step, step.0.questId == helperStep { let was = target.map { QuestOpen.key($0) }; setTarget(step.0); if let was { drop(was) } }
        helperStep = step?.0.questId
        // 追踪里的都是接了的：记进清单（现在导航的由下面处理）
        for it in items where !it.objectives.isEmpty && !NavDB.shared.hasQuests {
            guard let o = book.match(it) else { continue }
            if let t = target, QuestOpen.key(t) == o.key { setProgress(it.objectives, sure: false) }
            else { note(o.target, bookGuards[o.key, default: ProgressGuard()].accept(NavDB.shared.progress(it.objectives, target: o.target), now: o.progress)) }
        }
        for it in items where !it.objectives.isEmpty {
            guard var t = NavDB.shared.target(title: it.title, paragraphs: [it.title], summary: ""), t.questId != nil, target.map({ QuestOpen.key($0) }) != QuestOpen.key(t) else { continue }
            let k = QuestOpen.key(t)
            if let o = book[k] { t = o.target } else { t.accepted = true; t.notStarted = false }
            note(t, bookGuards[k, default: ProgressGuard()].accept(NavDB.shared.progress(it.objectives, target: t), now: book[k]?.progress ?? [:]))
        }
        guard let (t, it) = QuestHelper.pick(items, target: target) else { return }
        if target == nil { setTarget(t) }
        // 追踪里有的就是已经接了的
        if var x = target, x.notStarted || x.accepted != true { x.notStarted = false; x.accepted = true; setTarget(x) }
        if let t = target, book[QuestOpen.key(t)] == nil { note(t, progress) }
        setProgress(it.objectives, sure: false)
    }

    /// 资料里没位置的门：把走动时看到的蓝圈攒起来对号；同样的结果连着 3 次才用
    private var doorMap = 0, doorSeen: [NavPoint] = [], doorHits = 0, doorLast: [Int: NavPoint]?
    private func watchDoors(_ v: MiniMapReading, _ m: NavMap) {
        if doorMap != m.id { doorMap = m.id; doorSeen = []; doorHits = 0; doorLast = nil }
        guard NavDB.shared.unplaced(m.id) else { return }
        for d in v.doors where !doorSeen.contains(where: { abs($0.x - d.x) < 60 && abs($0.y - d.y) < 80 }) { doorSeen.append(d) }
        let r = NavDB.shared.placeDoors(m.id, rings: doorSeen)
        doorHits = r != nil && r == doorLast ? doorHits + 1 : 0
        doorLast = r
        guard let r, doorHits >= 2 else { return }
        NavDB.shared.setDoors(m.id, r)
        trace("nav: 从小地图对出门 \(r.map { "\(NavDB.shared.mapName($0.key)) \(Int($0.value.x)),\(Int($0.value.y))" })")
        update()
    }

    /// 最近一次看到 NPC 对话框
    var talkedAt = Date.distantPast
    private var offerSeen: Int?, offerGone = 0
    /// 给任务的 NPC 头上的“!”：说完话没了就是接了
    private func watchOffer(_ v: MiniMapReading, _ m: NavMap) {
        guard let t = target, t.accepted != true, let s = t.start,
              let at = m.npcs.first(where: { $0.first.map(Int.init) == s }), at.count >= 3 else { offerSeen = nil; offerGone = 0; return }
        func near(_ p: NavPoint) -> Bool { abs(p.x - at[1]) < 70 && abs(p.y - at[2]) < 90 }
        if v.offers.contains(where: near) { offerSeen = t.questId ?? s; offerGone = 0; return }
        // 绿点看得到、没有“!”，连着 3 次
        guard v.npcs.contains(where: near), offerSeen == t.questId ?? s, Date().timeIntervalSince(talkedAt) < 60 else { return }
        offerGone += 1
        guard offerGone >= 3 else { return }
        offerSeen = nil; offerGone = 0
        trace("nav: 接了 \(t.title)（“!”没了）")
        var x = t; x.accepted = true; x.notStarted = false; setTarget(x)
    }

    /// 聊天框说得到的东西
    private var given: [String: Int] = [:]
    func chatItem(_ raw: String) {
        if let l = HuntLog.lost(raw) { given[l.name] = nil; return }
        let fixed = HuntLog.fixItemLine(raw)
        guard fixed.range(of: "[xX×][0-9]+\\s+ea[a-z]{1,3}ed", options: .regularExpression) != nil, let (name, n) = HuntLog.item(fixed) else { return }
        given[name, default: 0] += n
        if let t = target, t.accepted == true, let i = t.questId.flatMap({ NavDB.shared.quest($0) })?.items.first(where: { $0.name == name }), i.count > 0, progress[name] == nil {
            setProgress([(name: name, count: "\(min(given[name]!, i.count))/\(i.count)")])
        }
    }

    private func npcHere(_ id: Int?) -> Bool {
        guard let id, let m = mapId else { return false }
        return NavDB.shared.maps[m]?.npcs.contains { $0.first.map(Int.init) == id } == true
    }
    /// 交出的正好是某个已接任务要的东西（数量够），人在要交的 NPC 那张图：那个任务做完了
    private func handedIn(_ raw: String) -> String? {
        guard let l = HuntLog.lost(raw) else { return nil }
        var all = book.open.map(\.target)
        if let t = target, t.accepted == true, !all.contains(where: { QuestOpen.key($0) == QuestOpen.key(t) }) { all.insert(t, at: 0) }
        let fit = all.filter { t in npcHere(t.end) && (t.questId.flatMap { NavDB.shared.quest($0) }?.items ?? []).contains { $0.count > 0 && (l.n == 0 || l.n >= $0.count) && Fuzzy.similar($0.name, l.name, tolerance: 0.15) } }
        // 两个任务都对得上：现在导航的优先，否则不猜
        if let t = target, fit.contains(where: { QuestOpen.key($0) == QuestOpen.key(t) }) { return QuestOpen.key(t) }
        return fit.count == 1 ? QuestOpen.key(fit[0]) : nil
    }
    /// 聊天框出现交任务的提示（得到经验、交出物品），人就在要交的 NPC 那张图、刚说过话：这个任务做完了
    func questLine(_ raw: String) {
        if let k = handedIn(raw) { finish(k); return }
        guard let t = target, t.accepted == true, goal == .end, npcHere(t.end),
              raw.range(of: "^You (have )?(received|gained) (EXP|experience) ?\\(", options: [.regularExpression, .caseInsensitive]) != nil else { return }
        finish(QuestOpen.key(t))
    }
    /// 程序没开着时交的：刚启动看到的旧聊天里有“交出”、后面没有再得到，等认出地图再核对
    private var oldLines: [String] = []
    func startLines(_ raws: [String]) {
        oldLines = raws.enumerated().filter { i, r in
            guard let l = HuntLog.lost(r) else { return false }
            return !raws[(i + 1)...].contains { HuntLog.lost($0) == nil && HuntLog.item(HuntLog.fixItemLine($0))?.name == l.name }
        }.map(\.element)
        checkOld()
    }
    private func checkOld() {
        guard mapId != nil, !oldLines.isEmpty else { return }
        let l = oldLines; oldLines = []
        for r in l { if let k = handedIn(r) { finish(k) } }
    }

    /// 正在做问答任务：已接的任务名里有 Quiz 之类的字，要交的 NPC 就在这张图
    var quizzing: Bool {
        let all = book.open.map(\.target) + (target.map { [$0] } ?? [])
        return all.contains { t in
            npcHere(t.end) && (t.title + " " + (t.questId.flatMap { QuestDB.shared.name($0) } ?? "")).range(of: "quiz|exam|riddle|question|问答|考|测验|谜", options: [.regularExpression, .caseInsensitive]) != nil
        }
    }

    // MARK: 顺路一起做

    /// 已接的任务（每个角色一份 quests.json）
    @Published private(set) var book = QuestBook()
    @Published private(set) var plan: [QuestStop] = []
    private var bookName: String?, bookGuards: [String: ProgressGuard] = [:]
    private var planBusy = false, planAgain = false
    /// 只剩清单、没有正在导航的任务时也显示卡片
    var listOnly: Bool { target == nil && !closed && !book.open.isEmpty && !NavDB.shared.maps.isEmpty }
    private func bookURL(_ n: String) -> URL { dataDir.appendingPathComponent("角色/\(n)/quests.json") }
    /// 认出角色、换角色：换成那个角色的清单
    private func loadBook() {
        let n = playerName()
        guard !n.isEmpty, n != bookName else { return }
        let old = bookName, mine = old == nil ? book.open : []
        bookName = n; bookGuards = [:]
        // 换了角色：上一个角色的任务不跟过来（还在它自己的清单里）
        if old != nil, target != nil { setTarget(nil) }
        var b = (try? Data(contentsOf: bookURL(n))).flatMap { try? JSONDecoder().decode(QuestBook.self, from: $0) } ?? QuestBook()
        for o in mine { b.put(o.target, progress: o.progress) }
        b.prune(); b.clean(); book = b; if target == nil || target?.questId == nil { saveBook() }
        if target != nil, target?.questId == nil { let u = QuestHelper.unify(progress.filter { QuestHelper.plausible($0.key) }, with: [:]); progress = u.read.filter { !u.drop.contains($0.key) }; applyProgress() }
        planUpdate(); onQuestChange?()
    }
    private func saveBook() {
        guard let n = bookName, let d = try? JSONEncoder().encode(book) else { return }
        let u = bookURL(n)
        try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? d.write(to: u, options: .atomic)
    }
    var lastTalk: (() -> String?)?
    /// 这样东西在哪捡到过：自己的、朋友传的在前，再是自带的经验
    var seenPlaces: ((String) -> [String])?
    private func note(_ t: NavTarget, _ p: [String: [Int]]) {
        let k = QuestOpen.key(t)
        var t = t
        if t.questId == nil {
            t.giver = QuestTips.npc(text: t.en ?? "", items: p.keys.sorted()) ?? t.giver ?? book[k]?.target.giver
            // 刚和 NPC 说完话就多了这个任务：是他给的
            if book[k] == nil, t.giver == nil, !NavDB.shared.hasQuests, let n = lastTalk?(), t.accepted == true { t.giver = n; trace("nav: \(t.title) 是 \(n) 给的") }
            if target?.title == t.title, target?.giver != t.giver { target?.giver = t.giver }
        }
        // 没变化的一小时才记一次时间，别一直写盘
        if let o = book[k], o.target == t, o.progress.merging(p, uniquingKeysWith: { _, b in b }) == o.progress, Date().timeIntervalSince(o.seen) < 3600 { return }
        book.put(t, progress: p)
        saveBook(); planUpdate()
    }
    /// 不再做了：交掉、放弃、或用户点 ✕
    func drop(_ key: String) {
        guard book[key] != nil else { return }
        book.remove(key); bookGuards[key] = nil
        saveBook(); planUpdate(); onQuestChange?()
    }
    func finish(_ key: String) {
        trace("nav: 交完了 \(book[key]?.target.title ?? key)")
        if let t = target, QuestOpen.key(t) == key { setTarget(nil) }
        drop(key)
    }
    /// “已完成”页看到的
    func completed(_ t: NavTarget) { if t.questId != nil { finish(QuestOpen.key(t)) } }
    /// 点清单里的一项：换成导航它
    func choose(_ key: String, _ kind: QuestJob.Kind) {
        guard let o = book[key] else { return }
        setTarget(o.target)
        switch kind { case .mob(let m): goal = .mob(m); case .item(let n), .use(let n): goal = .find(n); case .npc, .level: goal = .end }
    }
    /// 找路不算快：放后台算，算着的时候又变了就再算一次
    private func planUpdate() {
        guard !planBusy else { planAgain = true; return }
        let open = book.open, m = mapId
        guard !open.isEmpty, !NavDB.shared.maps.isEmpty else { if !plan.isEmpty { plan = [] }; return }
        var found: [String: Int] = [:]
        for o in open { for i in o.target.questId.flatMap({ NavDB.shared.quest($0) })?.items ?? [] { found[i.name] = foundMap(i.name) } }
        let known = found, lv = myLevel()
        planBusy = true
        Task {
            let p = await Task.detached(priority: .utility) { QuestPlan.make(open, from: m, found: known, level: lv) }.value
            planBusy = false
            if p != plan { plan = p; onQuestChange?() }
            if planAgain { planAgain = false; planUpdate() }
        }
    }

    /// 每 2 秒：截左上角小地图标题那一小块识别（没在导航就不截）
    func tick(locator: GameWindowLocator, g: GameWindowInfo, client: OCRClient) async {
        // 没任务时也隔 8 秒看一眼在哪（组队任务进了关要自动出提示）
        if !active { guard Date().timeIntervalSince(idleAt) > (MobBook.shared.isEmpty ? 8 : 3) else { return }; idleAt = Date() }
        guard !busy else { return }
        busy = true; defer { busy = false }
        let win = g.frameTopLeft.size
        // 小地图可能被拖到别处：先在整窗里找它
        if let small = await withTimeout(2, { await locator.capture(g, rect: CGRect(origin: .zero, size: win), outputScale: 1) }) {
            let f = await Task.detached { MiniMap.find(in: small, scale: 1) }.value
            seenMini = f != nil; miniRect = f ?? miniRect
        }
        let m = miniRect ?? CGRect(x: 0, y: 28, width: 300, height: 80)
        // 没找到小地图窗口（室内只有一行标题）：按宽的截
        let r = CGRect(x: m.minX, y: m.minY, width: max(m.width, seenMini ? 150 : 320), height: 80).intersection(CGRect(origin: .zero, size: win))
        guard let img = await withTimeout(2, { await locator.capture(g, rect: r, outputScale: 2) }),
              let lines = await withTimeout(3, { client.recognize(img) }) else { setNotice(client.notice); return }
        setNotice(nil)
        var found = NavDB.shared.locate(lines.map(\.text), near: mapId)
        // 认不出：末尾的 “V” 紧挨着窗口边框会认成 “W”。只截标题文字、处理后再认一次（和采集用的一样）
        if found == nil, miniRect != nil,
           let c = MiniMap.titleImage(img, rect: CGRect(x: 44 * 2, y: 22 * 2, width: (m.width - 50) * 2, height: 44 * 2)),
           let l = await withTimeout(3, { client.recognize(c) }) {
            found = NavDB.shared.locate(l.map(\.text), near: mapId)
            if found != nil { trace("nav: 第二次认出 \(l.map(\.text))") }
        }
        // 同名的图标题分不清：看小地图上的门和 NPC
        if let f = found, case let tw = NavDB.shared.twins(f), tw.count > 1, let b = miniRect {
            let r = CGRect(x: b.minX - 4, y: b.minY - 2, width: b.width + 8, height: 300).intersection(CGRect(origin: .zero, size: win))
            let ms = tw.compactMap { NavDB.shared.maps[$0] }
            if let im = await withTimeout(2, { await locator.capture(g, rect: r, outputScale: 2) }),
               let w = await Task.detached(operation: { MiniMap.which(im, scale: 2, of: ms) }).value {
                if w != f { trace("nav: 同名的图，看小地图是 \(w)") }
                found = w
            }
        }
        guard let id = found else {
            misses += 1; pending = nil
            trace("nav: 没认出地图 \(lines.map(\.text))")
            if misses >= 3, !mapStale { mapStale = true; updateHint() }
            return
        }
        misses = 0
        defer { mapSeen = Date() }
        if mapStale { mapStale = false; updateHint() }
        guard id != mapId else { pending = nil; return }
        // 换图要连续两次都这么认才算（第一次认到的直接用）
        if mapId != nil, pending != id { pending = id; return }
        pending = nil
        let left = mapId, was = Date().timeIntervalSince(mapSeen) < 12
        mapId = id; me = nil; meMisses = 0; tried = []
        onEnter?(was ? left : nil, id)
        if was, let l = left, let m = NavDB.shared.maps[l], !m.portals.contains(where: { $0.first.map(Int.init) == id }) { onJump?(l, id) }
        trace("nav: 在 \(NavDB.shared.mapName(id))")
        update(); checkOld(); planUpdate()
    }
}

/// 采集向导：下一步走哪个门，跳过按钮
struct GuideCard: View {
    @ObservedObject var model: NavModel
    var body: some View {
        WidgetCard(title: "导航采集") {
            Text(model.mapId.map { "现在在 " + NavDB.shared.mapName($0) + (model.guide.map { $0.key != nil ? "，这张图还差 \($0.left) 项" : "" } ?? "") } ?? "没认出当前地图，正在重试（小地图要展开）").font(.system(size: 10)).foregroundStyle(Color.mSub).lineLimit(1)
            if let g = model.guide {
                Text(g.title).font(.system(size: 12, weight: .bold)).fixedSize(horizontal: false, vertical: true)
                if let s = g.route.steps.first, g.key == nil { Text("1. " + s).font(.system(size: 11)).foregroundStyle(Color.mSub).fixedSize(horizontal: false, vertical: true) }
                HStack(spacing: 8) {
                    if let k = g.key { Button("跳过这个") { model.collect?.skip(k) } }
                    Button("跳过「\(NavDB.shared.maps[g.goalMap]?.name ?? "")」") { model.skipGuideMap(g.goalMap) }.lineLimit(1)
                }.buttonStyle(.plain).font(.system(size: 10, weight: .bold)).foregroundStyle(Color(nsColor: Maple.warn))
            } else if model.mapId != nil { Text("从这里走得到的都采好了（要坐船的先自己坐过去）").font(.system(size: 11)) }
        }
        .overlay(alignment: .topTrailing) {
            Button { model.guideOn = false } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white).frame(width: 22, height: MapleCardView.strip).contentShape(Rectangle())
            }.buttonStyle(.plain).help("关闭导航采集，回到任务助手")
        }
        .padding(.horizontal, 8).padding(.top, 5)
    }
}

struct NavOrGuide: View {
    @ObservedObject var model: NavModel
    var tight = false, smallMobs = false
    var body: some View { if model.guideOn, model.choices.isEmpty { GuideCard(model: model) } else { NavCard(model: model, tight: tight, smallMobs: smallMobs) } }
}

/// 这张图里任务要打的怪：图、名字、等级、血量、刷新点；点一下箭头带路。放在任务助手卡里面
struct MobRows: View {
    @ObservedObject var model: NavModel
    /// 面板放不下：只排一行小图
    var small = false
    @MainActor static var cache: [String: NSImage] = [:]
    @MainActor private static func image(_ n: String) -> NSImage? {
        if let i = cache[n] { return i }
        guard let d = MobBook.shared.info(n)?.png, let i = NSImage(data: d) else { return nil }
        if let r = i.representations.first { i.size = NSSize(width: r.pixelsWide, height: r.pixelsHigh) }
        cache[n] = i
        return i
    }
    @ViewBuilder private func icon(_ n: String, _ side: CGFloat) -> some View {
        Group {
            if let i = Self.image(n) {
                // 小怪按原大小，大怪缩小放进格子
                if i.size.width <= side, i.size.height <= side { Image(nsImage: i).interpolation(.none) }
                else { Image(nsImage: i).resizable().aspectRatio(contentMode: .fit) }
            } else { Text("?").font(.system(size: 11)).foregroundStyle(Color.mSub) }
        }.frame(width: side, height: side)
    }
    var body: some View {
        let list = model.mobsHere
        if !list.isEmpty {
            Text("这张图要打的" + (model.mapStale ? "（上次认出的图）" : "")).font(.system(size: 10)).foregroundStyle(Color.mSub)
            if !small, list.count <= 5 { ForEach(list, id: \.name) { row($0.name, $0.n) } } else { strip(list) }
        }
    }
    private func detail(_ n: String, _ k: Int) -> String {
        let i = MobBook.shared.info(n)
        return ([i?.lv.map { "Lv.\($0)" }, i?.hp.map { "血 \($0)" }, i?.exp.map { "经验 \($0)" }, "\(k) 处"] as [String?]).compactMap { $0 }.joined(separator: " · ")
    }
    private func row(_ n: String, _ k: Int) -> some View {
        let on = model.mobFocus == n, t = model.mobTask(n)
        return Button { model.focus(n) } label: {
            HStack(spacing: 6) {
                icon(n, 30)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(NavDB.shared.mobName(n)).font(.system(size: 11, weight: .bold)).lineLimit(1).minimumScaleFactor(0.8)
                        if let t { Text(t.text).font(.system(size: 10, weight: .bold)).foregroundStyle(Color(nsColor: t.done ? Maple.done : Maple.warn)).lineLimit(1).fixedSize() }
                    }
                    Text(detail(n, k)).font(.system(size: 10)).foregroundStyle(Color.mSub).lineLimit(1).minimumScaleFactor(0.8)
                }
                Spacer(minLength: 0)
                Text(on ? "取消" : "带路 ▸").font(.system(size: 10, weight: .bold)).foregroundStyle(on ? .white : Color(nsColor: Maple.strip)).fixedSize()
                    .padding(.horizontal, 5).frame(height: 16).background(RoundedRectangle(cornerRadius: 4).fill(on ? Color(nsColor: Maple.warn) : Color.black.opacity(0.06)))
            }.contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
    /// 种类多、地方不够：小图 + 等级，鼠标停着看名字
    private func strip(_ list: [(name: String, n: Int)]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 38, maximum: 46), spacing: 4)], alignment: .leading, spacing: 4) {
            ForEach(list, id: \.name) { m in
                let t = model.mobTask(m.name)
                Button { model.focus(m.name) } label: {
                    VStack(spacing: 0) {
                        icon(m.name, 28)
                        Text(MobBook.shared.info(m.name)?.lv.map { "Lv.\($0)" } ?? "").font(.system(size: 9)).foregroundStyle(t.map { Color(nsColor: $0.done ? Maple.done : Maple.warn) } ?? Color.mSub)
                    }.frame(maxWidth: .infinity)
                        .background(RoundedRectangle(cornerRadius: 4).fill(model.mobFocus == m.name ? Color(nsColor: Maple.warn).opacity(0.25) : Color.black.opacity(0.04)))
                }.buttonStyle(.plain).help(NavDB.shared.mobName(m.name) + "：" + detail(m.name, m.n) + (t.map { " · " + $0.text } ?? "") + "。点一下箭头带路")
            }
        }
    }
}

/// 组队任务：这一关怎么过；要试组合的列出来，试过的点一下划掉
struct StageCard: View {
    @ObservedObject var model: NavModel
    let guide: StageGuide
    var body: some View {
        WidgetCard(title: "任务助手 · \(guide.title)") {
            ForEach(guide.lines, id: \.self) { Text($0).font(.system(size: 11)).foregroundStyle(Color.mText).fixedSize(horizontal: false, vertical: true) }
            let all = guide.combos
            if !all.isEmpty {
                let left = all.count - model.tried.intersection(all).count
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 40, maximum: 56), spacing: 4)], alignment: .leading, spacing: 4) {
                    ForEach(all, id: \.self) { c in
                        let no = model.tried.contains(c)
                        Button { if no { model.tried.remove(c) } else { model.tried.insert(c) } } label: {
                            Text(c).font(.system(size: 11, weight: .bold)).strikethrough(no).monospacedDigit()
                                .foregroundStyle(no ? Color.mSub.opacity(0.6) : Color.mText).frame(maxWidth: .infinity).frame(height: 18)
                                .background(RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(no ? 0.02 : 0.08)))
                        }.buttonStyle(.plain)
                    }
                }
                HStack(spacing: 8) {
                    Text("还剩 \(left) 种" + (guide.pick?.note.map { "；" + $0 } ?? "")).foregroundStyle(Color.mSub)
                    Spacer(minLength: 0)
                    if !model.tried.isEmpty { Button("重来") { model.tried = [] }.buttonStyle(.plain).foregroundStyle(Color(nsColor: Maple.warn)) }
                }.font(.system(size: 10)).lineLimit(1)
            }
        }
        .padding(.horizontal, 8).padding(.top, 5)
    }
}

/// 顺路一起做：平时一行，点开按站列出来；点一项就导航它
struct PlanList: View {
    @ObservedObject var model: NavModel
    @AppStorage("planOpen") private var planOpen = false
    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(model.plan.enumerated()), id: \.offset) { i, s in stop(i, s) }
                ForEach(model.book.open, id: \.key) { o in
                    HStack(spacing: 4) {
                        Text(o.target.title).lineLimit(1)
                        Spacer(minLength: 4)
                        Button { model.drop(o.key) } label: { Text("✕").frame(width: 16).contentShape(Rectangle()) }.buttonStyle(.plain).help("不做了、已经交了：从清单去掉")
                    }.font(.system(size: 10)).foregroundStyle(Color.mSub)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.frame(maxHeight: 150).fixedSize(horizontal: false, vertical: true)
    }
    @ViewBuilder private func stop(_ i: Int, _ s: QuestStop) -> some View {
        Text("\(i + 1). " + (s.map.map { NavDB.shared.mapName($0) + (s.hops == 0 ? "（就在这里）" : " · 走 \(s.hops) 张图") } ?? (s.jobs.allSatisfy { if case .level = $0.kind { true } else { false } } ? "等级到了再去" : model.mapId == nil ? "认出地图后排先后" : "没有路线资料")))
            .font(.system(size: 11, weight: .bold)).foregroundStyle(Color.mText).lineLimit(1)
        ForEach(s.jobs, id: \.self) { j in
            Button { if let p = j.parts.first { model.choose(p.key, j.kind); planOpen = false } } label: {
                (Text(j.text).foregroundStyle(Color(nsColor: Maple.warn)) + Text("：" + j.parts.map { $0.title + ($0.note.isEmpty ? "" : " " + $0.note) }.joined(separator: "、")).foregroundStyle(Color.mText))
                    .font(.system(size: 11)).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 12).contentShape(Rectangle())
            }.buttonStyle(.plain).help("点一下，箭头带路")
        }
    }
}

struct NavCard: View {
    @ObservedObject var model: NavModel
    /// 面板放不下：步骤只留两行，去掉次要的几行
    var tight = false
    var smallMobs = false
    @AppStorage("navArrow") private var arrowOn = true
    @AppStorage("planOpen") private var planOpen = false
    /// 标题条右边：顺路 / 回到任务 的切换按钮（和“店铺聊天”一样），再加关闭
    private func bar(_ title: String) -> some View {
        HStack(spacing: 4) {
            if model.book.open.count > 1, !NavDB.shared.maps.isEmpty {
                Button { planOpen.toggle() } label: { Text(title) }.buttonStyle(MapleButtonStyle()).help(planOpen ? "回到正在做的任务" : "几个任务怎么顺路一起做")
            }
            Button { model.close() } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 22, height: MapleCardView.strip).contentShape(Rectangle())
            }.buttonStyle(.plain).help("结束导航")
        }.frame(height: MapleCardView.strip)
    }
    var body: some View {
        if !model.choices.isEmpty {
            // 正在选：先换成选项，选完变回任务
            WidgetCard(title: "任务助手 · 选哪个") {
                ForEach(Array(model.choices.enumerated()), id: \.offset) { _, e in
                    (Text(e.chinese).foregroundStyle(Color(nsColor: e.color ?? Maple.text)).fontWeight(e.color == nil || e.color == Maple.text ? .regular : .bold)
                        + Text(e.original.isEmpty ? "" : "   " + e.original).font(.system(size: 10)).foregroundStyle(Color.mSub))
                        .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 8).padding(.top, 5)
        } else if let g = model.stage {
            StageCard(model: model, guide: g)
        } else if model.target != nil, planOpen, !NavDB.shared.maps.isEmpty, model.book.open.count > 1 {
            WidgetCard(title: "任务助手 · 顺路一起做") { PlanList(model: model); MobRows(model: model, small: true) }
                .overlay(alignment: .topTrailing) { bar("回到任务") }
                .padding(.horizontal, 8).padding(.top, 5)
        } else if let q = model.target {
            WidgetCard(title: "任务助手 · \(model.tipTitle ?? q.title)") {
                HStack(spacing: 6) {
                    // 三步：接 → 收集 / 打怪 → 交。每步灰 = 没开始、橙 = 进行中、绿 = 完成
                    if let n = q.start { pick((q.accepted == true ? "已接 ✓ " : "去接 ") + NavDB.shared.npcName(n), .start, model.startState) }
                    if q.start == nil, q.questId == nil, let n = model.fromNpc { pick((q.accepted == true ? "已接 ✓ " : "去接 ") + n, .start, q.accepted == true ? .done : .doing) }
                    // 只列还没够的（够了的在下面“要完成”里是绿的）；全够了只剩一个绿勾
                    ForEach(q.mobs.filter { !model.mobDone($0) || model.goal == .mob($0) && !model.ready }, id: \.self) { m in
                        pick((q.mobGuess ? "打 \(m)？" : "打 \(m)") + model.progressText(m), .mob(m), model.mobState(m)) }
                    if case .mob(let m) = model.goal, !q.mobs.contains(m), !model.mobDone(m) { pick("打 \(m)？" + model.progressText(m), .mob(m), model.mobState(m)) }
                    // 要打的都列：够了的绿色 ✓（用户要求，别收起来）
                    ForEach(model.tipAll, id: \.self) { m in pick("打 " + model.name(m) + (model.tipMobs.contains(m) ? model.tipCount(m) : " ✓"), .find(m), model.tipMobs.contains(m) ? .doing : .done) }
                    ForEach(model.unknownItems.filter { model.tipMob($0) == nil }, id: \.self) { n in
                        pick(model.useUp(n) ? "用掉 " + model.name(n) : "找 " + model.name(n) + model.countText(n), .find(n), .doing) }
                    if model.ready {
                        Text("东西齐了 ✓").font(.system(size: 10, weight: .bold)).foregroundStyle(NavModel.State.done.color).lineLimit(1)
                    }
                    if let n = q.end { pick((q.start == nil ? "去找 " : model.lackLevel != nil && q.accepted == true ? "\(model.lackLevel!) 级后交 " : model.ready ? "可以交了 " : "去交 ") + NavDB.shared.npcName(n), .end, model.ready ? .doing : .todo) }
                    if q.end == nil, q.questId == nil, let n = model.endNpc { pick((model.ready && !model.progress.isEmpty ? "可以交了 " : "去交 ") + n, .end, model.ready && !model.progress.isEmpty ? .doing : .todo) }
                    Spacer(minLength: 0)
                }
                if q.questId == nil, !tight, let s = model.walkHere?() { Text("现在在 " + s).font(.system(size: 10)).foregroundStyle(Color.mSub).lineLimit(1) }
                if NavDB.shared.maps.isEmpty, model.walkGoal == nil, !model.walkUnknown.isEmpty {
                    Text("任务里提到、还没去过或没见过：" + model.walkUnknown.joined(separator: "、")).font(.system(size: 10)).foregroundStyle(Color.mSub).lineLimit(2)
                }
                if !tight || model.mapStale || model.mapId == nil { HStack(spacing: 4) {
                    if !NavDB.shared.maps.isEmpty, !tight || model.mapStale || model.mapId == nil { Text(here).font(.system(size: 10)).foregroundStyle(model.mapStale ? Color(nsColor: Maple.warn) : Color.mSub).lineLimit(1).truncationMode(.tail) }
                } }
                // 挤的时候：步骤和上面的按钮重复，有目的地就不写
                if model.stepwise { ForEach(Array(model.stepLines.enumerated()), id: \.offset) { _, l in Text(l.0).font(.system(size: 11)).foregroundStyle(l.1 == .todo ? Color.mText : l.1.color).fixedSize(horizontal: false, vertical: true) } }
                else if !tight || destination == nil { howTo(q).font(.system(size: 11)).lineLimit(tight ? 2 : 5).fixedSize(horizontal: false, vertical: true) }
                if q.questId == nil, let s = model.tipDest { Text(s).font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.mText).lineLimit(2) }
                if let id = q.questId, let s = QuestTips.quest(id) { Text("要点：" + s).font(.system(size: 11)).foregroundStyle(Color.mText).fixedSize(horizontal: false, vertical: true) }
                if q.questId == nil, let s = model.stepwise ? model.stepTip : model.tip, !s.isEmpty { Text("经验：" + s).font(.system(size: 11)).foregroundStyle(Color.mText).fixedSize(horizontal: false, vertical: true) }
                if !tight, model.tip == nil, !model.stepwise, let b = q.brief { Text("大意：" + b).font(.system(size: 10)).foregroundStyle(Color.mSub).lineLimit(3).fixedSize(horizontal: false, vertical: true) }
                if let n = model.waitLevel {
                    Text("先升到 \(n) 级，再去").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color(nsColor: Maple.warn))
                } else if let d = destination {
                    Text(d).font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.mText).lineLimit(2)
                }
                if !tight, let s = model.shortcut {
                    Text("更快：" + s).font(.system(size: 11)).foregroundStyle(Color(nsColor: Maple.warn)).fixedSize(horizontal: false, vertical: true)
                }
                if model.route != nil, let s = model.sourceNote { Text("怎么弄到：" + s).font(.system(size: 11)).foregroundStyle(Color.mText).lineLimit(3).fixedSize(horizontal: false, vertical: true) }
                if let r = model.route {
                    // 怎么走看游戏画面上的箭头，这里只写目的地（用户定，省高度）；到了那张图写一句。箭头关了才写下一步
                    if r.arrived || !arrowOn, model.waitLevel == nil, let st = r.steps.first {
                        Text(st).font(.system(size: 12, weight: .bold)).foregroundStyle(Color.mText).fixedSize(horizontal: false, vertical: true)
                    }
                } else if let s = model.missing {
                    Text(s).font(.system(size: 11)).foregroundStyle(Color.mSub)
                } else if let n = model.npc {
                    Text(noRoute(n)).font(.system(size: 11)).foregroundStyle(Color.mSub).fixedSize(horizontal: false, vertical: true)
                } else if !NavDB.shared.maps.isEmpty {
                    Text(model.mapId == nil ? "认出当前地图后显示路线" : "没有路线资料").font(.system(size: 11)).foregroundStyle(Color.mSub)
                }
                MobRows(model: model, small: smallMobs)
            }
            .overlay(alignment: .topTrailing) { bar("顺路 \(model.book.open.count)") }
            .padding(.horizontal, 8).padding(.top, 5)
        } else if model.listOnly {
            WidgetCard(title: "任务助手") { PlanList(model: model); MobRows(model: model, small: smallMobs) }
                .overlay(alignment: .topTrailing) {
                    Button { model.close() } label: {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 22, height: MapleCardView.strip).contentShape(Rectangle())
                    }.buttonStyle(.plain).help("收起")
                }
                .padding(.horizontal, 8).padding(.top, 5)
        }
    }
    /// 目的地写在最前面：不想走路的可以自己坐车、用回城卷过去
    private var destination: String? {
        let db = NavDB.shared
        if let r = model.route {
            guard !r.arrived else { return nil }
            let place = "「\(db.mapName(r.goalMap))」"
            let who: String
            if case .mob(let m) = model.goal { who = "\(db.mobName(m)) 在\(place)" } else if case .find(let n) = model.goal { who = "\(db.itemName(n)) 在\(place)\(model.sourceNote != nil ? "找" : model.bought(n) ? "的店里买" : "捡到过")" } else if let n = model.npc { who = "\(db.npcName(n)) 在\(place)的\(r.goalSide)" } else { return nil }
            return "目的地：\(who)，走路 \(r.hops) 张图"
        }
        return nil
    }
    private var here: String {
        guard let m = model.mapId else { return model.ocrNotice ?? "没认出当前地图，请展开左上角小地图" }
        return (model.mapStale ? "上次在 " : "现在在 ") + NavDB.shared.mapName(m)
    }
    /// 用自己的话写怎么完成：接 → 打怪、收集（带进度）→ 交。做完的绿色打 ✓
    private func howTo(_ t: NavTarget) -> Text {
        let db = NavDB.shared, q = t.questId.flatMap { db.quest($0) }
        var steps: [[(String, NavModel.State)]] = []
        if let s = t.start, t.accepted != true { steps.append([("找 \(db.npcName(s)) 接任务", model.startState)]) }
        if t.questId == nil, t.accepted != true {
            if let w = model.fromText { steps.append([("找 \(w) 接任务", .doing)]) }
        }
        func amount(_ n: String, _ need: Int, _ unit: String) -> String {
            if model.itemState(n) == .done { return " ✓" }
            return model.progress[n].map { " \($0[0])/\($0[1])" } ?? (need > 0 ? " \(need) \(unit)" : "")
        }
        var todo: [(String, NavModel.State)] = []
        for m in q?.mobs ?? [] { todo.append(("打 \(db.mobName(m.name))\(amount(m.name, m.count, "只"))", model.itemState(m.name))) }
        for i in q?.items ?? [] {
            if i.count == 0 {
                todo.append(("把 \(db.itemName(i.name)) 用掉" + (model.itemState(i.name) == .done ? " ✓" : "：打开背包（默认按 I）→ 点 Use 页 → 双击它"), model.itemState(i.name)))
                continue
            }
            let from = db.mob(forObjective: i.name, target: t) ?? (q?.items.count == 1 && q?.mobs.isEmpty == true && t.mobs.count == 1 ? t.mobs[0] : nil)
            todo.append(("收集 \(db.itemName(i.name))\(amount(i.name, i.count, "个"))" + (from.map { "（打 \(db.mobName($0))\(t.mobGuess ? "，推测" : "")）" } ?? ""), model.itemState(i.name)))
        }
        if todo.isEmpty {
            // 先打怪、再收集（打谁掉），和有资料时一样
            let all = model.progress.keys.sorted()
            for n in all where t.questId == nil && QuestTips.mobZh(n) != nil { todo.append(("打 \(model.name(n))\(amount(n, 0, ""))", model.itemState(n))) }
            for n in all where t.questId != nil || QuestTips.mobZh(n) == nil {
                let m = t.questId == nil ? model.tipMob(n) : nil
                todo.append(((t.questId == nil ? "收集 " : "完成 ") + "\(model.name(n))\(amount(n, 0, ""))" + (m.map { "（打 \(model.name($0))）" } ?? ""), model.itemState(n)))
            }
        }
        if todo.isEmpty { for m in t.mobs { todo.append(("打 \(db.mobName(m))\(t.mobGuess ? "（推测）" : "")", model.mobState(m))) } }
        if !todo.isEmpty { steps.append(todo) }
        if let n = model.lackLevel, let me = model.myLevel() { steps.insert([("升到 \(n) 级\(t.accepted == true ? "" : "才能接")（现在 \(me) 级）", .doing)], at: t.accepted == true ? steps.count : 0) }
        let end = t.end.map { db.npcName($0) }
        if todo.isEmpty, let e = end { steps.append([("\(t.accepted == true && model.lackLevel != nil ? "到了再找" : "找") \(e) 说话", .todo)]) }
        else if let e = end { steps.append([("回去找 \(e) 交任务", model.ready ? .doing : .todo)]) }
        else if !todo.isEmpty { steps.append([("回去找 \(model.endNpc ?? "给任务的 NPC") 交任务", model.ready ? .doing : .todo)]) }
        if steps.isEmpty { return Text("没看到要打什么、要交什么，看下面的大意").foregroundStyle(Color.mSub) }
        var out = AttributedString()
        for (i, st) in steps.enumerated() {
            var no = AttributedString((i == 0 ? "" : "\n") + "\(i + 1). "); no.foregroundColor = .mSub
            out += no
            for (k, (text, state)) in st.enumerated() {
                var sep = AttributedString(k == 0 ? "" : "，"); sep.foregroundColor = .mSub
                var a = AttributedString(text); a.foregroundColor = state == .todo ? .mText : state.color
                out += sep + a
            }
        }
        return Text(out)
    }
    private func noRoute(_ n: Int) -> String {
        let name = NavDB.shared.npcName(n)
        guard let m = NavDB.shared.npcMaps(n).first else { return "没有 \(name) 的位置资料" }
        return model.mapId == nil ? "\(name) 在 \(NavDB.shared.mapName(m))" : "没有走过去的路线资料（可能要坐船或找 NPC 传送）；\(name) 在 \(NavDB.shared.mapName(m))"
    }
    private func pick(_ t: String, _ g: NavModel.Goal, _ state: NavModel.State) -> some View {
        let on = model.goal == g
        return Button { model.pick(g) } label: {
            Text(t).font(.system(size: 10, weight: .bold)).lineLimit(1).minimumScaleFactor(0.7)
                .foregroundStyle(on ? .white : state.color).padding(.horizontal, 6).frame(height: 18)
                .background(RoundedRectangle(cornerRadius: 4).fill(on ? (state == .todo ? Color(nsColor: Maple.strip) : state.color) : Color.black.opacity(0.06)))
        }.buttonStyle(.plain)
    }
}

/// 游戏画面上的箭头条：一个会动的箭头 + 一句话。鼠标穿透，不挡操作。
struct NavArrowView: View {
    @ObservedObject var model: NavModel
    var body: some View {
        if let h = model.hint ?? (model.moving ? NavHint(dir: .none, text: "导航会显示在这里（没有任务）") : nil) {
            HStack(spacing: 8) {
                if let icon = icon(h.dir) { MovingArrow(icon: icon, dir: h.dir).id(icon) }
                VStack(alignment: .leading, spacing: 1) {
                    Text(h.lines.0).font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                    if let s = h.lines.1 { Text(s).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.85)) }
                }
                .lineLimit(1).truncationMode(.tail).minimumScaleFactor(0.8).shadow(color: .black, radius: 0, x: 1, y: 1)
            }
            .padding(.horizontal, 12).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 12).fill(.black.opacity(0.55)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(model.moving ? .yellow : .white.opacity(0.3), lineWidth: model.moving ? 2 : 1))
            .contentShape(Rectangle())
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    private func icon(_ d: NavHint.Dir) -> String? {
        switch d {
        case .left: "arrow.left"; case .right: "arrow.right"; case .up: "arrow.up"; case .down: "arrow.down"; case .upLeft: "arrow.up.left"; case .upRight: "arrow.up.right"; case .downLeft: "arrow.down.left"; case .downRight: "arrow.down.right"; case .here: "checkmark"; case .none: nil
        }
    }
}
private struct MovingArrow: View {
    let icon: String, dir: NavHint.Dir
    @State private var on = false
    private var move: CGSize {
        switch dir {
        case .left: CGSize(width: -4, height: 0); case .right: CGSize(width: 4, height: 0)
        case .up: CGSize(width: 0, height: -3); case .down: CGSize(width: 0, height: 3)
        case .upLeft: CGSize(width: -3, height: -3); case .upRight: CGSize(width: 3, height: -3)
        case .downLeft: CGSize(width: -3, height: 3); case .downRight: CGSize(width: 3, height: 3)
        case .here, .none: .zero
        }
    }
    var body: some View {
        Image(systemName: icon).font(.system(size: 24, weight: .black)).foregroundStyle(Color(nsColor: Maple.rgb(255, 210, 60)))
            .shadow(color: .black, radius: 0, x: 1, y: 1)
            .offset(x: on ? move.width : 0, y: on ? move.height : 0)
            .onAppear { withAnimation(.easeInOut(duration: 0.45).repeatForever(autoreverses: true)) { on = true } }
    }
}
@MainActor
final class NavArrowPanel: NSObject {
    let panel = makePanel(clickThrough: true)
    private let model: NavModel
    private var game = CGRect.zero, placing = false
    init(_ model: NavModel) {
        self.model = model
        super.init()
        panel.contentView = NSHostingView(rootView: NavArrowView(model: model))
        NotificationCenter.default.addObserver(self, selector: #selector(moved), name: NSWindow.didMoveNotification, object: panel)
    }
    /// 移动模式：可以用鼠标拖；关掉后恢复鼠标穿透
    var movable = false {
        didSet {
            panel.ignoresMouseEvents = !movable
            panel.isMovableByWindowBackground = movable
            model.moving = movable
        }
    }
    /// 用户拖到的位置：在游戏画面里的比例（0~1，左上原点），换窗口大小也不会跑出去。nil = 默认（中间偏上）
    private var spot: CGPoint? {
        get { (UserDefaults.standard.array(forKey: "navArrowSpot") as? [Double]).flatMap { $0.count == 2 ? CGPoint(x: $0[0], y: $0[1]) : nil } }
        set { if let v = newValue { UserDefaults.standard.set([v.x, v.y], forKey: "navArrowSpot") } else { UserDefaults.standard.removeObject(forKey: "navArrowSpot") } }
    }
    func resetSpot() { spot = nil }
    private static let size = CGSize(width: 300, height: 48), bar: CGFloat = 28
    private var room: CGSize { CGSize(width: max(1, game.width - Self.size.width), height: max(1, game.height - Self.bar - Self.size.height)) }
    @objc private func moved() {
        guard movable, !placing, game != .zero, NSEvent.pressedMouseButtons != 0 else { return }
        let g = Coords.toAppKit(game)
        let x = (panel.frame.minX - g.minX) / room.width, y = (g.maxY - panel.frame.maxY - Self.bar) / room.height
        spot = CGPoint(x: min(1, max(0, x)), y: min(1, max(0, y)))
    }
    /// 放在游戏画面中间偏上（小地图、队伍血条下面一点），或用户拖到的地方
    func show(over game: CGRect, level: NSWindow.Level) {
        self.game = game
        let o = spot.map { CGPoint(x: game.minX + $0.x * room.width, y: game.minY + Self.bar + $0.y * room.height) }
            ?? CGPoint(x: game.midX - Self.size.width / 2, y: game.minY + Self.bar + (game.height - Self.bar) * 0.23)
        let f = Coords.toAppKit(CGRect(origin: o, size: Self.size))
        // 正在拖的时候不抢
        if panel.frame != f, !(movable && NSEvent.pressedMouseButtons != 0) { placing = true; panel.setFrame(f, display: true); placing = false }
        if panel.level != level { panel.level = level }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }
    func hide() { if panel.isVisible { panel.orderOut(nil) } }
}

/// 面板顶部最多能用多高（SidePanel 按面板高度算）
final class SideSpace: ObservableObject { @Published var budget: CGFloat = 400 }

/// 侧边面板顶部：角色、收益卡（经验统计开着才有）+ 导航卡（有任务才有）
struct SideHeader: View {
    let exp: ExpModel?
    let nav: NavModel?
    @ObservedObject var space: SideSpace
    var onHeight: (CGFloat) -> Void = { _ in }
    var body: some View {
        // GeometryReader：里面比外面高时也从顶上排，不会居中溢出
        GeometryReader { geo in
            // 从宽松到紧凑，用第一个放得下的（给聊天留够地方）
            ViewThatFits(in: .vertical) {
                // 图一直在：先少列掉落，再收短任务卡
                stack(84, 3)
                stack(84, 3, false, true)
                if exp != nil { stack(68, 2, false, true); stack(68, 1, false, true); stack(68, 0, false, true); stack(60, 1, true); stack(60, 0, true); stack(48, 0, true) }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onHeight($0) }
            .frame(width: geo.size.width, height: space.budget, alignment: .top)
        }
    }
    private func stack(_ chart: CGFloat, _ rows: Int, _ tight: Bool = false, _ smallMobs: Bool = false) -> some View {
        VStack(spacing: 0) {
            if let exp { ExpWidgets(model: exp, chartHeight: chart, lootRows: rows) }
            if let nav { NavOrGuide(model: nav, tight: tight, smallMobs: tight || smallMobs) }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
