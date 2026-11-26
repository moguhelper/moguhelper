// 经验统计：每 6 秒截游戏窗口最下面一条（状态栏），识别 “LV. 26 … EXP 30.782[56.07%]”，
// 算出每分钟获得多少经验，存到本机（只存数字，不存图片）。显示在侧边面板顶部的小组件里（不盖在游戏上）。
import AppKit
import SwiftUI
import Charts
import TranslatorCore

@MainActor
final class ExpModel: ObservableObject {
    /// 等级：橙色花体数字不是每次都认得出，所以存下来；已知后只在升级时加 1
    @Published var name = UserDefaults.standard.string(forKey: "myName") ?? ""
    private func key(_ k: String) -> String { name.isEmpty ? k : "\(k)@\(name)" }
    @Published var level: Int? {
        didSet { if level != oldValue { UserDefaults.standard.set(level, forKey: key("level")) } }
    }
    /// 职业（状态栏名字上面那行，英文）；转职后自动更新
    @Published var job: String? {
        didSet { if job != oldValue { UserDefaults.standard.set(job, forKey: key("job")) } }
    }
    @Published var reading: ExpReading? = nil
    @Published var need: Double? = nil
    @Published var store = ExpStore()
    @Published var lastSeen: Date? = nil
    /// 金币：背包里最近一次看到的数、什么时候看到的；minutes 记赚的，losses 记花的
    @Published var mesos: Int? = nil
    @Published var mesoSeen: Date? = nil
    @Published var mesoStore = ExpStore()
    @Published var potions = PotionLog()
    @Published var recent = RecentLoot()
    func usedPotion(_ id: Int, _ n: Int) { recent.add(.used(id), n) }
    func killed() { recent.add(.kill, 1) }
    func gotItem(_ k: String, _ n: Int) { recent.add(.item(k), n) }
}

/// 最近一小时打了几只、捡了什么、喝了什么（每个角色一份 recent.json，重启接着用）
struct RecentLoot: Codable {
    struct Event: Codable { var t: Date, kind: Kind, n: Int }
    enum Kind: Hashable, Codable { case kill, item(String), used(Int) }
    private var events: [Event] = []
    mutating func add(_ k: Kind, _ n: Int) {
        let now = Date()
        events.removeAll { now.timeIntervalSince($0.t) > 3600 }
        events.append(Event(t: now, kind: k, n: n))
    }
    var hasAny: Bool { let now = Date(); return events.contains { now.timeIntervalSince($0.t) <= 3600 } }
    func summary(_ now: Date) -> (kills: Int, drops: [String: Int], used: [Int: Int], fresh: [Kind: Date]) {
        var out: (kills: Int, drops: [String: Int], used: [Int: Int], fresh: [Kind: Date]) = (0, [:], [:], [:])
        for e in events where now.timeIntervalSince(e.t) <= 3600 {
            switch e.kind {
            case .kill: out.kills += e.n
            case .item(let k): out.drops[k, default: 0] += e.n
            case .used(let i): out.used[i, default: 0] += e.n
            }
            if e.n > 0 { out.fresh[e.kind] = e.t }
        }
        out.drops = out.drops.filter { $0.value > 0 }
        return out
    }
}

