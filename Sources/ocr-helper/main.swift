// 文字识别小助手（由聊天翻译程序启动的子进程）
// 从标准输入读取：4 字节长度（大端）+ PNG 图片数据；向标准输出写一行 JSON（识别出的文字行）。
// 只处理传进来的图片，不接触游戏，不写文件。
import Foundation
import ImageIO
import OCRCore

setvbuf(stdout, nil, _IOLBF, 0)
let t0 = Date()
func log(_ s: String) { FileHandle.standardError.write(Data(String(format: "[helper %.2fs] %@\n", Date().timeIntervalSince(t0), s).utf8)) }
log("start qos=\(qos_class_self().rawValue)")
// 自定义词由主程序通过环境变量传进来（不在这里读词表，免得词表、解析代码一改子进程就跟着变）
let words = (ProcessInfo.processInfo.environment["CT_CUSTOM_WORDS"] ?? "").split(separator: "\n").map(String.init)
let ocr = ChatOCR(upscale: 1.5, customWords: words)
// 大图（物品说明框）：游戏的像素字体里数字容易认错，实测放大 2 倍最准
let ocrLarge = ChatOCR(upscale: 2.0, customWords: words)
let ocrLarge2 = ChatOCR(upscale: 1.5, customWords: words)
let input = FileHandle.standardInput

// 主程序没了（退出、被杀、重新打包）就跟着退出：卡在系统识别里时读不到输入结束，会一直留着变成孤儿
Thread.detachNewThread {
    while getppid() != 1 { sleep(2) }
    exit(0)
}

func readExactly(_ n: Int) -> Data? {
    var buf = Data()
    while buf.count < n {
        let chunk = input.readData(ofLength: n - buf.count)
        if chunk.isEmpty { return nil }
        buf.append(chunk)
    }
    return buf
}

while let head = readExactly(4) {
    let len = head.withUnsafeBytes { Int(UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self))) }
    guard let png = readExactly(len) else { break }
    log("got image \(len) bytes")
    var lines: [OCRLine]? = []      // 识别出错时回 null，主程序才分得清“没有字”和“没识别成”
    autoreleasepool {
        if let src = CGImageSourceCreateWithData(png as CFData, nil),
           let img = CGImageSourceCreateImageAtIndex(src, 0, nil) {
            if img.width >= 600 {
                lines = try? ChatOCR.recognizeMerged(img, primary: ocrLarge, secondary: ocrLarge2)
            } else {
                lines = try? ocr.recognize(img)
            }
        }
    }
    log("recognized \(lines?.count ?? -1) lines")
    let json = (try? JSONEncoder().encode(lines)) ?? Data("[]".utf8)
    FileHandle.standardOutput.write(json)
    FileHandle.standardOutput.write(Data("\n".utf8))
}
