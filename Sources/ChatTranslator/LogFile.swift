// 运行日志：只写在本机，出错时好查。不写聊天内容，不上传。满 4 MB 换新的，只留上一份。
import Foundation

enum LogFile {
    static let dir = dataDir.appendingPathComponent("日志")
    private static let url = dir.appendingPathComponent("MoguHelper.log"), old = dir.appendingPathComponent("MoguHelper-上一份.log")
    private static let queue = DispatchQueue(label: "log", qos: .utility)
    private static var handle: FileHandle?, size = 0, last: [String: Date] = [:]
    private static let stamp: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "MM-dd HH:mm:ss.SSS"; return f }()
    static var on: Bool {
        get { UserDefaults.standard.object(forKey: "logOn") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "logOn") }
    }
    /// 每秒都有、查问题用不上的
    private static let skip = ["lines=", "字形:", "translate timeout", "tip 没找到说明框"]
    static func write(_ s: String) {
        guard on, !skip.contains(where: s.hasPrefix) else { return }
        let now = Date()
        queue.async {
            // 同一句一分钟只写一次
            if let t = last[s], now.timeIntervalSince(t) < 60 { return }
            if last.count > 500 { last = last.filter { now.timeIntervalSince($0.value) < 60 } }
            last[s] = now
            if handle == nil { open() }
            guard let d = "\(stamp.string(from: now)) \(s.replacingOccurrences(of: "\n", with: " "))\n".data(using: .utf8) else { return }
            try? handle?.write(contentsOf: d)
            size += d.count
            if size > 4_000_000 {
                try? handle?.close(); handle = nil
                try? FileManager.default.removeItem(at: old)
                try? FileManager.default.moveItem(at: url, to: old)
            }
        }
    }
    private static func open() {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        handle = try? FileHandle(forWritingTo: url)
        size = Int((try? handle?.seekToEnd()) ?? 0)
    }
}