@MainActor
final class ExpMonitor: ObservableObject {
    let model = ExpModel()
    private var tracker = ExpTracker()
    /// 统计专用的识别子进程：不和鼠标指向、物品说明抢（抢不到那一次就白读了）
    let client = OCRClient(idleStop: 90, wait: 1.5)
    /// 背包金币框在窗口里的位置（点）。知道了就只认那一小条，又快又省
    private var bagBox: CGRect?
    private var lastBagScan = Date.distantPast
    private var busy = false
    private var misses = 0
    private var reads = 0
    private var mesoTracker = MesoTracker()
    private var mesoBusy = false
    private var levelSeen: (Int, Int)?
    private var jobSeen = ""
    private var pickupBusy = false
    private var pickup = PickupTracker()
    /// 捡钱提示先记着，背包读数一确认就校正；存下来，重启后照样能对账
    private var ledger = MesoLedger()
    // 每个角色一份记录：ChatTranslator/角色/名字/；地图、价格表大家共用
    static let base = dataDir
    static var knownNames: [String] { ((try? FileManager.default.contentsOfDirectory(atPath: base.appendingPathComponent("角色").path)) ?? []).filter { !$0.hasPrefix(".") && $0 != "未命名" }.sorted() }
    private var dir: URL { Self.base.appendingPathComponent("角色").appendingPathComponent(model.name.isEmpty ? "未命名" : model.name) }
    private var fileURL: URL { dir.appendingPathComponent("exp.json") }
    private var mesoURL: URL { dir.appendingPathComponent("mesos.json") }
    private func key(_ k: String) -> String { model.name.isEmpty ? k : "\(k)@\(model.name)" }
    private var names = CharName()
    var onNameChange: (() -> Void)?
    /// 换角色：先把现在的存好，再读那个角色的
    func switchTo(_ name: String) {
        guard name != model.name else { return }
        save()
        // 还没名字时记的归第一个认出的角色
        let from = model.name.isEmpty ? dir : nil
        // 还没名字时读到的等级、职业也带过去，不用重新认
        let level = model.level, job = model.job
        model.name = name
        UserDefaults.standard.set(name, forKey: "myName")
        if from != nil {
            if let level, UserDefaults.standard.object(forKey: key("level")) == nil { UserDefaults.standard.set(level, forKey: key("level")) }
            if let job, UserDefaults.standard.object(forKey: key("job")) == nil { UserDefaults.standard.set(job, forKey: key("job")) }
        }
        if let from, !FileManager.default.fileExists(atPath: dir.path), FileManager.default.fileExists(atPath: from.path) { try? FileManager.default.moveItem(at: from, to: dir) }
        load()
        trace("char: 现在是 \(name)")
        onNameChange?()
    }
    private func load() {
        let fm = FileManager.default, ud = UserDefaults.standard
        // 以前没分角色的旧记录：归给现在这个角色（复制一份，旧的留着）
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            if !ud.bool(forKey: "charMigrated") {
                for f in ["exp.json", "mesos.json", "hunt.json", "potions.json"] { try? fm.copyItem(at: Self.base.appendingPathComponent(f), to: dir.appendingPathComponent(f)) }
                if !model.name.isEmpty {
                    for k in ["level", "job", "expNeed", "expLast", "lastMesos", "mesoLedger"] { if let v = ud.object(forKey: k) { ud.set(v, forKey: key(k)) } }
                    ud.set(true, forKey: "charMigrated")
                }
            }
        }
        func read<T: Decodable>(_ f: String, _ t: T.Type) -> T? { (try? Data(contentsOf: dir.appendingPathComponent(f))).flatMap { try? JSONDecoder().decode(t, from: $0) } }
        model.store = read("exp.json", ExpStore.self) ?? ExpStore()
        model.mesoStore = read("mesos.json", ExpStore.self) ?? ExpStore()
        hunt = read("hunt.json", HuntLog.self) ?? HuntLog()
        model.potions = read("potions.json", PotionLog.self) ?? PotionLog()
        model.potions.apply(book, icons: IconStore.shared.colors())
        model.level = ud.object(forKey: key("level")) as? Int; model.job = ud.string(forKey: key("job"))
        model.reading = nil; model.need = nil; model.mesos = ud.object(forKey: key("lastMesos")) as? Int; model.mesoSeen = nil
        model.recent = read("recent.json", RecentLoot.self) ?? RecentLoot()
        ledger = MesoLedger(); mesoTracker = MesoTracker(); pickup = PickupTracker(); kills = KillFilter(); bagBook.reset(); shopAt = nil; stallAt = nil; travelAt = nil; etcBag = [:]; levelSeen = nil; jobSeen = ""; bagBox = nil
        // 离上次看背包 30 分钟以内才接着对账；更久的（没开程序时的进出说不清）从下次看到的重新开始
        if let d = ud.data(forKey: key("mesoLedger")), let l = try? JSONDecoder().decode(MesoLedger.self, from: d), let t = l.bagTime, Date().timeIntervalSince(t) < 1800 { ledger = l; model.mesos = l.expected ?? model.mesos }
        tracker = ExpTracker()
        // 上次锁定的升级所需（马上就能核对读数，不用重新猜）；上次的读数也接着用，重启这几秒打的经验不漏
        if let a = ud.array(forKey: key("expNeed")) as? [Double], a.count == 2, a[0] <= a[1] {
            let l = ud.array(forKey: key("expLast")) as? [Double] ?? []
            tracker = l.count == 3 ? ExpTracker(need: a[0]...a[1], last: ExpReading(exp: Int(l[0]), pct: l[1]), at: Date(timeIntervalSince1970: l[2])) : ExpTracker(need: a[0]...a[1])
        }
    }
    // 价格表（NPC 商店读来的）
    @Published private(set) var book = PriceBook()
    private var bookURL: URL { Self.base.appendingPathComponent("prices.json") }
    private var shopBusy = false, shopAt: Date?
    /// 最近一次看到个人商店开着
    var stallAt: Date?
    /// 最近一次和 NPC 说完话一下跳到不相邻的图（坐车、坐船）
    var travelAt: Date?
    /// 给线索用：现在在哪张图、最近一次 NPC 对话
    var mapNow: () -> Int? = { nil }
    var npcAt = Date.distantPast
    /// 没认出来的一笔：记下线索（只有时间、金额、地图编号、多少秒前开过什么窗口），存本机，以后照着补
    private func noteUnknown(_ n: Int, since: Date?) {
        func ago(_ d: Date?) -> String { d.map { $0 == .distantPast ? "-" : "\(min(99_999, Int(Date().timeIntervalSince($0))))" } ?? "-" }
        let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm:ss"
        let line = "\(f.string(from: Date())) \(n) 图\(mapNow() ?? 0) 上次读数\(ago(since)) NPC商店\(ago(shopAt)) 摊位\(ago(stallAt)) NPC对话\(ago(npcAt)) 换图\(ago(travelAt))"
        trace("meso: 没认出来 \(line)")
        let u = bookURL.deletingLastPathComponent().appendingPathComponent("没认出来.txt")
        var all = ((try? String(contentsOf: u, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        all.append(line)
        try? all.suffix(200).joined(separator: "\n").write(to: u, atomically: true, encoding: .utf8)
    }
    /// 聊天框里的任务奖励
    /// 坐车坐船：聊天框那句和换图前后 20 秒都算
    private var lostMesos: (v: Int, t: Date)?
    func chatLost(_ v: Int) { lostMesos = (v, Date()); rideCheck() }
    func rode() { travelAt = Date(); rideCheck() }
    private func rideCheck() {
        guard let l = lostMesos, let t = travelAt, abs(l.t.timeIntervalSince(t)) < 20 else { return }
        lostMesos = nil
        guard ledger.ride(l.v, at: l.t, store: &model.mesoStore) else { return }
        if let e = ledger.expected { model.mesos = e }
        trace("meso: 交通费 \(l.v)"); save()
    }
    func questMesos(_ v: Int) {
        ledger.quest(v, at: Date(), store: &model.mesoStore)
        if let e = ledger.expected { model.mesos = e }
        trace("meso: 任务奖励 \(v)"); save()
    }
    /// 每 2 秒：看是不是开着 NPC 商店，开着就读名字和价格
    func shopTick(locator: GameWindowLocator, g: GameWindowInfo) async {
        guard !shopBusy else { return }
        shopBusy = true; defer { shopBusy = false }
        let w = g.frameTopLeft.size, client = self.client
        guard let small = await withTimeout(2, { await locator.capture(g, rect: CGRect(origin: .zero, size: w), outputScale: 1) }),
              let f = await Task.detached(operation: { ShopWindow.find(small, scale: 1) }).value else { return }
        let a = CGRect(x: f.left.x - 4, y: f.left.y - 4, width: f.right.x + f.right.w - f.left.x + 8, height: 270).intersection(CGRect(origin: .zero, size: w))
        guard let big = await withTimeout(2, { await locator.capture(g, rect: a, outputScale: 2) }),
              let h = await Task.detached(operation: { ShopWindow.find(big, scale: 2, from: 0) }).value,
              let cut = big.cropping(to: CGRect(x: h.left.x, y: h.left.y, width: h.right.x + h.right.w - h.left.x, height: big.height - h.left.y)),
              let lines = await withTimeout(3, { client.recognize(cut) }) else { return }
        let rightX = h.right.x - h.left.x
        let rows = await Task.detached { ShopWindow.rows(cut, scale: 2, lines: lines, rightX: rightX) }.value
        bagBook.shopOpen(at: Date()); shopAt = Date()
        // 顺便取图标：同一样东西连着两次取到一样的才要（鼠标、说明框会挡住）
        for r in rows { if let n = r.row { IconStore.shared.offer(r.name, IconGrab.shop(cut, x: (r.mine ? rightX : 0) + 10, y: (12 + n * 40) * 2, scale: 2)) } }
        let sold = rows.filter { !$0.mine && (ItemDB.shared.items.isEmpty || ItemDB.shared.exact($0.name) != nil) }.map(\.name)
        if sold.count >= 2, Set(sold).isSubset(of: soldLast) { onShop(Array(Set(sold))) }
        soldLast = Set(sold)
        var b = book
        guard b.feed(rows) || b != book else { return }
        let changed = b.items != book.items
        book = b
        guard changed else { return }
        if let d = try? JSONEncoder().encode(b) { try? d.write(to: bookURL, options: .atomic) }
        model.potions.apply(b, icons: IconStore.shared.colors()); savePotions()
        trace("shop: 记下 \(b.items.count) 样东西的价格")
    }
    /// 商店货架上有什么（连着两次看到的）
    var onShop: ([String]) -> Void = { _ in }
    private var soldLast: Set<String> = []
    private var lastSave = Date()
    // 打怪记录：现在在哪张图由地图采集告诉；刚换图 3 秒内不记，免得记到别的图上
    var currentMap: () -> String? = { nil }
    @Published private(set) var hunt = HuntLog()
    private var huntDirty = false, kills = KillFilter()
    private var huntURL: URL { fileURL.deletingLastPathComponent().appendingPathComponent("hunt.json") }
    // 药水
    private var potionURL: URL { fileURL.deletingLastPathComponent().appendingPathComponent("potions.json") }
    private var potionBusy = false
    /// 每 1 秒看一眼快捷栏的数量（不用文字识别，很省）
    private var iconsUsed = -1
    func potionTick(locator: GameWindowLocator, g: GameWindowInfo) async {
        guard (names.candidate == nil || model.name.isEmpty), !potionBusy else { return }
        potionBusy = true; defer { potionBusy = false }
        let w = g.frameTopLeft.size
        // 底部那条 800 点宽、居中；快捷栏在它右边上面
        let r = CGRect(x: (w.width / 2 + 230).rounded(), y: w.height - 156, width: 173, height: 100).intersection(CGRect(origin: .zero, size: w))
        guard let img = await withTimeout(2, { await locator.capture(g, rect: r, outputScale: 2) }) else { return }
        let c = await Task.detached { QuickSlot.read(img, scale: 2) }.value
        var log = model.potions
        var used = log.feed(c, at: Date())
        // 背包开着、停在 Use 页：也看一眼
        if let b = bagGrid, Date().timeIntervalSince(bagSeenAt) < 1 {
            let a = CGRect(x: b.x - 7, y: b.y - 50, width: 205, height: 262).intersection(CGRect(origin: .zero, size: w))
            if a.width > 150, a.height > 200, let bag = await withTimeout(2, { await locator.capture(g, rect: a, outputScale: 2) }) {
                let cells = await Task.detached { QuickSlot.onUseTab(bag, scale: 2) ? QuickSlot.read(bag, scale: 2) : [] }.value
                used += log.feedBag(cells, at: Date())
            }
        }
        // 新出现的东西：马上按图标、价格表填名字和单价
        if log.slots.count != model.potions.slots.count || iconsUsed != IconStore.shared.count { iconsUsed = IconStore.shared.count; log.apply(book, icons: IconStore.shared.colors()) }
        if log != model.potions { let fresh = log.slots.count != model.potions.slots.count; model.potions = log; if fresh || !used.isEmpty { savePotions() } }
        for u in used {
            // 没认出是什么、也没有单价的格子（常是说明框压着认错的）：不算喝掉
            if let s = model.potions.slots.first(where: { $0.id == u.id }), s.name.isEmpty, s.price == 0 { trace("potion: 第 \(u.id) 格少了 \(u.n) 个，不认识是什么，不记"); continue }
            model.usedPotion(u.id, u.n)
            if let e = model.potions.slots.first(where: { $0.id == u.id })?.en { bagBook.usedUp(e, u.n, at: Date()) }
            if u.cost > 0, let k = currentMap() { hunt.potion(u.cost, map: k); huntDirty = true }
            trace("potion: 第 \(u.id) 格用了 \(u.n) 个，花 \(u.cost)")
        }
    }
    // 背包图标：不靠文字识别，翻页也来得及
    /// 第一格左上角（窗口内的点）、最近一次看到背包
    private var bagGrid: CGPoint?, bagSeenAt = Date.distantPast
    private var bagBusy = false, bagArea: CGRect? = UserDefaults.standard.string(forKey: "bagArea").map(NSRectFromString), bagScan = Date.distantPast, bagSeenLog = ""
    /// 每 0.3 秒：知道背包在哪就只看那一块；没看到时每 0.8 秒找一次整窗
    func bagTick(locator: GameWindowLocator, g: GameWindowInfo) async {
        guard !bagBusy else { return }      // 没有图标资料（公开版）也要找：金币框的位置靠它
        bagBusy = true; defer { bagBusy = false }
        if ItemPrints.shared.count == 0 { shareIcons(); settleLearn() }
        let win = CGRect(origin: .zero, size: g.frameTopLeft.size)
        if let a = bagArea, await grabBag(locator, g, a.intersection(win)) { return }
        guard Date().timeIntervalSince(bagScan) >= 0.8 else { return }
        bagScan = Date()
        // 1 倍截图会混色、对不准，只用来粗看有没有一大片格子底色；有才截 2 倍的
        guard let small = await withTimeout(2, { await locator.capture(g, rect: win, outputScale: 1) }),
              await Task.detached(operation: { IconGrab.maybeBag(small) }).value else { return }
        _ = await grabBag(locator, g, win)
    }
    // 双复核
    /// 背包 Etc 页最后看到的一屏
    @Published private(set) var etcBag: [String: Int] = [:]
    private var bagBook = BagBook(), glyphLast = "", glyphSeen: [String: Date] = [:]
    /// 没有图标资料时：靠“捡了几个、哪格多了几个”认格子
    private static let learnURL = ExpMonitor.base.appendingPathComponent("bagprints.json")
    private var learn: BagLearn = (try? Data(contentsOf: ExpMonitor.learnURL)).flatMap { try? JSONDecoder().decode(BagLearn.self, from: $0) } ?? BagLearn()
    private func notePick(_ name: String, _ n: Int, _ text: String = "") {
        guard ItemPrints.shared.count == 0, n > 0 else { return }
        let tab = text.contains("(Etc") ? "Etc" : text.contains("(Use") ? "Use" : text.contains("(Equip") ? "Equip" : nil
        learn.use(model.name); learn.pick(name, n, tab: tab, at: Date())
    }
    private var iconVersion = -1
    /// 新取到图标（商店、说明框看到的）：背包里这些格子就都认识了
    private func shareIcons() {
        guard iconVersion != IconStore.shared.version || IconStore.shared.count != learnIcons else { return }
        iconVersion = IconStore.shared.version; learnIcons = IconStore.shared.count
        learn.setIcons(IconStore.shared.prints())
    }
    private var learnIcons = -1
    private var learnSaved = Date.distantPast
    private func saveLearn() {
        guard learn.dirty, Date().timeIntervalSince(learnSaved) > 10 else { return }
        learnSaved = Date()
        guard let d = try? JSONEncoder().encode(learn) else { return }
        try? d.write(to: Self.learnURL, options: .atomic); learn.saved()
    }
    /// 格子在 5 列 6 行里的位置；不在格线上的（背包外面误认的）不要
    private static func place(_ c: IconGrab.BagCell, _ x0: Int, _ y0: Int) -> (Int, Int)? {
        let dx = c.x - x0 + 10, dy = c.y - y0 + 10
        guard dx >= 0, dy >= 0, dx % 72 <= 20, dy % 68 <= 20, dx / 72 < 5, dy / 68 < 6 else { return nil }
        return (dx / 72, dy / 68)
    }
    /// 左上角：能放下最多格子的那个（外面误认的不会把位置带歪）
    private static func corner(_ cells: [IconGrab.BagCell]) -> (Int, Int) {
        let xs = Set(cells.map(\.x)).sorted(), ys = Set(cells.map(\.y)).sorted()
        var best = (n: -1, x: xs[0], y: ys[0])
        for y in ys { for x in xs {
            let n = cells.filter { place($0, x, y) != nil }.count
            if n > best.n { best = (n, x, y) }
        } }
        return (best.x, best.y)
    }
    private func learnBag(_ cells: [IconGrab.BagCell], _ nums: [QuickSlot.Count]) {
        let (x0, y0) = Self.corner(cells)
        var list = [BagLearn.Slot?](repeating: nil, count: 30)
        for c in cells {
            guard let (q, w) = Self.place(c, x0, y0) else { continue }
            let n = nums.first { $0.x * 2 >= c.x - 4 && $0.x * 2 < c.x + 60 && $0.y * 2 > c.y + 20 && $0.y * 2 < c.y + 66 }?.value
            list[w * 5 + q] = c.empty ? .init([], 0) : .init(c.print, n)
        }
        learn.use(model.name)
        learn.see(list, at: Date())
    }
    private func settleLearn() {
        let was = learn.log, new = learn.settle(at: Date())
        if learn.log != was { trace("bag: 对数 \(learn.log)") }
        if !new.isEmpty { trace("bag: 对数学到 \(new)") }
        apply(learn.takeExtra().map { BagBook.Fix(name: $0.name, n: $0.n) }, "背包")
        saveLearn()
    }
    private func checkBag(_ cells: [IconGrab.BagCell], _ nums: [QuickSlot.Count]) {
        var cats: [String: Int] = [:]
        // 按位置放进 5 列 6 行（没开的格子、被鼠标压住的空着，不错位）
        let (x0, y0) = Self.corner(cells)
        var at: [Int: IconGrab.BagCell] = [:]
        for c in cells { if let (q, w) = Self.place(c, x0, y0) { at[w * 5 + q] = c } }
        let list = (0..<30).map { i -> BagBook.Cell in
            guard let c = at[i] else { return .init(nil, 0) }
            if c.empty { return .init("", 0) }
            guard let n = c.names.first else { return .init(nil, 0) }
            // 没有物品表（公开版）：靠取过的图标认出来的，哪一页看捡的时候提示写的
            if ItemDB.shared.items.isEmpty {
                if let k = learn.tabOf(n) { cats[k, default: 0] += 1 }
                guard let q = nums.first(where: { $0.x * 2 >= c.x - 4 && $0.x * 2 < c.x + 60 && $0.y * 2 > c.y + 20 && $0.y * 2 < c.y + 66 }) else { return .init(nil, 0) }
                return .init(n, q.value)
            }
            guard let e = ItemDB.shared.exact(n) else { return .init(nil, 0) }
            for k in e.cat ?? [] { cats[k, default: 0] += 1 }
            // 装备没有数量；别的没读到数就算没看清
            if e.cat?.contains("Equip") == true { return .init(n, 1) }
            guard let q = nums.first(where: { $0.x * 2 >= c.x - 4 && $0.x * 2 < c.x + 60 && $0.y * 2 > c.y + 20 && $0.y * 2 < c.y + 66 }) else { return .init(nil, 0) }
            return .init(n, q.value)
        }
        guard let cat = cats.max(by: { $0.value < $1.value })?.key else { return }
        apply(bagBook.see(list, cat: cat, at: Date()), "背包")
        if cat == "Etc" { let b = bagBook.seen("Etc"); if b != etcBag { etcBag = b } }
    }
    func questCounts(_ l: [(String, Int)]) {
        if ItemPrints.shared.count == 0 { for (w, n) in l { learn.total(w, n, at: Date()) } }
        for (raw, n) in l { if let e = ItemDB.shared.title(raw)?.entry, !NavDB.shared.hasMob(e.en), let f = bagBook.track(e.en, n, at: Date()) { apply([f], "任务追踪") } }
    }
    private func apply(_ fixes: [BagBook.Fix], _ from: String) {
        for f in fixes {
            model.gotItem(f.name, f.n)
            if let k = currentMap() { hunt.drop(f.name, f.n, map: k); huntDirty = true }
            trace("复核: \(from) \(f.name) \(f.n > 0 ? "补记 +\(f.n)" : "撤回 \(f.n)")")
        }
    }
    private func grabBag(_ locator: GameWindowLocator, _ g: GameWindowInfo, _ r: CGRect) async -> Bool {
        guard r.width > 60, r.height > 60, let img = await withTimeout(2, { await locator.capture(g, rect: r, outputScale: 2) }) else { return false }
        let want = IconStore.shared.wanted, learn = ItemPrints.shared.count == 0 ? self.learn : nil
        // 游戏的手形鼠标会被一起截到：离鼠标近的格子不取
        let o = g.frameTopLeft.origin, m = Coords.toTopLeft(NSEvent.mouseLocation)
        let mx = Int(m.x - o.x - r.minX) * 2, my = Int(m.y - o.y - r.minY) * 2
        let (cells, got, nums) = await Task.detached { () -> ([IconGrab.BagCell], [(String, IconGrab.Icon)], [QuickSlot.Count]) in
            var cells = IconGrab.bag(img, scale: 2)
            if let learn { for i in cells.indices where !cells[i].empty { if let n = learn.name(cells[i].print) { cells[i].names = [n] } } }
            let todo = cells.filter { c in c.names.contains(where: want) && !(mx > c.x - 68 && mx < c.x + 76 && my > c.y - 76 && my < c.y + 76) }
            guard cells.count >= 6 else { return (cells, [], []) }
            // 只在格子那一块找数字
            let x0 = max(0, cells.map(\.x).min()! / 2 * 2 - 4), y0 = max(0, cells.map(\.y).min()! / 2 * 2 - 4)
            let box = CGRect(x: x0, y: y0, width: cells.map(\.x).max()! + 68 - x0, height: cells.map(\.y).max()! + 68 - y0)
            let nums = img.cropping(to: box).map { QuickSlot.read($0, scale: 2) }?.map { QuickSlot.Count(value: $0.value, x: $0.x + x0 / 2, y: $0.y + y0 / 2, color: $0.color) } ?? []
            return (cells, todo.flatMap { c -> [(String, IconGrab.Icon)] in
                guard let i = IconGrab.bagIcon(img, c, counts: nums, scale: 2) else { return [] }
                return c.names.filter(want).map { ($0, i) }
            }, nums)
        }.value
        guard cells.count >= 6 else { return false }
        let log = "\(cells.count) 格 认出 \(cells.filter { !$0.names.isEmpty }.count) 样"
        if log != bagSeenLog { bagSeenLog = log; trace("bag: \(Int(g.frameTopLeft.width))x\(Int(g.frameTopLeft.height)) \(log)，新取 \(got.count) 个图标") }
        IconStore.shared.offerBag(got)
        if cells.count >= 18 { checkBag(cells, nums); if ItemPrints.shared.count == 0 { learnBag(cells, nums) } }
        // 整页（5 列 6 行）都看到才定位置
        if cells.count >= 18 {
            let x = r.minX + CGFloat(cells.map(\.x).min()! / 2), y = r.minY + CGFloat(cells.map(\.y).min()! / 2)
            bagGrid = CGPoint(x: x, y: y); bagSeenAt = Date()
            bagBox = CGRect(x: x + 1, y: y + 219, width: 171, height: 12)      // 金币框就在格子下面，不用整窗识别去找
        }
        if r.width > 400 {
            let x0 = cells.map(\.x).min()!, y0 = cells.map(\.y).min()!
            bagArea = CGRect(x: r.minX + CGFloat(x0 / 2) - 12, y: r.minY + CGFloat(y0 / 2) - 12, width: 205, height: 235)
            UserDefaults.standard.set(NSStringFromRect(bagArea!), forKey: "bagArea")
        }
        return true
    }
    func savePotions() { if let d = try? JSONEncoder().encode(model.potions) { try? d.write(to: potionURL, options: .atomic) } }
    /// 一次 5 个以上、又不是逐像素读到的（x1 可能认成 x13）：先存着，两秒内屏幕上再读到同样的数才算，不然按 1 个
    private var bulk: [(name: String, n: Int, t: Date, map: String?)] = []
    /// 公开版：以前逐像素读到过、或取过图标的东西
    private func seenNames() -> [String] {
        guard ItemDB.shared.items.isEmpty else { return [] }
        // 攻略站的物品名单（知识包）也算见过的：只读到半截、错一两个字母时能补全
        return Array(Set(hunt.maps.values.flatMap(\.drops.keys)).union(IconStore.shared.names).union(ItemNames.all))
    }
    /// 普通识别读到的：同一条提示几帧读成不同样子，会被当成好几条。几秒内同名的只记一次（宁可少记）
    private var looseAt: [String: Date] = [:], spellSeen: [String: (name: String, at: Date)] = [:]
    private func picked(_ text: String) -> (name: String, n: Int)? {
        let exact = glyphSeen[text] != nil, now = Date()
        guard ItemDB.shared.items.isEmpty else {
            guard let i = ItemDB.shared.pickedName(text, exact: exact) else { return nil }
            return big(i, text, exact)
        }
        if exact {
            guard let i = ItemDB.shared.pickedName(text, exact: true, known: Array(Set(hunt.maps.values.flatMap(\.drops.keys)).union(IconStore.shared.names))) else { return nil }
            // 刚才这一条已经按认花的记过
            if let t = looseAt[i.name], now.timeIntervalSince(t) < 4 { looseAt[i.name] = nil; return nil }
            exactAt[i.name] = now
            return i
        }
        let known = seenNames()
        var hit = ItemDB.shared.pickedName(text, exact: false, known: known) ?? ItemDB.looseEarned(text, known: known)
        // 没见过的名字：两次读到同样的、而且拼得对
        if hit == nil, let s = ItemDB.spelled(text) {
            let old = spellSeen[s.key]
            let name = s.name.isEmpty ? old?.name ?? "" : s.name
            spellSeen[s.key] = (name, now)
            if old != nil, !name.isEmpty { hit = (name, s.n) }
        }
        guard let i = hit else { return nil }
        for t in [looseAt[i.name], exactAt[i.name]] { if let t, now.timeIntervalSince(t) < 4 { return nil } }
        looseAt[i.name] = now
        return big(i, text, false)
    }
    private var exactAt: [String: Date] = [:]
    /// 一次 5 个以上又没逐像素读准：再看一眼
    private func big(_ i: (name: String, n: Int), _ text: String, _ exact: Bool) -> (name: String, n: Int)? {
        guard !exact, i.n >= 5 else { return i }
        guard !bulk.contains(where: { $0.name == i.name && $0.n == i.n }) else { return nil }
        bulk.append((i.name, i.n, Date(), currentMap())); trace("hunt: 一次 \(i.n) 个，再看一眼 \(text)")
        return nil
    }
    private func settleBulk(_ seen: [PickupTracker.Line]) {
        guard !bulk.isEmpty else { return }
        let now = Date()
        bulk.removeAll { b in
            let again = now.timeIntervalSince(b.t) > 0.3 && seen.contains { l in HuntLog.item(l.text).map { $0.n == b.n && ItemDB.shared.pickedName(l.text, exact: false, known: [b.name])?.name == b.name } ?? false }
            guard again || now.timeIntervalSince(b.t) > 2.5 else { return false }
            let n = bagBook.pick(b.name, again ? b.n : 1, at: now)
            if n > 0 { if let k = b.map { hunt.drop(b.name, n, map: k); huntDirty = true }; model.gotItem(b.name, n); notePick(b.name, n) }
            trace("hunt: \(b.name) 记 \(n)")
            return true
        }
    }
    private func huntPickup(_ fresh: [PickupTracker.Line], mesos: Int) {
        let at = currentMap()
        guard let k = at else {
            for l in fresh where !l.text.isEmpty {
                if let v = HuntLog.killExp(l.text) { if kills.accept(v) { model.killed(); bagBook.kill(at: Date()) } }
                else if let i = picked(l.text) { let n = bagBook.pick(i.name, i.n, at: Date()); if n > 0 { model.gotItem(i.name, n); notePick(i.name, n, l.text) } }
            }
            return
        }
        let now = Date()
        if mesos > 0 { hunt.mesos(mesos, map: k); huntDirty = true }
        for l in fresh where !l.text.isEmpty {
            if let v = HuntLog.killExp(l.text) { if kills.accept(v) { bagBook.kill(at: now); hunt.kill(1, map: k, at: now); model.killed(); huntDirty = true } }
            // 只记物品表里有的（认花的不要）；材料、药水、装备、卷轴都算
            else if let i = picked(l.text) { let n = bagBook.pick(i.name, i.n, at: now); if n > 0 { hunt.drop(i.name, n, map: k); model.gotItem(i.name, n); notePick(i.name, n, l.text); huntDirty = true }; trace("hunt: 捡到 \(i.name) ×\(i.n) 在 \(k)") }
            else if l.key.hasPrefix("o") { trace("hunt: 没认出的提示「\(l.text)」") }
        }
    }
    init() {
        if let d = try? Data(contentsOf: bookURL), var b = try? JSONDecoder().decode(PriceBook.self, from: d) { if ItemDB.shared.items.isEmpty { b.clean() }; book = b }
        IconStore.shared.clean()
        load()
    }

    func save() {
        model.store.prune(now: Date())
        if let d = try? JSONEncoder().encode(model.store) { try? d.write(to: fileURL, options: .atomic) }
        model.mesoStore.prune(now: Date())
        if let d = try? JSONEncoder().encode(model.mesoStore) { try? d.write(to: mesoURL, options: .atomic) }
        saveLedger(); saveLearn()
        if let d = try? JSONEncoder().encode(model.recent) { try? d.write(to: fileURL.deletingLastPathComponent().appendingPathComponent("recent.json"), options: .atomic) }
        model.potions.prune(now: Date()); savePotions()
        if huntDirty, let d = try? JSONEncoder().encode(hunt) { try? d.write(to: huntURL, options: .atomic); huntDirty = false }
        lastSave = Date()
    }
    private func saveLedger() {
        if let d = try? JSONEncoder().encode(ledger) { UserDefaults.standard.set(d, forKey: key("mesoLedger")) }
    }

    /// 金币：每 0.8 秒看一次背包金币框（位置记住后只认那一小条）
    func mesoTick(locator: GameWindowLocator, g: GameWindowInfo) async {
        guard (names.candidate == nil || model.name.isEmpty), !mesoBusy else { return }
        mesoBusy = true; defer { mesoBusy = false }
        guard let v = await readBag(locator: locator, g: g) else { return }
        var shot = v.1
        _ = mesoTracker.feed(v.0)
        // 新数字要看到两次才算：马上再读（背包开一下就关也来得及）
        for _ in 0..<3 where mesoTracker.confirmed != v.0 {
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard let again = await readBag(locator: locator, g: g) else { continue }
            guard again.0 == v.0 else { return }      // 正在变，等下一轮
            shot = again.1
            _ = mesoTracker.feed(again.0)
        }
        guard mesoTracker.confirmed == v.0 else { return }
        let was = ledger.bagTime, cx = MesoContext.pick([shopAt, stallAt, travelAt], since: was), shop = cx[0], stall = cx[1]
        let o0 = (model.mesoStore.other ?? [:]).values.reduce(0, +), l0 = model.mesoStore.unknownOut
        let d = ledger.confirm(v.0, at: shot, shop: shop, stall: stall, travel: cx[2], store: &model.mesoStore)
        let u = (model.mesoStore.other ?? [:]).values.reduce(0, +) - o0 - (model.mesoStore.unknownOut - l0)
        // 刚和 NPC 说过话，多出来的正好是这里某个任务的奖励（聊天那句没认到）
        if u > 0, Date().timeIntervalSince(npcAt) < 180, let m = mapNow(), let r = NavDB.shared.reward(in: m, atMost: u), model.mesoStore.moveToQuest(r, at: shot) {
            trace("meso: \(u) 里 \(r) 是任务奖励")
            if u > r { noteUnknown(u - r, since: was) }
        } else if u != 0 { noteUnknown(u, since: was) }
        if d != 0 || model.mesos != v.0 { trace("meso: 背包 \(v.0)，校正 \(d)") }
        model.mesos = ledger.expected; model.mesoSeen = Date()
        UserDefaults.standard.set(v.0, forKey: key("lastMesos"))
        if d != 0 { save() } else { saveLedger() }
    }

    /// 读一次背包金币框，返回数字和截图时间。知道框在哪就只看那一条（每次都看）；不知道或没看到，每 1.5 秒找一次整窗
    private func readBag(locator: GameWindowLocator, g: GameWindowInfo) async -> (Int, Date)? {
        let client = self.client, win = g.frameTopLeft.size
        if let b = bagBox {
            let shot = Date()
            let r = b.insetBy(dx: -8, dy: -6).intersection(CGRect(origin: .zero, size: win))
            if r.width > 60, let img = await withTimeout(2, { await locator.capture(g, rect: r, outputScale: 2) }),
               let lines = await withTimeout(3, { client.recognize(img) }),
               let f = await Task.detached(operation: { MesoReader.locate(lines: lines, in: img, scale: 2) }).value { return (f.value, shot) }
        }
        guard Date().timeIntervalSince(lastBagScan) >= 1.5 else { return nil }
        lastBagScan = Date()
        let shot = Date()
        guard let img = await withTimeout(3, { await locator.capture(g, rect: CGRect(origin: .zero, size: win), outputScale: 1) }),
              let lines = await withTimeout(5, { client.recognize(img) }) else { return nil }
        guard let f = await Task.detached(operation: { MesoReader.locate(lines: lines, in: img, scale: 1) }).value else { return nil }
        bagBox = f.box
        return (f.value, shot)
    }

    /// 捡钱提示：每 0.7 秒识别画面右下方，“You have gained mesos (+10)” 新出现一条就记一笔
    func pickupTick(locator: GameWindowLocator, g: GameWindowInfo) async {
        guard (names.candidate == nil || model.name.isEmpty), !pickupBusy else { return }
        pickupBusy = true; defer { pickupBusy = false }
        let win = g.frameTopLeft
        let client = self.client
        // 提示贴着画面右边、快捷键栏上面，最多七八行；只截这一块（小图只认一遍，快）
        let area = CGRect(x: win.width - 260, y: win.height - 320, width: 258, height: 175).intersection(CGRect(origin: .zero, size: win.size))
        guard let img = await withTimeout(2, { await locator.capture(g, rect: area, outputScale: 2) }) else { return }
        func toLines(_ l: [OCRLine]) -> [PickupTracker.Line] { l.compactMap { PickupTracker.line($0.text, y: $0.minY * Double(area.height)) } }
        guard let clean = await Task.detached(operation: { PickupTracker.isolate(img) }).value,
              let a = await withTimeout(3, { client.recognize(clean) }) else { return }
        // 字形读到的排最前面
        let exact = await Task.detached(operation: { PickupTracker.glyphs(img, scale: 2) }).value
        // 提示先记待定、下一帧才算新的：字形读到的文字留几秒
        let seenAt = Date(); glyphSeen = glyphSeen.filter { seenAt.timeIntervalSince($0.value) < 10 }
        for l in exact { glyphSeen[l.text] = seenAt }
        for l in exact where l.text != glyphLast { trace("字形: \(l.text)"); glyphLast = l.text }
        var found = PickupTracker.combine(exact.compactMap { PickupTracker.line($0.text, y: Double($0.base) - 10) }, toLines(a))
        // 有提示行、或什么都没认出来时，原图再认一遍补上变淡的行
        if let b = await withTimeout(3, { client.recognize(img) }) { found = PickupTracker.combine(found, toLines(b)) }
        settleBulk(found)
        let new = pickup.feed(found).filter { $0 < 10_000_000 }
        huntPickup(pickup.fresh, mesos: new.reduce(0, +))
        guard !new.isEmpty else { return }
        let now = Date()
        for v in new { ledger.pick(v, at: now, store: &model.mesoStore) }
        if let e = ledger.expected { model.mesos = e }
        else if let m = model.mesos { model.mesos = m + new.reduce(0, +) }   // 还没看过背包：先接着上次的数往上加
        if let m = model.mesos { UserDefaults.standard.set(m, forKey: key("lastMesos")) }     // 捡的也存，重启不丢
        saveLedger()
        trace("meso: 捡钱 \(new)")
    }

    /// 每 6 秒一次（由 AppController 在游戏可见、没暂停时调用）
    func tick(locator: GameWindowLocator, g: GameWindowInfo) async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        let client = self.client
        let win = g.frameTopLeft
        // 状态栏在窗口最下面（各分辨率、窗口模式都一样）；截 50 点高、整个宽度
        // 状态栏是中间 800 点那段：窗口更宽时只截它，整条太宽会漏认右半边
        let barW = min(800, win.width)
        let strip = CGRect(x: ((win.width - barW) / 2).rounded(), y: max(0, win.height - 50), width: barW, height: 50)
        guard let img = await withTimeout(3, { await locator.capture(g, rect: strip) }),
              let lines = await withTimeout(5, { client.recognize(img) }) else { return }
        let text = lines.sorted { $0.minX < $1.minX }.map(\.text).joined(separator: " ")
        let now = Date()
        // 角色名：换角色自动切到那个角色的记录；正在核对是不是换了人的时候先不记
        let exactName = await Task.detached(operation: { CharName.read(img, scale: img.height / 50) }).value
        if let n = names.feed(lines, exact: exactName, current: model.name, known: Self.knownNames) { switchTo(n); return }
        if names.candidate != nil, !model.name.isEmpty { return }
        // 等级：按橙色格子和字形认；文字识别只在位数和格子数一样时参考（12 会漏成 2、27 会认成 22）
        let tiles = await Task.detached(operation: { LevelDigits.read(img, scale: max(1, img.height / 50)) }).value
        let ocrLevel = text.range(of: "LV\\.?\\s*([0-9|]{1,4})", options: [.regularExpression, .caseInsensitive]).map { text[$0].filter(\.isNumber) }
            .flatMap { d in tiles.map { $0.count == d.count } ?? false ? Int(d) : nil }.flatMap { (1...250).contains($0) ? $0 : nil }
        if let t = tiles, let v = t.value ?? ocrLevel {
            levelSeen = levelSeen?.0 == v ? (v, levelSeen!.1 + 1) : (v, 1)
            // 核实过的字形：连着两次一样就算，也能改掉以前认错的。推的字形、靠文字识别的：不知道等级，或现在的位数明显不对才用
            let wrong = model.level.map { String($0).count != t.count } ?? true
            if model.level != v, t.sure ? levelSeen!.1 >= 2 : wrong && levelSeen!.1 >= 3 { trace("exp: 等级 \(model.level ?? 0) → \(v)\(t.sure ? "" : "（没全核实）")"); model.level = v }
        }
        // 职业：状态栏左边两行里上面那行（下面是角色名）；连着两次一样才换
        if let j = lines.filter({ $0.minX < 0.3 && ($0.minY + $0.maxY) / 2 < 0.64 }).compactMap({ JobName.match($0.text) }).first {
            if j == jobSeen { model.job = j }
            jobSeen = j
        }
        let cands = ExpReading.candidates(text)
        guard !cands.isEmpty else { misses += 1; if misses % 10 == 1 { trace("exp: 没读到经验「\(text)」") }; return }
        let before = tracker.lastTime
        let ev = tracker.feed(cands, at: now)
        if case .gain(let v) = ev, let pt = before, now.timeIntervalSince(pt) > 60 { model.store.recordSpan(v, from: pt, to: now) }
        else { model.store.record(ev, at: now) }
        if case .levelUp = ev, let l = model.level { model.level = l + 1 }
        switch ev {
        case .gain(let g), .levelUp(let g):
            if let k = currentMap() { hunt.exp(g, map: k, at: now); huntDirty = true }
        default: break
        }
        if ev != .rejected {
            // “差多少升级”要等升级所需锁定（核对过）才显示
            if tracker.need != nil, let l = tracker.last { model.reading = l; model.need = tracker.need }
            // 刚开始、经验还没变过：先显示读到的数（不算“差多少”、不计入统计）
            else if tracker.need == nil, let l = tracker.display { model.reading = l }
            if let r = tracker.range { UserDefaults.standard.set([r.lowerBound, r.upperBound], forKey: key("expNeed")) }
            if let l = tracker.last, let t = tracker.lastTime { UserDefaults.standard.set([Double(l.exp), l.pct, t.timeIntervalSince1970], forKey: key("expLast")) }
            model.lastSeen = now
        }
        reads += 1
        if ev != .none || reads <= 2 || ProcessInfo.processInfo.environment["CT_EXP_LOG"] != nil { trace("exp: 「\(text.suffix(40))」\(ev) 读数=\(tracker.last.map { "\($0.exp) \($0.pct)%" } ?? "-") 升级所需=\(tracker.need.map { Int($0) } ?? -1)") }
        if now.timeIntervalSince(lastSave) > 60 { save() }
    }

}

// MARK: 界面

private func fmt(_ n: Int) -> String {
    let f = NumberFormatter(); f.numberStyle = .decimal; f.groupingSeparator = ","
    return f.string(from: NSNumber(value: n)) ?? "\(n)"
}

private func fmtDuration(_ s: Double) -> String {
    guard s.isFinite, s > 0 else { return "—" }
    let m = Int(s / 60)
    if m < 60 { return "约 \(max(1, m)) 分钟" }
    if m < 48 * 60 { return "约 \(m / 60) 小时 \(m % 60) 分" }
    return "约 \(m / 1440) 天"
}

struct MinutePoint: Identifiable {
    let id: Int          // 分钟
    let date: Date
    let exp: Int
    let segment: Int     // 连续有数据的一段（中间没数据就断开，线不连过去）
}

// MARK: 小组件样式（放在侧边面板顶部，冒险岛窗口样式的内板）

struct WidgetCard<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: MapleCardView.strip)
                .background(Color(nsColor: Maple.strip))
            VStack(alignment: .leading, spacing: 5) { content }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(Color.mText)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color.mEdge, lineWidth: 1))
    }
}

