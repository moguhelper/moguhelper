// 背包 Etc 页的东西：任务要的留着，任务用不到的写明
import AppKit
import SwiftUI
import TranslatorCore

struct KeepView: View {
    @ObservedObject var exp: ExpMonitor
    /// 自己点过“做过了”的任务，每个角色分开记
    @State private var done: Set<Int> = []
    private var key: String { "questDone@\(exp.model.name)" }
    var body: some View {
        let rows = exp.etcBag.map { (name: $0.key, n: $0.value, need: NavDB.shared.needs($0.key, done: done)) }
            .sorted { ($0.need.isEmpty ? 1 : 0, $0.name) < ($1.need.isEmpty ? 1 : 0, $1.name) }
        VStack(alignment: .leading, spacing: 8) {
            Text("打开背包 Etc 页停两秒，看到哪一屏就列哪一屏。只按任务判断，制作要不要没算；做过的任务点一下“做过了”就不再算。").font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if rows.isEmpty { Text("还没看到背包。") }
            List(rows, id: \.name) { r in
                HStack(alignment: .top, spacing: 8) {
                    ItemIconView(name: r.name, fallback: " ").frame(width: 34, height: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("\(ItemDB.shared.exact(r.name)?.zh ?? r.name) ×\(r.n)").font(.system(size: 12, weight: .bold))
                            Spacer()
                            if r.need.isEmpty { Text("任务用不到，可以卖").font(.system(size: 11)).foregroundStyle(.secondary) }
                            else {
                                let most = r.need.map(\.count).reduce(0, +)
                                Text(r.n > most ? "留 \(most) 个，多的 \(r.n - most) 个可以卖" : "留着，一共要 \(most) 个").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color(nsColor: Maple.done))
                            }
                        }
                        ForEach(r.need) { q in
                            HStack { Text("\(q.title)：\(q.count) 个").font(.system(size: 11)).foregroundStyle(.secondary); Spacer()
                                Button("做过了") { done.insert(q.id); UserDefaults.standard.set(done.sorted(), forKey: key) }.controlSize(.mini) }
                        }
                    }
                }
            }
            if !done.isEmpty { Button("恢复标成做过的 \(done.count) 个任务") { done = []; UserDefaults.standard.removeObject(forKey: key) }.controlSize(.small) }
        }.padding(12).frame(minWidth: 460, minHeight: 420)
        .onAppear { load() }
        .onChange(of: exp.model.name) { load() }
    }
    private func load() { done = Set(UserDefaults.standard.array(forKey: key) as? [Int] ?? []) }
}
