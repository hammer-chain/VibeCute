import Foundation

enum DeveloperPreviewAction: String, CaseIterable, Identifiable {
    case thinking, mouth, singing, shortAvoidance, stroll, sleep, singingStep, frontRetreat, windowPeek, windowSeat, kira
    var id: String { rawValue }
    var title: String {
        switch self {
        case .thinking: return "思考与眨眼"
        case .mouth: return "口型"
        case .singing: return "起身唱歌"
        case .shortAvoidance: return "短程避让动作"
        case .stroll: return "起身小跑"
        case .sleep: return "趴睡与醒来"
        case .singingStep: return "唱歌小步移动"
        case .frontRetreat: return "正面急退"
        case .windowPeek: return "窗口后探头"
        case .windowSeat: return "坐在窗口"
        case .kira: return "Kira"
        }
    }
    func supports(_ character: CharacterChoice) -> Bool {
        switch self {
        case .thinking: return true
        case .mouth: return [.codex,.deepseek,.orangeHoodie].contains(character)
        case .singing, .shortAvoidance: return [.deepseek,.orangeHoodie].contains(character)
        default: return character == .deepseek
        }
    }
}