enum StatMetric: String { case exp, meso }

enum ExpPeriod: String, CaseIterable {
    case hour = "这一小时", today = "今天", week = "本周", month = "本月"
    /// 页签上的字（rawValue 是存设置用的，别改）
    var title: String { self == .hour ? "每小时" : rawValue }
}

private func barUnit(_ m: Int) -> Calendar.Component { m == 1 ? .minute : m == 60 ? .hour : .day }

/// 横轴刻度：这一小时每 15 分钟、今天每 6 小时（含 24:00）、本周和本月每天
private func axisDates(_ from: Date, _ to: Date, _ unit: Int) -> [Date] {
    var c = Calendar(identifier: .gregorian); c.timeZone = .current
    var out: [Date] = []
    switch unit {
    case 1:
        var d = c.date(bySetting: .second, value: 0, of: from)!
        while c.component(.minute, from: d) % 15 != 0 { d = d.addingTimeInterval(60) }
        while d < to { out.append(d); d = d.addingTimeInterval(900) }
        // 太靠边的放不下
        out = out.filter { $0.timeIntervalSince(from) >= 180 && to.timeIntervalSince($0) >= 240 }
    case 60:
        for h in [0, 6, 12, 18] { out.append(c.date(bySettingHour: h, minute: 0, second: 0, of: from)!) }
        out.append(to)
    default:
        let days = Int(to.timeIntervalSince(from) / 86400 + 0.5)
        // 标签放在当天正中（柱子正下方）
        for k in 0..<days { out.append(c.date(byAdding: .day, value: k, to: from)!.addingTimeInterval(43200)) }
    }
    return out
}

