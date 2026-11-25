// 怪物的图、等级、血量、刷新点（Mobs.json，游戏素材，只自用，不进仓库、不放公开版；没有这个文件时没有怪物列表）。
import Foundation

public final class MobBook: @unchecked Sendable {
    public struct Info: Decodable, Sendable { public var lv: Int?, hp: Int?, exp: Int?, png: Data? }
    struct File: Decodable { var mobs: [String: Info], spawns: [String: [String: [[Double]]]] }
    public static let shared: MobBook = {
        let u = GameData.url("Mobs") ?? Bundle.main.url(forResource: "Mobs", withExtension: "json") ?? URL(fileURLWithPath: "Assets/Mobs.json")
        return MobBook((try? Data(contentsOf: u)).flatMap { try? JSONDecoder().decode(File.self, from: $0) })
    }()
    private let mobs: [String: Info], spawns: [String: [String: [[Double]]]]
    private init(_ f: File?) { mobs = f?.mobs ?? [:]; spawns = f?.spawns ?? [:] }
    public var isEmpty: Bool { mobs.isEmpty }
    public func info(_ en: String) -> Info? { mobs[en] }
    /// 这张图的怪和刷新点数，等级低的在前
    public func list(in map: Int) -> [(name: String, n: Int)] {
        (spawns[String(map)] ?? [:]).map { (name: $0.key, n: $0.value.count) }
            .sorted { (mobs[$0.name]?.lv ?? 999, $0.name) < (mobs[$1.name]?.lv ?? 999, $1.name) }
    }
    /// 带路去最近的刷新点
    public func route(in map: Int, mob: String) -> NavRoute? {
        let p = (spawns[String(map)]?[mob] ?? []).filter { $0.count == 2 }.map { NavPoint(x: $0[0], y: $0[1]) }
        guard !p.isEmpty else { return nil }
        var r = NavRoute(steps: ["这张图就有 \(NavDB.shared.mobName(mob))"], arrived: true, uncertain: false, next: p, kind: .mob)
        r.goalMap = map; r.npcName = mob
        return r
    }
}
