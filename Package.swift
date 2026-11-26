// swift-tools-version: 6.0
import Foundation
import PackageDescription

let package = Package(
    name: "ChatTranslator",
    platforms: [.macOS("26.0")],
    targets: [
        // 核心流程：识别 → 整理 → 词表 → 翻译（不涉及任何游戏进程）
        // 文字识别：单独一个库，识别子进程只依赖它。别的代码改动不会让子进程跟着变（变了系统要重新编译识别模型）
        .target(name: "OCRCore"),
        .target(name: "TranslatorCore", dependencies: ["OCRCore"], resources: [.copy("Glossary.json"), .copy("Slang.json"), .copy("Quests.json"), .copy("QuestNames.json"), .copy("Items.json"), .copy("Maps.json"), .copy("ItemSources.json"), .copy("QuestTips.json"), .copy("Glyphs.json")]),
        .executableTarget(name: "ocr-helper", dependencies: ["OCRCore"]),
        // 图形界面（第二步）
        .executableTarget(name: "ChatTranslator", dependencies: ["TranslatorCore"]),
    ],
    swiftLanguageModes: [.v5]
)

// 只在本机有的测试程序（private/ 不进仓库）
for n in ["pipeline-test", "capture-test", "quick-test"] where FileManager.default.fileExists(atPath: Context.packageDirectory + "/private/Sources/\(n)/main.swift") {
    package.targets.append(.executableTarget(name: n, dependencies: ["TranslatorCore"], path: "private/Sources/\(n)"))
}