private func axisLabel(_ d: Date, _ unit: Int, month: Bool, now: Date, end: Date) -> String {
    var c = Calendar(identifier: .gregorian); c.timeZone = .current
    let p = c.dateComponents([.month, .day, .hour, .minute, .weekday], from: d)
    switch unit {
    case 1: return String(format: "%02d:%02d", p.hour!, p.minute!)
    case 60: return d == end ? "24:00" : String(format: "%02d:00", p.hour!)
    default:
        if month { return "\(p.day!)" }       // 每天都标，只写几号
        if c.isDate(d, inSameDayAs: now) { return "今天" }
        let days = ["日", "一", "二", "三", "四", "五", "六"]
        return "\(p.month!)/\(p.day!) 周\(days[p.weekday! - 1])"
    }
}

/// 角色卡：照游戏状态栏的样子（深色底、LV. 橙色数字块、职业在名字上面、EXP 凹槽条），全部代码画
struct RoleCard: View {
    let name: String, level: Int?, job: String?, reading: ExpReading?, need: Double?, eta: String?
    var body: some View {
        // 一整行：等级牌 | 职业、名字 | 经验文字 + 经验条
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                Text("LV.").font(.system(size: 14, weight: .black)).italic().foregroundStyle(.white)
                HStack(spacing: 2) {
                    if let l = level { ForEach(Array(String(l).enumerated()), id: \.offset) { _, c in DigitTile(digit: c.wholeNumberValue ?? 0) } }
                    else { Text("—").font(.system(size: 16, weight: .bold)).foregroundStyle(.white.opacity(0.7)) }
                }
            }
            .padding(.horizontal, 7).frame(height: 36)
            .background(RoundedRectangle(cornerRadius: 5).fill(LinearGradient(colors: [Color(white: 0.24), Color(white: 0.10)], startPoint: .top, endPoint: .bottom)))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.black.opacity(0.5), lineWidth: 1))
            .fixedSize()
            VStack(alignment: .leading, spacing: 1) {
                Text(job.map { JobName.zh[$0] ?? $0 } ?? "职业识别中").font(.system(size: 11, weight: .medium))
                    .foregroundStyle(job == nil ? .white.opacity(0.5) : Color(nsColor: Maple.rgb(255, 221, 120)))
                Text(name.isEmpty ? "未设置角色名" : name).font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
            }
            .lineLimit(1).minimumScaleFactor(0.7)
            .shadow(color: .black.opacity(0.6), radius: 0, x: 1, y: 1)
            .frame(minWidth: 56, maxWidth: 88, alignment: .leading).fixedSize(horizontal: true, vertical: false)
            VStack(spacing: 3) {
                if let r = reading {
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        // 和游戏一样：只有方括号是黄绿色，数字是白的
                        (Text("EXP. ").fontWeight(.black).italic() + Text(fmt(r.exp)) + Text(" [").foregroundStyle(Color(nsColor: Maple.rgb(200, 226, 20)))
                            + Text(String(format: "%.2f%%", r.pct)) + Text("]").foregroundStyle(Color(nsColor: Maple.rgb(200, 226, 20))))
                            .foregroundStyle(.white)
                        Spacer(minLength: 4)
                        if let n = need {
                            (Text("差 ") + Text(fmt(max(0, Int(n) - r.exp))).fontWeight(.heavy).foregroundStyle(Color(nsColor: Maple.rgb(255, 170, 40)))
                                + Text(eta.map { " · \($0)" } ?? "")).foregroundStyle(.white.opacity(0.75))
                        }
                    }
                    .font(.system(size: 11, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.6)
                    .help("还差多少经验升级" + (eta.map { "；按最近 15 分钟的速度，\($0)后升级" } ?? ""))
                    ExpBar(pct: r.pct)
                } else {
                    Text("还没读到经验").help("游戏底部的状态栏要露出来").font(.system(size: 11)).foregroundStyle(.white.opacity(0.7)).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 7).padding(.vertical, 6)
        .background(LinearGradient(stops: [.init(color: Color(nsColor: Maple.rgb(118, 124, 130)), location: 0), .init(color: Color(nsColor: Maple.rgb(62, 72, 82)), location: 0.16),
                                           .init(color: Color(nsColor: Maple.rgb(46, 54, 62)), location: 1)], startPoint: .top, endPoint: .bottom))
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color(nsColor: Maple.rgb(196, 212, 222)), lineWidth: 1.5))
    }
}

