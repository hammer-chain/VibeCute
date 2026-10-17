import AppKit
import SwiftUI
import CaptionCore

final class AppModel: ObservableObject {
    @Published var developerModeEnabled: Bool { didSet {
        if BuildProfile.isRelease && developerModeEnabled != false { developerModeEnabled = false; return }
        save("developerModeEnabled", developerModeEnabled)
        if !developerPreviewCharacter.isSelectable(developerMode:developerModeEnabled) { developerPreviewCharacter = .deepseek }
        bindingsChanged()
    } }
    @Published var developerPreviewCharacter: CharacterChoice { didSet {
        save("developerPreviewCharacter",developerPreviewCharacter.rawValue)
        if oldValue != developerPreviewCharacter { stopPreview() }
    } }
    @Published private(set) var developerPreviewStatus = "选择角色后预览动作"
    private var requestedPreviewCharacter: CharacterChoice?
    private var demoCharacterOverride: CharacterChoice?
    var developerPreviewArtwork: String? {
        guard demoMode else { return nil }
        return overlays.character(for:demoDeepSeek ? .deepseek : .codex)?.subtitle.mascotArtwork
    }
    func previewAction(_ action: DeveloperPreviewAction) {
        guard BuildProfile.experiments else { return }
        guard action.supports(developerPreviewCharacter) else {
            developerPreviewStatus = "该角色尚未制作此动作"; return
        }
        requestedPreviewCharacter = developerPreviewCharacter
        defer { requestedPreviewCharacter = nil }
        switch action {
        case .thinking: showDemo(deepSeek:true)
        case .mouth: showDemo(deepSeek:true); showMouthDemo()
        case .singing: showSingingDemo()
        case .shortAvoidance:
            if developerPreviewCharacter == .orangeHoodie { showOrangeHoodieAvoidanceDemo() }
            else { showScootDemo() }
        case .stroll: showStrollDemo()
        case .sleep: showSleepDemo()
        case .singingStep: showSingingStepDemo()
        case .frontRetreat: showFrontRetreatDemo()
        case .windowPeek: showWindowPeek()
        case .windowSeat: showWindowSeat()
        case .kira: showKiraDemo()
        }
        developerPreviewStatus = "\(developerPreviewCharacter.title) · \(action.title)"
    }
    var availableCharacters: [CharacterChoice] { CharacterChoice.selectable(developerMode: developerModeEnabled) }
    var companionChoice: CharacterChoice {
        CharacterChoice.resolved(companionCharacter.rawValue, developerMode: developerModeEnabled)
    }
    func bindCompanion(_ choice: CharacterChoice) {
        guard choice.isSelectable(developerMode: developerModeEnabled) else { return }
        companionCharacter = choice
    }
    @Published var enabled = true { didSet { configureAudio(); redraw() } }
    @Published var movable = true { didSet { redraw() } }
    @Published var bubblesFixedToCharacter: Bool { didSet {
        save("bubblesFixedToCharacter", bubblesFixedToCharacter); redraw()
    } }
    @Published var fontSize: Double { didSet { save("fontSize", fontSize); redraw() } }
    @Published var opacity: Double { didSet { save("opacity", opacity); redraw() } }
    @Published var bottom: Double { didSet { save("bottom", bottom); redraw() } }
    @Published var characterScale: Double { didSet { save("characterScale", characterScale); redraw() } }
    @Published var pinkBearBinding: PinkBearBinding { didSet {
        save("pinkBearBinding", pinkBearBinding.rawValue); redraw(); updateMouth()
    } }
    @Published var trackedHarnesses: Set<String> { didSet {
        save("trackedHarnesses", trackedHarnesses.sorted()); trackingChanged()
    } }
    @Published var companionEnabled: Bool { didSet {
        save("companionEnabled", companionEnabled); bindingsChanged()
    } }
    @Published var companionCharacter: CharacterChoice { didSet {
        save("companionCharacter", companionCharacter.rawValue); bindingsChanged()
    } }
    private var companionSource: CaptionMascot {
        .companion
    }
    @Published var companionHair: String { didSet { save("companionHair", companionHair); redraw() } }
    var companionHairstyle: String {
        #if VIBECUTE_RELEASE
        return ""
        #else
        return cutoutHairstyles.contains(where: { $0.id == companionHair }) ? companionHair
            : CharacterChoice.cutoutDefaultHair
        #endif
    }
    @Published var characterBindings: [String: String] { didSet {
        save("characterBindings", characterBindings); bindingsChanged()
    } }
    @Published var cutoutHairBindings: [String: String] { didSet {
        save("cutoutHairBindings", cutoutHairBindings); redraw()
    } }
    @Published var taskSoundOutcomes: Set<String> { didSet {
        save("taskSoundOutcomes", taskSoundOutcomes.sorted())
        taskSounds.setEnabledOutcomes(Set(TaskOutcome.allCases.filter { taskSoundOutcomes.contains($0.rawValue) }))
    } }
    func tracks(_ source: SessionSource) -> Bool { trackedHarnesses.contains(source.preferenceID) }
    func setTracking(_ source: SessionSource, enabled: Bool) {
        guard tracks(source) != enabled else { return }
        if enabled { trackedHarnesses.insert(source.preferenceID) }
        else { trackedHarnesses.remove(source.preferenceID) }
    }
    func characterChoice(for source: SessionSource) -> CharacterChoice {
        CharacterChoice.resolved(characterBindings[source.preferenceID], developerMode: developerModeEnabled)
    }
    func bind(_ choice: CharacterChoice, to source: SessionSource) {
        guard choice.isSelectable(developerMode: developerModeEnabled) else { return }
        guard characterChoice(for: source) != choice else { return }
        characterBindings[source.preferenceID] = choice.rawValue
    }
    #if VIBECUTE_RELEASE
    func cutoutHair(for source: SessionSource) -> String { "" }
    func bindCutoutHair(_ id: String, to source: SessionSource) {}
    #else
    var cutoutHairstyles: [CutoutRig.Variant] {
        MascotAnimation.cutoutCharacter.cutout!.variants.filter { $0.category == "hair" && $0.id != "hair-none" }
    }
    func cutoutHair(for source: SessionSource) -> String {
        let id = cutoutHairBindings[source.preferenceID] ?? ""
        return cutoutHairstyles.contains(where: { $0.id == id }) ? id
            : MascotAnimation.cutoutCharacter.cutout!.defaults["hair"]!
    }
    func bindCutoutHair(_ id: String, to source: SessionSource) {
        guard cutoutHairstyles.contains(where: { $0.id == id }), cutoutHair(for: source) != id else { return }
        cutoutHairBindings[source.preferenceID] = id
    }
    #endif
    func soundEnabled(_ outcome: TaskOutcome) -> Bool { taskSoundOutcomes.contains(outcome.rawValue) }
    func setSound(_ outcome: TaskOutcome, enabled: Bool) {
        guard soundEnabled(outcome) != enabled else { return }
        if enabled { taskSoundOutcomes.insert(outcome.rawValue) }
        else { taskSoundOutcomes.remove(outcome.rawValue) }
    }
    private var effectiveCharacterBindings: [CaptionMascot: CharacterChoice] {
        if demoMode { return [.codex: demoPinkBear && CharacterChoice.includesPinkBear ? .pinkBear : .codex, .deepseek: demoCharacterOverride ?? ((CommandLine.arguments.contains("--orange-hoodie-demo") || CommandLine.arguments.contains("--orange-hoodie-avoidance-demo")) ? .orangeHoodie : .deepseek)] }
        var bindings = Dictionary(uniqueKeysWithValues: SessionSource.allCases.filter { tracks($0) }.map {
            (CaptionMascot(rawValue: $0.preferenceID)!, characterChoice(for: $0))
        })
        if companionEnabled { bindings[companionSource] = companionChoice }
        return bindings
    }
    private var deepSeekSource: CaptionMascot {
        effectiveCharacterBindings[.deepseek] == .deepseek ? .deepseek
            : CaptionMascot.allCases.first { effectiveCharacterBindings[$0] == .deepseek } ?? .deepseek
    }
    private var backdropCandidateIndex = 0
    private var eligibleBackdropSources: [CaptionMascot] {
        overlays.eligibleBackdropSources(allowHoodie:singingPlayer.phase == .seated)
    }
    private var backdropSource: CaptionMascot {
        if let activeBackdropSource { return activeBackdropSource }
        let sources = eligibleBackdropSources
        return sources.isEmpty ? deepSeekSource : sources[backdropCandidateIndex % sources.count]
    }
    private var activeBackdropSource: CaptionMascot?
    private var activeBackdropArtwork: String?
    private var backdropArtworkKey = ""
    private var hoodieAvoidanceDemo = false
    private var hoodiePreviewAnchor: CGPoint?
    private var hoodiePreviewReturning = false
    private var backdropPreviewCheck = false
    private var deepSeekSessionSource: SessionSource {
        SessionSource.allCases.first { $0.preferenceID == deepSeekSource.rawValue } ?? .deepseek
    }
    private var hasDeepSeekCharacter: Bool {
        demoMode || effectiveCharacterBindings.values.contains(.deepseek)
    }
    private var audioSources: Set<CaptionMascot> {
        return Set(SessionSource.allCases.filter { tracks($0) }.compactMap { CaptionMascot(rawValue: $0.preferenceID) })
            .union(companionEnabled ? [.companion] : [])
            .intersection(audioTarget.mascots)
    }
    private var singingSources: Set<CaptionMascot> {
        if singingDemoStartedAt != nil { return [deepSeekSource] }
        return Set(effectiveCharacterBindings.filter { ($0.value == .deepseek || $0.value == .orangeHoodie) && audioSources.contains($0.key) }.keys)
    }
    private func trackingChanged() {
        guard !sourcePath.isEmpty else { return }
        stopWindowPeek(); stopBackdropRelocation(); stopPreview()
        selection = ""; states.removeAll(); sessions = []; taskSounds.stop()
        connect(root: URL(fileURLWithPath: sourcePath))
        receive([], error: nil)
    }
    private func bindingsChanged() {
        stopWindowPeek(); stopBackdropRelocation(); stopPreview()
        windowPeekIdle.reset(); backdropObservation.invalidate()
        redraw(); updateMouth()
    }
    func stopPreview() {
        let restoreEnabled = questionPreviewPreviousEnabled
        questionPreviewActive = false; questionPreviewRequest = nil; questionPreviewRevealAt = nil
        questionPreviewPreviousEnabled = nil
        stopBackdropRelocation(cooldown:0)
        stopWindowPeek(); stopSleepDemo(); stopScootDemo(); stopStrollDemo(); stopFrontRetreatDemo()
        mouthDemoStartedAt = nil; mouthTransitionDemoStartedAt = nil; singingDemoStartedAt = nil
        speechDemo = false; kiraDemo = false; demoMode = false; demoPinkBear = false
        demoCharacterOverride = nil; backdropPreviewCheck = false; developerPreviewStatus = "预览已停止"
        previewUntil = .distantPast; resetSinging()
        if let restoreEnabled { enabled = restoreEnabled }
        receive(sessions, error: errorText); updateMouth()
    }
    @Published var screenIndex: Int { didSet { CharacterPositionStore.saveScreen(screenIndex, defaults: preferences); redraw() } }
    @Published var showAnswers: Bool { didSet { save("showAnswers", showAnswers); states.removeAll(); receive(sessions, error: errorText) } }
    @Published var showTools: Bool { didSet { doubaoReader?.setIncludesTools(showTools); save("showTools", showTools); states.removeAll(); receive(sessions, error: errorText) } }
    @Published var typewriterEnabled: Bool { didSet { save("typewriterEnabled", typewriterEnabled); redraw() } }
    @Published var akimboUtterancePause: Double { didSet {
        akimboUtterancePause = AkimboReaction.boundedUtterancePause(akimboUtterancePause)
        save("akimboUtterancePause", akimboUtterancePause); redraw()
    } }
    @Published var typewriterCharactersPerSecond: Double { didSet {
        save("typewriterCharactersPerSecond", typewriterCharactersPerSecond); redraw()
    } }
    @Published var autoHide: Bool { didSet { save("autoHide", autoHide); redraw() } }
    @Published var taskSoundsEnabled: Bool { didSet {
        save("taskSoundsEnabled", taskSoundsEnabled)
        if !taskSoundsEnabled { taskSounds.stop() }
    } }
    @Published var taskSoundVolume: Double { didSet {
        save("taskSoundVolume", taskSoundVolume); taskSounds.volume = taskSoundVolume
    } }
    @Published private(set) var taskSoundStatus = "等待 Codex 任务结果"
    private let taskSounds = TaskOutcomeSoundPlayer()
    @Published var selection = "" { didSet { monitor?.pin(selection.isEmpty ? nil : selection); receive(sessions, error: nil) } }
    @Published var sessions: [SessionSnapshot] = []
    @Published var status = "正在连接本机会话…"
    @Published var currentLabel = "自动跟随最近运行的任务"
    @Published var currentText = "字幕已就绪，等待 Codex 的下一条进度…"
    @Published var sourcePath = ""
    @Published var harnessPath = ""
    @Published var claudePath = ""
    @Published var openCodePath = ""
    @Published var openCodeNavigationStatus = "等待检测 OpenCode"
    @Published var openCodeInstalled = false
    @Published var openCodePluginInstalling = false
    @Published var workBuddyPath = ""
    @Published var errorText: String?
    @Published var demoMode = false
    @Published var audioEnabled: Bool { didSet { save("audioEnabled", audioEnabled); configureAudio(); redraw() } }
    @Published var audioSensitivity: Double { didSet { save("audioSensitivity", audioSensitivity); audio.setSensitivity(audioSensitivity) } }
    @Published var audioVoicePriority: Bool { didSet { save("audioVoicePriority", audioVoicePriority); audio.setVoicePriority(audioVoicePriority) } }
    @Published var audioLipEngine: LipMatchingEngine { didSet {
        if BuildProfile.isRelease && audioLipEngine != .mfcc { audioLipEngine = .mfcc; return }
        save("audioLipEngine", audioLipEngine.rawValue); configureLipMatching()
    } }
    @Published private(set) var lipMatchingStatus = ""
    @Published var vocalSeparationEnabled: Bool { didSet {
        if BuildProfile.isRelease && vocalSeparationEnabled != false { vocalSeparationEnabled = false; return }
        save("vocalSeparationEnabled", vocalSeparationEnabled); configureVocalSeparation()
    } }
    @Published private(set) var vocalSeparationStatus = "使用原始声音"
    private lazy var vocalRuntime: URL? = {
        let directory = argument("--vocal-runtime").map { URL(fileURLWithPath: $0) }
            ?? Bundle.main.resourceURL?.appendingPathComponent("Vocal", isDirectory: true)
        guard let directory, FileManager.default.isExecutableFile(atPath: directory.appendingPathComponent("captions-vocal").path),
              FileManager.default.fileExists(atPath: directory.appendingPathComponent("model.onnx").path) else { return nil }
        return directory
    }()
    private lazy var lipVowelProfile: LipVowelProfile? = {
        guard let url = Bundle.main.url(forResource: "LipVowels", withExtension: "json")
            ?? Bundle.module.url(forResource: "LipVowels", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let profile = try? JSONDecoder().decode(LipVowelProfile.self, from: data), profile.isValid else { return nil }
        return profile
    }()
    @Published var singingActionEnabled: Bool { didSet {
        save("singingActionEnabled", singingActionEnabled)
        songRecognitionEnabled = singingActionEnabled
        if !singingActionEnabled {
            singingDemoStartedAt = nil; speechDemo = false; resetSinging()
            refreshMusicTempoLabel(beat: lastLipFrame.beat, preview: false)
            redraw()
        }
        refreshAnimationPlaybackLabel()
        configureSpeech()
    } }
    @Published var songRecognitionEnabled: Bool { didSet {
        if BuildProfile.isRelease && songRecognitionEnabled != false { songRecognitionEnabled = false; return }
        save("songRecognitionEnabled", songRecognitionEnabled); configureNowPlaying()
    } }
    @Published private(set) var songRecognitionLabel = "等待系统播放信息"
    @Published private(set) var kiraMarkerLabel = "尚未标记此版本的 Kira 时间点"
    @Published var speechKeywordEnabled: Bool { didSet {
        if BuildProfile.isRelease && speechKeywordEnabled != false { speechKeywordEnabled = false; return }
        save("speechKeywordEnabled", speechKeywordEnabled); configureSpeech()
    } }
    @Published var speechEngine: SpeechEngine { didSet {
        save("speechEngine", speechEngine.rawValue); resetSpeechPresentation(); configureSpeech()
    } }
    @Published var whisperModelPath: String { didSet {
        save("whisperModelPath", whisperModelPath); resetSpeechPresentation(); configureSpeech()
    } }
    var whisperModelLabel: String {
        URL(fileURLWithPath: whisperModelPath.isEmpty ? WhisperKeywordSpeech.bundledModelPath : whisperModelPath).lastPathComponent
    }
    @Published var speechKiraDelay: Double { didSet { save("speechKiraDelay", speechKiraDelay) } }
    @Published var speechBackupExtraDelay: Double { didSet { save("speechBackupExtraDelay", speechBackupExtraDelay) } }
    @Published private(set) var speechStatus = "Apple Speech 已关闭"
    @Published private(set) var speechTranscript = ""
    @Published private(set) var speechCountdownLabel = "等待「\(JapaneseKiraKeyword.displayList)」"
    @Published private(set) var speechKeywordTimingLabel = ""
    @Published private(set) var speechHighlightedKeyword: JapaneseKiraKeyword?
    @Published private(set) var speechHighlightedKeywords: Set<JapaneseKiraKeyword> = []
    private var speechHighlight = SpeechKeywordHighlight()
    @Published private(set) var speechRunning = false
    @Published private(set) var speechProgress = SpeechProgress()
    @Published private(set) var speechInputLabel = "音频输入：尚未收到 PCM"
    @Published private(set) var speechResultLabel = "尚无识别结果"
    @Published private(set) var speechHistory: [String] = []
    private var speechHistoryText = ""
    private var speechHistoryRequest = 0
    private var speechHistoryFinal = false
    private var speechCountdown = SpeechKiraCountdown()
    private var speechCueDeduplicator = SpeechCueDeduplicator()
    private var speechKeywordCount = 0
    private var speechUsesArrivalTime = false
    private var speechCountdownKeyword: JapaneseKiraKeyword = .kamawanai
    private var speechDemo = false
    private var speechDemoFired = false
    private var kiraFromSpeech = false
    private let nowPlaying = NowPlayingMonitor()
    private var currentTrack: NowPlayingTrack?
    private var kiraCues: [String: [Double]] = [:]
    private var cueScheduler = KiraCueScheduler()
    private var kiraStartedAt: TimeInterval?
    private var kiraAutomatic = false
    private var kiraDemo = false
    private var kiraDemoFired = false
    @Published var audioTempoEngine: TempoEngine { didSet {
        if BuildProfile.isRelease && audioTempoEngine != .beatnet { audioTempoEngine = .beatnet; return }
        save("audioTempoEngine", audioTempoEngine.rawValue)
        audio.setTempoEngine(audioTempoEngine)
        singingPlayer.forgetTempo(); tempoEvidenceLabel = ""
        lastLipFrame = .silence
        musicTempoLabel = audioRunning ? "等待稳定节拍" : (audioEnabled ? "等待系统声音" : "未启用")
    } }
    @Published var audioTarget: AudioCharacterTarget { didSet {
        save("audioTarget", audioTarget.rawValue); configureSpeech(); refreshAnimationPlaybackLabel(); redraw(); updateMouth()
    } }
    @Published private(set) var audioStatus = "系统声音口型已关闭"
    @Published private(set) var audioRunning = false
    @Published private(set) var audioRecognitionActive = false
    @Published private(set) var audioLevel: Double = 0
    @Published private(set) var audioVoiceLike = false
    @Published private(set) var audioMouthLabel = "自然停顿"
    @Published private(set) var audioSceneLabel = "正在判断声音类型"
    @Published private(set) var audioInstruments = ""
    @Published private(set) var singingActionLabel = "DeepSeek · 坐姿"
    @Published private(set) var musicTempoLabel = "未启用"
    @Published private(set) var tempoEvidenceLabel = ""
    @Published private(set) var animationPlaybackLabel = "未播放 · 坐姿待机"
    private var singingPlayer = SingingPerformance()
    private var singingDemoStartedAt: TimeInterval?
    private var singingStepDemo = false
    private var singingStepDemoMoved = false
    @Published var autoAvoidanceEnabled: Bool { didSet {
        save("autoAvoidanceEnabled",autoAvoidanceEnabled)
        backdropObservation.invalidate(); backdropTrigger.reset()
        backdropObservation.retryAccess()
        if !autoAvoidanceEnabled { stopBackdropRelocation(cooldown:0) }
        avoidanceStatus = autoAvoidanceEnabled ? "正在检查角色背后的背景" : "自动避让已关闭"
    } }
    @Published private(set) var avoidanceStatus = "正在检查角色背后的背景"
    private let backdropObservation = BackdropObservationService()
    private let backdropRelocation = BackdropRelocation()
    private var backdropTrigger = BackdropAvoidanceTrigger()
    private var lastBackdropScan = -Double.infinity
    private var backdropPlanningMilliseconds = 0.0
    private var backdropCheckRequested = false
    private var lastManualDragEndedAt: Double?
    private var lastBackdropOrigins: [CaptionMascot:CGPoint] = [:]
    private var backdropSilhouettes: [Int:BackdropSilhouette] = [:]
    private var backdropOverlap = false
    private var backdropScans = 0
    private var backdropMoves = 0
    private var lastBackdropPlan: BackdropAvoidancePlan?
    private var backdropLastSafe = false
    private var backdropPermission = false
    private var sleepDemoStartedAt: TimeInterval?
    private var automaticSleep = false
    private var sleepWakeAt: TimeInterval?
    private var sleepWakeEntryFrame: Int?
    private var sleepAnchor: NSRect?
    private var automaticSleepCount = 0
    private var scootDemoStartedAt: TimeInterval?
    @Published private(set) var scootActionLabel = "保持坐姿 · 撑地挪动"
    private var strollDemoStartedAt: TimeInterval?
    private var frontRetreatDemoStartedAt: TimeInterval?
    @Published private(set) var frontRetreatActionLabel = "正面横退 · 加急小步"
    private let windowPeek = WindowPeekController()
    private var windowPeekIdle: WindowPeekIdleTrigger
    private var lastWindowPeekObservation = -Double.infinity
    private var activeWindowPeekSource: CaptionMascot?
    private var automaticWindowPeek = false
    private var automaticWindowPeekCount = 0
    private var harnessStateObserved = false
    private var pendingWindowPeekPreview = false
    private var pendingWindowSeatPreview = false
    private var deepSeekHarnessIdle: Bool {
        !sessions.contains { tracks($0.source) && characterChoice(for: $0.source) == .deepseek &&
            ($0.active || $0.runningSubagentCount > 0 || !$0.readable) }
    }
    @Published var autoWindowPeekEnabled: Bool { didSet {
        save("autoWindowPeekEnabled",autoWindowPeekEnabled); windowPeekIdle.reset()
        autoWindowPeekLabel = autoWindowPeekEnabled ? "等待角色与非全屏窗口保持静止" : "自动休息已关闭"
        if !autoWindowPeekEnabled && automaticWindowPeek { stopWindowPeek() }
    } }
    @Published private(set) var autoWindowPeekLabel = "等待角色与非全屏窗口保持静止"
    @Published private(set) var windowPeekActive = false
    @Published private(set) var windowPeekLabel = "小跑藏到窗口后面，再扒边探头"
    @Published private(set) var strollActionLabel = "坐姿 → 起身 → 侧身小跑"
    private var posePlayer = MouthPosePlayer()
    private var lastLipFrame = LiveLipFrame.silence
    private var lipDeliveredAt: TimeInterval?
    private var lipTimeline: FileHandle?
    private var lastLipTimelineKey = ""
    private var mouthDemoStartedAt: TimeInterval?
    private var mouthDemoIndex: Int?
    private var mouthTransitionDemoStartedAt: TimeInterval?
    private let audio = RealtimeAudio()
    private var audioClock: Timer?
    private var terminationObserver: NSObjectProtocol?
    private var demoPinkBear = false
    private var demoDeepSeek = false
    private var demoMultiple = false
    private var demoTypewriterID = UUID().uuidString
    @Published private(set) var questionPreviewActive = false
    private var approvalPreview = false
    private var questionPreviewRequest: UserQuestionRequest?
    private var questionPreviewRevealAt: Date?
    private var questionPreviewPreviousEnabled: Bool?
    private lazy var overlays = ProjectOverlays(positionStore: CommandLine.arguments.contains("--no-position-memory")
        ? nil : CharacterPositionStore(defaults: preferences))
    private var states: [String: ProjectCaptionState] = [:]
    var onboardingActive = false { didSet { overlays.onboardingActive = onboardingActive; redraw() } }
    var onOnboardingLayout: (() -> Void)?
    var onOnboardingDragEnded: (() -> Void)?
    var onboardingPreferences: UserDefaults { preferences }
    var onboardingScreenReady: Bool { backdropPermission }
    var onboardingCharacter: OverlayController? { overlays.character(for: companionEnabled ? .companion : deepSeekSource) }
    func prepareOnboardingCharacter() {
        // Reuse a current source; replay must not enable another log reader.
        let source = companionEnabled ? nil
            : SessionSource.allCases.first { tracks($0) && characterChoice(for: $0) == .deepseek }
                ?? (selected?.source).flatMap { tracks($0) ? $0 : nil }
                ?? SessionSource.allCases.first { tracks($0) }
        let role = source.flatMap { CaptionMascot(rawValue: $0.preferenceID) } ?? .companion
        let frame = overlays.character(for: role)?.panel.frame
        if demoMode { stopPreview() }
        if let source { bind(.deepseek, to: source) }
        else {
            if companionCharacter != .deepseek { companionCharacter = .deepseek }
            if !companionEnabled { companionEnabled = true }
        }
        enabled = true
        if let frame, let character = onboardingCharacter {
            character.panel.setFrameOrigin(NSPoint(x: frame.midX-character.panel.frame.width/2, y: frame.minY))
            overlays.flushPositions()
        }
    }
    func observeOnboardingPointer(_ callback: ((NSEvent, NSPoint) -> Void)?) { overlays.onOnboardingPointer = callback }
    func onboardingReact() { onboardingCharacter?.subtitle.playOnboardingReaction() }
    var onboardingHarnessRoots: [SessionSource: URL] {
        Dictionary(uniqueKeysWithValues: [(SessionSource.codex, sourcePath), (.claude, claudePath), (.deepseek, harnessPath)]
            .filter { !$0.1.isEmpty }.map { ($0.0, URL(fileURLWithPath: $0.1)) })
    }
    func connectOnboarding(_ source: SessionSource) {
        let origin = onboardingCharacter?.panel.frame.origin
        bind(.deepseek, to: source)
        autoHide = false
        companionEnabled = false
        setTracking(source, enabled: true)
        if let origin { onboardingCharacter?.panel.setFrameOrigin(origin); overlays.flushPositions() }
    }
    var onStatus: ((Bool) -> Void)?
    private var monitor: SessionMonitor?
    private var doubaoReader: DoubaoVisibleReader?
    private lazy var questionReplies = CodexQuestionReply(socketPath: argument("--codex-question-socket")
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/ipc/ipc.sock").path)
    private lazy var approvalStream = CodexApprovalStream(path: argument("--codex-question-socket")
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/ipc/ipc.sock").path) { [weak self] requests in
            guard let self else { return }
            self.pendingApprovals = requests
            self.pruneQuestionNotifications()
            self.redraw()
        }
    private var pendingApprovals: [CodexApproval] = []
    private var codexAverageSpeeds: [String: Double] = [:]
    private var codexQuota: CodexQuota?
    @Published var balanceAlertThreshold: Double {
        didSet {
            if !balanceAlertThreshold.isFinite || balanceAlertThreshold < 0 { balanceAlertThreshold = 1 }
            save("balanceAlertThreshold", balanceAlertThreshold); redraw()
        }
    }
    private var harnessNormalBalance: Decimal?
    private var balanceAlertActive: Bool {
        enabled && tracks(.deepseek) && HarnessBalance.isLow(normalCNY: harnessNormalBalance, threshold: balanceAlertThreshold)
    }
    private var displayedHarnessBalance: String { (balanceAlertActive ? "⚠️ 普通余额偏低 · " : "") + harnessBalanceText }
    private var harnessBalanceText = "账户余额 -"
    private var harnessBalanceRefreshing = false
    private var harnessBalanceQueries = 0
    private var harnessBalanceQuerySeconds = 0.0
    private var submittedQuestions: [String] = []
    private var closedQuestions = Set<String>()
    private var dismissedErrorText: String?
    private var displayedQuestion: String?
    private var notifiedQuestions = Set<String>()
    private var notifiedApprovals: [String] = []
    @Published var questionSoundsEnabled: Bool { didSet {
        save("questionSoundsEnabled", questionSoundsEnabled)
        taskSounds.setQuestionEnabled(questionSoundsEnabled)
    } }
    private var clock: Timer?
    private var selected: SessionSnapshot?
    private var waitingHideAt = Date().addingTimeInterval(10)
    private var previewUntil = Date.distantPast
    private var diagnosticsURL: URL?
    private let openCodeNavigationInstaller = OpenCodeNavigationInstaller()
    private var lastDiagnostics = ""

    private let preferences: UserDefaults
    init() {
        let suiteIndex = CommandLine.arguments.firstIndex(of: "--preferences-suite")
        let suiteName = suiteIndex.flatMap { $0 + 1 < CommandLine.arguments.count ? CommandLine.arguments[$0 + 1] : nil }
        let defaults = suiteName.flatMap(UserDefaults.init(suiteName:)) ?? UserDefaults.standard
        OnboardingProgress.prepare(defaults)
        preferences = defaults
        developerModeEnabled = BuildProfile.experiments && defaults.bool(forKey: "developerModeEnabled")
        let previewIndex = CommandLine.arguments.firstIndex(of:"--preview-character")
        let previewArgument = previewIndex.flatMap { $0+1<CommandLine.arguments.count ? CommandLine.arguments[$0+1] : nil }
        developerPreviewCharacter = CharacterChoice.resolved(previewArgument ?? defaults.string(forKey:"developerPreviewCharacter")
            ?? (defaults.dictionary(forKey:"characterBindings")?["codex"] as? String) ?? "deepseek",
            developerMode:defaults.bool(forKey:"developerModeEnabled"))
        closedQuestions = Set(defaults.stringArray(forKey: "closedRequestBubbles")?.suffix(128) ?? [])
        let savedSpeeds = defaults.dictionary(forKey: "codexLastResponseSpeeds") as? [String: Double] ?? [:]
        codexAverageSpeeds = Dictionary(uniqueKeysWithValues: savedSpeeds.filter { $0.value.isFinite && $0.value >= 0 }.prefix(16).map { ($0.key, $0.value) })
        bubblesFixedToCharacter = defaults.object(forKey: "bubblesFixedToCharacter") as? Bool ?? true
        companionEnabled = defaults.bool(forKey: "companionEnabled")
        companionCharacter = CharacterChoice(rawValue: defaults.string(forKey: "companionCharacter") ?? "") ?? .defaultChoice
        companionHair = defaults.string(forKey: "companionHair") ?? ""
        autoAvoidanceEnabled = !CommandLine.arguments.contains("--no-avoidance") &&
            (CommandLine.arguments.contains("--avoidance-demo") || defaults.object(forKey:"autoAvoidanceEnabled") as? Bool ?? true)
        autoWindowPeekEnabled = CommandLine.arguments.contains("--window-peek-auto") ? true
            : defaults.object(forKey:"autoWindowPeekEnabled") as? Bool ?? true
        let idleDelay = CommandLine.arguments.firstIndex(of:"--window-peek-idle-delay").flatMap { index in
            index+1 < CommandLine.arguments.count ? Double(CommandLine.arguments[index+1]) : nil
        } ?? WindowPeekIdleTrigger.defaultDelay
        windowPeekIdle = WindowPeekIdleTrigger(delay:idleDelay)
        screenIndex = CharacterPositionStore.selectedScreen(defaults: defaults, screens: NSScreen.screens)
        fontSize = defaults.object(forKey: "fontSize") as? Double ?? 14
        opacity = defaults.object(forKey: "opacity") as? Double ?? 0.68
        bottom = defaults.object(forKey: "bottom") as? Double ?? 46
        let scaleArgument = CommandLine.arguments.firstIndex(of:"--character-scale").flatMap { i in
            i+1 < CommandLine.arguments.count ? Double(CommandLine.arguments[i+1]) : nil
        }
        characterScale = min(2, max(0.5, scaleArgument ?? defaults.object(forKey: "characterScale") as? Double ?? 1))
        let bearArgument = CommandLine.arguments.firstIndex(of: "--pink-bear-binding").flatMap { index in
            index + 1 < CommandLine.arguments.count ? CommandLine.arguments[index + 1] : nil
        }
        let legacyBear = PinkBearBinding(rawValue: bearArgument ?? defaults.string(forKey: "pinkBearBinding") ?? "codex") ?? .codex
        pinkBearBinding = CharacterChoice.includesPinkBear ? legacyBear : .disabled
        var storedHarnesses = Set(defaults.stringArray(forKey: "trackedHarnesses") ?? SessionSource.allCases.map(\.preferenceID))
        // Enable the newly supported source once, preserving later opt-outs.
        if !defaults.bool(forKey: "claudeTrackingMigrated") {
            storedHarnesses.insert("claude")
            defaults.set(storedHarnesses.sorted(), forKey: "trackedHarnesses")
            defaults.set(true, forKey: "claudeTrackingMigrated")
        }
        if !defaults.bool(forKey: "doubaoTrackingMigrated") {
            storedHarnesses.insert("doubao")
            defaults.set(storedHarnesses.sorted(), forKey: "trackedHarnesses")
            defaults.set(true, forKey: "doubaoTrackingMigrated")
        }
        // Isolated QA can exclude the real foreground conversation.
        if CommandLine.arguments.contains("--no-doubao") { storedHarnesses.remove("doubao") }
        if CommandLine.arguments.contains("--no-workbuddy") { storedHarnesses.remove("workbuddy") }
        trackedHarnesses = storedHarnesses
        characterBindings = (bearArgument == nil ? defaults.dictionary(forKey: "characterBindings") as? [String: String] : nil)
            ?? Dictionary(uniqueKeysWithValues: SessionSource.allCases.map { source in
                let bear = bearArgument != nil && CharacterChoice.includesPinkBear &&
                    ((source == .codex && legacyBear == .codex) || (source == .deepseek && legacyBear == .deepseek))
                return (source.preferenceID, bear ? CharacterChoice.pinkBear.rawValue : CharacterChoice.defaultChoice.rawValue)
            })
        cutoutHairBindings = defaults.dictionary(forKey:"cutoutHairBindings") as? [String:String] ?? [:]
        var storedSounds = Set(defaults.stringArray(forKey: "taskSoundOutcomes")
            ?? ((defaults.object(forKey: "taskSoundsEnabled") as? Bool ?? true) ? TaskOutcome.allCases.map(\.rawValue) : []))
        if !defaults.bool(forKey: "taskStartSoundMigrated") {
            if !storedSounds.isEmpty { storedSounds.insert(TaskOutcome.started.rawValue) }
            defaults.set(storedSounds.sorted(), forKey: "taskSoundOutcomes")
            defaults.set(true, forKey: "taskStartSoundMigrated")
        }
        taskSoundOutcomes = storedSounds
        showAnswers = defaults.object(forKey: "showAnswers") as? Bool ?? true
        showTools = defaults.object(forKey: "showTools") as? Bool ?? true
        typewriterEnabled = defaults.object(forKey: "typewriterEnabled") as? Bool ?? true
        akimboUtterancePause = AkimboReaction.boundedUtterancePause(defaults.object(forKey: "akimboUtterancePause") as? Double ?? AkimboReaction.utterancePause)
        let storedTypewriterSpeed = defaults.object(forKey: "typewriterCharactersPerSecond") as? Double ?? 25
        typewriterCharactersPerSecond = min(40, max(5, storedTypewriterSpeed))
        autoHide = defaults.object(forKey: "autoHide") as? Bool ?? true
        taskSoundsEnabled = !CommandLine.arguments.contains("--no-task-sounds") &&
            (!CommandLine.arguments.contains("-taskSoundsEnabled") || defaults.bool(forKey: "taskSoundsEnabled"))
        questionSoundsEnabled = !CommandLine.arguments.contains("--no-question-sounds")
            && (defaults.object(forKey: "questionSoundsEnabled") == nil || defaults.bool(forKey: "questionSoundsEnabled"))
        let storedBalanceThreshold = defaults.object(forKey: "balanceAlertThreshold") as? Double ?? 1
        balanceAlertThreshold = storedBalanceThreshold.isFinite && storedBalanceThreshold >= 0 ? storedBalanceThreshold : 1
        let storedSoundVolume = defaults.object(forKey: "taskSoundVolume") == nil ? 0.6 : defaults.double(forKey: "taskSoundVolume")
        taskSoundVolume = storedSoundVolume.isFinite ? min(3, max(0, storedSoundVolume)) : 0.6
        audioEnabled = !CommandLine.arguments.contains("--no-audio") &&
            (CommandLine.arguments.contains("--audio-live") || defaults.bool(forKey: "audioEnabled"))
        audioSensitivity = min(4, max(0.25, defaults.object(forKey: "audioSensitivity") as? Double ?? 1))
        audioVoicePriority = defaults.object(forKey: "audioVoicePriority") as? Bool ?? true
        let lipArgument = CommandLine.arguments.firstIndex(of: "--lip-engine").flatMap { index in
            index + 1 < CommandLine.arguments.count ? CommandLine.arguments[index + 1] : nil
        }
        audioLipEngine = BuildProfile.isRelease ? .mfcc : LipMatchingEngine(rawValue: lipArgument ?? defaults.string(forKey: "audioLipEngine") ?? "") ?? .acoustic
        vocalSeparationEnabled = BuildProfile.experiments && !SpeechEngine.minimalRelease && !CommandLine.arguments.contains("--no-vocal-separation") &&
            (CommandLine.arguments.contains("--vocal-separation") || defaults.bool(forKey: "vocalSeparationEnabled"))
        let storedSingingAction = defaults.object(forKey: "singingActionEnabled") as? Bool ?? true
        singingActionEnabled = storedSingingAction
        songRecognitionEnabled = BuildProfile.experiments && storedSingingAction
        speechKeywordEnabled = BuildProfile.experiments && !CommandLine.arguments.contains("--no-speech") &&
            (CommandLine.arguments.contains("--speech-live") || defaults.bool(forKey: "speechKeywordEnabled"))
        let engineArgument = CommandLine.arguments.firstIndex(of: "--speech-engine").flatMap { index in
            index + 1 < CommandLine.arguments.count ? CommandLine.arguments[index + 1] : nil
        }
        speechEngine = SpeechEngine(rawValue: engineArgument ?? defaults.string(forKey: "speechEngine") ?? "") ?? .apple
        if SpeechEngine.minimalRelease { speechEngine = .apple }
        let modelArgument = CommandLine.arguments.firstIndex(of: "--whisper-model").flatMap { index in
            index + 1 < CommandLine.arguments.count ? CommandLine.arguments[index + 1] : nil
        }
        whisperModelPath = modelArgument ?? defaults.string(forKey: "whisperModelPath") ?? ""
        let storedDelay = defaults.object(forKey: "speechKiraDelay") as? Double ?? 3
        speechKiraDelay = storedDelay.isFinite ? min(8, max(0.5, storedDelay)) : 3
        let extra = defaults.object(forKey: "speechBackupExtraDelay") as? Double ?? 3
        speechBackupExtraDelay = extra.isFinite ? min(6, max(0.5, extra)) : 3
        if let data = defaults.data(forKey: "kiraCues.v1"),
           let cues = try? JSONDecoder().decode([String: [Double]].self, from: data) {
            kiraCues = cues.mapValues { $0.filter { $0.isFinite && $0 >= 0 }.sorted() }
        }
        audioTarget = .both
        let tempoArgument = CommandLine.arguments.firstIndex(of: "--tempo-engine").flatMap { index in
            index + 1 < CommandLine.arguments.count ? CommandLine.arguments[index + 1] : nil
        }
        audioTempoEngine = BuildProfile.isRelease ? .beatnet : TempoEngine(rawValue: tempoArgument ?? defaults.string(forKey: "audioTempoEngine") ?? "") ?? .aubio
        musicTempoLabel = audioEnabled ? "等待系统声音" : "未启用"
    }

    func start() {
        backdropObservation.onIdle = { [weak self] in
            guard let self, self.backdropCheckRequested else { return }
            self.updateBackdropAvoidance()
        }
        overlays.onCharacterDragStarted = { [weak self] source in
            guard let self, let role = CaptionMascot(rawValue:source),
                  self.effectiveCharacterBindings[role] == .deepseek || self.effectiveCharacterBindings[role] == .orangeHoodie else { return }
            // A click enters this callback before any movement. Only the owner
            // may interrupt sleep or an in-flight background relocation.
            if role == self.deepSeekSource { self.stopSleepDemo() }
            guard self.activeBackdropSource == nil || self.activeBackdropSource == role else { return }
            self.stopBackdropRelocation(cooldown:0)
            self.backdropObservation.invalidate()
            self.backdropCheckRequested = false
        }
        overlays.onCharacterDockChanged = { [weak self] in self?.redraw() }
        overlays.onCaptionScroll = { [weak self] delta in
            guard let self else { return }
            let size = min(42, max(10, self.fontSize + delta))
            if size != self.fontSize { self.fontSize = size }
        }
        overlays.onCharacterScrollScale = { [weak self] delta in
            guard let self else { return }
            let scale = min(2, max(0.5, self.characterScale + delta))
            if scale != self.characterScale { self.characterScale = scale }
        }
        overlays.onCharacterDragEnded = { [weak self] source, moved in
            guard let self else { return }
            if moved, source == (self.companionEnabled ? CaptionMascot.companion.rawValue : self.deepSeekSource.rawValue) {
                self.onOnboardingDragEnded?()
            }
            guard moved, let role = CaptionMascot(rawValue:source),
                  self.effectiveCharacterBindings[role] == .deepseek || self.effectiveCharacterBindings[role] == .orangeHoodie else { return }
            self.lastBackdropOrigins[role] = self.overlays.character(for:role)?.panel.frame.origin
            guard self.activeBackdropSource == nil || self.activeBackdropSource == role else { return }
            self.lastManualDragEndedAt = ProcessInfo.processInfo.systemUptime
            self.recheckBackdrop()
        }
        windowPeek.onReturnToEdge = { [weak self] frame in
            guard let self else { return }
            self.overlays.finishDeepSeekWindowRecovery(at:frame, source:self.activeWindowPeekSource)
        }
        windowPeek.onFinish = { [weak self] reason in
            guard let self else { return }
            self.windowPeekActive = false
            self.automaticWindowPeek = false
            self.windowPeekLabel = reason.isEmpty ? "小跑藏到窗口后面，再扒边探头" : reason
            self.overlays.setSourceHidden(self.activeWindowPeekSource ?? self.deepSeekSource,false)
            self.activeWindowPeekSource = nil
            self.demoMode = false; self.previewUntil = .distantPast
            self.receive(self.sessions,error:self.errorText)
        }
        audio.onRecognitionActivity = { [weak self] active in self?.audioRecognitionActive = active }
        audio.speech.onStatus = { [weak self] status, running in
            guard let self else { return }
            self.speechStatus = status; self.speechRunning = running
            if !running { self.speechCountdown.cancel(); self.speechTranscript = "" }
        }
        audio.speech.onProgress = { [weak self] progress in
            guard let self else { return }
            self.speechProgress = progress
            if progress.requestNumber == 0 {
                self.speechHistory = []; self.speechHistoryText = ""
                self.speechHistoryRequest = 0; self.speechHistoryFinal = false
            }
            self.refreshSpeechProgress()
        }
        audio.speech.onTranscript = { [weak self] text, progress in
            guard let self, self.speechKeywordEnabled, self.audioRunning else { return }
            self.speechTranscript = text
            if !text.isEmpty && (text != self.speechHistoryText || progress.resultRequestNumber != self.speechHistoryRequest ||
                                 progress.isFinal != self.speechHistoryFinal) {
                let elapsed = max(0, (progress.resultReceivedAt ?? 0) - (progress.streamStartedAt ?? 0))
                let phase = self.speechEngine == .whisper ? "窗口结果" : (progress.isFinal ? "定稿" : "临时")
                self.speechHistory.append(String(format: "返回 +%.1fs · 第 %d 段 · %@\n%@", elapsed,
                    progress.resultRequestNumber, phase, String(text.suffix(80))))
                self.speechHistory = Array(self.speechHistory.suffix(4))
                self.speechHistoryText = text; self.speechHistoryRequest = progress.resultRequestNumber
                self.speechHistoryFinal = progress.isFinal
            }
        }
        audio.speech.onKeyword = { [weak self] match, audible in
            guard let self, self.enabled, self.speechKeywordEnabled, self.audioRunning,
                  !self.speechDemo, self.singingActionEnabled, !self.singingSources.isEmpty else { return }
            self.receiveSpeechKeyword(keyword: match.keyword, endpoint: match.endpoint, receivedAt: match.receivedAt, audible: audible)
        }
        nowPlaying.onUpdate = { [weak self] track, message in
            guard let self else { return }
            if track?.recordingKey != self.currentTrack?.recordingKey || track?.title != self.currentTrack?.title {
                if self.kiraAutomatic { self.kiraStartedAt = nil }
            }
            self.currentTrack = track
            if let track {
                let state = track.candidate ? "候选《星间飞行》 · 标题匹配" : "当前播放"
                self.songRecognitionLabel = "\(state)：\(track.title)" +
                    (track.artist.isEmpty ? "" : " · \(track.artist)") +
                    (track.rate == 0 ? " · 已暂停" : "")
            } else { self.songRecognitionLabel = message }
            self.refreshKiraMarkers()
        }
        audio.onStatus = { [weak self] message, running in
            guard let self else { return }
            self.audioStatus = message; self.audioRunning = running
            self.configureSpeech()
            if self.singingDemoStartedAt == nil {
                self.musicTempoLabel = running ? "等待稳定节拍" : (self.audioEnabled ? "等待系统声音" : "未启用")
            }
            if !running {
                self.overlays.setAudioMouth(nil, targets: [])
                self.posePlayer = MouthPosePlayer(); self.lastLipFrame = .silence
                self.audioMouthLabel = "自然停顿"
                self.resetSinging()
            }
            self.redraw(); self.updateMouth()
        }
        let audioClock = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] _ in self?.updateMouth() }
        self.audioClock = audioClock
        RunLoop.main.add(audioClock, forMode: .common)
        terminationObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
            object: nil, queue: nil) { [weak self] _ in
                self?.audio.speech.setEnabled(false); self?.audio.shutdown(); self?.nowPlaying.stop()
            }
        configureAudio()
        if !CommandLine.arguments.contains("--no-position-memory") {
            CharacterPositionStore.saveScreen(screenIndex, defaults: preferences)
        }
        if let path = argument("--diagnostics") { diagnosticsURL = URL(fileURLWithPath: path) }
        if let path = argument("--lip-timeline") {
            if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
            lipTimeline = try? FileHandle(forWritingTo: URL(fileURLWithPath: path))
            _ = try? lipTimeline?.seekToEnd()
        }
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"] ?? NSHomeDirectory() + "/.codex"
        let root = argument("--sessions-root") ?? preferences.string(forKey: "sessionsRoot") ?? home + "/sessions"
        let harnessHome = ProcessInfo.processInfo.environment["DSH_HOME"] ?? NSHomeDirectory() + "/.dsh"
        harnessPath = argument("--deepseek-root") ?? preferences.string(forKey: "harnessRoot")
            ?? harnessHome + "/sessions"
        let claudeHome = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] ?? NSHomeDirectory() + "/.claude"
        claudePath = argument("--claude-root") ?? preferences.string(forKey: "claudeRoot") ?? claudeHome + "/projects"
        let dataHome = ProcessInfo.processInfo.environment["XDG_DATA_HOME"] ?? NSHomeDirectory() + "/.local/share"
        openCodePath = argument("--opencode-root") ?? preferences.string(forKey: "openCodeRoot")
            ?? dataHome + "/opencode"
        workBuddyPath = argument("--workbuddy-root") ?? preferences.string(forKey: "workBuddyRoot")
            ?? NSHomeDirectory() + "/.workbuddy"
        connect(root: URL(fileURLWithPath: root))
        clock = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
        let deepSeekDemo = CommandLine.arguments.contains("--deepseek-demo")
        let multipleDemo = CommandLine.arguments.contains("--multi-demo")
        if CommandLine.arguments.contains("--mouth-demo") { showMouthDemo() }
        if CommandLine.arguments.contains("--mouth-transition-demo") {
            mouthTransitionDemoStartedAt = ProcessInfo.processInfo.systemUptime
            posePlayer = MouthPosePlayer(); enabled = true
            redraw(); updateMouth()
        }
        if CommandLine.arguments.contains("--singing-demo") { showSingingDemo() }
        if CommandLine.arguments.contains("--kira-demo") { showKiraDemo() }
        if CommandLine.arguments.contains("--speech-demo") { showSpeechDemo() }
        if CommandLine.arguments.contains("--avoidance-demo") {
            showDemo(deepSeek:true); previewUntil = .distantFuture
            if let raw = argument("--avoidance-start") {
                let values = raw.split(separator:",").compactMap { Double($0) }
                if values.count == 2 { overlays.character(for:deepSeekSource)?.panel.setFrameOrigin(NSPoint(x:values[0],y:values[1])) }
            }
        }
        if CommandLine.arguments.contains("--orange-hoodie-avoidance-demo") { showOrangeHoodieAvoidanceDemo() }
        if let action = argument("--developer-preview-action").flatMap(DeveloperPreviewAction.init(rawValue:)) { previewAction(action) }
        if CommandLine.arguments.contains("--singing-step-demo") { showSingingStepDemo() }
        if CommandLine.arguments.contains("--singing-avoidance-demo") { showSingingDemo() }
        if CommandLine.arguments.contains("--sleep-demo") { showSleepDemo() }
        if CommandLine.arguments.contains("--scoot-demo") { showScootDemo() }
        if CommandLine.arguments.contains("--stroll-demo") { showStrollDemo() }
        if CommandLine.arguments.contains("--front-retreat-demo") { showFrontRetreatDemo() }
        if CommandLine.arguments.contains("--window-seat-demo") { showWindowSeat() }
        else if CommandLine.arguments.contains("--window-peek-demo") { showWindowPeek() }
        if CommandLine.arguments.contains("--demo") || deepSeekDemo || multipleDemo {
            showDemo(deepSeek: deepSeekDemo, multiple: multipleDemo)
        }
        if let path = argument("--preview") {
            if !CommandLine.arguments.contains("--avoidance-demo") && !CommandLine.arguments.contains("--orange-hoodie-avoidance-demo") && argument("--developer-preview-action") == nil && singingDemoStartedAt == nil && sleepDemoStartedAt == nil && scootDemoStartedAt == nil && strollDemoStartedAt == nil && frontRetreatDemoStartedAt == nil && !windowPeekActive { showDemo(deepSeek: deepSeekDemo, multiple: multipleDemo) }
            let delay = argument("--preview-at").flatMap(Double.init) ?? 0.7
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0.1, delay)) { [weak self] in
                do {
                    try self?.overlays.exportPreview(to: URL(fileURLWithPath: path),
                        background: CommandLine.arguments.contains("--preview-white-background") ? .white : nil)
                }
                catch { fputs("Preview failed: \(error)\n", stderr) }
            }
        }
        if let seconds = argument("--quit-after").flatMap(Double.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + max(1, seconds)) { NSApp.terminate(nil) }
        }
        redraw()
    }

    func connect(root: URL) {
        monitor?.stop()
        monitor = nil
        doubaoReader = nil
        sourcePath = root.path
        guard !trackedHarnesses.isEmpty else { updateApprovalTracking(); receive([], error: nil); return }
        openCodeNavigationInstaller.onStatus = { [weak self] value in
            self?.openCodeNavigationStatus = value
            self?.openCodePluginInstalling = self?.openCodeNavigationInstaller.isInstalling ?? false
        }
        openCodeInstalled = OpenCodeNavigationInstaller.installedExecutable() != nil
        if !openCodeInstalled { openCodeNavigationStatus = "未检测到 OpenCode，已跳过安装" }
        else if openCodeNavigationStatus == "等待检测 OpenCode" { openCodeNavigationStatus = "可按需安装会话跳转插件" }
        taskSounds.volume = taskSoundVolume
        taskSounds.setQuestionEnabled(questionSoundsEnabled)
        taskSounds.onChange = { [weak self] in
            guard let self else { return }
            self.taskSoundStatus = self.taskSounds.status
            self.redraw()
        }
        taskSounds.setEnabledOutcomes(Set(TaskOutcome.allCases.filter { soundEnabled($0) }))
        let visible = tracks(.doubao) ? DoubaoVisibleReader() : nil
        visible?.setIncludesTools(showTools)
        doubaoReader = visible
        let reader = SessionMonitor(root: root, harnessRoot: harnessPath.isEmpty ? nil : URL(fileURLWithPath: harnessPath),
                                    claudeRoot: claudePath.isEmpty ? nil : URL(fileURLWithPath: claudePath),
                                    openCodeRoot: openCodePath.isEmpty ? nil : URL(fileURLWithPath: openCodePath),
                                    workBuddyRoot: workBuddyPath.isEmpty ? nil : URL(fileURLWithPath: workBuddyPath),
                                    enabledSources: Set(SessionSource.allCases.filter { tracks($0) }),
                                    visibleReader: visible.map { adapter in { adapter.poll() } })
        reader.onChange = { [weak self, weak reader] sessions, error in
            guard let self, self.monitor === reader else { return }
            self.receive(sessions, error: error)
        }
        reader.onOutcomes = { [weak self, weak reader] notices in
            guard let self, self.monitor === reader, self.taskSoundsEnabled else { return }
            for value in notices where self.soundEnabled(value.notice.outcome) {
                self.taskSounds.play(value.notice.outcome, title: value.title, turnID: value.notice.turnID)
            }
        }
        monitor = reader; reader.start()
    }

    func previewTaskSound(_ outcome: TaskOutcome) {
        taskSounds.play(outcome, preview: true)
    }

    func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.title = "选择 Codex 会话目录"
        panel.message = "默认目录为 ~/.codex/sessions。这里只读取公开摘要和助手进度。"
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true; panel.directoryURL = URL(fileURLWithPath: sourcePath)
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            save("sessionsRoot", url.path); selection = ""; states.removeAll(); connect(root: url)
        }
    }

    func chooseHarnessDirectory() {
        let panel = NSOpenPanel()
        panel.title = "选择 DeepSeek Harness 会话目录"
        panel.message = "选择 session-persistence-jsonl 的 root，默认 ~/.dsh/sessions。支持 .jsonl 和 .jsonl.zstd。"
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true; panel.directoryURL = URL(fileURLWithPath: harnessPath)
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            harnessPath = url.path; save("harnessRoot", url.path)
            selection = ""; states.removeAll(); connect(root: URL(fileURLWithPath: sourcePath))
        }
    }

    func directoryPath(for source: SessionSource) -> String {
        switch source { case .codex: return sourcePath; case .deepseek: return harnessPath; case .opencode: return openCodePath; case .workbuddy: return workBuddyPath; case .claude: return claudePath; case .doubao: return "跟随当前打开的对话 · 需要辅助功能权限" }
    }

    func openDoubaoAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func chooseClaudeDirectory() {
        let panel = NSOpenPanel()
        panel.title = "选择 Claude Code 会话目录"
        panel.message = "默认 ~/.claude/projects。只读主会话的助手文本和工具状态。"
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true; panel.directoryURL = URL(fileURLWithPath: claudePath)
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            claudePath = url.path; save("claudeRoot", url.path)
            selection = ""; states.removeAll(); connect(root: URL(fileURLWithPath: sourcePath))
        }
    }

    func installOpenCodeNavigationPlugin() {
        openCodeInstalled = OpenCodeNavigationInstaller.installedExecutable() != nil
        openCodeNavigationInstaller.install()
    }

    func chooseOpenCodeDirectory() {
        let panel = NSOpenPanel()
        panel.title = "选择 OpenCode 数据目录"
        panel.message = "选择包含 opencode.db 的目录，默认 ~/.local/share/opencode。"
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true; panel.directoryURL = URL(fileURLWithPath: openCodePath)
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            openCodePath = url.path; save("openCodeRoot", url.path)
            selection = ""; states.removeAll(); connect(root: URL(fileURLWithPath: sourcePath))
        }
    }

    func pinCurrent() { if let selected { selection = selected.path } }

    func chooseWorkBuddyDirectory() {
        let panel = NSOpenPanel()
        panel.title = "选择 WorkBuddy 数据目录"
        panel.message = "选择包含 workbuddy.db 和 projects 的目录，默认 ~/.workbuddy。"
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true; panel.directoryURL = URL(fileURLWithPath: workBuddyPath)
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            workBuddyPath = url.path; save("workBuddyRoot", url.path)
            selection = ""; states.removeAll(); connect(root: URL(fileURLWithPath: sourcePath))
        }
    }

    func showMouthDemo() {
        stopBackdropRelocation()
        stopWindowPeek()
        stopSleepDemo()
        stopScootDemo()
        stopStrollDemo()
        stopFrontRetreatDemo()
        singingDemoStartedAt = nil; speechDemo = false; resetSinging()
        refreshMusicTempoLabel(beat: lastLipFrame.beat, preview: false)
        mouthDemoStartedAt = ProcessInfo.processInfo.systemUptime
        enabled = true
        redraw(); updateMouth()
    }

    func showSingingDemo() {
        showDemo(deepSeek: true)
        stopBackdropRelocation()
        stopWindowPeek()
        stopSleepDemo()
        stopScootDemo()
        stopStrollDemo()
        stopFrontRetreatDemo()
        speechDemo = false; speechDemoFired = false
        kiraDemo = false; kiraDemoFired = false
        singingStepDemo = false; singingStepDemoMoved = false
        mouthDemoStartedAt = nil; mouthDemoIndex = nil
        singingDemoStartedAt = ProcessInfo.processInfo.systemUptime
        resetSinging(); enabled = true
        redraw(); updateMouth()
    }

    func showSingingStepDemo() {
        guard DeepSeekPerformance.shared.singingStepAvailable else { return }
        showDemo(deepSeek:true)
        showSingingDemo(); singingStepDemo = true
    }

    func showKiraDemo() {
        guard BuildProfile.experiments else { return }
        showSingingDemo(); kiraDemo = true; kiraDemoFired = false
    }

    func showSleepDemo() {
        guard DeepSeekSleepArtwork.shared.available else { return }
        showDemo(deepSeek: true)
        singingDemoStartedAt = nil; mouthDemoStartedAt = nil; mouthDemoIndex = nil
        speechDemo = false; resetSinging()
        sleepDemoStartedAt = ProcessInfo.processInfo.systemUptime
        currentText = "困了，趴一会儿……"
        previewUntil = Date().addingTimeInterval(DeepSeekSleepTimeline.duration+1)
        redraw(); updateMouth()
    }

    private func stopSleepDemo() {
        sleepDemoStartedAt = nil
        automaticSleep = false; sleepWakeAt = nil; sleepWakeEntryFrame = nil; sleepAnchor = nil
        overlays.setDeepSeekSleep(nil)
    }

    func showOrangeHoodieAvoidanceDemo() {
        let requested = requestedPreviewCharacter
        requestedPreviewCharacter = .orangeHoodie
        defer { requestedPreviewCharacter = requested }
        singingDemoStartedAt = nil; mouthDemoStartedAt = nil; resetSinging()
            showDemo(deepSeek:true); previewUntil = .distantFuture
            let source = backdropSource
            if let character = overlays.character(for:source), let area = character.panel.screen?.visibleFrame {
                let from = character.panel.frame.origin
                let allowed = overlays.allowedBackdropOrigins(for:source,in:area)
                guard !allowed.isNull else { developerPreviewStatus = "当前屏幕没有可用的移动范围"; return }
                let direction: CGFloat = argument("--avoidance-direction") == "left" ? -1 : 1
                let to = CGPoint(x:min(allowed.maxX,max(allowed.minX,from.x+direction*64*CGFloat(characterScale))),y:from.y)
                let plan = BackdropAvoidancePlan(from:from,to:to,movement:.scoot,destinationBody:.zero)
                hoodieAvoidanceDemo = true; hoodiePreviewAnchor = from; hoodiePreviewReturning = false; activeBackdropSource = source; activeBackdropArtwork = "blue-fish-orange-hoodie"; lastBackdropPlan = plan
                overlays.beginBackdropRelocation(for:source)
                backdropRelocation.start(plan,scale:CGFloat(characterScale),at:ProcessInfo.processInfo.systemUptime)
            }
    }

    func showScootDemo() {
        guard DeepSeekScoot.shared.available else { return }
        singingDemoStartedAt = nil; mouthDemoStartedAt = nil; mouthDemoIndex = nil
        speechDemo = false; resetSinging()
        showDemo(deepSeek: true)
        scootDemoStartedAt = ProcessInfo.processInfo.systemUptime
        currentText = "坐着挪一挪，\n换个舒服的位置。"
        previewUntil = Date().addingTimeInterval(SeatedScootTimeline.duration+1)
        redraw(); updateMouth()
    }

    func stopScootDemo() {
        let wasPlaying = scootDemoStartedAt != nil
        scootDemoStartedAt = nil
        overlays.setDeepSeekScoot(nil)
        scootActionLabel = "保持坐姿 · 撑地挪动"
        if wasPlaying { redraw() }
    }

    func showStrollDemo() {
        guard DeepSeekStroll.shared.available else { return }
        singingDemoStartedAt = nil; mouthDemoStartedAt = nil; mouthDemoIndex = nil
        speechDemo = false; resetSinging()
        showDemo(deepSeek: true)
        currentText = "起来活动一下，\n轻轻跑两步。"
        strollDemoStartedAt = ProcessInfo.processInfo.systemUptime
        previewUntil = Date().addingTimeInterval(StrollTimeline.duration+0.5)
        redraw(); updateMouth()
    }

    private func stopStrollDemo() {
        strollDemoStartedAt = nil
        overlays.setDeepSeekStroll(nil)
        strollActionLabel = "坐姿 → 起身 → 侧身小跑"
    }

    func showFrontRetreatDemo() {
        guard DeepSeekFrontRetreat.shared.available else { return }
        singingDemoStartedAt = nil; mouthDemoStartedAt = nil; mouthDemoIndex = nil
        speechDemo = false; resetSinging()
        showDemo(deepSeek:true)
        frontRetreatDemoStartedAt = ProcessInfo.processInfo.systemUptime
        currentText = "先让一让，\n马上挪开！"
        previewUntil = Date().addingTimeInterval(FrontRetreatTimeline.duration+1)
        redraw(); updateMouth()
    }

    func stopFrontRetreatDemo() {
        let wasPlaying = frontRetreatDemoStartedAt != nil
        frontRetreatDemoStartedAt = nil
        overlays.setDeepSeekFrontRetreat(nil)
        frontRetreatActionLabel = "正面横退 · 加急小步"
        if wasPlaying { redraw() }
    }

    private var singingBlocksWindowPeek: Bool {
        singingPlayer.phase != .seated || singingDemoStartedAt != nil
    }

    func showWindowSeat() { showWindowPeek(previewSeat:true) }

    func showWindowPeek(previewSeat:Bool = false) {
        guard !singingBlocksWindowPeek else {
            windowPeekLabel = "正在唱歌 · 坐下后才能预览窗口休息"
            return
        }
        guard harnessStateObserved else {
            pendingWindowPeekPreview = true
            pendingWindowSeatPreview = previewSeat
            windowPeekLabel = "正在确认绑定的 Harness 是否空闲"
            return
        }
        guard deepSeekHarnessIdle else {
            windowPeekLabel = "绑定的 Harness 正在工作 · 空闲后才能预览窗口休息"
            return
        }
        stopWindowPeek()
        singingDemoStartedAt = nil; mouthDemoStartedAt = nil; mouthDemoIndex = nil
        resetSinging(); showDemo(deepSeek:true)
        let original = overlays.character(for:deepSeekSource)?.panel.frame ?? overlays.character.panel.frame
        beginWindowPeek(from:original,previewSeat:previewSeat)
        redraw()
    }

    private func beginWindowPeek(from original:NSRect, requiredTarget:DesktopWindowTarget? = nil,
                                 previewSeat:Bool = false) {
        guard !singingBlocksWindowPeek else {
            windowPeekLabel = "正在唱歌 · 坐下后才能休息"
            windowPeekIdle.reset()
            return
        }
        guard harnessStateObserved && deepSeekHarnessIdle else {
            windowPeekLabel = "绑定的 Harness 正在工作 · 空闲后才能休息"
            windowPeekIdle.reset()
            return
        }
        let target = argument("--window-peek-target").flatMap(UInt32.init)
        let speed = argument("--window-peek-speed").flatMap(Double.init).map { CGFloat($0) }
        let hold = argument("--window-peek-hold").flatMap(Double.init) ?? 4.8
        if windowPeek.start(from:original,scale:CGFloat(characterScale),targetID:target,
                            forceFixture:CommandLine.arguments.contains("--window-peek-fixture"),
                            speed:speed,hold:hold,requiredTarget:requiredTarget,
                            allowedReturnOrigins:overlays.deepSeekAllowedOrigins,
                            preferSeat:requiredTarget?.prefersSeat == true,previewSeat:previewSeat) {
            windowPeekActive = true
            automaticWindowPeek = requiredTarget != nil
            if automaticWindowPeek { automaticWindowPeekCount += 1 }
            activeWindowPeekSource = deepSeekSource
            overlays.setSourceHidden(deepSeekSource,true)
            if demoMode { previewUntil = .distantFuture }
        }
        windowPeekLabel = windowPeek.status
    }

    func requestBackdropPermission() {
        // Explicit user action also registers this running bundle with macOS's permission UI.
        // Keep actual capture as the authority even if the legacy request returns false.
        if !CGPreflightScreenCaptureAccess() { _ = CGRequestScreenCaptureAccess() }
        guard let screen = overlays.character(for:deepSeekSource)?.panel.screen ?? NSScreen.main,
              let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else { return }
        guard !backdropObservation.busy else { recheckBackdrop(); return }
        backdropObservation.retryAccess()
        avoidanceStatus = "正在验证实际屏幕读取能力"
        backdropObservation.checkAccess(displayID:displayID) { [weak self] result in
            guard let self else { return }
            self.backdropPermission = self.backdropObservation.hasCaptureAccess
            switch result {
            case .success:
                self.avoidanceStatus = "屏幕读取已就绪 · 正在检查背景"
                self.recheckBackdrop()
            case .failure(let error):
                self.avoidanceStatus = error.localizedDescription
                if BackdropCapture.isPermissionFailure(error) {
                    NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                }
            }
        }
    }

    func recheckBackdrop() {
        if demoMode && singingDemoStartedAt == nil && mouthDemoStartedAt == nil {
            backdropPreviewCheck = true; previewUntil = .distantFuture
        }
        backdropObservation.retryAccess()
        backdropTrigger.reset(until:ProcessInfo.processInfo.systemUptime)
        lastBackdropScan = -Double.infinity
        backdropCheckRequested = true
        updateBackdropAvoidance()
    }

    private func stopBackdropRelocation(cooldown: Double = 10) {
        if backdropRelocation.running {
            let source = activeBackdropSource ?? backdropSource
            let restore = hoodieAvoidanceDemo ? hoodiePreviewAnchor : nil
            backdropRelocation.stop(); overlays.endBackdropRelocation(for:source)
            if let restore { overlays.character(for:source)?.panel.setFrameOrigin(restore) }
            lastBackdropOrigins[source] = overlays.character(for:source)?.panel.frame.origin
            hoodiePreviewAnchor = nil; hoodiePreviewReturning = false
            activeBackdropSource = nil; activeBackdropArtwork = nil; hoodieAvoidanceDemo = false
            backdropCandidateIndex += 1
        }
        backdropTrigger.reset(until:ProcessInfo.processInfo.systemUptime+cooldown)
    }

    private var backdropAvoidanceDiagnostics: [String:Any] {
        var value: [String:Any] = ["enabled":autoAvoidanceEnabled,"permission":backdropPermission,
            "legacyPermissionPreflight":CGPreflightScreenCaptureAccess(),
            "permissionRejectedByCapture":backdropObservation.permissionDenied,
            "status":avoidanceStatus,"active":backdropRelocation.running,"source":(activeBackdropSource ?? backdropSource).rawValue,"eligibleSources":eligibleBackdropSources.map(\.rawValue),"scans":backdropScans,
            "planningMilliseconds":backdropPlanningMilliseconds,
            "observationMilliseconds":backdropObservation.lastCaptureMilliseconds + backdropObservation.lastAnalysisMilliseconds + backdropPlanningMilliseconds,
            "captureDisplays":backdropObservation.lastDisplayCount,
            "captureMilliseconds":backdropObservation.lastCaptureMilliseconds,
            "analysisMilliseconds":backdropObservation.lastAnalysisMilliseconds,
            "analysisMode":"uniformity","overlap":backdropOverlap,"moves":backdropMoves,
            "destinationConfirmedBlank":backdropLastSafe,"busy":backdropObservation.busy]
        if let character = overlays.character(for:activeBackdropSource ?? backdropSource), let screen = character.panel.screen {
            let area = overlays.allowedBackdropOrigins(for:activeBackdropSource ?? backdropSource,in:screen.visibleFrame)
            if !area.isNull { value["allowedOrigins"] = [area.minX,area.minY,area.width,area.height] }
            value["screenFrame"] = [screen.frame.minX,screen.frame.minY,screen.frame.width,screen.frame.height]
            if let sprite = character.subtitle.backdropSprite {
                let rect = sprite.1.offsetBy(dx:character.panel.frame.minX,dy:character.panel.frame.minY)
                value["spriteFrame"] = [rect.minX,rect.minY,rect.width,rect.height]
            }
        }
        value["lastScanStartedAt"] = lastBackdropScan.isFinite ? lastBackdropScan as Any : NSNull()
        value["manualDragEndedAt"] = lastManualDragEndedAt.map { $0 as Any } ?? NSNull()
        if let p = lastBackdropPlan {
            value["movement"] = p.movement.rawValue; value["distance"] = p.distance
            value["from"] = [p.from.x,p.from.y]; value["to"] = [p.to.x,p.to.y]
            value["destinationBody"] = [p.destinationBody.minX,p.destinationBody.minY,p.destinationBody.width,p.destinationBody.height]
        }
        return value
    }

    private func updateBackdropAvoidance() {
        let now = ProcessInfo.processInfo.systemUptime
        let source = backdropSource
        let hoodie = effectiveCharacterBindings[source] == .orangeHoodie
        let expectedArtwork = hoodie ? "blue-fish-orange-hoodie" : "deepseek"
        let blocked = !autoAvoidanceEnabled ? "自动避让已关闭" : !enabled ? "角色显示已关闭" :
            (demoMode && !CommandLine.arguments.contains("--avoidance-demo") && !backdropPreviewCheck) ? "动作预览中 · 可点击检查所选角色背景进行实测" : nil
        if let blocked {
            if avoidanceStatus != blocked { avoidanceStatus = blocked }
            return
        }
        if activeBackdropSource == nil && eligibleBackdropSources.isEmpty {
            let status = singingPlayer.phase == .seated ? "等待可移动的可见角色" : "唱歌中 · 坐回后检查短程避让"
            if avoidanceStatus != status { avoidanceStatus = status }
            return
        }
        guard !onboardingActive, autoAvoidanceEnabled, enabled,
              !demoMode || CommandLine.arguments.contains("--avoidance-demo") || backdropPreviewCheck,
              !windowPeek.isRunning, sleepDemoStartedAt == nil, scootDemoStartedAt == nil, strollDemoStartedAt == nil, frontRetreatDemoStartedAt == nil,
              singingDemoStartedAt == nil || CommandLine.arguments.contains("--singing-avoidance-demo"), mouthDemoStartedAt == nil,
              singingPlayer.phase == .seated || (!hoodie && singingPlayer.phase == .singing),
              let character = overlays.character(for:source), character.panel.isVisible,
              character.subtitle.mascotArtwork == expectedArtwork, character.subtitle.screenEdgeDock == nil, !character.panel.isManuallyDragging,
              !character.subtitle.headPatActive,
              let backdrop = character.subtitle.backdropSprite,
              let screen = character.panel.screen else { return }
        if !backdropRelocation.running {
            if let previous = lastBackdropOrigins[source], hypot(previous.x-character.panel.frame.minX,previous.y-character.panel.frame.minY) > 3 {
                backdropTrigger.reset(until:now+4)
            }
            lastBackdropOrigins[source] = character.panel.frame.origin
        }
        let scanInterval = backdropRelocation.running ? 1.2
            : backdropTrigger.needsQuickConfirmation ? BackdropAvoidanceTrigger.confirmationScanInterval : 1.5
        guard backdropCheckRequested || now-lastBackdropScan >= scanInterval,
              !backdropObservation.busy else { return }
        backdropCheckRequested = false
        lastBackdropScan = now
        backdropPlanningMilliseconds = 0
        guard !backdropObservation.permissionDenied else { return }
        let origin = character.panel.frame.origin, sprite = backdrop.1.offsetBy(dx:origin.x,dy:origin.y)
        if backdropArtworkKey != expectedArtwork {
            backdropSilhouettes.removeAll(); backdropArtworkKey = expectedArtwork
            backdropTrigger.reset()
        }
        let key = character.subtitle.performanceFrameIndex ?? (character.subtitle.hasScootRestPose ? -2 : -1)
        let silhouette = backdropSilhouettes[key] ?? BackdropSilhouette(image:backdrop.0)
        backdropSilhouettes[key] = silhouette
        var landingBounds: CGRect?
        let singing = !hoodie && singingPlayer.phase == .singing && DeepSeekPerformance.shared.singingStepAvailable
        if singing {
            // Reserve every standing and step pose, in both directions; no seated landing.
            for index in Array(16..<24)+Array(DeepSeekPerformance.singingStepStart..<(DeepSeekPerformance.singingStepStart+8)) {
                let mask = backdropSilhouettes[index] ?? BackdropSilhouette(image:DeepSeekPerformance.shared.frames[index].cgImage(forProposedRect:nil,context:nil,hints:nil)!)
                backdropSilhouettes[index] = mask
                let body = mask.worldBounds(in:sprite)
                let mirrored = CGRect(x:2*sprite.midX-body.maxX,y:body.minY,width:body.width,height:body.height)
                landingBounds = (landingBounds ?? body).union(body).union(mirrored)
            }
        } else if let rest = character.subtitle.backdropRestSprite {
            let restMask = backdropSilhouettes[-2] ?? BackdropSilhouette(image:rest.0)
            backdropSilhouettes[-2] = restMask
            landingBounds = restMask.worldBounds(in:rest.1.offsetBy(dx:origin.x,dy:origin.y))
        }
        let scale = CGFloat(characterScale)
        if hoodie {
            // Reserve the small whole-body lean/lift and every seated blink pose.
            let restBounds = silhouette.worldBounds(in:sprite).insetBy(dx:-8*scale,dy:-8*scale)
            landingBounds = restBounds
        }
        let searchScreens = NSScreen.screens
        let searchAreas = searchScreens.map { screen -> CGRect in
            var allowed = overlays.allowedBackdropOrigins(for:source,in:screen.visibleFrame)
            if let raw = argument("--avoidance-search-region") {
                let v = raw.split(separator:",").compactMap { Double($0) }
                if v.count == 4 { allowed = allowed.intersection(CGRect(x:v[0],y:v[1],width:v[2],height:v[3])) }
            }
            return allowed
        }
        let captures = searchScreens.compactMap { screen -> (id: CGDirectDisplayID, frame: CGRect)? in
            guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else { return nil }
            return (id,screen.frame)
        }
        guard captures.count == searchScreens.count else { return }
        // During travel only recapture the target screen, even while the sprite straddles the seam.
        let targets = backdropRelocation.plan.flatMap { plan in
            captures.first { $0.frame.contains(plan.destinationBody) }
        }.map { [$0] } ?? captures
        backdropObservation.observe(displays:targets) { [weak self] result in
            guard let self, self.autoAvoidanceEnabled, self.enabled,
                  !self.demoMode || CommandLine.arguments.contains("--avoidance-demo") || self.backdropPreviewCheck,
                  self.sleepDemoStartedAt == nil, self.scootDemoStartedAt == nil, self.strollDemoStartedAt == nil, self.frontRetreatDemoStartedAt == nil,
                  self.singingDemoStartedAt == nil || CommandLine.arguments.contains("--singing-avoidance-demo"), self.mouthDemoStartedAt == nil,
                  !self.windowPeek.isRunning,
                  source == self.backdropSource,
                  let current = self.overlays.character(for:source), current.panel.isVisible,
                  current.subtitle.mascotArtwork == expectedArtwork, !current.panel.isManuallyDragging else { return }
            guard !current.subtitle.headPatActive else { return }
            switch result {
            case .failure(let error):
                self.backdropPermission = self.backdropObservation.hasCaptureAccess
                self.avoidanceStatus = error.localizedDescription
                self.backdropTrigger.reset()
                if self.backdropRelocation.running {
                    self.backdropLastSafe = false
                    self.backdropRelocation.settle(at:current.panel.frame.origin,now:ProcessInfo.processInfo.systemUptime)
                }
            case .success(let scenes):
                self.backdropPermission = true
                let time = ProcessInfo.processInfo.systemUptime
                guard scenes.allSatisfy({ time-$0.capturedAt < 5 }),
                      searchScreens.map(\.frame) == NSScreen.screens.map(\.frame) else {
                    self.backdropTrigger.reset()
                    if self.backdropRelocation.running { self.backdropRelocation.settle(at:current.panel.frame.origin,now:time) }
                    return
                }
                self.backdropScans += 1
                if self.backdropRelocation.running, let plan = self.backdropRelocation.plan {
                    if !scenes.contains(where: { $0.isBlank(plan.destinationBody) }) {
                        self.backdropLastSafe = false
                        self.backdropRelocation.settle(at:current.panel.frame.origin,now:time)
                    }
                    return
                }
                guard hypot(current.panel.frame.minX-origin.x,current.panel.frame.minY-origin.y) < 3,
                      self.singingPlayer.phase == .seated || self.singingPlayer.phase == .singing,
                      singing == (!hoodie && self.singingPlayer.phase == .singing && DeepSeekPerformance.shared.singingStepAvailable),
                      self.sleepDemoStartedAt == nil, self.scootDemoStartedAt == nil, self.strollDemoStartedAt == nil, self.frontRetreatDemoStartedAt == nil, !self.windowPeek.isRunning else {
                    self.backdropTrigger.reset(); return
                }
                guard let currentScene = scenes.first(where: { $0.frame == screen.frame }) else { self.backdropTrigger.reset(); return }
                self.backdropOverlap = currentScene.isObstructed(silhouette:silhouette,sprite:sprite)
                guard self.backdropOverlap else {
                    self.avoidanceStatus = "当前角色位于纯色背景"
                    self.backdropCandidateIndex += 1
                    self.backdropTrigger.reset(); return
                }
                let planningStartedAt = ProcessInfo.processInfo.systemUptime
                let plan = scenes.compactMap { scene -> BackdropAvoidancePlan? in
                    guard let index = searchScreens.firstIndex(where: { $0.frame == scene.frame }) else { return nil }
                    return BackdropAvoidancePlanner.plan(scene:scene,silhouette:silhouette,sprite:sprite,
                        panelOrigin:origin,allowedOrigins:searchAreas[index],scale:scale,
                        destinationBounds:landingBounds,singing:singing,requireObstruction:false,
                        maxDistance:hoodie ? 120*scale : nil)
                }.min { $0.distance < $1.distance }
                self.backdropPlanningMilliseconds = (ProcessInfo.processInfo.systemUptime-planningStartedAt)*1000
                guard let plan else {
                    self.avoidanceStatus = hoodie ? "附近暂无短程空位 · 保持坐姿等待" : "检测到遮挡 · 暂无足够大的纯色空白区域"
                    self.backdropCandidateIndex += 1
                    self.backdropTrigger.reset(); return
                }
                guard self.backdropTrigger.observe(plan,at:time) else {
                    self.avoidanceStatus = time < self.backdropTrigger.cooldownUntil
                        ? "移动冷却中 · 稍后重新检查空白区域"
                        : "检测到遮挡 · 正在确认附近空白区域"
                    return
                }
                if !singing { self.resetSinging() }
                self.lastBackdropPlan = plan; self.backdropLastSafe = true; self.backdropMoves += 1
                self.activeBackdropSource = source
                self.activeBackdropArtwork = expectedArtwork
                self.overlays.beginBackdropRelocation(for:source)
                self.backdropRelocation.start(plan,scale:scale,at:time)
                self.windowPeekIdle.reset()
                self.updateMouth()
            }
        }
    }

    private func wakeAutomaticSleep(at now: TimeInterval) {
        guard automaticSleep, sleepWakeAt == nil, let start = sleepDemoStartedAt else { return }
        sleepWakeAt = now
        if now-start < 3.2 {
            sleepWakeEntryFrame = DeepSeekSleepTimeline.sample(at: now-start)?.frame ?? 0
        }
        windowPeekIdle.reset()
    }

    private func updateAutomaticWindowPeek() {
        let now = ProcessInfo.processInfo.systemUptime
        if automaticSleep {
            let character = overlays.character(for: deepSeekSource)
            let moved = character.map { $0.panel.frame != sleepAnchor } ?? true
            if !enabled || !autoWindowPeekEnabled || !deepSeekHarnessIdle || singingBlocksWindowPeek ||
                character?.panel.isManuallyDragging == true || character?.panel.isVisible != true || moved {
                wakeAutomaticSleep(at: now)
            }
            windowPeekIdle.pause(at: now)
            autoWindowPeekLabel = sleepWakeAt == nil ? "没有合适窗口 · 正在趴睡" : "正在醒来 · 恢复坐姿"
            return
        }
        guard !singingBlocksWindowPeek else {
            windowPeekIdle.reset()
            autoWindowPeekLabel = "正在唱歌 · 坐下后重新计时"
            return
        }
        guard deepSeekHarnessIdle else {
            windowPeekIdle.reset()
            autoWindowPeekLabel = "绑定的 Harness 正在工作 · 暂不藏身"
            if windowPeek.isRunning { windowPeek.stop(reason:"绑定的 Harness 已开始工作 · 恢复工作展示") }
            return
        }
        if windowPeek.isRunning {
            windowPeekIdle.pause(at:now)
            if automaticWindowPeek { autoWindowPeekLabel = "已自动触发 · "+windowPeek.status }
            return
        }
        guard now-lastWindowPeekObservation >= 0.5 else { return }
        lastWindowPeekObservation = now
        guard enabled, autoWindowPeekEnabled, harnessStateObserved, !demoMode, hasDeepSeekCharacter,
              singingDemoStartedAt == nil, sleepDemoStartedAt == nil, scootDemoStartedAt == nil, strollDemoStartedAt == nil, frontRetreatDemoStartedAt == nil, mouthDemoStartedAt == nil,
              !backdropRelocation.running, !backdropOverlap,
              let character = overlays.character(for:deepSeekSource), character.panel.isVisible,
              character.subtitle.screenEdgeDock == nil, !character.panel.isManuallyDragging, !character.subtitle.headPatActive else {
            windowPeekIdle.reset()
            autoWindowPeekLabel = autoWindowPeekEnabled ? "等待 DeepSeek 角色保持静止" : "自动休息已关闭"
            return
        }
        let frame = character.panel.frame
        let onlyWindow = argument("--window-peek-target").flatMap(UInt32.init)
        let target = DesktopWindowTarget.choose(near:frame,scale:CGFloat(characterScale),onlyWindow:onlyWindow)
        if windowPeekIdle.observe(character:frame,target:target,at:now,harnessIdle:deepSeekHarnessIdle,
                                  singing:singingBlocksWindowPeek, allowNoTarget: true) {
            resetSinging()
            if let target { beginWindowPeek(from:frame,requiredTarget:target) }
            if !windowPeek.isRunning, DeepSeekSleepArtwork.shared.available {
                sleepDemoStartedAt = now; automaticSleep = true
                sleepWakeAt = nil; sleepWakeEntryFrame = nil; sleepAnchor = frame
                automaticSleepCount += 1
                updateMouth()
            }
            redraw()
        }
        if automaticSleep { autoWindowPeekLabel = "没有合适窗口 · 正在趴睡" }
        else if target == nil { autoWindowPeekLabel = String(format:"无合适窗口 · 静止 %.0f / %.0f 秒后睡觉",windowPeekIdle.stationarySeconds,windowPeekIdle.delay) }
        else if windowPeekIdle.fired { autoWindowPeekLabel = "本轮静止已触发 · 移动角色或窗口后重新计时" }
        else { autoWindowPeekLabel = String(format:"角色与窗口静止 %.0f / %.0f 秒",windowPeekIdle.stationarySeconds,windowPeekIdle.delay) }
    }

    func stopWindowPeek() {
        guard windowPeek.isRunning else { return }
        windowPeek.stop(reason:"窗口动作已停止 · 已回到原位")
    }

    private func triggerKira(at now: TimeInterval, automatic: Bool, fromSpeech: Bool = false) {
        guard BuildProfile.experiments else { return }
        guard kiraStartedAt == nil, DeepSeekPerformance.shared.kiraAvailable,
              singingPlayer.phase == .singing else { return }
        kiraStartedAt = now; kiraAutomatic = automatic; kiraFromSpeech = fromSpeech
    }

    func retrySpeech() {
        audio.speech.setEnabled(false, engine: speechEngine, modelPath: whisperModelPath)
        resetSpeechPresentation(); configureSpeech()
    }

    func chooseWhisperModel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.message = "选择 whisper.cpp 多语言 ggml .bin 模型（不要选择 .en 英语模型）"
        if panel.runModal() == .OK, let url = panel.url { whisperModelPath = url.path }
    }

    private func resetSpeechPresentation() {
        speechCountdown.cancel(); speechTranscript = ""; speechKeywordTimingLabel = ""
        speechHighlight = SpeechKeywordHighlight(); speechHighlightedKeyword = nil
        speechHighlightedKeywords = []
        speechCueDeduplicator = SpeechCueDeduplicator()
        speechCountdownLabel = "等待「\(JapaneseKiraKeyword.displayList)」"
        if kiraFromSpeech { kiraStartedAt = nil }
    }

    private func refreshSpeechProgress() {
        let now = ProcessInfo.processInfo.systemUptime
        let input = speechProgress.inputLabel(at: now)
        let result = speechProgress.resultLabel(at: now)
        if speechInputLabel != input { speechInputLabel = input }
        if speechResultLabel != result { speechResultLabel = result }
    }

    func showSpeechDemo() {
        guard BuildProfile.experiments else { return }
        resetSpeechPresentation()
        showSingingDemo(); speechDemo = true; speechDemoFired = false
    }

    private func configureSpeech() {
        let active = BuildProfile.experiments && enabled && audioEnabled && audioRunning && speechKeywordEnabled &&
            singingActionEnabled && !singingSources.isEmpty
        audio.speech.setEnabled(active, engine: speechEngine, modelPath: whisperModelPath)
        if !active {
            speechCountdown.cancel(); speechTranscript = ""
            if kiraFromSpeech { kiraStartedAt = nil }
            if speechKeywordEnabled { speechStatus = "等待系统声音与 DeepSeek 歌唱功能开启" }
        }
    }

    private func receiveSpeechKeyword(keyword: JapaneseKiraKeyword = .kamawanai, endpoint: TimeInterval?,
                                      receivedAt: TimeInterval, audible: Bool = true) {
        speechKeywordCount += 1
        speechHighlight.receive(keyword, at: ProcessInfo.processInfo.systemUptime)
        speechHighlightedKeyword = speechHighlight.keyword
        speechHighlightedKeywords = speechHighlight.keywords
        speechKeywordTimingLabel = endpoint.map {
            String(format: "命中「%@」· 词末→返回约 %.2f 秒", keyword.rawValue, max(0, receivedAt - $0))
        } ?? "命中「\(keyword.rawValue)」· 词时间未定稿或缺失，按返回时刻计时（拍点待校准）"
        guard audible else {
            speechCountdownLabel = "关键词已命中 · 最近没有声音，跳过动作"; return
        }
        guard speechCountdown.target == nil else {
            speechCountdownLabel = "关键词已命中 · 保留当前倒计时"; return
        }
        speechUsesArrivalTime = endpoint == nil
        let delay = speechDemo ? 3 : keyword.countdownDelay(primary: speechKiraDelay, backupExtra: speechBackupExtraDelay)
        guard speechCueDeduplicator.allows(keyword, at: receivedAt,
                cooldown: max(12, speechKiraDelay + speechBackupExtraDelay + KiraTimeline.duration)) else {
            speechCountdownLabel = "关键词已命中 · 该句已触发，跳过重复动作"; return
        }
        if speechCountdown.arm(endpoint: endpoint ?? receivedAt, receivedAt: receivedAt, delay: delay) {
            speechCueDeduplicator.record(keyword, at: receivedAt)
            speechCountdownKeyword = keyword
            speechCountdownLabel = speechUsesArrivalTime ? "命中 · 按返回时刻开始倒计时" : "命中 · 按词末时间开始倒计时"
        } else {
            speechCountdownLabel = "关键词已命中 · 返回太晚，已错过动作时间"
        }
    }

    var canMarkKira: Bool {
        guard songRecognitionEnabled, let track = currentTrack, track.recordingKey != nil,
              (track.rate ?? 0) > 0 else { return false }
        return track.position(at: ProcessInfo.processInfo.systemUptime) != nil
    }

    func markKiraNow() {
        guard BuildProfile.experiments else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard canMarkKira, let track = currentTrack, let key = track.recordingKey,
              let position = track.position(at: now) else { return }
        var cues = kiraCues[key] ?? []
        if !cues.contains(where: { abs($0 - position) < 1 }) { cues.append(position) }
        kiraCues[key] = Array(cues.sorted().prefix(16))
        persistKiraCues(); cueScheduler = KiraCueScheduler()
        // This click marks an audible accent now. Start at the held pose;
        // subsequent playback includes the anticipatory arm transition.
        triggerKira(at: now - KiraTimeline.accentOffset, automatic: false)
    }

    func clearKiraMarkers() {
        guard let key = currentTrack?.recordingKey else { return }
        kiraCues.removeValue(forKey: key); cueScheduler = KiraCueScheduler(); persistKiraCues()
    }

    private func persistKiraCues() {
        if let data = try? JSONEncoder().encode(kiraCues) { save("kiraCues.v1", data) }
        refreshKiraMarkers()
    }

    private func refreshKiraMarkers() {
        guard let track = currentTrack, track.candidate else {
            kiraMarkerLabel = "等待《星间飞行》的播放标题"; return
        }
        guard let key = track.recordingKey, track.elapsed != nil else {
            kiraMarkerLabel = "播放信息不完整，暂不能标记此版本"; return
        }
        let cues = kiraCues[key] ?? []
        kiraMarkerLabel = cues.isEmpty ? "此版本尚未标记 · 唱到 Kira 时点下方按钮" :
            "此版本已标记：" + cues.map { String(format: "%d:%04.1f", Int($0) / 60, $0.truncatingRemainder(dividingBy: 60)) }.joined(separator: "、")
    }

    private func configureNowPlaying() {
        let active = BuildProfile.experiments && enabled && songRecognitionEnabled && (audioEnabled || CommandLine.arguments.contains("--now-playing-probe"))
        nowPlaying.setEnabled(active)
        if !active {
            currentTrack = nil; cueScheduler = KiraCueScheduler()
            if kiraAutomatic { kiraStartedAt = nil }
            songRecognitionLabel = songRecognitionEnabled ? "开启系统声音后识别歌曲标题" : "歌曲彩蛋已关闭"
            refreshKiraMarkers()
        }
    }

    private func resetSinging() {
        singingStepDemo = false; singingStepDemoMoved = false
        if backdropRelocation.plan?.movement == .singingStep { stopBackdropRelocation() }
        speechCountdown.cancel()
        kiraStartedAt = nil; cueScheduler = KiraCueScheduler()
        singingPlayer = SingingPerformance()
        if singingActionLabel != "DeepSeek · 坐姿" { singingActionLabel = "DeepSeek · 坐姿" }
        refreshAnimationPlaybackLabel()
        overlays.setDeepSeekPerformance(nil)
        overlays.setOrangeHoodieSinging(phase:.seated,cycle:0,at:ProcessInfo.processInfo.systemUptime,targets:[])
    }

    private func updateSinging(scene: SoundScene, level: Float, now: TimeInterval, allowed: Bool,
                               beat: BeatEstimate = .unknown, beatDeliveryAge: TimeInterval = 0) {
        let frame = singingPlayer.sample(scene: scene, level: level, at: now,
                                        enabled: allowed && (DeepSeekPerformance.shared.available || OrangeHoodiePerformance.shared.available), beat: beat, beatDeliveryAge: beatDeliveryAge)
        overlays.setOrangeHoodieSinging(phase:singingPlayer.phase,cycle:singingPlayer.cycleProgress,at:now,targets:singingSources)
        #if VIBECUTE_RELEASE
        let kiraFrame: Int? = nil
        #else
        if speechDemo, !speechDemoFired, let start = singingDemoStartedAt, now - start >= 2.6 {
            speechDemoFired = true
            receiveSpeechKeyword(endpoint: start + 2.2, receivedAt: now)
        }
        if !allowed || (scene.kind == .silence && level < 0.01) || (!speechDemo && !speechKeywordEnabled) {
            if speechCountdown.target != nil {
                speechCountdownLabel = !allowed || (!speechDemo && !speechKeywordEnabled) ?
                    "倒计时已取消 · 功能已关闭" : "倒计时已取消 · 系统声音已静音"
            }
            speechCountdown.cancel()
        }
        if let remaining = speechCountdown.remaining(at: now) {
            let label = String(format: "%@Kira 倒计时 %.1f 秒%@", speechDemo ? "模拟 · " : "", remaining,
                               speechUsesArrivalTime ? "（按返回时刻）" : "")
            if speechCountdownLabel != label { speechCountdownLabel = label }
        }
        let hadCountdown = speechCountdown.target != nil
        if let start = speechCountdown.takeStart(at: now) {
            if singingPlayer.phase == .singing {
                triggerKira(at: start, automatic: false, fromSpeech: true)
                speechCountdownLabel = speechDemo ? "模拟 · Kira！" : "「\(speechCountdownKeyword.rawValue)」→ Kira！"
            } else { speechCountdownLabel = "关键词已命中 · DeepSeek 尚未站立唱歌" }
        } else if hadCountdown && speechCountdown.target == nil {
            speechCountdownLabel = "倒计时已过 · 跳过迟到动作"
        }
        let cues = currentTrack?.recordingKey.flatMap { kiraCues[$0] } ?? []
        let cue = cueScheduler.sample(track: songRecognitionEnabled ? currentTrack : nil, cues: cues, at: now)
        if cue && allowed && singingPlayer.phase == .singing && singingDemoStartedAt == nil {
            triggerKira(at: now, automatic: true)
        }
        if kiraDemo, !kiraDemoFired, let start = singingDemoStartedAt, now - start >= 3.2 {
            kiraDemoFired = true; triggerKira(at: now, automatic: false)
        }
        if !allowed || singingPlayer.phase != .singing ||
            (kiraAutomatic && (currentTrack?.candidate != true || currentTrack?.fresh(at: now) != true || (currentTrack?.rate ?? 0) <= 0)) {
            kiraStartedAt = nil
        }
        let kiraFrame = kiraStartedAt.flatMap { KiraTimeline.frame(at: now - $0) }
        if kiraStartedAt != nil && kiraFrame == nil { kiraStartedAt = nil }
        #endif
        if backdropRelocation.plan?.movement == .singingStep, backdropRelocation.running {
            if singingPlayer.phase == .singing {
                overlays.setDeepSeekPerformance(backdropRelocation.sample(at:now)?.performanceFrame ?? frame, targets: singingSources)
            } else {
                stopBackdropRelocation(cooldown:3)
                avoidanceStatus = "歌唱结束 · 在当前位置坐下"
                overlays.setDeepSeekPerformance(kiraFrame ?? frame, targets: singingSources)
            }
        } else { overlays.setDeepSeekPerformance(kiraFrame ?? frame, targets: singingSources) }
        refreshMusicTempoLabel(beat: beat, preview: singingDemoStartedAt != nil)
        refreshAnimationPlaybackLabel()
        let phase: String
        switch singingPlayer.phase {
        case .seated: phase = "坐姿"
        case .rising: phase = "正在起身"
        case .singing: phase = backdropRelocation.running && backdropRelocation.plan?.movement == .singingStep ? "站立唱歌 · 小步移动" : "站立唱歌"
        case .sitting: phase = "正在坐下"
        }
        let tempo = singingPlayer.phase == .singing && beat.reliable ? " · \(Int(beat.bpm!.rounded())) BPM" : ""
        let label = kiraFrame == nil ? "DeepSeek · \(phase)\(tempo)" : "DeepSeek · (<ゝω·)~☆ Kira！"
        if singingActionLabel != label { singingActionLabel = label }
    }

    func showDemo(deepSeek: Bool = false, multiple: Bool = false) {
        questionPreviewActive = false; questionPreviewRequest = nil; questionPreviewRevealAt = nil
        questionPreviewPreviousEnabled = nil
        singingStepDemo = false
        stopBackdropRelocation(cooldown:0)
        stopWindowPeek()
        stopSleepDemo()
        stopScootDemo()
        stopStrollDemo()
        stopFrontRetreatDemo()
        previewUntil = Date().addingTimeInterval(12)
        demoMode = true; demoPinkBear = false
        demoCharacterOverride = requestedPreviewCharacter; backdropPreviewCheck = false
        demoDeepSeek = deepSeek
        demoMultiple = multiple
        demoTypewriterID = UUID().uuidString
        currentText = deepSeek ? "正在梳理问题，\n把思路一步步展开。" : "把 Codex 的工作进度，\n轻轻放在屏幕上。"
        enabled = true
        redraw()
    }

    func showQuestionPreview(approval: Bool = false) {
        let previousEnabled = questionPreviewPreviousEnabled ?? enabled
        showDemo()
        questionPreviewPreviousEnabled = previousEnabled
        questionPreviewActive = true
        approvalPreview = approval
        currentText = "一行字幕预览。"
        // Reuse the existing 250 ms UI clock; no new preview timer or IPC.
        questionPreviewRevealAt = Date().addingTimeInterval(0.65)
        previewUntil = Date().addingTimeInterval(60)
        redraw()
    }

    private func finishQuestionPreview(_ answers: [String: String],
                                      completion: @escaping (Result<Void, Error>) -> Void) {
        guard questionPreviewActive, let request = questionPreviewRequest,
              request.questions.allSatisfy({ !(answers[$0.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            completion(.failure(QuestionReplyError.stale)); return
        }
        completion(.success(()))
        questionPreviewRequest = nil; questionPreviewRevealAt = nil
        currentText = request.approval ? "预览决定已提交。" : "预览已回复。"
        previewUntil = Date().addingTimeInterval(3)
        redraw()
    }

    func showPinkBearDemo() {
        showDemo()
        demoPinkBear = true
        currentText = "正在想一想，\n把思路慢慢理清楚。"
        redraw()
    }

    private func refreshHarnessBalance() {
        guard !harnessBalanceRefreshing else { return }
        harnessBalanceRefreshing = true
        harnessBalanceQueries += 1
        let started = ProcessInfo.processInfo.systemUptime
        redraw()
        let url = argument("--deepseek-credentials").map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: harnessPath).deletingLastPathComponent().appendingPathComponent(".credentials.yaml")
        HarnessBalanceQuery.fetchBalance(credentialsURL: url) { [weak self] text, normal in
            guard let self else { return }
            self.harnessBalanceRefreshing = false
            if text.hasPrefix("账户余额查询失败") || text.hasPrefix("账户余额不可用") {
                // A failed refresh is not a zero balance and must not clear a known alert.
                if self.harnessNormalBalance != nil {
                    if !self.harnessBalanceText.hasSuffix(" · 更新失败") { self.harnessBalanceText += " · 更新失败" }
                } else { self.harnessBalanceText = "账户余额 - · 查询失败或未登录" }
            } else {
                self.harnessNormalBalance = normal
                self.harnessBalanceText = text
            }
            self.harnessBalanceQuerySeconds = ProcessInfo.processInfo.systemUptime - started
            self.redraw()
        }
    }

    private func receive(_ snapshots: [SessionSnapshot], error: String?) {
        var responseSpeeds = codexAverageSpeeds
        let codexSessions = snapshots.filter { $0.source == .codex }.prefix(16)
        let ids = Set(codexSessions.map(\.id))
        responseSpeeds = responseSpeeds.filter { ids.contains($0.key) }
        for session in codexSessions {
            if let result = session.codexResponseSpeed { responseSpeeds[session.id] = result.tokensPerSecond }
        }
        if responseSpeeds != codexAverageSpeeds {
            codexAverageSpeeds = responseSpeeds
            preferences.set(responseSpeeds, forKey: "codexLastResponseSpeeds")
        }
        if let newest = snapshots.filter({ $0.source == .codex }).compactMap(\.codexQuota)
            .max(by: { $0.observedAt < $1.observedAt }),
           codexQuota == nil || newest.observedAt >= codexQuota!.observedAt { codexQuota = newest }
        let snapshots = snapshots.filter { tracks($0.source) }
        sessions = snapshots
        pruneQuestionNotifications()
        errorText = error
        harnessStateObserved = true
        if !deepSeekHarnessIdle && windowPeek.isRunning {
            windowPeekIdle.reset()
            windowPeek.stop(reason:"绑定的 Harness 已开始工作 · 恢复工作展示")
        }
        if pendingWindowPeekPreview {
            let previewSeat = pendingWindowSeatPreview
            pendingWindowPeekPreview = false
            pendingWindowSeatPreview = false
            showWindowPeek(previewSeat:previewSeat)
        }
        guard Date() >= previewUntil else { return }
        selected = SessionSelection.choose(snapshots, pinned: selection.isEmpty ? nil : selection)
        let groups = Dictionary(grouping: snapshots, by: captionGroup)
        states = states.filter { groups[$0.key] != nil }
        for (id, group) in groups {
            let pinned = !selection.isEmpty && selected.map(captionGroup) == id ? selection : nil
            guard let session = SessionSelection.choose(group, pinned: pinned) else { continue }
            let active = session.active && Date().timeIntervalSince(session.activity) < 3600
            let recent = session.displayCaption(showAnswers: showAnswers).map { Date().timeIntervalSince($0.date) < 90 } ?? false
            guard states[id] != nil || active || recent || group.contains(where: { !$0.pendingQuestions.isEmpty })
                || selected.map(captionGroup) == id else { continue }
            let state = states[id] ?? ProjectCaptionState(session: session)
            state.receive(session, answers: showAnswers, tools: showTools, font: fontSize)
            states[id] = state
        }
        let activeCount = states.values.filter(\.active).count
        currentLabel = activeCount > 1 && selection.isEmpty ? "同时显示 \(activeCount) 个项目／聊天" : selected?.label ?? "自动显示运行中的项目"
        status = companionEnabled && trackedHarnesses.isEmpty ? "仅显示独立角色 · 不跟踪 Harness"
            : selected == nil ? (trackedHarnesses.isEmpty ? "请选择要跟踪的 Harness" : error == nil ? "等待任务" : "连接需要处理")
            : activeCount > 1 && selection.isEmpty ? "\(activeCount) 个项目／聊天正在工作"
            : selected?.readable == false ? "会话暂时无法读取" : activeCount > 0 ? "正在跟随 · 任务运行中" : "已连接 · 等待下一轮"
        redraw()
    }

    private func tick() {
        overlays.finishReleasedCharacterDrags()
        updateBackdropAvoidance()
        if lastWindowPeekObservation == -Double.infinity,
           let raw=argument("--window-seat-start"),let character=overlays.character(for:deepSeekSource) {
            let values=raw.split(separator:",").compactMap {Double($0)}
            if values.count == 2 { character.panel.setFrameOrigin(NSPoint(x:values[0],y:values[1])) }
        }
        updateAutomaticWindowPeek()
        speechHighlight.expire(at: ProcessInfo.processInfo.systemUptime)
        if speechHighlightedKeyword != speechHighlight.keyword { speechHighlightedKeyword = speechHighlight.keyword }
        if speechHighlightedKeywords != speechHighlight.keywords { speechHighlightedKeywords = speechHighlight.keywords }
        if speechKeywordEnabled { refreshSpeechProgress() }
        if demoMode {
            if Date() >= previewUntil {
                if questionPreviewActive { stopPreview() }
                else { demoMode = false; receive(sessions, error: errorText) }
            } else if let revealAt = questionPreviewRevealAt, Date() >= revealAt {
                questionPreviewRevealAt = nil
                let id = "preview:" + UUID().uuidString
                questionPreviewRequest = UserQuestionRequest.parse(id: id, turnID: nil, asynchronous: true,
                    questions: [["title": "希望字幕怎样显示？", "options": ["保持一行字幕", "自动换行"]]], date: Date())
                if approvalPreview {
                    questionPreviewRequest = CodexApproval.parse(threadID: "preview", row: [
                        "id": id, "method": "item/permissions/requestApproval", "params": [
                            "threadId": "preview", "turnId": "preview", "startedAtMs": Date().timeIntervalSince1970 * 1000,
                            "cwd": "/示例项目", "reason": "下载示例项目需要联网（仅为本地演示）。",
                            "permissions": ["network": ["enabled": true]]]])?.question
                }
                taskSounds.playQuestion(title: "提问预览", requestID: id, preview: true)
                redraw()
            } else if diagnosticsURL != nil {
                redraw()
            }
            return
        }
        states.values.forEach { $0.tick() }
        redraw()
    }

    private func save(_ key: String, _ value: Any) { preferences.set(value, forKey: key) }

    private func pruneQuestionNotifications() {
        notifiedQuestions.formIntersection(Set(sessions.flatMap { session in
            session.pendingQuestions.map { session.id + ":" + $0.id }
        } + pendingApprovals.map(\.key)))
    }

    private func updateApprovalTracking() {
        guard !CommandLine.arguments.contains("--no-approval-stream") else { return }
        let relevant = enabled && !demoMode ? sessions.filter { session in
            session.source == .codex && (selection.isEmpty || session.path == selection)
            // Pending IPC requests do not append to the rollout. A bounded cold
            // log tail can also omit turn_started, so log activity must not gate
            // approval discovery. SessionMonitor already limits Codex to 16.
        }.map(\.id) : []
        approvalStream.watch(relevant)
    }

    private static func conversationOpener(threadID: String) -> (() -> String?)? {
        guard let url = UserQuestionRequest.conversationURL(threadID: threadID) else { return nil }
        return { NSWorkspace.shared.open(url) ? nil : "无法打开 Codex，请确认已安装桌面应用。" }
    }

    private static func conversationOpener(session: SessionSnapshot) -> (() -> String?)? {
        switch session.source {
        case .codex: return conversationOpener(threadID: session.id)
        case .deepseek:
            guard let url = URL(string: "dsh://open") else { return nil }
            return { NSWorkspace.shared.open(url) ? nil : "无法打开 DeepSeek Harness，请确认已安装桌面应用。" }
        case .claude:
            return { ClaudeConversationNavigator.shared.open(sessionID: session.id) }
        case .opencode:
            return { OpenCodeConversationNavigator.open(sessionID: session.id) }
        case .workbuddy:
            return { WorkBuddyConversationNavigator.open(sessionID: session.id) }
        case .doubao:
            return { DoubaoConversationNavigator.open(sessionID: session.id) }
        default: return nil
        }
    }

    private func redraw() {
        updateApprovalTracking()
        let focusedID = demoMode ? "demo" : selected.map(captionGroup) ?? "waiting"
        let focused = states[focusedID]
        let previewTitle = approvalPreview ? "审批预览" : "提问预览"
        let title = demoMode ? (questionPreviewActive ? previewTitle : "VibeCute") : selected?.headerName ?? ""
        let kind = demoMode ? (questionPreviewActive ? previewTitle : "样式预览") : focused?.kind ?? "等待更新"
        let active = focused?.active ?? false
        let header = demoMode ? "\(demoDeepSeek ? "DSH" : "Codex")  ·  \(kind)  ·  VibeCute"
            : focused?.header ?? "VibeCute  ·  等待更新"
        var items: [OverlayItem] = []
        if demoMode {
            items = [OverlayItem(id: "demo", text: currentText, header: header, title: title,
                                 active: !questionPreviewActive, mascot: demoDeepSeek ? .deepseek : .codex,
                                 typewriterID: typewriterEnabled && !questionPreviewActive ? "demo:\(demoTypewriterID)" : nil,
                                 typewriterCharactersPerSecond: typewriterCharactersPerSecond,
                                 question: questionPreviewRequest,
                                 onOpenConversation: questionPreviewActive ? { "这是预览；真实请求会打开对应的 Codex 对话。" } : nil,
                                 onQuestionClose: questionPreviewActive ? { [weak self] in self?.stopPreview() } : nil,
                                 onCaptionClose: questionPreviewActive ? nil : { [weak self] in self?.stopPreview() },
                                 onQuestionReply: questionPreviewActive ? { [weak self] answers, completion in
                                     guard let self else { completion(.failure(QuestionReplyError.stale)); return }
                                     self.finishQuestionPreview(answers, completion: completion)
                                 } : nil)]
            if demoMultiple {
                items.append(OverlayItem(id: "demo-data", text: "正在检查数据，\n整理今天的变化。", header: "Codex  ·  样式预览  ·  数据项目",
                                         title: "数据项目", active: true, mascot: .codex,
                                         typewriterID: typewriterEnabled ? "demo:\(demoTypewriterID):data" : nil,
                                         typewriterCharactersPerSecond: typewriterCharactersPerSecond,
                                         onCaptionClose: { [weak self] in self?.stopPreview() }))
                items.append(OverlayItem(id: "demo-deepseek", text: "正在梳理问题，\n把思路一步步展开。", header: "DSH  ·  样式预览  ·  研究项目",
                                         title: "研究项目", active: true, mascot: .deepseek,
                                         typewriterID: typewriterEnabled ? "demo:\(demoTypewriterID):deepseek" : nil,
                                         typewriterCharactersPerSecond: typewriterCharactersPerSecond,
                                         onCaptionClose: { [weak self] in self?.stopPreview() }))
            }
        } else {
            currentText = focused?.text ?? (errorText ?? "字幕已就绪，等待下一条思考或进度…")
            let candidates = sessions.filter { session in
                session.source == .codex && (selection.isEmpty || captionGroup(session) == focusedID)
                    && session.pendingQuestions.contains { !submittedQuestions.contains(session.id + ":" + $0.id)
                        && !closedQuestions.contains(session.id + ":" + $0.id) }
            }
            var pending: [(SessionSnapshot, UserQuestionRequest, CodexApproval?)] = candidates.flatMap { session in
                session.pendingQuestions.filter { !submittedQuestions.contains(session.id + ":" + $0.id)
                    && !closedQuestions.contains(session.id + ":" + $0.id) }
                    .map { (session, $0, nil) }
            }
            pending += pendingApprovals.compactMap { approval in
                guard !submittedQuestions.contains(approval.key),
                      !closedQuestions.contains(approval.key),
                      let session = sessions.first(where: { $0.source == .codex && $0.id == approval.threadID }),
                      selection.isEmpty || captionGroup(session) == focusedID else { return nil }
                return (session, approval.question, approval)
            }
            // One expanded question at a time prevents overlapping cards and
            // preserves an in-progress draft when another chat asks a question.
            let chosen = pending.first { $0.0.id + ":" + $0.1.id == displayedQuestion }
                ?? pending.max { $0.1.date < $1.1.date }
            displayedQuestion = chosen.map { $0.0.id + ":" + $0.1.id }
            // Keep the current reply draft mounted, but never let it hide a
            // permission request from another chat. Show one additional approval.
            let extraApproval = pending.filter {
                $0.2 != nil && $0.0.id + ":" + $0.1.id != displayedQuestion
            }.max { $0.1.date < $1.1.date }
            let displayedPending = (chosen.map { [$0] } ?? []) + (extraApproval.map { [$0] } ?? [])
            let questionSessions = displayedPending.map { $0.0 }
            let questionGroups = Set(questionSessions.map(captionGroup))
            items = states.compactMap { id, state in
                guard (selection.isEmpty || id == focusedID),
                      state.hasContent, !state.isDismissed,
                      !questionGroups.contains(id),
                      state.active || !autoHide || Date() < state.hideAt else { return nil }
                return OverlayItem(id: id, text: state.text, header: state.header, title: state.session.headerName,
                    active: state.active, mascot: CaptionMascot(rawValue: state.session.source.preferenceID),
                    typewriterID: typewriterEnabled ? state.typewriterID : nil,
                    typewriterCharactersPerSecond: typewriterCharactersPerSecond,
                    averageSpeed: state.session.source == .codex ? codexAverageSpeeds[state.session.id]
                        : state.session.source == .opencode ? state.session.openCodeResponseSpeed?.tokensPerSecond
                        : state.session.harnessResponseSpeed?.tokensPerSecond,
                    quotaText: state.session.source == .codex ? codexQuota?.displayText()
                        : state.session.source == .deepseek ? displayedHarnessBalance : nil,
                    metricsRefreshing: state.session.source == .deepseek && harnessBalanceRefreshing,
                    onMetricsHover: state.session.source == .deepseek ? { [weak self] in self?.refreshHarnessBalance() } : nil,
                    onOpenConversation: Self.conversationOpener(session: state.session),
                    onCaptionClose: { [weak self, weak state] in state?.dismissCaption(); self?.redraw() })
            }
            for (session, request, approval) in displayedPending {
                let key = session.id + ":" + request.id
                let shouldNotify: Bool
                if approval != nil {
                    shouldNotify = enabled && !notifiedApprovals.contains(key)
                    if shouldNotify {
                        notifiedApprovals.append(key)
                        if notifiedApprovals.count > 64 { notifiedApprovals.removeFirst() }
                    }
                } else { shouldNotify = enabled && notifiedQuestions.insert(key).inserted }
                if shouldNotify {
                    taskSounds.playQuestion(title: session.headerName, requestID: key)
                }
                items.append(OverlayItem(id: approval?.key ?? captionGroup(session), text: request.questions[0].title,
                    header: "Codex · " + (request.approval ? "等待审批 · " : "等待回复 · ") + session.headerName, title: session.headerName,
                    active: false, mascot: .codex, question: request,
                    averageSpeed: codexAverageSpeeds[session.id], quotaText: codexQuota?.displayText(),
                    onOpenConversation: Self.conversationOpener(threadID: session.id),
                    onQuestionClose: { [weak self] in
                        guard let self else { return }
                        self.closedQuestions.insert(key)
                        var recent = self.preferences.stringArray(forKey: "closedRequestBubbles") ?? []
                        recent.removeAll { $0 == key }; recent.append(key)
                        recent = Array(recent.suffix(128))
                        self.closedQuestions = Set(recent)
                        self.save("closedRequestBubbles", recent)
                        self.redraw()
                    },
                    onQuestionReply: { [weak self] answers, completion in
                        guard let self else { return }
                        let done: (Result<Void, Error>) -> Void = { [weak self] result in
                            completion(result)
                            if case .success = result, let self {
                                self.submittedQuestions.append(key)
                                if self.submittedQuestions.count > 64 { self.submittedQuestions.removeFirst() }
                                self.states[captionGroup(session)]?.didReplyToQuestion(approval: approval != nil)
                                self.redraw()
                            }
                        }
                        if let approval {
                            self.questionReplies.submitApproval(approval, choice: answers[request.questions[0].id] ?? "", completion: done)
                        } else { self.questionReplies.submit(threadID: session.id, request: request, answers: answers, completion: done) }
                    }))
            }
            if !trackedHarnesses.isEmpty && selected == nil, let errorText, !errorText.isEmpty, errorText != dismissedErrorText,
               !autoHide || Date() < waitingHideAt {
                items = [OverlayItem(id: "waiting", text: errorText, header: header, title: "",
                                     active: false, mascot: nil, onCaptionClose: { [weak self] in
                                         self?.dismissedErrorText = errorText; self?.redraw() })]
            }
        }
        let metricsSession = selected?.source == .deepseek ? selected : sessions.first { $0.source == .deepseek }
        let codexMetricsSession = selected?.source == .codex ? selected : sessions.first { $0.source == .codex }
        let openCodeMetricsSession = selected?.source == .opencode ? selected : sessions.first { $0.source == .opencode }
        var restingMascots = Set<CaptionMascot>()
        if enabled && !demoMode {
            if balanceAlertActive { restingMascots.insert(.deepseek) }
            if companionEnabled { restingMascots.insert(companionSource) }
            if !autoHide { restingMascots.formUnion(effectiveCharacterBindings.keys) }
            if autoWindowPeekEnabled && hasDeepSeekCharacter && deepSeekHarnessIdle
                && sessions.contains(where: { $0.source == deepSeekSessionSource })
                && (selection.isEmpty || selected?.source == deepSeekSessionSource) {
                restingMascots.insert(deepSeekSource)
            }
        }
        if onboardingActive { items = []; restingMascots.formUnion(effectiveCharacterBindings.keys) }
        overlays.update(enabled ? items : [], font: fontSize, opacity: opacity, bottom: bottom,
                        screenIndex: screenIndex, movable: movable, focusedID: focusedID,
                        characterScale: characterScale,
                        akimboUtterancePause: akimboUtterancePause,
                        bubblesFixedToCharacter: bubblesFixedToCharacter,
                        audioMascots: enabled && singingDemoStartedAt != nil ? [deepSeekSource]
                            : enabled && (mouthDemoStartedAt != nil || mouthTransitionDemoStartedAt != nil) ? (demoMode && demoCharacterOverride != nil ? [.deepseek] : [.codex, .deepseek])
                            : enabled && audioEnabled && audioRunning ? audioSources : [],
                        restingMascots: restingMascots,
                        characterBindings: effectiveCharacterBindings,
                        fallbackMetrics: [
                            .deepseek: OverlayHoverMetrics(averageSpeed: metricsSession?.harnessResponseSpeed?.tokensPerSecond,
                                quotaText: displayedHarnessBalance, refreshing: harnessBalanceRefreshing,
                                onHover: { [weak self] in self?.refreshHarnessBalance() }, persistent: balanceAlertActive),
                            .codex: OverlayHoverMetrics(averageSpeed: codexMetricsSession.flatMap { codexAverageSpeeds[$0.id] },
                                quotaText: codexQuota?.displayText()),
                            .opencode: OverlayHoverMetrics(averageSpeed: openCodeMetricsSession?.openCodeResponseSpeed?.tokensPerSecond,
                                quotaText: nil)],
                        cutoutHair: Dictionary(uniqueKeysWithValues: effectiveCharacterBindings.filter {
                            $0.value == .deepseekCutout
                        }.map { binding in
                            (binding.key, binding.key == .companion ? companionHairstyle
                                : cutoutHair(for: SessionSource.allCases.first { source in source.preferenceID == binding.key.rawValue }!))
                        }))
        let visible = overlays.visibleIDs.contains(focusedID)
        let overlay = overlays.controller(for: focusedID)
        onStatus?(enabled)
        onOnboardingLayout?()
        if let url = diagnosticsURL {
            let value: [String: Any] = ["visible": visible, "text": currentText, "kind": kind,
                "title": title,
                "header": header,
                "source": selected?.source.rawValue ?? "",
                "mascotVisible": overlays.character.subtitle.showsMascot,
                "mascotSource": overlays.character.subtitle.mascotSource,
                "mascotArtwork": overlays.character.subtitle.mascotArtwork,
                "pinkBearBinding": pinkBearBinding.rawValue,
                "doubaoReader": doubaoReader?.diagnostics ?? [:],
                "codexQuota": codexQuota?.displayText() ?? "",
                "codexAverageSpeeds": codexAverageSpeeds,
                "balanceAlertActive": balanceAlertActive, "balanceAlertThreshold": balanceAlertThreshold,
                "harnessNormalBalance": harnessNormalBalance.map { NSDecimalNumber(decimal: $0).stringValue } ?? "",
                "harnessBalance": displayedHarnessBalance, "harnessBalanceRefreshing": harnessBalanceRefreshing,
                "harnessBalanceQueries": harnessBalanceQueries, "harnessBalanceQuerySeconds": harnessBalanceQuerySeconds,
                "trackedHarnesses": trackedHarnesses.sorted(), "characterBindings": characterBindings,
                "companionEnabled": companionEnabled, "companionCharacter": companionCharacter.rawValue,
                "sessionMonitorRunning": monitor != nil, "showAnswers": showAnswers,
                "audioCharacterSources": audioSources.map(\.rawValue).sorted(),
                "taskSoundOutcomes": taskSoundOutcomes.sorted(),
                "bubblesFixedToCharacter": bubblesFixedToCharacter,
                "mascotAnimating": overlays.character.subtitle.mascotAnimating,
                "mascotFrameCount": overlays.character.subtitle.mascotFrameCount,
                "mascotFrameIndex": overlays.character.subtitle.mascotFrameIndex,
                "characterFrame": ["x": overlays.character.panel.frame.minX, "y": overlays.character.panel.frame.minY,
                    "width": overlays.character.panel.frame.width, "height": overlays.character.panel.frame.height],
                "processID":ProcessInfo.processInfo.processIdentifier, "bundlePath":Bundle.main.bundlePath,
                "visibleWindowTitles": NSApp.windows.filter(\.isVisible).map(\.title),
                "overlays": overlays.diagnostics, "overlayCount": overlays.visibleIDs.count,
                "characters": overlays.characterDiagnostics, "characterCount": overlays.characterDiagnostics.count,
                "characterScale": characterScale,
                "session": selected?.path ?? "", "active": active, "sessionCount": sessions.count,
                "taskOutcome": selected?.outcome?.rawValue ?? "",
                "taskSoundsEnabled": taskSoundsEnabled, "taskSoundVolume": taskSoundVolume,
                "questionSoundsEnabled": questionSoundsEnabled,
                "questionPreviewActive": questionPreviewActive,
                "questionPreviewExpanded": questionPreviewRequest != nil,
                "taskSounds": taskSounds.diagnostics,
                "pendingQuestionCount": sessions.reduce(0) { $0 + $1.pendingQuestions.count },
                "pendingApprovalCount": pendingApprovals.count,
                "audioRunning": audioRunning, "audioStatus": audioStatus,
                "audioRecognitionActive": audioRecognitionActive,
                "audioLevel": audioLevel, "audioVoiceLike": audioVoiceLike,
                "audioMouthTarget": lastLipFrame.shape.rawValue, "audioConfidence": lastLipFrame.confidence,
                "audioTime": lastLipFrame.audioTime,
                "audioCaptureUptime": lastLipFrame.capturedAt.map { $0 as Any } ?? NSNull(),
                "audioAnalysisUptime": lastLipFrame.analyzedAt.map { $0 as Any } ?? NSNull(),
                "audioDeliveryUptime": lipDeliveredAt.map { $0 as Any } ?? NSNull(),
                "audioCaptureTimeEstimated": lastLipFrame.captureTimeEstimated,
                "audioInput": lastLipFrame.separatedVocal ? "vocal" : "mix",
                "vocalSeparationEnabled": vocalSeparationEnabled,
                "vocalSeparationStatus": vocalSeparationStatus,
                "vocalProcessedBatches": audio.vocalStatus().processed,
                "vocalDroppedPackets": audio.vocalStatus().dropped,
                "audioDisplayedMouth": posePlayer.displayed.rawValue,
                "audioTransitionTarget": posePlayer.transitionTarget.map { $0.rawValue as Any } ?? NSNull(),
                "audioCandidateTarget": posePlayer.candidateTarget.map { $0.rawValue as Any } ?? NSNull(),
                "audioTransitionsStarted": posePlayer.transitionsStarted,
                "audioStaleTargetsDiscarded": posePlayer.staleTargetsDiscarded,
                "mouthTransitionDemo": mouthTransitionDemoStartedAt != nil,
                "singingPhase": singingPlayer.phase.rawValue,
                "kiraActive": kiraStartedAt != nil,
                "speechEnabled": speechKeywordEnabled, "speechRunning": speechRunning,
                "speechEngine": speechEngine.rawValue,
                "speechWindowSeconds": speechEngine == .whisper ? WhisperKeywordSpeech.windowSeconds as Any : NSNull(),
                "speechDemo": speechDemo,
                "speechStatus": speechStatus, "speechKeywordCount": speechKeywordCount,
                "speechHighlightedKeyword": speechHighlightedKeyword?.rawValue as Any? ?? NSNull(),
                "speechHighlightedKeywords": JapaneseKiraKeyword.allCases.filter { speechHighlightedKeywords.contains($0) }.map(\.rawValue),
                "speechCueKeyword": speechCountdownKeyword.rawValue,
                "speechPrimaryDelay": speechKiraDelay, "speechBackupExtraDelay": speechBackupExtraDelay,
                "speechCountdownLabel": speechCountdownLabel,
                "speechLatency": (speechUsesArrivalTime ? nil : speechCountdown.lastLatency).map { $0 as Any } ?? NSNull(),
                "speechUsesArrivalTime": speechUsesArrivalTime,
                "speechKeywordTimingLabel": speechKeywordTimingLabel,
                "speechRequestNumber": speechProgress.requestNumber,
                "speechRequestReason": speechProgress.requestReason,
                "speechResultCount": speechProgress.resultCount,
                "speechTextChangeCount": speechProgress.textChangeCount,
                "speechResultRequestNumber": speechProgress.resultRequestNumber,
                "speechResultFinal": speechProgress.isFinal,
                "speechInputEndUptime": speechProgress.inputEnd.map { $0 as Any } ?? NSNull(),
                "speechResultUptime": speechProgress.resultReceivedAt.map { $0 as Any } ?? NSNull(),
                "speechTextChangeUptime": speechProgress.textChangedAt.map { $0 as Any } ?? NSNull(),
                "speechWordEndUptime": speechProgress.wordEnd.map { $0 as Any } ?? NSNull(),
                "speechWordToResultDelay": speechProgress.wordToResultDelay.map { $0 as Any } ?? NSNull(),
                "songCandidate": currentTrack?.candidate ?? false,
                "nowPlayingTitle": currentTrack?.title ?? "",
                "songRecognitionLabel": songRecognitionLabel,
                "singingDemoElapsed": singingDemoStartedAt.map { (ProcessInfo.processInfo.systemUptime - $0) as Any } ?? NSNull(),
                "backdropAvoidance": backdropAvoidanceDiagnostics,
                "developerPreviewCharacter": developerPreviewCharacter.rawValue,
                "developerPreviewStatus": developerPreviewStatus,
                "automaticSleep": automaticSleep, "automaticSleepCount": automaticSleepCount,
                "sleepWaking": sleepWakeAt != nil,
                "scootDemoElapsed": scootDemoStartedAt.map { (ProcessInfo.processInfo.systemUptime - $0) as Any } ?? NSNull(),
                "scootActionLabel": scootActionLabel,
                "strollDemoElapsed": strollDemoStartedAt.map { (ProcessInfo.processInfo.systemUptime - $0) as Any } ?? NSNull(),
                "strollActionLabel": strollActionLabel,
                "frontRetreatDemoElapsed": frontRetreatDemoStartedAt.map { (ProcessInfo.processInfo.systemUptime-$0) as Any } ?? NSNull(),
                "frontRetreatActionLabel": frontRetreatActionLabel,
                "openCodeNavigationInstaller": openCodeNavigationStatus,
                "windowPeek": windowPeek.diagnostics,
                "windowPeekAutomatic":automaticWindowPeek,
                "windowPeekAutomaticCount":automaticWindowPeekCount,
                "windowPeekIdle":windowPeekIdle.diagnostics,
                "windowPeekHarnessIdle":deepSeekHarnessIdle,
                "autoWindowPeekEnabled":autoWindowPeekEnabled,
                "autoWindowPeekLabel":autoWindowPeekLabel,
                "singingCycleDuration": singingPlayer.cycleDuration,
                "singingCycleProgress": singingPlayer.cycleProgress,
                "singingPhaseAlignmentCount": singingPlayer.phaseAlignmentCount,
                "singingAccentPhaseErrorMs": singingPlayer.accentPhaseErrorSeconds.map { $0 * 1000 as Any } ?? NSNull(),
                "audioTempoEngine": audioTempoEngine.rawValue,
                "beatnetRuntime": BeatNetRuntime.availability,
                "tempoDroppedBatches": lastLipFrame.beat.droppedBatches,
                "tempoProcessingMs": lastLipFrame.beat.processingMs,
                "audioBeatEngine": lastLipFrame.beat.engine.rawValue,
                "audioReferenceBPM": lastLipFrame.beat.referenceBPM.map { $0 as Any } ?? NSNull(),
                "audioTempoMultiplier": lastLipFrame.beat.tempoMultiplier,
                "tempoEvidenceLabel": tempoEvidenceLabel,
                "audioRawBPM": lastLipFrame.beat.rawBPM.map { $0 as Any } ?? NSNull(),
                "audioBPM": lastLipFrame.beat.bpm.map { $0 as Any } ?? NSNull(),
                "audioBeatConfidence": lastLipFrame.beat.confidence,
                "animationTrackedBPM": singingPlayer.trackedBPM.map { $0 as Any } ?? NSNull(),
                "musicTempoLabel": musicTempoLabel, "animationPlaybackLabel": animationPlaybackLabel,
                "audioScene": lastLipFrame.scene.kind.rawValue, "audioVoicePriority": audioVoicePriority,
                "audioSceneTime": lastLipFrame.scene.audioTime,
                "audioSpeechScore": lastLipFrame.scene.speech, "audioSingingScore": lastLipFrame.scene.singing,
                "audioMusicScore": lastLipFrame.scene.music, "audioInstruments": lastLipFrame.scene.instruments,
                "audioGateOpen": lastLipFrame.voiceGateOpen,
                "mouthDemoIndex": mouthDemoIndex.map { $0 as Any } ?? NSNull(),
                "audioF1": lastLipFrame.firstFormant.map { $0 as Any } ?? NSNull(),
                "audioF2": lastLipFrame.secondFormant.map { $0 as Any } ?? NSNull(),
                "runningSubagentCount": selected?.runningSubagentCount ?? 0,
                "ignoresMouseEvents": overlay?.panel.ignoresMouseEvents ?? true, "status": status]
            if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
               let string = String(data: data, encoding: .utf8), string != lastDiagnostics {
                lastDiagnostics = string
                if let handle = try? FileHandle(forWritingTo: url) {
                    defer { try? handle.close() }; _ = try? handle.seekToEnd()
                    try? handle.write(contentsOf: data + Data([10]))
                } else { try? (data + Data([10])).write(to: url) }
            }
        }
    }

    private func configureAudio() {
        configureNowPlaying()
        configureSpeech()
        audio.setSensitivity(audioSensitivity)
        audio.setVoicePriority(audioVoicePriority)
        configureLipMatching()
        configureVocalSeparation()
        audio.setTempoEngine(audioTempoEngine)
        audio.setEnabled(audioEnabled && enabled)
        if !audioEnabled || !enabled {
            audioRunning = false; audioLevel = 0; audioVoiceLike = false
            posePlayer = MouthPosePlayer(); lastLipFrame = .silence; audioMouthLabel = "自然停顿"
            audioSceneLabel = "正在判断声音类型"; audioInstruments = ""
            musicTempoLabel = audioEnabled ? "等待系统声音" : "未启用"
            tempoEvidenceLabel = ""
            resetSinging()
            overlays.setAudioMouth(nil, targets: [])
        } else if !audioRunning {
            musicTempoLabel = "等待系统声音"
        }
    }

    private func configureLipMatching() {
        let profile = audioLipEngine == .mfcc ? lipVowelProfile : nil
        audio.setVowelProfile(profile)
        lipMatchingStatus = audioLipEngine == .acoustic ? "根据频谱与共振峰估计嘴型"
            : profile == nil ? "校准数据不可用，使用声学规则" : "高置信匹配辅助元音选择"
    }

    private func configureVocalSeparation() {
        audio.setVocalSeparation(BuildProfile.experiments && vocalSeparationEnabled && !SpeechEngine.minimalRelease, directory: BuildProfile.experiments ? vocalRuntime : nil)
        vocalSeparationStatus = vocalSeparationEnabled ? "正在准备人声分离…" : "使用原始声音"
    }

    private func refreshMusicTempoLabel(beat: BeatEstimate, preview: Bool) {
        let label: String
        if beat.reliable, let bpm = beat.bpm {
            label = "\(preview ? "预览 · " : "")\(Int(bpm.rounded())) BPM"
        } else if singingPlayer.phase == .singing, let bpm = singingPlayer.trackedBPM {
            label = "\(preview ? "预览 · " : "")最近 \(Int(bpm.rounded())) BPM · 重新识别中"
        } else if preview {
            label = "预览中 · 等待节拍"
        } else if audioRunning {
            label = "等待稳定节拍"
        } else {
            label = audioEnabled ? "等待系统声音" : "未启用"
        }
        if musicTempoLabel != label { musicTempoLabel = label }
        let evidence: String
        if !preview && (beat.engine == .aubio || beat.engine == .btrack || beat.engine == .beatnet), let raw = beat.rawBPM {
            evidence = "\(beat.engine == .beatnet ? "BeatNet+" : (beat.engine == .btrack ? "BTrack" : "aubio")) 原始 \(Int(raw.rounded())) BPM" +
                (beat.referenceBPM.map { " · 起音 \(Int($0.rounded())) BPM" } ?? "") +
                (beat.tempoMultiplier != 1 ? String(format: " · ×%.2g 校正", beat.tempoMultiplier) : "")
        } else { evidence = "" }
        if tempoEvidenceLabel != evidence { tempoEvidenceLabel = evidence }
    }

    private func refreshAnimationPlaybackLabel() {
        let label: String
        if !singingActionEnabled {
            label = "歌唱动作已关闭"
        } else if singingSources.isEmpty {
            label = "响应角色未包含支持唱歌的角色"
        } else {
            switch singingPlayer.phase {
            case .seated:
                label = "未播放 · 坐姿待机"
            case .rising:
                label = "起身过渡中"
            case .sitting:
                label = "坐下过渡中"
            case .singing:
                let duration = backdropRelocation.running && backdropRelocation.plan?.movement == .singingStep
                    ? BackdropRelocation.singingStepCycle : singingPlayer.cycleDuration
                label = String(format: "%.1f 秒/轮 · %.1f 轮/分", duration, 60 / duration)
            }
        }
        if animationPlaybackLabel != label { animationPlaybackLabel = label }
    }

    private func updateMouth() {
        let now = ProcessInfo.processInfo.systemUptime
        overlays.updateDragReactions(at: now)
        // Model lifecycle status must keep updating while character actions
        // temporarily take over mouth rendering.
        if vocalSeparationEnabled {
            let status = audio.vocalStatus().message
            if vocalSeparationStatus != status { vocalSeparationStatus = status }
        }
        if let start = mouthTransitionDemoStartedAt {
            let elapsed = now - start
            if enabled, elapsed < MouthTransitionDemo.duration {
                let frame = MouthTransitionDemo.frame(elapsed: elapsed, startedAt: start)
                lastLipFrame = frame
                let pose = posePlayer.sample(frame, at: now)
                overlays.setAudioMouth(pose.rawValue, targets: [.codex, .deepseek])
                lipDeliveredAt = ProcessInfo.processInfo.systemUptime
                recordLipTimeline(frame, at: lipDeliveredAt!)
                return
            }
            mouthTransitionDemoStartedAt = nil; posePlayer = MouthPosePlayer()
            overlays.setAudioMouth(nil, targets: []); redraw()
        }
        if windowPeek.isRunning {
            if !enabled { stopWindowPeek() }
            // An articulated return still needs ticks after the app is disabled.
            windowPeek.tick(at:now)
            if windowPeekLabel != windowPeek.status { windowPeekLabel = windowPeek.status }
            if windowPeek.isRunning { return }
        }
        if backdropRelocation.running {
            let source = activeBackdropSource ?? deepSeekSource
            let supported = effectiveCharacterBindings[source] == .deepseek || effectiveCharacterBindings[source] == .orangeHoodie
            if !enabled || (!autoAvoidanceEnabled && !singingStepDemo && !hoodieAvoidanceDemo) ||
                (!supported && !singingStepDemo) ||
                (activeBackdropArtwork != nil && overlays.character(for:source)?.subtitle.mascotArtwork != activeBackdropArtwork) ||
                overlays.backdropRelocationInterrupted(for:source) {
                stopBackdropRelocation(cooldown:30)
                avoidanceStatus = "手动调整或功能关闭 · 自动避让已暂停"
            } else if let sample = backdropRelocation.sample(at:now) {
                if sample.performanceFrame == nil {
                    overlays.setAudioMouth(nil,targets:[])
                    overlays.setDeepSeekPerformance(nil)
                }
                overlays.applyBackdropRelocation(sample,for:source)
                if avoidanceStatus != sample.phase { avoidanceStatus = sample.phase }
                if sample.performanceFrame == nil { return }
            } else {
                if hoodieAvoidanceDemo, !hoodiePreviewReturning, let anchor = hoodiePreviewAnchor,
                   let character = overlays.character(for:source) {
                    hoodiePreviewReturning = true
                    let plan = BackdropAvoidancePlan(from:character.panel.frame.origin,to:anchor,movement:.scoot,destinationBody:.zero)
                    lastBackdropPlan = plan; backdropRelocation.start(plan,scale:CGFloat(characterScale),at:now)
                    avoidanceStatus = "短程动作预览 · 返回原位"
                    return
                }
                let singing = backdropRelocation.plan?.movement == .singingStep
                stopBackdropRelocation(cooldown:3)
                avoidanceStatus = !backdropLastSafe ? "目标背景变化 · 已停止移动并重新检查"
                    : singing ? "已到空白区域 · 继续站着唱歌" : "已坐到空白区域 · 继续检查背景"
                lastBackdropScan = -Double.infinity
                redraw()
            }
        }
        if let start = sleepDemoStartedAt {
            let sample: DeepSeekSleepTimeline.Sample?
            if automaticSleep {
                if !deepSeekHarnessIdle || !autoWindowPeekEnabled { wakeAutomaticSleep(at: now) }
                if let wake = sleepWakeAt {
                    if let frame = sleepWakeEntryFrame {
                        let next = frame-Int((now-wake)/0.16)
                        sample = next >= 0 ? .init(phase: "醒来坐好", waking: false, frame: next, sleepTick: nil) : nil
                    } else { sample = DeepSeekSleepTimeline.sample(at: 7.04+now-wake) }
                } else {
                    let elapsed = now-start
                    sample = DeepSeekSleepTimeline.sample(at: elapsed < 3.2 ? elapsed : 3.2+(elapsed-3.2).truncatingRemainder(dividingBy:3.84))
                }
            } else { sample = DeepSeekSleepTimeline.sample(at: now-start) }
            if enabled, let sample {
                overlays.setAudioMouth(nil, targets: [])
                overlays.setDeepSeekPerformance(nil)
                overlays.setDeepSeekSleep(sample)
                return
            }
            stopSleepDemo(); redraw()
        }
        if let start = frontRetreatDemoStartedAt {
            if enabled, let sample = FrontRetreatTimeline.sample(at:now-start) {
                overlays.setAudioMouth(nil,targets:[])
                overlays.setDeepSeekPerformance(nil)
                overlays.setDeepSeekFrontRetreat(sample)
                let phase = overlays.deepSeekFrontRetreatPhase
                if frontRetreatActionLabel != phase { frontRetreatActionLabel = phase }
                return
            }
            stopFrontRetreatDemo(); redraw()
        }
        if let start = scootDemoStartedAt {
            if enabled, let sample = SeatedScootTimeline.sample(at: now-start) {
                overlays.setAudioMouth(nil, targets: [])
                overlays.setDeepSeekPerformance(nil)
                overlays.setDeepSeekScoot(sample)
                let phase = overlays.deepSeekScootPhase ?? sample.phase
                if scootActionLabel != phase { scootActionLabel = phase }
                return
            }
            stopScootDemo(); redraw()
        }
        if let start = strollDemoStartedAt {
            if enabled, let sample = StrollTimeline.sample(at: now-start) {
                overlays.setAudioMouth(nil, targets: [])
                overlays.setDeepSeekPerformance(nil)
                overlays.setDeepSeekStroll(sample)
                if strollActionLabel != sample.phase.rawValue { strollActionLabel = sample.phase.rawValue }
                return
            }
            stopStrollDemo(); redraw()
        }
        if let start = singingDemoStartedAt {
            let elapsed = now - start
            let duration: Double = CommandLine.arguments.contains("--singing-avoidance-demo") ? 60 : 10
            if elapsed < duration, enabled {
                let silenceAt = argument("--singing-step-silence-at").flatMap(Double.init) ?? 8
                let singing = elapsed < min(4,silenceAt)
                let music = elapsed < silenceAt
                let scene = SoundScene(kind: singing ? .singing : music ? .music : .silence,
                                       singing: singing ? 0.85 : 0, music: music ? 0.8 : 0,
                                       audioTime: floor(elapsed * 2) / 2)
                let demoBPM = argument("--singing-demo-bpm").flatMap(Double.init)
                let bpm = demoBPM.flatMap { $0.isFinite && (60...360).contains($0) ? $0 : nil }
                    ?? (elapsed < 5 ? 75.0 : 120.0)
                let reacquiring = (6..<6.7).contains(elapsed)
                let beat = music && elapsed > 2 && !reacquiring ? BeatEstimate(bpm: bpm, confidence: 0.9, audioTime: elapsed,
                    lastBeatTime: floor(elapsed / (60 / bpm)) * (60 / bpm),
                    lastAccentTime: floor(elapsed / (60 / bpm)) * (60 / bpm)) : .unknown
                updateSinging(scene: scene, level: music ? 0.35 : 0, now: now, allowed: true, beat: beat)
                let poses: [MouthShape] = [.ah, .eh, .ee, .oh, .oo]
                let mouth = singing && elapsed > 0.5 ? poses[Int(elapsed / 0.28) % poses.count] : .rest
                overlays.setAudioMouth(music ? mouth.rawValue : nil, targets: [deepSeekSource])
                if singingStepDemo, !singingStepDemoMoved, elapsed >= 2.5, singingPlayer.phase == .singing,
                   let character = overlays.character(for:deepSeekSource) {
                    let origin = character.panel.frame.origin, allowed = overlays.deepSeekAllowedOrigins
                    let left = argument("--singing-step-direction") == "left"
                    let dx = 120*CGFloat(characterScale)
                    let x = min(allowed.maxX,max(allowed.minX,origin.x+(left ? -dx : dx)))
                    let plan = BackdropAvoidancePlan(from:origin,to:CGPoint(x:x,y:origin.y),movement:.singingStep,destinationBody:.zero)
                    singingStepDemoMoved = true; lastBackdropPlan = plan
                    backdropMoves += 1
                    activeBackdropSource = deepSeekSource
                    overlays.beginDeepSeekRelocation()
                    backdropRelocation.start(plan,scale:CGFloat(characterScale),at:now)
                }
                return
            }
            singingDemoStartedAt = nil; singingStepDemo = false; speechDemo = false; resetSinging()
            refreshMusicTempoLabel(beat: lastLipFrame.beat, preview: false)
            overlays.setAudioMouth(nil, targets: []); redraw()
        }
        if let preview = argument("--mouth-preview").flatMap(Int.init), (0..<MascotAnimation.mouthCount).contains(preview) {
            overlays.setAudioMouth(preview, targets: [.codex, .deepseek]); return
        }
        if let start = mouthDemoStartedAt {
            let frame = audioRunning ? audio.snapshot() : .silence
            if audioRunning { lastLipFrame = frame }
            refreshMusicTempoLabel(beat: frame.beat, preview: false)
            let index = Int((ProcessInfo.processInfo.systemUptime - start) / 0.45)
            if let pose = MouthShape(rawValue: index), enabled {
                mouthDemoIndex = index
                let label = "素材预览 · \(pose.title)"
                if audioMouthLabel != label { audioMouthLabel = label }
                overlays.setAudioMouth(index, targets: [.codex, .deepseek])
                return
            }
            mouthDemoStartedAt = nil; mouthDemoIndex = nil
            overlays.setAudioMouth(nil, targets: [])
            audioMouthLabel = "自然停顿"; posePlayer = MouthPosePlayer()
            redraw()
        }
        guard enabled, audioEnabled, audioRunning else { return }
        let frame = audio.snapshot()
        lastLipFrame = frame
        if abs(audioLevel - Double(frame.level)) > 0.02 { audioLevel = Double(frame.level) }
        if audioVoiceLike != frame.voiceLike { audioVoiceLike = frame.voiceLike }
        if audioSceneLabel != frame.scene.kind.title { audioSceneLabel = frame.scene.kind.title }
        let instruments = frame.scene.instruments.joined(separator: "、")
        if audioInstruments != instruments { audioInstruments = instruments }
        let pose = posePlayer.sample(frame, at: ProcessInfo.processInfo.systemUptime)
        let mouthLabel = posePlayer.laughterPriorityActive ? "笑声优先 · \(pose.title)" : pose.title
        if audioMouthLabel != mouthLabel { audioMouthLabel = mouthLabel }
        let silent = (frame.scene.kind == .silence || frame.capturedAt == nil) && frame.level.isFinite && frame.level < 0.01
        if silent && pose == .rest && !posePlayer.isTransitioning {
            // Release the first-frame mouth overlay so the thinking atlas can
            // blink and move. A new sound starts a fresh mouth transition.
            overlays.setAudioMouth(nil, targets: [])
        } else {
            overlays.setAudioMouth(pose.rawValue, targets: audioTarget.mascots)
        }
        let deliveredAt = ProcessInfo.processInfo.systemUptime
        lipDeliveredAt = deliveredAt
        recordLipTimeline(frame, at: deliveredAt)
        updateSinging(scene: frame.scene, level: frame.level, now: now,
                      allowed: singingActionEnabled && !singingSources.isEmpty,
                      beat: frame.beat.engine == audioTempoEngine ? frame.beat : BeatEstimate(engine: audioTempoEngine),
                      beatDeliveryAge: frame.capturedAt.map { max(0, now - $0) } ?? 0)
    }

    /// Opt-in pose/timing evidence only; contains no PCM, transcript or sessions.
    /// Delivery is the UI update call, not a measurement of compositor scanout.
    private func recordLipTimeline(_ frame: LiveLipFrame, at now: TimeInterval) {
        guard let handle = lipTimeline else { return }
        let key = "\(frame.capturedAt ?? 0):\(frame.shape.rawValue):\(posePlayer.displayed.rawValue)"
        guard key != lastLipTimelineKey else { return }
        lastLipTimelineKey = key
        let record: [String: Any] = ["audioTime": frame.audioTime,
            "capturedAt": frame.capturedAt.map { $0 as Any } ?? NSNull(),
            "analyzedAt": frame.analyzedAt.map { $0 as Any } ?? NSNull(), "deliveredAt": now,
            "sampleToDeliveryMs": frame.capturedAt.map { (now - $0) * 1000 as Any } ?? NSNull(),
            "captureTimeEstimated": frame.captureTimeEstimated,
            "target": frame.shape.rawValue, "displayed": posePlayer.displayed.rawValue,
            "transitionTarget": posePlayer.transitionTarget.map { $0.rawValue as Any } ?? NSNull(),
            "candidateTarget": posePlayer.candidateTarget.map { $0.rawValue as Any } ?? NSNull(),
            "transitionsStarted": posePlayer.transitionsStarted,
            "staleTargetsDiscarded": posePlayer.staleTargetsDiscarded,
            "displayedSourceCapturedAt": posePlayer.displayedSourceCapturedAt.map { $0 as Any } ?? NSNull(),
            "displayedSourceAgeMs": posePlayer.displayedSourceCapturedAt.map { (now - $0) * 1000 as Any } ?? NSNull(),
            "confidence": frame.confidence, "level": frame.level, "voiceLike": frame.voiceLike,
            "lipEngine": audioLipEngine.rawValue,
            "audioInput": frame.separatedVocal ? "vocal" : "mix",
            "beatAudioTime": frame.beat.audioTime,
            "beatBPM": frame.beat.bpm.map { $0 as Any } ?? NSNull(),
            "usedMFCC": frame.usedMFCC,
            "mfccConfidence": frame.mfccConfidence.map { $0 as Any } ?? NSNull(),
            "scene": frame.scene.kind.rawValue,
            "laughterScore": frame.scene.laughter,
            "laughterPriority": frame.laughterPriority,
            "laughterScheduled": posePlayer.laughterPriorityActive,
            "f1": frame.firstFormant.map { $0 as Any } ?? NSNull(),
            "f2": frame.secondFormant.map { $0 as Any } ?? NSNull()]
        if let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) {
            try? handle.write(contentsOf: data + Data([10]))
        }
    }

    func openAudioPermissions() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}

func argument(_ flag: String) -> String? {
    guard let index = CommandLine.arguments.firstIndex(of: flag), index + 1 < CommandLine.arguments.count else { return nil }
    return CommandLine.arguments[index + 1]
}
