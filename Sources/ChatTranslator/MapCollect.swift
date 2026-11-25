// 地图采集：平时走图时自动记“哪个门通到哪张图”，存在本机；窗口里看哪些采好了、哪些还没采
import AppKit
import SwiftUI
import TranslatorCore

@MainActor
final class MapCollectModel: ObservableObject {
    @Published private(set) var maps: [String: WalkedMap] = [:]
    @Published private(set) var current: String?
    private let collector: MapCollector
    private let url: URL
    private var busy = false, rect: CGRect?, lastFind = Date.distantPast
    private var ocrPrint = 0, ocrTries = 0

    init() {
        let dir = dataDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("mymaps.json")
        let old = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([String: WalkedMap].self, from: $0) } ?? [:]
        collector = MapCollector(maps: old); maps = old
        linksURL = dir.appendingPathComponent("mylinks.json")
        links = (try? Data(contentsOf: linksURL)).flatMap { try? JSONDecoder().decode([WalkedLink].self, from: $0) } ?? []
        warpsURL = dir.appendingPathComponent("mywarps.json")
        warps = (try? Data(contentsOf: warpsURL)).flatMap { try? JSONDecoder().decode([WalkedWarp].self, from: $0) } ?? []
        npcs = (try? Data(contentsOf: npcsURL)).flatMap { try? JSONDecoder().decode([MetNpc].self, from: $0) } ?? []
        publishLinks()
        met = (try? Data(contentsOf: metURL)).flatMap { try? JSONDecoder().decode(NpcBook.self, from: $0) } ?? NpcBook()
    }

    // MARK: 没有地图资料时带路
    /// 路过时看到的 NPC
    @Published private(set) var met = NpcBook()
    private var metURL: URL { url.deletingLastPathComponent().appendingPathComponent("mynpcnames.json") }
    /// 自己在小地图画面里的左右位置，小地图有多宽（点）
    private(set) var meFx: Double?, meAt = Date.distantPast
    /// 在整张小地图里的位置
    var spot: (x: Double?, y: Double?)? { Date().timeIntervalSince(meAt) < 3 ? collector.spot : nil }
    private var viewW = 0.0, tagAt = Date.distantPast
    var playerName: () -> String = { "" }
    var onMe: (() -> Void)?
    /// 对话框、任务窗口开着：名牌会被切掉半个，不看
    var covered: () -> Bool = { false }
    private func saveMet() { if let d = try? JSONEncoder().encode(met) { try? d.write(to: metURL, options: .atomic) } }
    /// 和 NPC 说话：他就在旁边
    func talked(_ raw: String) {
        guard NavDB.shared.maps.isEmpty, let n = NpcTags.name(raw), let k = steadyMap, let x = meFx, Date().timeIntervalSince(meAt) < 5 else { return }
        if met.see(n, map: k, fx: x, ax: spot?.x, ay: spot?.y, at: Date(), talk: true) { trace("collect: 说过话的 NPC \(n) 在 \(k) \(x)"); saveMet() }
    }
    /// 每 4 秒看一眼画面里的黄字名牌
    private func tagTick(_ locator: GameWindowLocator, _ g: GameWindowInfo, _ client: OCRClient) async {
        guard NavDB.shared.maps.isEmpty, !covered(), Date().timeIntervalSince(tagAt) > 4, let key = steadyMap, let me = meFx, viewW > 20, Date().timeIntervalSince(meAt) < 1.5 else { return }
        tagAt = Date()
        let win = g.frameTopLeft.size, name = playerName()
        // 标题栏下面到聊天框上面；左上角小地图、右上角任务追踪里的黄字不是名牌，靠名字格式和两次位置一样挡掉
        let r = CGRect(x: 0, y: 28, width: win.width, height: win.height - 28 - 150)
        let here = spot
        guard r.height > 200, let shape = TagShape.make(name), let img = await withTimeout(2, { await locator.capture(g, rect: r, outputScale: 2) }),
              let mine = await Task.detached(operation: { shape.spot(img, scale: 2) }).value,
              let y = await Task.detached(operation: { NpcTags.isolate(img) }).value,
              let lines = await withTimeout(3, { client.recognize(y) }), collector.current == key else { return }
        var changed = false
        for l in lines {
            guard l.confidence >= 0.5, let n = NpcTags.name(l.text) else { continue }
            let dx = ((l.minX + l.maxX) / 2 - Double(mine.x)) * r.width, dy = ((l.minY + l.maxY) / 2 - Double(mine.y)) * r.height
            if met.see(n, map: key, fx: me + dx / 16 / viewW, ax: here?.x.map { $0 + dx / 16 }, ay: here?.y.map { $0 + dy / 16 }, at: Date()) { changed = true; trace("collect: 路过 NPC \(n) 在 \(key)") }
        }
        if changed { saveMet(); onChange?() }
    }

    /// 现在稳稳在哪张图（刚换图 3 秒内为 nil）
    private var enteredAt = Date()
    var steadyMap: String? { Date().timeIntervalSince(enteredAt) > 3 ? collector.current : nil }
    // MARK: 采集向导
    /// 走过的同图隐藏传送点（量到的入口、出口）
    struct WalkedWarp: Codable { var map: Int, index: Int, x1: Double, y1: Double, x2: Double, y2: Double, n: Int }
    private let warpsURL: URL
    @Published private(set) var warps: [WalkedWarp] = []
    /// 走到过旁边的 NPC（自己站的位置）
    struct MetNpc: Codable { var map: Int, npc: Int, x: Double, y: Double }
    private var npcsURL: URL { warpsURL.deletingLastPathComponent().appendingPathComponent("mynpcs.json") }
    @Published private(set) var npcs: [MetNpc] = []
    private var npcSeen: (String, Int)?
    var onChange: (() -> Void)?
    /// 向导里点了“跳过”的
    @Published private(set) var skipped = Set(UserDefaults.standard.stringArray(forKey: "guideSkip") ?? [])
    @Published private(set) var skippedMaps = Set(UserDefaults.standard.array(forKey: "guideSkipMaps") as? [Int] ?? [])
    func skip(_ key: String) { skipped.insert(key); saveSkip() }
    func skip(map: Int) { skippedMaps.insert(map); saveSkip() }
    func clearSkips() { skipped = []; skippedMaps = []; saveSkip() }
    private func saveSkip() {
        UserDefaults.standard.set(skipped.sorted(), forKey: "guideSkip"); UserDefaults.standard.set(skippedMaps.sorted(), forKey: "guideSkipMaps")
        onChange?()
    }
    /// 采好的：走过的门、走过的隐藏传送点
    /// 没有小地图的室内图：只能靠标题知道进出过。走过的门、屏幕里的 NPC
    private lazy var indoor: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "collectIndoor") ?? [])
    func entered(from: Int?, to: Int) {
        let db = NavDB.shared
        guard let m = db.maps[to] else { return }
        var add: Set<String> = []
        if let from, let a = db.maps[from], a.mini.isEmpty || m.mini.isEmpty, a.portals.contains(where: { Int($0[0]) == to }) { add.insert("\(from)-\(to)") }
        // 室内图就一屏大，进去就看得到里面的 NPC（位置用表里的）
        if m.mini.isEmpty, m.box[2] - m.box[0] <= 1100 { for n in m.npcs { add.insert("\(to)n\(Int(n[0]))") } }
        guard !add.isSubset(of: indoor) else { return }
        indoor.formUnion(add)
        UserDefaults.standard.set(indoor.sorted(), forKey: "collectIndoor")
        trace("collect: 室内 \(m.name) \(add.sorted())"); onChange?()
    }
    var done: Set<String> {
        var s = indoor.union(warps.map { "\($0.map)w\($0.index)" }).union(npcs.map { "\($0.map)n\($0.npc)" })
        for (k, m) in maps { if let a = mapId(k) { for e in m.exits { if let b = mapId(e.to) { s.insert("\(a)-\(b)") } } } }
        return s
    }
    /// 上一次认出的位置，看有没有一下子从入口到了出口
    private var lastSpot: (id: Int, p: NavPoint, t: Date)?
    private var onScreen: Set<String> = []
    private func met(_ id: Int, _ n: Int, _ at: NavPoint) {
        guard !npcs.contains(where: { $0.map == id && $0.npc == n }) else { return }
        npcs.append(MetNpc(map: id, npc: n, x: at.x, y: at.y))
        if let d = try? JSONEncoder().encode(npcs) { try? d.write(to: npcsURL, options: .atomic) }
        trace("collect: 采到 NPC \(NavDB.shared.npcName(n)) 在 \(Int(at.x)),\(Int(at.y))"); onChange?()
    }
    private func spot(_ id: Int, _ m: NavMap, _ p: NavPoint, green: [NavPoint], _ now: Date) {
        defer { lastSpot = (id, p, now) }
        // 屏幕里看得到、小地图上有绿点，连着两次就算（不用走到脚下），位置用绿点的
        let seen = NavDB.shared.npcsSeen(m, p, green: green)
        for (n, at) in seen where onScreen.contains("\(id)n\(n)") { met(id, n, at) }
        onScreen = Set(seen.map { "\(id)n\($0.id)" })
        // 绿点被别的点盖住时：站到旁边连着看到 2 次也算
        if let n = NavDB.shared.npcNear(m, p) {
            let k = "\(id)n\(n)"
            npcSeen = npcSeen?.0 == k ? (k, npcSeen!.1 + 1) : (k, 1)
            if npcSeen!.1 == 2 { met(id, n, p) }
        } else { npcSeen = nil }
        guard let l = lastSpot, l.id == id, now.timeIntervalSince(l.t) < 1.8, let i = Warps.passed(m, from: l.p, to: p) else { return }
        if let k = warps.firstIndex(where: { $0.map == id && $0.index == i }) { warps[k].n += 1 }
        else { warps.append(WalkedWarp(map: id, index: i, x1: l.p.x, y1: l.p.y, x2: p.x, y2: p.y, n: 1)) }
        if let d = try? JSONEncoder().encode(warps) { try? d.write(to: warpsURL, options: .atomic) }
        trace("collect: 走过隐藏传送点 \(m.name) 第 \(i + 1) 个")
        onChange?()
    }

    // 走过的门在地图上的位置（隐藏门给导航用）
    private let linksURL: URL
    private var links: [WalkedLink] = []
    private var pos: (id: Int, x: Double, y: Double, t: Date, door: Bool)?
    private var ids: [String: Int] = [:]
    private var ringMap = 0, ringSeen: [NavPoint] = []
    private func mapId(_ key: String) -> Int? {
        if let i = ids[key] { return i }
        guard let m = collector.maps[key], let i = NavDB.shared.locate([m.street, m.name]) else { return nil }
        ids[key] = i
        return i
    }
    /// 只有确认是门的（来回走过，或看到蓝圈）才给导航
    private func publishLinks() {
        let ok = Set(collector.maps.flatMap { k, m -> [String] in
            guard let a = mapId(k) else { return [] }
            return m.exits.filter(\.door).compactMap { e in mapId(e.to).map { "\(a)-\($0)" } }
        })
        NavDB.shared.setWalked(links.filter { l in
            ok.contains("\(l.from)-\(l.to)") || l.door == true && NavDB.shared.maps[l.from]?.portals.contains { Int($0[0]) == l.to } == true
        })
    }
    /// 换图了：上一张图最后的位置就是那个门
    private func leave(_ old: (id: Int, x: Double, y: Double, t: Date, door: Bool), to: Int, at now: Date) {
        guard now.timeIntervalSince(old.t) < 8, to != old.id else { return }
        if let i = links.firstIndex(where: { $0.from == old.id && $0.to == to }) {
            // 站在门上记的不被没站在门上的（死了、回城卷）盖掉
            if links[i].door == true, !old.door { return }
            links[i].x = old.x; links[i].y = old.y; links[i].door = old.door ? true : links[i].door
        } else { links.append(WalkedLink(from: old.id, to: to, x: old.x, y: old.y, door: old.door ? true : nil)) }
        trace("collect: 记下门 \(NavDB.shared.mapName(old.id)) → \(NavDB.shared.mapName(to)) \(Int(old.x)),\(Int(old.y)) 站在圈上 \(old.door)")
        publishLinks()
        if let d = try? JSONEncoder().encode(links) { try? d.write(to: linksURL, options: .atomic) }
    }

    /// 每 0.5 秒一次：截小地图那一块；标题变了才识别文字
    func tick(locator: GameWindowLocator, g: GameWindowInfo, client: OCRClient) async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        let win = CGRect(origin: .zero, size: g.frameTopLeft.size)
        if rect == nil || Date().timeIntervalSince(lastFind) > 3 {
            lastFind = Date()
            guard let small = await withTimeout(2, { await locator.capture(g, rect: win, outputScale: 1) }) else { return }
            rect = await Task.detached { MiniMap.find(in: small, scale: 1) }.value
        }
        guard let b = rect else { return }
        let area = CGRect(x: b.minX - 4, y: b.minY - 2, width: b.width + 8, height: 320).intersection(win)
        guard let img = await withTimeout(2, { await locator.capture(g, rect: area, outputScale: 2) }) else { return }
        // 标题文字：左边约 42 点是地区图标
        let title = CGRect(x: (b.minX - area.minX + 44) * 2, y: (b.minY - area.minY + 22) * 2, width: (b.width - 50) * 2, height: 44 * 2)
        guard let s = await Task.detached(operation: { MiniMap.sample(img, scale: 2, title: title) }).value else { return }
        let now = Date()
        if collector.needsTitle(s) {
            if s.titlePrint != ocrPrint {
                ocrPrint = s.titlePrint; ocrTries = 0
                // 小地图窗口的宽度跟着地名长短变：标题变了先重新量，按旧宽度截会少半截（“Tree Dungeon, Forest Up”），量出来不一样就等下一帧
                lastFind = Date()
                guard let small = await withTimeout(2, { await locator.capture(g, rect: win, outputScale: 1) }) else { ocrPrint = 0; return }
                let r = await Task.detached { MiniMap.find(in: small, scale: 1) }.value
                if r == nil || abs(r!.minX - b.minX) > 1 || abs(r!.minY - b.minY) > 1 || abs(r!.width - b.width) > 1 { rect = r; ocrPrint = 0; return }
            }
            // 认不出的（被挡住、有动画）试 6 次就算了，别一直占着识别
            // 鼠标压在标题上会读短（“Tree Dungeon, Forest Up”）：先不读
            let m = NSEvent.mouseLocation, top = NSScreen.screens.first?.frame.maxY ?? 0
            let onTitle = CGRect(x: g.frameTopLeft.minX + b.minX, y: g.frameTopLeft.minY + b.minY, width: b.width, height: 72).insetBy(dx: -30, dy: -30).contains(CGPoint(x: m.x, y: top - m.y))
            if !onTitle, ocrTries < 6, let c = MiniMap.titleImage(img, rect: title) {
                ocrTries += 1
                if let l = await withTimeout(3, { client.recognize(c) }), let t = MapCollector.parseTitle(l) { collector.setTitle(s.titlePrint, street: t.street, name: t.name) }
            }
        }
        let was = collector.current
        let fed = collector.feed(s, at: now)
        if collector.current != was { enteredAt = now; meFx = nil }
        if let m = s.me, s.view.width > 0, !collector.needsTitle(s) { meFx = Double(m.x / s.view.width); viewW = Double(s.view.width); meAt = now } else if now.timeIntervalSince(meAt) > 3 { meFx = nil }
        if NavDB.shared.maps.isEmpty { current = collector.current; onMe?() }
        if let k = collector.current, !collector.needsTitle(s) {
            // 同名的图（两张 Mushroom Town）看小地图分；这一下分不出就等下一下
            var here = mapId(k)
            if let h = here, case let tw = NavDB.shared.twins(h), tw.count > 1 {
                let ms = tw.compactMap { NavDB.shared.maps[$0] }
                here = await Task.detached(operation: { MiniMap.which(img, scale: 2, of: ms) }).value
            }
            if let p = pos, let h = here, p.id != h { leave(p, to: h, at: now); pos = nil }
            if let id = here, let m = NavDB.shared.maps[id],
               let r = await Task.detached(operation: { MiniMap.read(img, scale: 2, map: m) }).value, let y = r.y {
                // 站上去时自己的黄点会盖住蓝圈：用走近前看到过的
                if ringMap != id { ringMap = id; ringSeen = [] }
                for d in r.doors where !ringSeen.contains(where: { abs($0.x - d.x) < 60 && abs($0.y - d.y) < 80 }) { ringSeen.append(d) }
                pos = (id, r.x, y, now, ringSeen.contains { abs($0.x - r.x) < 70 && abs($0.y - y) < 90 }); spot(id, m, NavPoint(x: r.x, y: y), green: r.npcs, now) }
        }
        if fed {
            publishLinks()
            maps = collector.maps; current = collector.current
            if let d = try? JSONEncoder().encode(maps) { try? d.write(to: url, options: .atomic) }
            onChange?()
            trace("collect: 在 \(current.flatMap { maps[$0]?.name } ?? "?")，共 \(maps.count) 张，走通 \(maps.values.reduce(0) { $0 + $1.walked }) 个门")
        }
        await tagTick(locator, g, client)
    }
}