/// 橙色方块里的像素数字（5×7 点阵，自己画的）
struct DigitTile: View {
    let digit: Int
    private static let glyphs: [[String]] = [
        ["01110", "10001", "10011", "10101", "11001", "10001", "01110"], ["00100", "01100", "00100", "00100", "00100", "00100", "01110"],
        ["01110", "10001", "00001", "00110", "01000", "10000", "11111"], ["01110", "10001", "00001", "00110", "00001", "10001", "01110"],
        ["00010", "00110", "01010", "10010", "11111", "00010", "00010"], ["11111", "10000", "11110", "00001", "00001", "10001", "01110"],
        ["00110", "01000", "10000", "11110", "10001", "10001", "01110"], ["11111", "00001", "00010", "00100", "00100", "01000", "01000"],
        ["01110", "10001", "10001", "01110", "10001", "10001", "01110"], ["01110", "10001", "10001", "01111", "00001", "00010", "01100"]]
    var body: some View {
        Canvas { c, size in
            let box = CGRect(origin: .zero, size: size)
            c.fill(Path(roundedRect: box, cornerRadius: 2.5), with: .linearGradient(Gradient(colors: [Color(nsColor: Maple.rgb(255, 160, 30)), Color(nsColor: Maple.rgb(255, 106, 10))]), startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            c.stroke(Path(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 2), with: .color(Color(nsColor: Maple.rgb(190, 70, 0))), lineWidth: 1)
            let p: CGFloat = 2, x0 = (size.width - 5 * p) / 2, y0 = (size.height - 7 * p) / 2
            for pass in 0..<2 {          // 先画阴影，再画白字
                for (y, row) in Self.glyphs[max(0, min(9, digit))].enumerated() { for (x, b) in row.enumerated() where b == "1" {
                    let o: CGFloat = pass == 0 ? 1 : 0
                    c.fill(Path(CGRect(x: x0 + CGFloat(x) * p + o, y: y0 + CGFloat(y) * p + o, width: p, height: p)), with: .color(pass == 0 ? Color(nsColor: Maple.rgb(170, 60, 0)) : .white))
                } }
            }
        }
        .frame(width: 18, height: 22)
    }
}

struct ExpWidgets: View {
    @ObservedObject var model: ExpModel
    /// 面板矮、放不下时收紧：柱状图高度（一直有图）、掉落最多几排（0 = 不列）
    var chartHeight: CGFloat = 76
    var lootRows = 3
    /// 定时刷新用；算的时候一律用真正的现在（展开、收起换了一份界面时，存着的时间可能是旧的）
    @State private var tick = Date()
    private var now: Date { max(tick, Date()) }
    @AppStorage("incomeFold") private var fold = false
    @AppStorage("lootOpen") private var lootOpen = false
    @AppStorage("incomeDetail") private var detail = false
    @AppStorage("expPeriod") private var period: ExpPeriod = .hour
    @AppStorage("statMetric") private var metric: StatMetric = .exp
    private let timer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()
    private var cal: Calendar { var c = Calendar(identifier: .gregorian); c.firstWeekday = 2; c.timeZone = .current; return c }

    /// 选中时间段的柱子：这一小时 60 根（每分钟）、今天 24 根（每小时）、本周 7 根、本月按天
    private func buckets(_ p: ExpPeriod) -> (Date, Date, Int) {
        let from: Date, to: Date, unit: Int
        switch p {
        case .hour: from = Date(timeIntervalSince1970: Double(ExpStore.minute(now) - 59) * 60); to = from.addingTimeInterval(3600); unit = 1
        case .today: from = cal.startOfDay(for: now); to = cal.date(byAdding: .day, value: 1, to: from)!; unit = 60
        case .week: from = cal.dateInterval(of: .weekOfYear, for: now)!.start; to = cal.date(byAdding: .day, value: 7, to: from)!; unit = 1440
        case .month: let m = cal.dateInterval(of: .month, for: now)!; from = m.start; to = m.end; unit = 1440
        }
        return (from, to, unit)
    }

    var body: some View {
        let name = model.name
        // 升级还要多久：按最近 15 分钟的速度（在玩的时间不到 3 分钟不估）
        let rate = hourly(model.store.minutes, now.addingTimeInterval(-15 * 60), now.addingTimeInterval(60), atLeast: 3)
        VStack(spacing: 5) {
            RoleCard(name: name, level: model.level, job: model.job, reading: model.reading, need: model.need,
                     eta: rate > 0 ? model.need.flatMap { n in model.reading.map { fmtDuration(max(0, n - Double($0.exp)) / rate * 3600) } } : nil)
            statsCard
        }
        .padding(.horizontal, 8).padding(.top, 4)
        .onReceive(timer) { tick = $0 }
    }

    /// 收益卡：上面两块（经验、金币）并排显示所选时间段的数字，点哪块下面柱状图就显示哪块；再下面选时间段
    @ViewBuilder private var statsCard: some View {
        let (from, to) = range(period)
        let (bFrom, bTo, unitMin) = buckets(period)
        let expSum = model.store.total(from: from, to: to)
        let gain = sum(model.mesoStore.minutes, from, to), spend = sum(model.mesoStore.losses, from, to)
        WidgetCard(title: fold ? "收益 · \(period.title) ▸" : "收益 ▾") {
            // 从上往下：选时间 → 两个大数 → 点哪个就只展开哪个
            if !fold { MapleTabs(items: ExpPeriod.allCases.map { ($0, $0.title) }, selection: $period) }
            HStack(spacing: 8) {
                tile(.exp) {
                    ExpIcon().frame(width: 22, height: 22)
                    tileText("经验", "+\(fmt(expSum.exp))") {
                        Text(expRate(from, to) ?? (expSum.exp > 0 ? "打怪不到 3 分钟" : "没有数据"))
                    }
                }
                tile(.meso) {
                    CoinIcon().frame(width: 22, height: 22)
                    tileText("金币收益", "\(gain < spend ? "-" : "+")\(fmt(abs(gain - spend)))") {
                        // 旧账分不开来源：只能说“约”
                        let clean = hourly(model.mesoStore.hunted, max(from, Self.ledgerSince), to), h = clean > 0 ? clean : hourly(model.mesoStore.hunted, from, to)
                        Text(h > 0 ? "\(clean > 0 ? "" : "约")每小时 \(fmt(Int(h)))" : gain > 0 || spend > 0 ? "打怪不到 3 分钟" : "没有数据").help("打怪捡的金币 ÷ 打怪的时间；卖东西的钱不算")
                    }
                }
            }
            if metric == .meso, !fold {
                // 左边钱从哪来、右边花到哪去，正好对着看
                let sIn = sum(model.mesoStore.stallIn ?? [:], from, to), sOut = sum(model.mesoStore.stallOut ?? [:], from, to)
                let sold = sum(model.mesoStore.sold ?? [:], from, to), other = sum(model.mesoStore.other ?? [:], from, to), shop = sum(model.mesoStore.bought ?? [:], from, to)
                // 开始分类以前的旧账：照实写没分类
                let since = Self.ledgerSince, oldIn = from < since ? sum(model.mesoStore.minutes, from, min(to, since)) : 0, oldOut = from < since ? sum(model.mesoStore.losses, from, min(to, since)) : 0
                let q = sum(model.mesoStore.quest ?? [:], from, to), ride = sum(model.mesoStore.travel ?? [:], from, to)
                HStack(alignment: .top, spacing: 8) {
                    flow("收入", gain, [("打怪捡的", max(0, gain - sold - other - sIn - q - oldIn)), ("卖给 NPC", sold), ("摆摊卖出", sIn), ("任务奖励", q)], [(other > 0 ? oldIn > 0 ? "没认出来和旧账" : "没认出来" : "旧账", other + oldIn)], "+", .incomeBar)
                    flow("支出", spend, [("NPC 商店", shop), ("逛摊买入", sOut), ("坐车坐船", ride)], [(oldOut == 0 ? "没认出来" : spend - shop - sOut - ride - oldOut > 0 ? "没认出来和旧账" : "旧账", max(oldOut, spend - shop - sOut - ride))], "-", .spendBar)
                }
                .contentShape(Rectangle()).onTapGesture { detail.toggle() }
                .help("点一下\(detail ? "收起" : "看")明细。没认出来：钱变了但看不出原因，比如和玩家交易。旧账：分类功能以前的，没记来源，过期就不显示了")
            }
            // 掉落（每小时）：图下面一条背包格，点右边展开；收益收起时也在
            let loot = (fold || period == .hour) && model.recent.hasAny
            // 图一直在，高度跟着面板；刻度是整数，按这段时间的多少自动换
            let up = bars(metric == .exp ? model.store.minutes : model.mesoStore.minutes, bFrom, bTo, unitMin)
            let down = metric == .exp ? [] : bars(model.mesoStore.losses, bFrom, bTo, unitMin)
            if !fold { BarsChart(up: up, down: down, from: bFrom, to: bTo, unit: unitMin, month: period == .month, now: now, color: metric == .exp ? .expBar : .incomeBar, height: chartHeight, calendar: cal)
                .id("\(period.rawValue)\(metric.rawValue)") }
            if loot { LootStrip(model: model, now: now, open: $lootOpen, height: chartHeight) }
        }
        .overlay(alignment: .top) {
            Color.clear.frame(height: MapleCardView.strip).contentShape(Rectangle()).onTapGesture { fold.toggle() }.help(fold ? "点一下展开" : "点一下收起，给聊天腾地方")
        }
        // 身上的余额和时间段无关：放标题条右边
        .overlay(alignment: .topTrailing) {
            Text(model.mesos.map { "身上金币 \(fmt($0))" } ?? "打开背包读身上金币").font(.system(size: 11, weight: .semibold)).monospacedDigit()
                .foregroundStyle(.white).frame(height: MapleCardView.strip).padding(.trailing, 9)
        }
    }

    private func tileText<C: View>(_ label: String, _ big: String, @ViewBuilder _ small: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // 窄面板放不下就只写数字（前面有图标），数字要写全
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(label).font(.system(size: 10)).foregroundStyle(Color.mSub)
                    Text(big).font(.system(size: 15, weight: .heavy, design: .rounded))
                }.fixedSize()
                Text(big).font(.system(size: 15, weight: .heavy, design: .rounded)).fixedSize()
                Text(big).font(.system(size: 12, weight: .heavy, design: .rounded))
            }
            .help(label)
            HStack(spacing: 6) { small() }.font(.system(size: 10)).foregroundStyle(Color.mSub)
        }
        .lineLimit(1).minimumScaleFactor(0.7)
    }

    /// 从什么时候开始给收支分类（第一次打开这一版的整分钟）
    private static let ledgerSince: Date = {
        let ud = UserDefaults.standard
        if ud.object(forKey: "ledgerSince") == nil { ud.set(Double(ExpStore.minute(Date())) * 60, forKey: "ledgerSince") }
        return Date(timeIntervalSince1970: ud.double(forKey: "ledgerSince"))
    }()
    /// 固定的几类一直在（没有就淡淡的 0），extra 有才显示
    private func flow(_ title: String, _ total: Int, _ rows: [(String, Int)], _ extra: [(String, Int)], _ sign: String, _ color: Color) -> some View {
        VStack(spacing: 1) {
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
                let num = total > 0 ? "\(sign)\(fmt(total))" : "0"
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 5) { Text(title + (detail ? " ▾" : " ▸")).fixedSize(); Spacer(minLength: 4); Text(num).fixedSize() }
                    HStack(spacing: 2) { Text(title).fixedSize(); Spacer(minLength: 2); Text(num).minimumScaleFactor(0.6) }
                }.monospacedDigit()
            }.font(.system(size: 11, weight: .bold)).foregroundStyle(Color.mText).lineLimit(1)
            if detail { Rectangle().fill(color.opacity(0.5)).frame(height: 1)
            ForEach(rows + extra.filter { $0.1 > 0 }, id: \.0) { r in
                HStack { Text(r.0).foregroundStyle(Color.mSub); Spacer(minLength: 4); Text(r.1 > 0 ? fmt(r.1) : "0").monospacedDigit().foregroundStyle(r.1 > 0 ? Color.mText : Color.mSub.opacity(0.6)) }.font(.system(size: 10)).lineLimit(1)
            } }
        }.padding(.horizontal, 3).frame(maxWidth: .infinity, alignment: .top)
    }

    /// 上面可点的一块（选中时亮一些、带边框）
    private func tile<C: View>(_ m: StatMetric, @ViewBuilder _ c: () -> C) -> some View {
        HStack(spacing: 7) { c() }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 40, maxHeight: 40, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 3).fill(metric == m ? Color(nsColor: Maple.rgb(255, 246, 214)) : Color(nsColor: Maple.bag)))
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color(nsColor: metric == m ? Maple.orange : Maple.slotEdge), lineWidth: metric == m ? 1.5 : 1))
            .contentShape(Rectangle())
            .onTapGesture { metric = m }
    }

    /// 每小时多少 = 这段时间的总数 ÷ 在玩的分钟数 × 60（在玩 = 有经验或金币进账的分钟和中间的短空当，逛店、挂机不算）
    private func hourly(_ d: [Int: Int], _ from: Date, _ to: Date, atLeast: Double = 3) -> Double {
        let keys = ExpStore.playing([model.store.minutes, model.mesoStore.minutes])
        let mins = ExpStore.activeMinutes(keys, from: from, to: to, now: now)
        return mins >= atLeast ? Double(sum(d, from, to)) / mins * 60 : 0
    }

    private func expRate(_ from: Date, _ to: Date) -> String? {
        let h = hourly(model.store.minutes, from, to)
        return h > 0 ? "每小时 \(fmt(Int(h)))" : nil
    }

    private func sum(_ d: [Int: Int], _ from: Date, _ to: Date) -> Int {
        let a = ExpStore.minute(from), b = ExpStore.minute(to)
        return d.filter { $0.key >= a && $0.key < b }.values.reduce(0, +)
    }

    /// 按格子累加（每根柱子从本地整点 / 零点开始）
    private func bars(_ d: [Int: Int], _ from: Date, _ to: Date, _ unit: Int) -> [MinutePoint] {
        ExpStore.grouped(d, from: from, to: to, by: barUnit(unit), calendar: cal)
            .map { MinutePoint(id: ExpStore.minute($0.0), date: $0.0, exp: $0.1, segment: 0) }
    }

    private func range(_ p: ExpPeriod) -> (Date, Date) {
        let to = now.addingTimeInterval(60)
        switch p {
        case .hour: return (now.addingTimeInterval(-3600), to)
        case .today: return (cal.startOfDay(for: now), to)
        case .week: return (cal.dateInterval(of: .weekOfYear, for: now)!.start, to)
        case .month: return (cal.dateInterval(of: .month, for: now)!.start, to)
        }
    }

    private func stat(_ t: String, _ v: Int) -> some View {
        VStack(spacing: 1) {
            Text(t).font(.system(size: 10)).foregroundStyle(Color.mSub)
            Text(fmtShort(v)).font(.system(size: 12, weight: .medium, design: .monospaced))
        }.frame(maxWidth: .infinity)
    }
}

