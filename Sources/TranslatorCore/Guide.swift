// 同一张图里的隐藏传送点、采集向导：只算路和写字，不碰游戏。
import Foundation

public enum Warps {
    /// 走过去大概多远（上下要绕梯子，算远一点）
    static func cost(_ a: NavPoint, _ b: NavPoint) -> Double { abs(a.x - b.x) + abs(a.y - b.y) * 2.5 }
    /// 从 a 到 b 走隐藏传送点（可以接着走好几个）省一大截，就返回第一个要进的；不划算返回 nil
    public static func first(_ m: NavMap, from a: NavPoint, to b: NavPoint) -> [Double]? {
        guard let w = m.warps, !w.isEmpty else { return nil }
        func p(_ k: Int, _ o: Int) -> NavPoint { NavPoint(x: w[k][o], y: w[k][o + 1]) }
        let walk = cost(a, b)
        // best[k]：到达第 k 个入口、走完它落地时的最少花费；head[k]：这条路上第一个进的
        var best = w.indices.map { cost(a, p($0, 0)) + 60 }, head = Array(w.indices)
        for _ in w.indices { for i in w.indices { for j in w.indices where i != j {
            let d = best[i] + cost(p(i, 2), p(j, 0)) + 60
            if d < best[j] - 0.5 { best[j] = d; head[j] = head[i] }
        } } }
        guard let k = w.indices.min(by: { best[$0] + cost(p($0, 2), b) < best[$1] + cost(p($1, 2), b) }) else { return nil }
        let total = best[k] + cost(p(k, 2), b)
        return total < walk * 0.65 && walk - total > 400 ? w[head[k]] : nil
    }
    /// 太近的（传不远）分不清是走过去的还是传过去的，不用采
    public static func worth(_ w: [Double]) -> Bool { abs(w[0] - w[2]) + abs(w[1] - w[3]) >= 250 }
    /// 刚才在入口、一眨眼到了出口：走过了第几个
    public static func passed(_ m: NavMap, from a: NavPoint, to b: NavPoint) -> Int? {
        func d(_ x: Double, _ y: Double, _ q: NavPoint) -> Double { max(abs(x - q.x), abs(y - q.y)) }
        let hits = (m.warps ?? []).enumerated().filter { worth($0.element) && d($0.element[0], $0.element[1], a) <= 90 && d($0.element[2], $0.element[3], b) <= 100 }
        return hits.min { d($0.element[2], $0.element[3], b) < d($1.element[2], $1.element[3], b) }?.offset
    }
}

/// 采集向导的下一步
public struct GuideStep: Sendable, Equatable {
    public var route: NavRoute
    /// 这一步完成后算采好的那一项；nil = 还在路上
    public var key: String?
    public var title: String
    public var goalMap: Int
    /// 这张图还差几项（到了要采的图才有）
    public var left: Int
}

