// 文字识别：只处理传进来的图片（内存中），不接触游戏进程，不写文件。
import Foundation
import Vision
import CoreImage
import CoreGraphics

/// 识别出的一行文字。坐标是相对图片的 0~1，左上角为原点。
public struct OCRLine: Sendable, Codable {
    public var text: String
    public var minX: Double
    public var maxX: Double
    public var minY: Double   // 顶部
    public var maxY: Double   // 底部
    public var confidence: Double = 1   // 识别把握（0~1）
    /// 其他候选写法（整行）。物品说明里的单个数字容易认错（+6 → +b），从候选里挑像数字的那个
    public var alternatives: [String]? = nil

    public init(text: String, minX: Double, maxX: Double, minY: Double, maxY: Double, confidence: Double = 1) {
        self.text = text; self.minX = minX; self.maxX = maxX; self.minY = minY; self.maxY = maxY; self.confidence = confidence
    }
}

public final class ChatOCR: @unchecked Sendable {
    private let ciContext = CIContext()
    public var upscale: Double
    public var customWords: [String]
    /// 语言纠错：聊天句子打开更准；物品说明里的数字（+6、-1）打开反而会被“纠正”成字母，关掉
    public var languageCorrection = true
    /// 同时返回候选写法（物品说明用）
    public var wantAlternatives = false
    /// 快速模式：准确度稍低，但不需要加载大模型，马上可用
    public var fast: Bool

    public init(upscale: Double = 1.5, customWords: [String] = [], fast: Bool = false) {
        self.upscale = upscale
        self.customWords = customWords
        self.fast = fast
    }

    /// 识别整张图片里的文字行，并去掉“背景串进来”的碎片（例如聊天框背后的角色名）。
    public func recognize(_ image: CGImage) throws -> [OCRLine] {
        // 每次识别产生的临时对象当场释放，长时间运行内存不累积
        try autoreleasepool { try recognizeInPool(image) }
    }

    private func recognizeInPool(_ image: CGImage) throws -> [OCRLine] {
        var cg = image
        if upscale != 1.0 {
            let ci = CIImage(cgImage: image)
                .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: upscale, kCIInputAspectRatioKey: 1.0])
            if let scaled = ciContext.createCGImage(ci, from: ci.extent) { cg = scaled }
        }
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = fast ? .fast : .accurate
        req.recognitionLanguages = ["en-US"]
        req.usesLanguageCorrection = languageCorrection
        req.customWords = customWords
        try VNImageRequestHandler(cgImage: cg, options: [:]).perform([req])

        var lines: [OCRLine] = []
        for obs in req.results ?? [] {
            let cands = obs.topCandidates(wantAlternatives ? 10 : 1)
            guard let cand = cands.first else { continue }
            let parts = splitAtLargeGaps(cand, lineBox: obs.boundingBox)
            lines.append(contentsOf: parts.map {
                var l = $0; l.confidence = Double(cand.confidence)
                if wantAlternatives, parts.count == 1, cands.count > 1 { l.alternatives = cands.dropFirst().map(\.string) }
                return l
            })
        }
        return lines
    }

    /// 物品说明框：用两种放大倍数各识别一次再合并。单次识别偶尔整行漏掉（实测 2 倍时漏了 “Type: Hat”），
    /// 以第一种为准，另一种里多出来的行（和已有行上下不重叠）补进去。
    public static func recognizeMerged(_ image: CGImage, primary: ChatOCR, secondary: ChatOCR) throws -> [OCRLine] {
        var lines = try primary.recognize(image)
        for l in try secondary.recognize(image) {
            let mid = (l.minY + l.maxY) / 2
            let overlaps = lines.contains { mid >= $0.minY && mid <= $0.maxY && l.minX < $0.maxX && l.maxX > $0.minX }
            if !overlaps { lines.append(l) }
        }
        return lines
    }

    /// Vision 有时把同一高度、但隔得很远的两段文字认成一行（例如聊天文字 + 背后的名牌）。
    /// 按单词间距切开，间距远大于字宽的地方视为两段。
    private func splitAtLargeGaps(_ cand: VNRecognizedText, lineBox: CGRect) -> [OCRLine] {
        let s = cand.string
        var words: [(range: Range<String.Index>, box: CGRect)] = []
        var idx = s.startIndex
        for w in s.split(separator: " ", omittingEmptySubsequences: true) {
            guard let r = s.range(of: w, range: idx..<s.endIndex) else { continue }
            idx = r.upperBound
            if let b = try? cand.boundingBox(for: r)?.boundingBox { words.append((r, b)) }
        }
        func make(_ from: Int, _ to: Int) -> OCRLine {
            let text = String(s[words[from].range.lowerBound..<words[to].range.upperBound])
            let boxes = words[from...to].map(\.box)
            let minX = boxes.map(\.minX).min()!, maxX = boxes.map(\.maxX).max()!
            return OCRLine(text: text, minX: minX, maxX: maxX,
                           minY: 1 - lineBox.maxY, maxY: 1 - lineBox.minY)
        }
        guard words.count > 1 else {
            return [OCRLine(text: s, minX: lineBox.minX, maxX: lineBox.maxX, minY: 1 - lineBox.maxY, maxY: 1 - lineBox.minY)]
        }
        let charW = lineBox.width / Double(max(s.count, 1))
        var out: [OCRLine] = []
        var start = 0
        for i in 1..<words.count {
            let gap = words[i].box.minX - words[i - 1].box.maxX
            if gap > charW * 3.5 {
                out.append(make(start, i - 1))
                start = i
            }
        }
        out.append(make(start, words.count - 1))
        return out
    }
}
