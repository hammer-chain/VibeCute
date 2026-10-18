import SwiftUI
import CaptionCore
import AppKit

struct DeveloperSettingsView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("开发者模式").font(.title2)
                Toggle("启用开发者模式（显示隐藏角色）", isOn: $model.developerModeEnabled)
                Text(Bundle.main.bundleURL.standardizedFileURL.path)
                    .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                Button("在访达中显示应用") {
                    NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                }
                GroupBox("动作与字幕预览") { actionPreviews }
                GroupBox("桌面天气预览") {
                    VStack(alignment: .leading, spacing: 10) {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]) {
                            ForEach(DesktopWeatherPreview.allCases) { weather in
                                Button(weather.rawValue) { model.previewWeather(weather) }
                                    .accessibilityIdentifier("weather-preview-" + weather.id)
                            }
                        }
                        Button("停止天气预览") { model.stopWeatherPreview() }
                        Text(model.weatherPreviewStatus).font(.caption).foregroundStyle(.secondary)
                        Text("预览使用本地效果，无需联网且默认静音；关闭此窗口后恢复原设置。小雨、中雨、大雨、雷雨会触发蓝鱼拿盆避雨；没有位置时在附近往返跑。")
                            .font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox("角色开发") {
                    VStack(alignment: .leading, spacing: 10) {
                        Button("对比 DeepSeek 两版…") { CutoutComparisonController.shared.show() }
                        Button("开启cutout工作台") { CutoutStudioController.shared.show() }
                        HStack {
                            Text("台词间隔")
                            Slider(value: $model.akimboUtterancePause, in: AkimboReaction.utterancePauseRange, step: 0.1)
                                .accessibilityLabel("台词间隔")
                            Text(String(format: "%.1f 秒", model.akimboUtterancePause)).monospacedDigit()
                        }
                        Text("蓝鱼叉腰台词，每句打完后的停顿。")
                            .font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox("音效试听") {
                    HStack {
                        ForEach(TaskOutcome.allCases) { outcome in
                            Button("\(outcome.title) · \(outcome.soundName)") { model.previewTaskSound(outcome) }
                        }
                    }
                }
                GroupBox("声音与语音识别调试") { audioDiagnostics }
                GroupBox("背景与窗口诊断") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(model.avoidanceStatus)
                        Button("立即检查背景") { model.recheckBackdrop() }
                        Text(model.autoWindowPeekLabel)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
        }.frame(minWidth: 460, idealWidth: 500, minHeight: 420, idealHeight: 740)
    }

    private var actionPreviews: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("预览角色", selection:$model.developerPreviewCharacter) {
                ForEach(model.availableCharacters) { character in Text(character.title).tag(character) }
            }.accessibilityIdentifier("developer-preview-character")
            Text("仅预览所选角色，其他角色照常显示；灰色动作尚未制作。")
                .font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns:[GridItem(.flexible()),GridItem(.flexible())],alignment:.leading,spacing:8) {
                ForEach(DeveloperPreviewAction.allCases) { action in
                    Button(action.title) { model.previewAction(action) }
                        .disabled(!action.supports(model.developerPreviewCharacter))
                        .accessibilityIdentifier("developer-preview-"+action.rawValue)
                }
            }.controlSize(.small)
            HStack {
                Button("停止预览") { model.stopPreview() }
                Button("多个项目字幕") { model.showDemo(multiple:true) }
            }.controlSize(.small)
            Text(model.developerPreviewStatus).font(.caption).foregroundStyle(.secondary)
            Button("检查所选角色背景") { model.previewAction(.thinking); model.recheckBackdrop() }
                .disabled(!model.autoAvoidanceEnabled || !DeveloperPreviewAction.shortAvoidance.supports(model.developerPreviewCharacter))
            Text("动作预览不依赖背景空位；背景实测需开启自动避让，并在附近有足够空白。")
                .font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var audioDiagnostics: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("开启口型识别（开启可能影响系统性能）", isOn: $model.audioEnabled)
            Button("预览 Kira") { model.previewAction(.kira) }.disabled(!DeveloperPreviewAction.kira.supports(model.developerPreviewCharacter))
            if model.songRecognitionEnabled {
                Text(model.songRecognitionLabel).font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(model.kiraMarkerLabel).font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("标记此刻 Kira") { model.markKiraNow() }.disabled(!model.canMarkKira)
                    Button("清除此版本标记") { model.clearKiraMarkers() }.disabled(!model.canMarkKira)
                }.controlSize(.small)
                Text("支持中日文及罗马字标题；标题匹配不是听音确认。\n标记仅用于相同播放版本，翻唱需分别标记。")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            if model.audioEnabled {
                Picker("口型匹配", selection: $model.audioLipEngine) {
                    ForEach(LipMatchingEngine.available) { Text($0.title).tag($0) }
                }.controlSize(.small)
                Text(model.lipMatchingStatus).font(.system(size: 10)).foregroundStyle(.secondary)
                if !SpeechEngine.minimalRelease {
                    Toggle("人声分离（实验）", isOn: $model.vocalSeparationEnabled)
                        .toggleStyle(.checkbox).font(.system(size: 12))
                }
                if model.vocalSeparationEnabled {
                    Text(model.vocalSeparationStatus).font(.system(size: 10)).foregroundStyle(.secondary)
                    Text("减少伴奏对口型的干扰，身体仍跟随完整节拍。部分声音可能失真，可随时关闭比较。")
                        .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Toggle("关键词命中后 Kira", isOn: $model.speechKeywordEnabled)
                    .toggleStyle(.checkbox).font(.system(size: 12))
                if model.speechKeywordEnabled {
                    SpeechKeywordIndicators(highlighted: model.speechHighlightedKeywords)
                    Picker("语音识别方案", selection: $model.speechEngine) {
                        ForEach(SpeechEngine.available) { engine in Text(engine.title).tag(engine) }
                    }.font(.system(size: 12))
                    if model.speechEngine == .whisper {
                        Text("模型：\(model.whisperModelLabel)")
                            .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
                        HStack {
                            Button("选择模型…") { model.chooseWhisperModel() }
                            Button("内置 small") { model.whisperModelPath = "" }
                        }.controlSize(.small)
                    }
                    Text(model.speechStatus).font(.system(size: 10)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(model.audioRecognitionActive ? "声音分类正在运行" : "等待声音 · 声音分类模型已停止")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    HStack {
                        Text("主词命中后到 Kira")
                        Slider(value: $model.speechKiraDelay, in: 0.5...8, step: 0.1)
                        Text(String(format: "%.1f 秒", model.speechKiraDelay)).monospacedDigit()
                    }.font(.system(size: 10))
                    HStack {
                        Text("备选词额外等待")
                        Slider(value: $model.speechBackupExtraDelay, in: 0.5...6, step: 0.1)
                        Text(String(format: "+%.1f 秒", model.speechBackupExtraDelay)).monospacedDigit()
                    }.font(.system(size: 10))
                    Text(String(format: "备选词命中后等待 %.1f 秒；同一句只触发一次。", model.speechKiraDelay + model.speechBackupExtraDelay))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    Text(model.speechCountdownLabel).font(.system(size: 10)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !model.speechKeywordTimingLabel.isEmpty {
                        Text(model.speechKeywordTimingLabel).font(.system(size: 10)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.speechInputLabel)
                        Text(model.speechResultLabel)
                        Text(model.speechEngine == .whisper ? "重叠窗口识别 · 按返回时刻计时，词末延迟未知" : model.speechProgress.timingLabel)
                    }.font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !model.speechTranscript.isEmpty {
                        Text("日语识别：\(String(model.speechTranscript.suffix(80)))")
                            .font(.system(size: 11)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                    DisclosureGroup("最近文字变化与分段") {
                        VStack(alignment: .leading, spacing: 7) {
                            Text("第 \(model.speechProgress.requestNumber) 段 · \(model.speechProgress.requestReason)")
                            ForEach(Array(model.speechHistory.enumerated()), id: \.offset) { _, entry in
                                Text(entry).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                            }
                            Text("时间从本次输入开始计算。仅保留内存中的 4 次变化。\n词末间隔大也可能是漏词或伴奏，不能单独判定识别积压。")
                                .foregroundStyle(.secondary)
                        }.font(.system(size: 10))
                    }.font(.system(size: 10))
                    HStack {
                        Button("重试识别") { model.retrySpeech() }
                        Button("模拟关键词倒计时") { model.showSpeechDemo() }
                    }.controlSize(.small)
                    Text(model.speechEngine == .whisper
                         ? "Whisper 仅在本机运行，不需要 Apple 语音授权。\n每次识别最近最多 \(WhisperKeywordSpeech.windowSeconds) 秒，窗口结果可能改写。\n按返回时刻倒计时；伴奏下的准确率和拍点需实测。\n不依赖歌曲标题，普通对话也可能命中。"
                         : "仅本机日语识别，首次使用需系统授权。\n不依赖歌曲标题；普通对话说到此词也可能命中。\n临时结果从返回时刻起算，定稿结果补偿词时间。\n3 秒为可调整试验值，需对照实际歌曲校准。")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Toggle("开启人声增强", isOn: $model.audioVoicePriority)
                    .toggleStyle(.checkbox).font(.system(size: 12))
                Toggle("开启唱歌识别", isOn: $model.singingActionEnabled)
                    .toggleStyle(.checkbox).font(.system(size: 12))
                Picker("节拍方案", selection: $model.audioTempoEngine) {
                    ForEach(TempoEngine.available) { engine in Text(engine.title).tag(engine) }
                }.font(.system(size: 12))
                if model.audioTempoEngine == .beatnet {
                    Text(BeatNetRuntime.availability).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                settingSlider("灵敏度", value: $model.audioSensitivity, range: 0.25...4,
                              valueText: String(format: "%.1f×", model.audioSensitivity))
                ProgressView(value: model.audioLevel).tint(model.audioVoiceLike ? .mint : .gray)
                Text("声音类型：\(model.audioSceneLabel)").font(.system(size: 10)).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text("识别音乐速度")
                        Spacer()
                        Text(model.musicTempoLabel).monospacedDigit().foregroundStyle(.primary)
                    }
                    HStack {
                        Text("动画播放速度")
                        Spacer()
                        Text(model.animationPlaybackLabel).monospacedDigit().foregroundStyle(.primary)
                            .lineLimit(1).minimumScaleFactor(0.8)
                    }
                }.font(.system(size: 10)).foregroundStyle(.secondary)
                if !model.tempoEvidenceLabel.isEmpty {
                    Text(model.tempoEvidenceLabel).font(.system(size: 10)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Text(model.singingActionLabel).font(.system(size: 10)).foregroundStyle(.secondary)
                    Spacer()
                    Button("预览起身唱歌") { model.previewAction(.singing) }.disabled(!DeveloperPreviewAction.singing.supports(model.developerPreviewCharacter)).buttonStyle(.link).font(.system(size: 10))
                }
                if !model.audioInstruments.isEmpty {
                    Text("可能乐器：\(model.audioInstruments)").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                HStack {
                    Text("当前口型：\(model.audioMouthLabel)").font(.system(size: 10)).foregroundStyle(.secondary)
                    Spacer()
                    Button("预览口型") { model.previewAction(.mouth) }.disabled(!DeveloperPreviewAction.mouth.supports(model.developerPreviewCharacter)).buttonStyle(.link).font(.system(size: 10))
                }
                Text(model.audioStatus).font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("离线判断讲话、歌声与音乐，类型切换约需 1–2 秒。\n人声增强会抑制无明显人声的片段，未分离伴奏；\n较轻的人声可能被漏掉，可关闭人声增强比较。\n12 个口型姿态，只在本机分析，不保存声音。")
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineSpacing(2)
                Button("系统录音权限…") { model.openAudioPermissions() }.buttonStyle(.link).font(.system(size: 10))
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func settingSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, valueText: String) -> some View {
        HStack {
            Text(title)
            Slider(value: value, in: range)
            Text(valueText).monospacedDigit()
        }.font(.system(size: 12))
    }
}
