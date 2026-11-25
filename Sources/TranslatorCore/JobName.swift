// 状态栏里的职业名（英文 → 国服叫法），识别允许认错一个字母
import Foundation

public enum JobName {
    public static let zh: [String: String] = [
        "Beginner": "新手", "Warrior": "战士", "Magician": "魔法师", "Bowman": "弓箭手", "Archer": "弓箭手", "Thief": "飞侠", "Rogue": "飞侠",
        "Fighter": "剑客", "Page": "准骑士", "Spearman": "枪战士", "Crusader": "勇士", "White Knight": "骑士", "Dragon Knight": "龙骑士",
        "Wizard (Fire, Poison)": "火毒法师", "Wizard (Ice, Lightning)": "冰雷法师", "Wizard (Fire/Poison)": "火毒法师", "Wizard (Ice/Lightning)": "冰雷法师",
        "Wizard (F/P)": "火毒法师", "Wizard (I/L)": "冰雷法师", "F/P Wizard": "火毒法师", "I/L Wizard": "冰雷法师", "Cleric": "牧师",
        "Mage (Fire, Poison)": "火毒巫师", "Mage (Ice, Lightning)": "冰雷巫师", "F/P Mage": "火毒巫师", "I/L Mage": "冰雷巫师", "Priest": "祭司",
        "Hunter": "猎人", "Crossbowman": "弩弓手", "Ranger": "射手", "Sniper": "游侠",
        "Assassin": "刺客", "Bandit": "侠客", "Hermit": "无影人", "Chief Bandit": "独行客"]

    /// 一行识别结果里的职业：整行，或行里最后一两个词（“LV. 27 Magician” 会连成一行）
    public static func match(_ line: String) -> String? {
        let w = line.split(separator: " ").map(String.init)
        var cands = [line]
        for n in [4, 3, 2, 1] where w.count > n { cands.append(w.suffix(n).joined(separator: " ")) }
        for c in cands {
            let k = Fuzzy.normalize(c)
            guard k.count >= 4 else { continue }
            if let e = zh.keys.first(where: { Fuzzy.normalize($0) == k }) { return e }
        }
        for c in cands {
            let k = Fuzzy.normalize(c)
            guard k.count >= 6 else { continue }
            if let e = zh.keys.sorted().first(where: { let n = Fuzzy.normalize($0); return n.count >= 6 && Fuzzy.distance(k, n, limit: 1) <= 1 }) { return e }
        }
        return nil
    }
}