extension Color {
    // 验算过：白底对比够，色弱也能分清（收、支还分上下）
    static let expBar = Color(nsColor: Maple.rgb(47, 127, 193)), incomeBar = Color(nsColor: Maple.rgb(42, 157, 124)), spendBar = Color(nsColor: Maple.rgb(168, 67, 58))
}

/// 柱状图：竖轴整数刻度，鼠标放上去看那一格的数；支出往下画
struct BarsChart: View {
    let up: [MinutePoint], down: [MinutePoint]
    let from: Date, to: Date, unit: Int, month: Bool, now: Date, color: Color, height: CGFloat, calendar: Calendar
    @State private var hover: Date?

    /// 整数刻度：一共三四条线。1、2、5 开头
    static func ticks(top: Int, bottom: Int) -> (lo: Int, hi: Int, step: Int) {
        if bottom > 0 {
            // 有收有支：刻度取大的那边以内最大的整数，保证至少有一条线写着数
            let m = max(top, bottom)
            var mag = 1
            while mag * 10 <= m { mag *= 10 }
            let st = [5, 2, 1].map { $0 * mag }.first { $0 <= m } ?? 1
            return (-((bottom + st - 1) / st) * st, (top + st - 1) / st * st, st)
        }
        let span = max(4, top + bottom)
        var mag = 1
        while mag * 10 <= span { mag *= 10 }
        for s in [max(1, mag / 10), max(1, mag / 5), max(1, mag / 2), mag, mag * 2, mag * 5] {
            let hi = (max(top, 1) + s - 1) / s, lo = (bottom + s - 1) / s
            if hi + lo <= 3 { return (-lo * s, hi * s, s) }
        }
        return (-bottom, max(1, top), max(1, top))
    }
    private func tickText(_ v: Int, _ step: Int, _ big: Bool) -> String {
        guard big else { return fmt(v) }
        if v == 0 { return "0" }
        return (step % 10_000 == 0 ? "\(v / 10_000)" : String(format: "%.1f", Double(v) / 10_000)) + "万"
    }
    private func start(_ d: Date) -> Date { calendar.dateInterval(of: barUnit(unit), for: d)?.start ?? d }
    private func tip(_ d: Date) -> String {
        let c = calendar.dateComponents([.month, .day, .hour, .minute], from: d)
        let t = unit == 1 ? String(format: "%02d:%02d", c.hour!, c.minute!) : unit == 60 ? "\(c.hour!)–\(c.hour! + 1) 点" : "\(c.month!)月\(c.day!)日"
        let a = up.first { $0.date == d }?.exp, b = down.first { $0.date == d }?.exp ?? 0
        if color == .expBar { return a.map { "\(t)  经验 \(fmt($0))" } ?? "\(t)  没有记录" }
        if (a ?? 0) == 0, b == 0 { return "\(t)  没有进出" }
        return "\(t)  收 \(fmt(a ?? 0))" + (b > 0 ? "  支 \(fmt(b))" : "")
    }