/// 打怪记录：每张图的效率、捡到什么、可能是谁掉的
struct HuntView: View {
    @ObservedObject var exp: ExpMonitor
    @ObservedObject var maps: MapCollectModel
    private func id(_ k: String) -> Int? { maps.maps[k].flatMap { NavDB.shared.locate([$0.street, $0.name]) } }
    private func mobs(_ k: String) -> [String] { id(k).map { NavDB.shared.mobs(in: $0) } ?? [] }
    var body: some View {
        let rows = exp.hunt.maps.filter { $0.value.minutes > 0 || !$0.value.drops.isEmpty }.sorted { rate($0.value.exp, $0.value) > rate($1.value.exp, $1.value) }
        VStack(alignment: .leading, spacing: 8) {
            Text("按每小时经验从高到低。捡到什么、捡了几个是自己看到的；“谁掉的”是推测：同一样东西在几张图都捡到，就看那几张图共有哪种怪。别人丢的、任务给的也会算进来。").font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if rows.isEmpty { Text("还没有记录。开着经验统计和地图采集，打几分钟怪、捡点东西就有了。") }
            List(rows, id: \.key) { k, v in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(id(k).map { NavDB.shared.mapName($0) } ?? maps.maps[k]?.name ?? k).font(.system(size: 12, weight: .bold))
                        Spacer()
                        Text("\(v.minutes) 分钟").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    if v.minutes >= 3 { Text("经验 \(rate(v.exp, v))/h · 金币 \(rate(v.mesos, v))/h\((v.potion ?? 0) > 0 ? "（药水 -\(rate(v.potion!, v))/h，净 \(rate(v.mesos - v.potion!, v))/h）" : "") · 约 \(rate(v.kills, v) / 60)只/min").font(.system(size: 11)).monospacedDigit() }
                    else { Text("打了不到 3 分钟，先不算效率").font(.system(size: 11)).foregroundStyle(.secondary) }
                    if !v.drops.isEmpty {
                        let x = exp.book.value(v.drops)
                        Text("捡到的东西卖店约值 \(x.mesos)" + (x.unknown > 0 ? "（还有 \(x.unknown) 种还不知道卖价）" : "")).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    ForEach(v.drops.sorted { ($0.value, $1.key) > ($1.value, $0.key) }, id: \.key) { n, c in
                        let s = exp.hunt.sources(of: n, mobs: mobs)
                        HStack(spacing: 6) { ItemIconView(name: n, fallback: " ").frame(width: 34, height: 32); Text("\(ItemDB.shared.exact(n)?.zh ?? n) ×\(c)" + (s.isEmpty ? "" : s.count == 1 ? "　可能是 \(NavDB.shared.mobName(s[0])) 掉的" : "　" + s.prefix(4).map { NavDB.shared.mobName($0) }.joined(separator: "、") + " 之一")).font(.system(size: 10)).foregroundStyle(.secondary) }.padding(.leading, 14)
                    }
                }
            }
        }.padding(12).frame(minWidth: 460, minHeight: 420)
    }
    private func rate(_ n: Int, _ m: HuntMap) -> Int { m.minutes > 0 ? n * 60 / m.minutes : 0 }
}