extension NavDB {
    /// 一张图要采的：每个通往别的图的门一项（同一目标图的几个门算一项），每个隐藏传送点、每个 NPC 一项
    public func guideItems(_ id: Int) -> [String] {
        guard let m = maps[id] else { return [] }
        var seen = Set<Int>()
        let doors = m.portals.filter { $0[3] >= 0 && maps[Int($0[0])] != nil && seen.insert(Int($0[0])).inserted }.map { "\(id)-\(Int($0[0]))" }
        return doors + (m.warps ?? []).enumerated().filter { Warps.worth($0.element) }.map { "\(id)w\($0.offset)" }
            + m.npcs.filter { npcName(Int($0[0])) != "?" }.map { "\(id)n\(Int($0[0]))" }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
    }
    /// 下一步去采什么。done：采好的和跳过的；goal：用户点了要去的图；skipMaps：跳过的图
    public func guide(from: Int, me: NavPoint? = nil, done: Set<String>, goal: Int? = nil, skipMaps: Set<Int> = []) -> GuideStep? {
        guard let m = maps[from] else { return nil }
        func todo(_ id: Int) -> [String] { skipMaps.contains(id) ? [] : guideItems(id).filter { !done.contains($0) } }
        if goal == nil || goal == from, case let t = todo(from), !t.isEmpty {
            // 离自己近的先采；不知道自己在哪就先门后传送点
            func points(_ k: String) -> [NavPoint] {
                if let n = npc(k, m) { return [NavPoint(x: n[1], y: n[2])] }
                if let w = warp(k, m) { return [NavPoint(x: w[0], y: w[1])] }
                return m.portals.filter { $0[3] >= 0 && "\(from)-\(Int($0[0]))" == k }.map { NavPoint(x: $0[1], y: $0[2]) }
            }
            func far(_ k: String) -> Double { me.flatMap { a in points(k).map { Warps.cost(a, $0) }.min() } ?? 0 }
            let k = t.enumerated().min { (far($0.element), $0.offset) < (far($1.element), $1.offset) }!.element
            var r: NavRoute, title: String
            if let n = npc(k, m) {
                title = "\(side(m, n[1], n[2]))的 NPC \(npcName(Int(n[0])))"
                r = NavRoute(steps: [title + "，走到屏幕里看得到就行"], arrived: false, uncertain: false, next: points(k), kind: .npc)
                r.npcName = npcName(Int(n[0]))
            } else if let w = warp(k, m) {
                title = "\(side(m, w[0], w[1]))的隐藏传送点 → \(side(m, w[2], w[3]))"
                r = NavRoute(steps: [title + (w[4] == 3 ? "（走上去自动传）" : "，站上去按 ↑")], arrived: false, uncertain: false, next: points(k), kind: w[4] == 3 ? .portalAuto : .hidden)
            } else {
                let p = m.portals.first { $0[3] >= 0 && "\(from)-\(Int($0[0]))" == k }!
                title = "\(side(m, p[1], p[2]))的门 → \(mapName(Int(p[0])))"
                r = NavRoute(steps: [title + (p[3] == 3 ? "（走进去自动传）" : "，按 ↑") + "，到了那边停 3 秒"], arrived: false, uncertain: false, next: points(k), kind: p[3] == 3 ? .portalAuto : .portalUp)
            }
            r.goalMap = from
            return GuideStep(route: r, key: k, title: title, goalMap: from, left: t.count)
        }
        let goals = goal.map { [$0] } ?? maps.keys.filter { $0 != from && !todo($0).isEmpty }
        guard goal != from, let (r, end) = walk(from: from, goals: Dictionary(goals.map { ($0, 0) }, uniquingKeysWith: { a, _ in a })) else { return nil }
        return GuideStep(route: r, key: nil, title: "去「\(mapName(end))」，走 \(r.hops) 张图", goalMap: end, left: todo(end).count)
    }
    /// 采集项是 NPC 的话，返回 [编号, x, y]
    func npc(_ k: String, _ m: NavMap) -> [Double]? {
        guard k.hasPrefix("\(m.id)n"), let i = Double(k.dropFirst("\(m.id)n".count)) else { return nil }
        return m.npcs.first { $0[0] == i }
    }
    /// 正站在哪个 NPC 旁边
    public func npcNear(_ m: NavMap, _ p: NavPoint) -> Int? {
        m.npcs.filter { abs($0[1] - p.x) <= 90 && abs($0[2] - p.y) <= 70 }.min { abs($0[1] - p.x) < abs($1[1] - p.x) }.map { Int($0[0]) }
    }
    /// 屏幕里看得到的 NPC：离自己不到一屏（按 800×600 算），而且小地图上有它的绿点。返回编号和绿点的位置
    public func npcsSeen(_ m: NavMap, _ me: NavPoint, green: [NavPoint]) -> [(id: Int, at: NavPoint)] {
        m.npcs.compactMap { n in
            guard abs(n[1] - me.x) <= 380, abs(n[2] - me.y) <= 280 else { return nil }
            let d = green.map { (p: $0, d: hypot($0.x - n[1], $0.y - n[2])) }.min { $0.d < $1.d }
            guard let d, d.d <= 80 else { return nil }
            return (Int(n[0]), d.p)
        }
    }
    private func warp(_ k: String, _ m: NavMap) -> [Double]? {
        guard k.hasPrefix("\(m.id)w"), let i = Int(k.dropFirst("\(m.id)w".count)), let w = m.warps, w.indices.contains(i) else { return nil }
        return w[i]
    }
}
