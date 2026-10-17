import SwiftUI
import CaptionCore

struct SpeechKeywordIndicators: View {
    let highlighted: Set<JapaneseKiraKeyword>
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach([false, true], id: \.self) { backup in
                HStack(spacing: 8) {
                    Text(backup ? "备选" : "主词").font(.system(size: 9)).foregroundStyle(.secondary)
                    ForEach(JapaneseKiraKeyword.allCases.filter { $0.isBackup == backup }, id: \.rawValue) { keyword in
                        let hit = highlighted.contains(keyword)
                        HStack(spacing: 4) {
                            Text(keyword.rawValue).fontWeight(hit ? .bold : .regular)
                            if hit { Image(systemName: "checkmark.circle.fill"); Text("已命中").font(.system(size: 9)) }
                        }
                        .font(.system(size: 11))
                        .foregroundStyle(hit ? Color.orange : Color.secondary)
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(hit ? Color.orange.opacity(0.18) : Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(hit ? Color.orange.opacity(0.7) : .clear, lineWidth: 1))
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(keyword.rawValue) · \(hit ? "已命中" : "等待识别")")
                    }
                }
            }
        }
        .animation(.easeOut(duration: 0.2), value: highlighted)
    }
}