    var body: some View {
        let top = up.map(\.exp).max() ?? 0, bottom = down.map(\.exp).max() ?? 0
        let k = Self.ticks(top: top, bottom: bottom)
        let empty = top == 0 && bottom == 0, big = max(k.hi, -k.lo) >= 10_000
        // 有支出时：范围贴着数据，只画落在里面的刻度，不白空一格。只有往上的：到整数刻度为止，顶上留点地方写最高的数
        let lo = bottom > 0 ? -Double(bottom) * 1.08 : 0
        let hi = bottom > 0 ? max(Double(top) * 1.08, Double(bottom) * 0.15, 1) : max(Double(k.hi), Double(top) * 1.22)
        let values = Array(stride(from: k.lo, through: k.hi, by: k.step)).filter { (!empty || $0 == 0) && Double($0) >= lo && Double($0) <= hi }
        Chart {
            ForEach(up) { p in
                BarMark(x: .value("t", p.date, unit: barUnit(unit)), y: .value("v", p.exp))
                    .foregroundStyle(color.opacity(hover == nil || hover == p.date ? 1 : 0.45)).cornerRadius(unit == 1 ? 1 : 3)
            }
            ForEach(down) { p in
                BarMark(x: .value("t", p.date, unit: barUnit(unit)), y: .value("v", -p.exp))
                    .foregroundStyle(Color.spendBar.opacity(hover == nil || hover == p.date ? 1 : 0.45)).cornerRadius(unit == 1 ? 1 : 3)
            }
            if hover == nil, bottom == 0, let m = up.max(by: { $0.exp < $1.exp }), m.exp > 0 {
                PointMark(x: .value("t", m.date, unit: barUnit(unit)), y: .value("v", m.exp)).symbolSize(0)
                    .annotation(position: .top, spacing: 0, overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) { Text(fmtShort(m.exp)).font(.system(size: 9, weight: .bold)).foregroundStyle(Color.mText).padding(.horizontal, 2).background(Color.white) }
            }
            RuleMark(y: .value("v", 0)).lineStyle(StrokeStyle(lineWidth: 1)).foregroundStyle(.black.opacity(0.3))
        }
        .chartYScale(domain: lo...hi)
        .chartXScale(domain: from...to)
        .chartXAxis {
            AxisMarks(values: axisDates(from, to, unit)) { v in
                if unit < 1440 { AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(.black.opacity(0.1)) }
                AxisValueLabel(anchor: .top, collisionResolution: .disabled) {
                    if let d = v.as(Date.self) {
                        let isToday = unit == 1440 && calendar.isDate(d, inSameDayAs: now)
                        Text(axisLabel(d, unit, month: month, now: now, end: to)).font(.system(size: month ? 8 : 9, weight: isToday ? .bold : .regular))
                            .foregroundStyle(isToday ? Color.mText : Color.mSub).fixedSize()
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: values) { v in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(.black.opacity(0.14))
                AxisValueLabel { if let d = v.as(Int.self) { Text(tickText(d, k.step, big)).font(.system(size: 9)).monospacedDigit().foregroundStyle(Color.mSub).frame(width: 34, alignment: .trailing) } }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { g in
                if let p = proxy.plotFrame.map({ g[$0] }) {
                    HoverTrack { pt in
                        let d = pt.flatMap { q in q.x >= p.minX && q.x <= p.maxX ? proxy.value(atX: q.x - p.minX, as: Date.self) : nil }.map(start)
                        if d != hover { hover = d }
                    }
                    if empty { Text("这段时间没有记录").font(.system(size: 10)).foregroundStyle(Color.mSub).position(x: p.midX, y: p.midY).allowsHitTesting(false) }
                    if !empty, let h = hover, let x = proxy.position(forX: h) {
                        Text(tip(h)).font(.system(size: 10, weight: .semibold)).monospacedDigit().foregroundStyle(.white).fixedSize()
                            .padding(.horizontal, 6).padding(.vertical, 2).background(RoundedRectangle(cornerRadius: 3).fill(Color(nsColor: Maple.text).opacity(0.92)))
                            // 放在柱子旁边，不盖住它：左半边的放右边，右半边的放左边
                            .frame(width: 170, alignment: x < p.width / 2 ? .leading : .trailing)
                            .position(x: p.minX + x + (x < p.width / 2 ? 1 : -1) * (85 + 16) + (x < p.width / 2 ? 0 : 8), y: p.minY + 9).allowsHitTesting(false)
                    }
                }
            }
        }
        .padding(.trailing, unit == 60 ? 13 : 0)     // 给右端的“24:00”留位置
        .padding(.top, 3)
        .frame(height: height)
    }
}

/// 鼠标位置（左上原点）。面板不是当前程序也收得到
struct HoverTrack: NSViewRepresentable {
    let on: (CGPoint?) -> Void
    final class V: NSView {
        var on: (CGPoint?) -> Void = { _ in }
        override var isFlipped: Bool { true }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        }
        override func mouseMoved(with e: NSEvent) { on(convert(e.locationInWindow, from: nil)) }
        override func mouseEntered(with e: NSEvent) { on(convert(e.locationInWindow, from: nil)) }
        override func mouseExited(with e: NSEvent) { on(nil) }
    }
    func makeNSView(context: Context) -> V { let v = V(); v.on = on; return v }
    func updateNSView(_ v: V, context: Context) { v.on = on }
}

/// 短格式：12,340 → 1.2万
private func fmtShort(_ n: Int) -> String {
    if n >= 100_000_000 { return String(format: "%.1f亿", Double(n) / 1e8) }
    if n >= 10_000 { return String(format: "%.1f万", Double(n) / 1e4) }
    return fmt(n)
}

private func fmtAgo(_ s: Double) -> String {
    if s < 60 { return "刚刚" }
    if s < 3600 { return "\(Int(s / 60)) 分钟前" }
    if s < 86400 { return "\(Int(s / 3600)) 小时前" }
    return "\(Int(s / 86400)) 天前"
}

/// 金币图标：照着背包里金币的样子用代码画的像素画（黑边、左上高光、中间枫叶印）
struct CoinIcon: View {
    private static let rows = [
        "...######...",
        "..#wwlyyy#..",
        ".#wygoggyl#.",
        "#wygggdgggo#",
        "#lggodgdgog#",
        "#lgddododdg#",
        "#ygoddddogg#",
        "#yggddddggg#",
        "#yodgodgodo#",
        ".#ygggdgyo#.",
        "..#dooood#..",
        "...######...",
    ]
    private static let colors: [Character: Color] = [
        "#": .black, "w": .white, "l": Color(red: 1, green: 1, blue: 0.7), "y": Color(red: 1, green: 0.9, blue: 0.35),
        "g": Color(red: 0.95, green: 0.79, blue: 0.06), "o": Color(red: 0.86, green: 0.65, blue: 0.02), "d": Color(red: 0.72, green: 0.52, blue: 0)]
    var body: some View {
        Canvas { ctx, size in
            // 每格取整数像素，边缘不发虚
            let p = size.width / 12
            for (y, r) in Self.rows.enumerated() { for (x, c) in r.enumerated() {
                if let col = Self.colors[c] { ctx.fill(Path(CGRect(x: CGFloat(x) * p, y: CGFloat(y) * p, width: p, height: p)), with: .color(col), style: FillStyle(antialiased: false)) }
            } }
        }
    }
}

/// 经验图标：小方块里写 EXP 的绿色角标（和金币图标一样大小）
struct ExpIcon: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(LinearGradient(colors: [Color(red: 1, green: 0.85, blue: 0.1), Color(red: 0.45, green: 0.85, blue: 0.2)], startPoint: .top, endPoint: .bottom))
            .overlay(Text("E").font(.system(size: 11, weight: .black)).foregroundStyle(.white))
    }
}

/// 药水设置：快捷栏里每样东西的名字、单价，用了多少
struct PotionView: View {
    @ObservedObject var exp: ExpMonitor
    @ObservedObject var model: ExpModel
    @State private var showAll = false
    let save: () -> Void
    var body: some View {
        let hour = ExpStore.minute(Date()) - 59, day = ExpStore.minute(Calendar.current.startOfDay(for: Date()))
        VStack(alignment: .leading, spacing: 8) {
            Text("快捷栏上带数量的东西会自动列在这里。数量是背包里的总数（快捷栏写的就是总数）；没放快捷栏的，打开背包 Use 页就会列进来。名字按图标自动认；单价在你去药店买药时自动读，不用做什么。怪掉的药没花钱，算 0。").font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if model.potions.slots.isEmpty { Text("还没看到。快捷栏要露出来，或打开背包的 Use 页，等几秒。") }
            Toggle("连不是药水的也显示", isOn: $showAll)
            List(model.potions.sorted().filter { showAll || !$0.ignored }, id: \.id) { s in
                HStack(spacing: 8) {
                    if let e = s.en, IconStore.shared.png(e) != nil { ItemIconView(name: e).frame(width: 24, height: 24) }
                    else { RoundedRectangle(cornerRadius: 3).fill(s.color.count == 3 ? Color(red: Double(s.color[0]) / 255, green: Double(s.color[1]) / 255, blue: Double(s.color[2]) / 255) : .gray).frame(width: 24, height: 24) }
                    TextField("还没认出", text: Binding(get: { s.name }, set: { v in if let i = model.potions.slots.firstIndex(where: { $0.id == s.id }) { model.potions.slots[i].name = v; model.potions.slots[i].manual = true; save() } })).frame(width: 110)
                    Text("单价"); TextField("0", value: Binding(get: { s.price }, set: { model.potions.setPrice(s.id, $0); save() }), format: .number).frame(width: 60)
                    Text("剩 \(s.last ?? s.bag ?? 0)").frame(width: 60, alignment: .leading)
                    Text("1 小时 \(model.potions.count(s.id, since: hour)) · 今天 \(model.potions.count(s.id, since: day))")
                    Spacer()
                    Toggle("不算", isOn: Binding(get: { s.ignored }, set: { model.potions.setIgnored(s.id, $0); save() }))
                }.font(.system(size: 11)).monospacedDigit()
            }
        }.padding(12).frame(minWidth: 560, minHeight: 260)
    }
}


/// “每小时”下面：杀了几只、捡到什么
struct LootStrip: View {
    @ObservedObject var model: ExpModel
    var now: Date
    @Binding var open: Bool
    var height: CGFloat
    /// 喝掉的在前，捡到的按个数
    @ViewBuilder private func tiles(_ used: [(Int, Int)], _ d: [(key: String, value: Int)], _ fresh: [RecentLoot.Kind: Date]) -> some View {
                        ForEach(used, id: \.0) { id, n in
                            let p = model.potions.slots.first { $0.id == id }
                            ItemTile(n: -n, fresh: fresh[.used(id)], help: "喝掉 \(p?.name ?? "") ×\(n)") {
                                if let e = p?.en { ItemIconView(name: e, fallback: p?.name ?? e) }
                                // 还没认出是什么：画个瓶子颜色的小块，别空着
                                else { RoundedRectangle(cornerRadius: 4).fill(p.map { $0.color.count == 3 ? Color(red: Double($0.color[0]) / 255, green: Double($0.color[1]) / 255, blue: Double($0.color[2]) / 255) : .gray } ?? .gray).frame(width: 16, height: 16) }
                            }
                        }
                        ForEach(d, id: \.key) { k, n in
                            ItemTile(n: n, fresh: fresh[.item(k)], help: "\(ItemDB.shared.exact(k)?.zh ?? k)（\(k)）×\(n)") { ItemIconView(name: k, fallback: ItemDB.shared.exact(k)?.zh ?? k) }
                        }
    }
    var body: some View {
        let s = model.recent.summary(Date()), d = s.drops.sorted { ($0.value, $1.key) > ($1.value, $0.key) }
        let used = s.used.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.map { ($0.key, $0.value) }.filter { u in model.potions.slots.first { $0.id == u.0 }?.ignored != true }
        // 像游戏背包的一条：左边图标（新捡的会发光），右边几种、杀几只；点右边展开
        HStack(alignment: .top, spacing: 6) {
            Group {
                if open {
                    ScrollView(.vertical) {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 32, maximum: 32), spacing: 3)], alignment: .leading, spacing: 3) { tiles(used, d, s.fresh) }
                    }.frame(maxHeight: 102).fixedSize(horizontal: false, vertical: true)
                } else if used.isEmpty && d.isEmpty {
                    Text("还没捡到东西").font(.system(size: 10)).foregroundStyle(Color.mSub).frame(height: 32)
                } else {
                    // 放得下几格就几格，不切半个；刚捡到的要是排在后面放不下，挪到最后一格
                    GeometryReader { geo in
                        let fit = max(1, Int((geo.size.width + 3) / 35)), u = Array(used.prefix(fit)), room = fit - u.count
                        let hot = d.indices.filter { $0 >= room }.first { i in s.fresh[.item(d[i].key)].map { Date().timeIntervalSince($0) < 6 } ?? false }
                        let list = hot.map { room > 0 ? Array(d.prefix(room - 1)) + [d[$0]] : [] } ?? Array(d.prefix(room))
                        HStack(spacing: 3) { tiles(u, list, s.fresh) }
                    }.frame(height: 32)
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 1) {
                Text("\(d.count) 种 \(open ? "▾" : "▸")").fontWeight(.bold).foregroundStyle(Color.mText)
                Text("杀 \(s.kills) 只").foregroundStyle(Color.mSub)
            }
            .font(.system(size: 10)).monospacedDigit().lineLimit(1).fixedSize().frame(height: 32)
            .contentShape(Rectangle()).onTapGesture { open.toggle() }.help(open ? "点一下收起" : "最近一小时捡到的。点一下全部展开")
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 3).fill(Color(nsColor: Maple.bag)))
        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color(nsColor: Maple.slotEdge), lineWidth: 1))
    }
}