struct MapCollectView: View {
    @ObservedObject var model: MapCollectModel
    @ObservedObject var nav: NavModel
    @State private var filter = 0
    private var plain: Bool { NavDB.shared.maps.isEmpty }
    private struct Row: Identifiable {
        var id: String; var street: String; var name: String; var m: WalkedMap?
        /// 现有地图表里这张图通往的图；空 = 表里没有
        var goals: [Int] = []
        var got: Set<Int> = []
        var mapId: Int? = nil
        var hidden = 0, hiddenGot = 0, npcs = 0, npcsGot = 0
        var missing: [Int] { goals.filter { !got.contains($0) } }
        /// 0 还差、1 采好、2 没去过
        var state: Int { m == nil ? 2 : !goals.isEmpty && missing.isEmpty && hiddenGot >= hidden && npcsGot >= npcs ? 1 : 0 }
    }
    /// 总门数、没去过的图从现有地图表里看（只给自己看进度，不存进采集数据）
    private func build() -> [Row] {
        let db = NavDB.shared
        func id(_ m: WalkedMap) -> Int? { db.locate([m.street, m.name]) }
        var used = Set<Int>()
        let done = model.done
        var out: [Row] = model.maps.map { k, v in
            var r = Row(id: k, street: v.street, name: v.name, m: v)
            if let i = id(v) {
                used.insert(i)
                var seen = Set<Int>()
                r.goals = (db.maps[i]?.portals ?? []).filter { $0[3] >= 0 }.map { Int($0[0]) }.filter { seen.insert($0).inserted }
                r.mapId = i
                let w = db.guideItems(i).filter { $0.hasPrefix("\(i)w") }
                r.hidden = w.count; r.hiddenGot = w.filter(done.contains).count
                let p = db.guideItems(i).filter { $0.hasPrefix("\(i)n") }
                r.npcs = p.count; r.npcsGot = p.filter(done.contains).count
                r.got = Set(v.exits.compactMap { e in model.maps[e.to].flatMap(id) })
            }
            return r
        }
        out += db.maps.values.filter { !used.contains($0.id) }.map { Row(id: "db\($0.id)", street: $0.street, name: $0.name, m: nil, mapId: $0.id) }
        return out.sorted { ($0.id == model.current ? 0 : 1, $0.state, $0.street, $0.name) < ($1.id == model.current ? 0 : 1, $1.state, $1.street, $1.name) }
    }
    var body: some View {
        let all = build()
        let rows = all.filter { plain || filter == 0 || (filter == 1 && $0.state == 2) || (filter == 2 && $0.state == 0) || (filter == 3 && $0.state == 1) }
        VStack(alignment: .leading, spacing: 8) {
            // 没有地图表：不知道还差什么，没有“导航采集”，只看自己走过的
            if plain {
                Text("走过 \(model.maps.count) 张图 · 见过 \(model.met.maps.values.reduce(0) { $0 + $1.count }) 个 NPC").font(.system(size: 13, weight: .semibold))
                Text("平时走过的门、路过的 NPC 会自动记在这里，做任务带路就靠它们。小地图要展开。").font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
            Text("采好 \(all.filter { $0.state == 1 }.count) 张 · 还差门 \(all.filter { $0.state == 0 }.count) 张 · 没去过 \(all.filter { $0.state == 2 }.count) 张").font(.system(size: 13, weight: .semibold))
            HStack {
                Button(nav.guideOn ? "关闭导航采集（回到任务助手）" : "开启导航采集") { nav.guideOn.toggle() }
                if nav.guideOn, let s = nav.guide { Text("下一步：" + s.title).font(.system(size: 11)).lineLimit(1) }
                Spacer()
                if !model.skipped.isEmpty || !model.skippedMaps.isEmpty { Button("恢复跳过的 \(model.skipped.count + model.skippedMaps.count) 项") { model.clearSkips() }.controlSize(.small) }
            }
            Text("向导会在游戏画面上用箭头带你走最近的、还没采的门、隐藏传送点和 NPC，走到自动打勾。小地图要展开，到了那边停 3 秒。想去别的图就点那一行的“带我去”。").font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Picker("", selection: $filter) { Text("全部").tag(0); Text("没去过").tag(1); Text("还差门").tag(2); Text("采好了").tag(3) }.pickerStyle(.segmented).labelsHidden()
            }
            List(rows) { r in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        if !plain { Circle().fill(r.state == 2 ? Color.gray.opacity(0.5) : r.state == 1 ? Color(nsColor: Maple.done) : Color(nsColor: Maple.warn)).frame(width: 8, height: 8) }
                        Text(r.name).font(.system(size: 12, weight: r.id == model.current ? .bold : .regular))
                        Text(r.id == model.current ? "现在在这里" : r.street).font(.system(size: 10)).foregroundStyle(.secondary)
                        Spacer()
                        if let i = r.mapId, r.state != 1, r.id != model.current { Button("带我去") { nav.startGuide(to: i) }.controlSize(.mini) }
                        if let m = r.m { Text(r.goals.isEmpty ? "走过 \(m.exits.count) 个门" : "门 \(r.goals.count - r.missing.count)/\(r.goals.count)").font(.system(size: 11)).monospacedDigit() }
                        if r.hidden > 0 { Text("隐藏 \(r.hiddenGot)/\(r.hidden)").font(.system(size: 11)).monospacedDigit() }
                        if r.npcs > 0 { Text("NPC \(r.npcsGot)/\(r.npcs)").font(.system(size: 11)).monospacedDigit() }
                        if r.m == nil { Text("没去过").font(.system(size: 11)).foregroundStyle(.secondary) }
                    }
                    if let m = r.m {
                        ForEach(Array(m.exits.enumerated()), id: \.offset) { _, e in
                            let known = model.maps[e.to].flatMap { NavDB.shared.locate([$0.street, $0.name]) }.map { r.goals.contains($0) } ?? false
                            Text("\(side(e.fx)) → \(model.maps[e.to]?.name ?? e.to)" + (e.door || known ? " ✓" : "（可能是坐车 / 回城 / NPC 传送）")).font(.system(size: 10))
                                .foregroundStyle(e.door || known ? Color(nsColor: Maple.done) : .secondary).padding(.leading, 14)
                        }
                        if plain, let n = model.met.maps[r.id], !n.isEmpty { Text("NPC：" + n.keys.sorted().joined(separator: "、")).font(.system(size: 10)).foregroundStyle(.secondary).padding(.leading, 14).fixedSize(horizontal: false, vertical: true) }
                        ForEach(r.missing, id: \.self) { g in
                            Text("还没走：→ \(NavDB.shared.maps[g]?.name ?? "")").font(.system(size: 10)).foregroundStyle(Color(nsColor: Maple.warn)).padding(.leading, 14)
                        }
                    }
                }
            }
        }.padding(12).frame(minWidth: 440, minHeight: 420)
    }
    private func side(_ f: Double) -> String { f < 0.15 ? "最左边" : f < 0.4 ? "左边" : f < 0.6 ? "中间" : f < 0.85 ? "右边" : "最右边" }
}