/// 游戏里的物品图标（原大小、不模糊）；没有图标文件时写名字
struct ItemIconView: View {
    let name: String
    var fallback = ""
    /// 新取到图标、切换模式后要重画
    @ObservedObject private var store = IconStore.shared
    @MainActor static var cache: [String: NSImage] = [:]
    @MainActor private static func image(_ n: String) -> NSImage? {
        if let i = cache[n] { return i }
        guard let d = IconStore.shared.png(n), let i = NSImage(data: d) else { return nil }
        // PNG 自带的分辨率会让尺寸不对：按像素数当点数
        if let r = i.representations.first { i.size = NSSize(width: r.pixelsWide, height: r.pixelsHigh) }
        cache[n] = i
        return i
    }
    var body: some View {
        if let i = Self.image(name) { Image(nsImage: i).interpolation(.none).fixedSize() }
        else { Text(fallback.isEmpty ? name : fallback).font(.system(size: 8)).foregroundStyle(Color.mText).lineLimit(2).multilineTextAlignment(.center).minimumScaleFactor(0.75).padding(.horizontal, 1).padding(.top, 2).frame(maxHeight: .infinity, alignment: .top) }      // 字靠上，数字在左下
    }
}
/// 背包格子的样子：图标、左下角像素数字；刚捡到的外面一圈金边会转几秒
struct ItemTile<C: View>: View {
    let n: Int
    let fresh: Date?
    let help: String
    @ViewBuilder let icon: C
    private static var glow: Double { 6 }
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            SlotBack()
            icon.frame(maxWidth: .infinity, maxHeight: .infinity)
            PixelNumber(n: n).padding(.leading, 1).padding(.bottom, 1)
        }
        .frame(width: 32, height: 32).clipped()
        .overlay { if let f = fresh { GlowRing(since: f, seconds: Self.glow) } }
        .help(help)
    }
}
/// 背包格子的底：颜色从游戏画面量的，左边、上边一条暗边
struct SlotBack: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(Color(nsColor: Maple.beige))
            Rectangle().fill(Color(nsColor: Maple.slotEdge)).frame(height: 1)
            Rectangle().fill(Color(nsColor: Maple.slotEdge)).frame(width: 1)
        }
    }
}
/// 转动的金边：到时间就停，停了不再占用
struct GlowRing: View {
    let since: Date, seconds: Double
    @State private var on = true
    var body: some View {
        // 底下要有东西：空的视图不会再收到 task，灭了以后就再也亮不起来
        ZStack {
            Color.clear
            if on {
                TimelineView(.animation(minimumInterval: 1 / 20)) { t in
                    let age = t.date.timeIntervalSince(since)
                    Rectangle().strokeBorder(AngularGradient(colors: [Color(red: 1, green: 0.95, blue: 0.5), Color(red: 1, green: 0.62, blue: 0), Color(red: 0.85, green: 0.45, blue: 0), Color(red: 1, green: 0.95, blue: 0.5)],
                                                             center: .center, angle: .degrees(age * 240)), lineWidth: 2)
                        .opacity(max(0, min(1, seconds - age)))
                }
            }
        }
        .allowsHitTesting(false)
        .task(id: since) {
            let left = seconds - Date().timeIntervalSince(since)
            on = left > 0
            guard left > 0 else { return }
            try? await Task.sleep(nanoseconds: UInt64(left * 1e9))
            if !Task.isCancelled { on = false }
        }
    }
}
/// 白字黑边的像素数字（点阵自己画）。上万写成 “1.2万”
struct PixelNumber: View {
    let n: Int
    var body: some View {
        if abs(n) >= 100_000 {
            Text(fmtShort(n)).font(.system(size: 9, weight: .black)).foregroundStyle(.white).shadow(color: .black, radius: 0, x: 1, y: 0).shadow(color: .black, radius: 0, x: -1, y: 0).shadow(color: .black, radius: 0, x: 0, y: 1)
        } else {
            let digits = String(abs(n)).compactMap(\.wholeNumberValue)
            // 宽 = 每个数字 + 1 点间隔；负数前面一横
            let w = digits.reduce(n < 0 ? 6 : 0) { $0 + QuickSlot.pixels($1)[0].count + 2 } + 2
            Canvas { c, _ in
                var cells: [(Int, Int, Color)] = []
                var x = 1
                if n < 0 { for k in 0..<4 { cells.append((x + k, 5, .white)) }; x += 6 }
                for d in digits {
                    let g = QuickSlot.pixels(d)
                    for r in 0..<9 { for k in g[r].indices where g[r][k] {
                        let q = QuickSlot.rowColor(r)
                        cells.append((x + k, r + 1, Color(red: Double(q.0) / 255, green: Double(q.1) / 255, blue: Double(q.2) / 255)))
                    } }
                    x += g[0].count + 2
                }
                for e in cells { c.fill(Path(CGRect(x: e.0 - 1, y: e.1 - 1, width: 3, height: 3)), with: .color(.black), style: FillStyle(antialiased: false)) }
                for e in cells { c.fill(Path(CGRect(x: e.0, y: e.1, width: 1, height: 1)), with: .color(e.2), style: FillStyle(antialiased: false)) }
            }
            .frame(width: CGFloat(w), height: 11)
        }
    }
}

/// 图标从哪来：自带的文件（自用版）；没有、或打开“只从画面取”时，用从自己画面上取到、存在本机的小图标
@MainActor
final class IconStore: ObservableObject {
    static let shared = IconStore()
    @Published private(set) var version = 0
    private let dir = ExpMonitor.base.appendingPathComponent("图标")
    private var grabbed: [String: Data] = [:], fromBag: [String: Data] = [:], pending: [String: IconGrab.Icon] = [:]
    /// 试普通用户模式：不用自带的图标
    var screenOnly: Bool {
        get { UserDefaults.standard.bool(forKey: "iconScreenOnly") }
        set { UserDefaults.standard.set(newValue, forKey: "iconScreenOnly"); ItemIconView.cache = [:]; version += 1 }
    }
    var names: Set<String> { Set(grabbed.keys).union(fromBag.keys) }
    var count: Int { Set(grabbed.keys).union(fromBag.keys).count }
    private init() {
        for f in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] where f.pathExtension == "png" {
            guard let d = try? Data(contentsOf: f) else { continue }
            let n = f.deletingPathExtension().lastPathComponent
            if n.hasSuffix(".bag") { fromBag[String(n.dropLast(4))] = d } else { grabbed[n] = d }
        }
    }
    func png(_ name: String) -> Data? { (screenOnly ? nil : ItemIcons.shared.png(name)) ?? grabbed[Self.file(name)] ?? fromBag[Self.file(name)]
        // 没有物品表（公开版）：名字被截断、认错一个字母的，对一对取过的
        ?? (ItemDB.shared.items.isEmpty ? ItemDB.same(Self.file(name), in: Array(Set(grabbed.keys).union(fromBag.keys))).flatMap { grabbed[$0] ?? fromBag[$0] } : nil) }
    /// 取到的图标的颜色，算法和快捷栏、商店里一样（右上那块鲜艳的颜色平均）
    private func remove(_ k: String) {
        grabbed[k] = nil; fromBag[k] = nil; ItemIconView.cache[k] = nil
        for s in [".png", ".bag.png"] { try? FileManager.default.removeItem(at: dir.appendingPathComponent(k + s)) }
        trace("icon: 名字认错的去掉 \(k)")
    }
    /// 以前存下的认错名字的
    func clean() {
        guard ItemDB.shared.items.isEmpty else { return }
        let c = colors(all: true)
        for k in c.keys.sorted() where ItemDB.dedupe(k, color: c[k]!, among: c.filter { $0.key != k }).use != k { remove(k) }
    }
    /// 取到的图标放在背包格子里的样子（不含背包里补出来的）
    func prints() -> [(name: String, print: [Int])] {
        fromBag.merging(grabbed, uniquingKeysWith: { _, b in b }).sorted { $0.key < $1.key }.compactMap { k, d in
            guard let im = NSBitmapImageRep(data: d)?.cgImage, im.width == 32, im.height == 32 else { return nil }
            var buf = [UInt8](repeating: 0, count: 4096)
            guard let c = CGContext(data: &buf, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 128, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            c.draw(im, in: CGRect(x: 0, y: 0, width: 32, height: 32))
            let px = (0..<1024).map { i -> (Int, Int, Int, Int) in
                let a = Int(buf[i * 4 + 3])
                func u(_ k: Int) -> Int { a == 0 ? 0 : Int(buf[i * 4 + k]) * 255 / a }
                return (u(0), u(1), u(2), a)
            }
            return (k, BagLearn.iconPrint(px))
        }
    }
    func colors(all: Bool = false) -> [String: [Int]] {
        guard ItemIcons.shared.count == 0 else { return [:] }
        var out: [String: [Int]] = [:]
        for (k, d) in fromBag.merging(grabbed, uniquingKeysWith: { _, b in b }) {
            if let im = NSBitmapImageRep(data: d)?.cgImage, let c = IconGrab.color(im) ?? (all ? [] : nil) { out[k] = c }
        }
        return out
    }
    /// 背包里看到时要不要取：还没有的才取
    var wanted: @Sendable (String) -> Bool {
        let have = Set(grabbed.keys).union(fromBag.keys)
        return { !have.contains(Self.file($0)) }
    }
    nonisolated private static func file(_ n: String) -> String { n.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_") }
    /// 背包里取的（被数量盖住的地方是补的；以后在商店、说明框看到完整的会换掉）
    func offerBag(_ list: [(String, IconGrab.Icon)]) {
        guard !list.isEmpty else { return }
        for (name, icon) in list {
            let k = Self.file(name)
            guard grabbed[k] == nil, fromBag[k] == nil, let im = icon.image,
                  let d = NSBitmapImageRep(cgImage: im).representation(using: .png, properties: [:]) else { continue }
            fromBag[k] = d
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? d.write(to: dir.appendingPathComponent(k + ".bag.png"), options: .atomic)
            ItemIconView.cache[name] = nil
        }
        version += 1
    }
    func offer(_ name: String, _ icon: IconGrab.Icon?) {
        let k = Self.file(name)
        guard let icon, grabbed[k] == nil else { return }
        guard pending[k] == icon else { pending[k] = icon; return }
        pending[k] = nil
        guard let im = icon.image, let d = NSBitmapImageRep(cgImage: im).representation(using: .png, properties: [:]) else { return }
        if ItemDB.shared.items.isEmpty {
            let x = ItemDB.dedupe(k, color: IconGrab.color(im) ?? [], among: colors(all: true))
            guard x.use == k else { return }       // 名字认错的，正确的已经有了
            for o in x.drop { remove(o) }
        }
        grabbed[k] = d
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? d.write(to: dir.appendingPathComponent(k + ".png"), options: .atomic)
        ItemIconView.cache[name] = nil; version += 1
        trace("icon: 从画面取到 \(name)，共 \(count) 个")
    }
}
