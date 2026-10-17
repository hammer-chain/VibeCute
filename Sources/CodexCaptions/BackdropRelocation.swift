import AppKit

struct BackdropRelocationSample {
    let origin: CGPoint
    let scoot: SeatedScootTimeline.Sample?
    let stroll: StrollTimeline.Sample?
    let mirrored: Bool
    let phase: String
    var performanceFrame: Int? = nil
    var frontRetreat: FrontRetreatTimeline.Sample? = nil
}

final class BackdropRelocation {
    private(set) var plan: BackdropAvoidancePlan?
    private(set) var startedAt = 0.0
    private(set) var running = false
    private var scale: CGFloat = 1
    private var steps = 1
    private var travelDuration = 1.0
    private var settleOrigin: CGPoint?
    private var settleStartedAt = 0.0
    private var settleScootPhase = 0.0
    static let riseDuration = StrollTimeline.steps.prefix { $0.phase != .walking }.reduce(0) { $0+$1.duration }
    static let sittingFrames = [11,10,9,8,7,6,5,4,3,2,1,0]
    static let sittingDuration = 1.8
    static let singingStepCycle = 0.8
    var duration: Double {
        guard let plan else { return 0 }
        if plan.movement == .singingStep { return Double(steps)*Self.singingStepCycle }
        if plan.movement == .frontRetreat { return FrontRetreatTimeline.relocationDuration(distance:plan.distance,scale:scale) }
        return plan.movement == .scoot ? 0.8+Double(steps)*SeatedScootTimeline.cycle
            : Self.riseDuration+travelDuration+Self.sittingDuration
    }
    func start(_ plan: BackdropAvoidancePlan, scale: CGFloat, at now: Double) {
        self.plan = plan; self.scale = scale; startedAt = now; running = true; settleOrigin = nil
        steps = max(1,Int(ceil(plan.distance/((plan.movement == .singingStep ? 40 : 32)*scale))))
        travelDuration = max(0.8,plan.distance/(165*scale))
    }
    func stop() { running = false; plan = nil; settleOrigin = nil }
    func settle(at origin: CGPoint, now: Double) {
        guard running, settleOrigin == nil else { return }
        settleScootPhase = sample(at:now)?.scoot?.pushPhase ?? 0
        settleOrigin = origin; settleStartedAt = now
    }
    func sample(at now: Double) -> BackdropRelocationSample? {
        guard running, let plan else { return nil }
        let elapsed = now-startedAt
        guard elapsed >= 0 else { return nil }
        let mirrored = plan.to.x < plan.from.x
        if let settleOrigin {
            if plan.movement == .singingStep { return nil }
            let t = now-settleStartedAt
            if plan.movement == .scoot {
                guard t < 0.4 else { return nil }
                let p = min(1,max(0,t/0.4)), eased = p*p*(3-2*p)
                return BackdropRelocationSample(origin:settleOrigin,
                    scoot:.init(frame:7,offset:0,phase:"坐稳",pushPhase:settleScootPhase+(1-settleScootPhase)*eased),stroll:nil,mirrored:false,phase:"背景变化 · 坐稳重新检查")
            }
            if plan.movement == .frontRetreat {
                guard now < settleStartedAt+FrontRetreatTimeline.sittingDuration+0.35 else { return nil }
                return BackdropRelocationSample(origin:settleOrigin,scoot:nil,stroll:nil,mirrored:false,
                    phase:"背景变化 · 正面坐下重新检查",frontRetreat:FrontRetreatTimeline.relocationSitting(at:t))
            }
            guard t < Self.sittingDuration else { return nil }
            return sitting(origin:settleOrigin,elapsed:t,mirrored:mirrored,phase:"背景变化 · 坐下重新检查")
        }
        guard now < startedAt+duration else { return nil }
        if plan.movement == .frontRetreat {
            guard let pose = FrontRetreatTimeline.relocationSample(at:elapsed,distance:plan.distance,scale:scale,leftward:mirrored) else { return nil }
            return BackdropRelocationSample(origin:mix(plan.from,plan.to,pose.offset),scoot:nil,stroll:nil,mirrored:false,
                phase:"中距空白 · "+pose.phase.rawValue,frontRetreat:pose)
        }
        if plan.movement == .singingStep {
            let cycle = elapsed/Self.singingStepCycle
            let index = Int(cycle), p = cycle-Double(index)
            // Two short foot pushes per cycle, with planted-foot holds.
            func push(_ t: Double) -> Double {
                let t = min(1,max(0,t)); return t*t*(3-2*t)
            }
            let advance = 0.5*push((p-0.125)/0.25)+0.5*push((p-0.625)/0.25)
            return BackdropRelocationSample(origin:mix(plan.from,plan.to,(Double(index)+advance)/Double(steps)),
                scoot:nil,stroll:nil,mirrored:mirrored,phase:"站着唱歌 · 小步避让背景",
                performanceFrame:DeepSeekPerformance.singingStepStart+min(7,Int(p*8)))
        }
        if plan.movement == .scoot {
            let t = elapsed-0.4
            let cycle = SeatedScootTimeline.cycle
            let progress: Double, frame: Int, pushPhase: Double
            if t < 0 { progress = 0; frame = 0; pushPhase = 0 }
            else if t >= Double(steps)*cycle {
                progress = 1; frame = 7; pushPhase = 1
            } else {
                let index = Int(t/cycle), p = (t-Double(index)*cycle)/cycle
                let push = min(1,max(0,(p-0.25)/0.375)), eased = push*push*(3-2*push)
                progress = (Double(index)+eased)/Double(steps); frame = min(7,Int(p*8)); pushPhase = p
            }
            return BackdropRelocationSample(origin:mix(plan.from,plan.to,progress),
                scoot:.init(frame:frame,offset:progress,phase:"坐姿避让背景",pushPhase:pushPhase),
                stroll:nil,mirrored:mirrored,phase:"近处空白 · 坐着挪过去")
        }
        if elapsed < Self.riseDuration {
            let pose = StrollTimeline.sample(at:elapsed+0.00001)
            return BackdropRelocationSample(origin:plan.from,scoot:nil,
                stroll:pose,mirrored:mirrored && pose?.isSideFacing == true,phase:"远处空白 · 正在起身")
        }
        let walking = elapsed-Self.riseDuration
        if walking < travelDuration {
            return BackdropRelocationSample(origin:mix(plan.from,plan.to,walking/travelDuration),scoot:nil,
                stroll:StrollTimeline.walkSample(at:walking),
                mirrored:mirrored,phase:"远处空白 · 走过去")
        }
        return sitting(origin:plan.to,elapsed:walking-travelDuration,mirrored:mirrored,phase:"已到空白区域 · 坐下")
    }
    private func sitting(origin: CGPoint,elapsed: Double,mirrored: Bool,phase: String) -> BackdropRelocationSample {
        let index = min(Self.sittingFrames.count-1,Int(elapsed/Self.sittingDuration*Double(Self.sittingFrames.count)))
        let frame = Self.sittingFrames[index]
        let pose = frame <= 1
            ? StrollTimeline.Sample(frame:nil,phase:.sitting,transitionFrame:frame == 1 ? 4 : 3)
            : StrollTimeline.Sample(frame:frame,phase:.sitting)
        return BackdropRelocationSample(origin:origin,scoot:nil,
            stroll:pose,mirrored:mirrored && frame >= 7,phase:phase)
    }
    private func mix(_ from: CGPoint,_ to: CGPoint,_ p: Double) -> CGPoint {
        CGPoint(x:from.x+(to.x-from.x)*p,y:from.y+(to.y-from.y)*p)
    }
}

final class BackdropObservationService {
    var onIdle: (() -> Void)?
    enum Failure: LocalizedError {
        case analysis(Error)
        var errorDescription: String? {
            switch self {
            case .analysis(let error): return "屏幕读取已就绪 · 背景分析暂不可用 · "+error.localizedDescription
            }
        }
    }
    private let capture = BackdropCapture()
    private(set) var busy = false
    private(set) var hasCaptureAccess = false
    private(set) var permissionDenied = false
    private var generation = 0
    private(set) var lastDisplayCount = 0
    private(set) var lastCaptureMilliseconds = 0.0
    private(set) var lastAnalysisMilliseconds = 0.0
    func invalidate() { generation += 1 }
    func retryAccess() { permissionDenied = false }
    func checkAccess(displayID: CGDirectDisplayID, completion: @escaping (Result<Void,Error>)->Void) {
        guard !busy else { return }
        busy = true
        let token = generation
        Task {
            let result: Result<Void,Error>
            do { _ = try await capture.capture(displayID:displayID); result = .success(()) }
            catch { result = .failure(error) }
            await MainActor.run {
                self.busy = false
                defer { self.onIdle?() }
                guard token == self.generation else { return }
                switch result {
                case .success: self.hasCaptureAccess = true; self.permissionDenied = false
                case .failure(let error):
                    if BackdropCapture.isPermissionFailure(error) { self.hasCaptureAccess = false; self.permissionDenied = true }
                }
                completion(result)
            }
        }
    }
    func observe(displays: [(id: CGDirectDisplayID, frame: CGRect)], completion: @escaping (Result<[BackdropScene],Error>)->Void) {
        guard !busy else { return }
        busy = true
        let token = generation, time = ProcessInfo.processInfo.systemUptime
        Task {
            let result: Result<[BackdropScene],Error>
            var captured = false
            do {
                let images = try await capture.capture(displayIDs:displays.map { $0.id })
                captured = true
                let capturedAt = ProcessInfo.processInfo.systemUptime
                lastDisplayCount = displays.count
                lastCaptureMilliseconds = (capturedAt-time)*1000
                do {
                    let scene = try await Task.detached(priority:.utility) {
                        try zip(images,displays).map { try BackdropScene.analyze($0.0,frame:$0.1.frame,at:time) }
                    }.value
                    lastAnalysisMilliseconds = (ProcessInfo.processInfo.systemUptime-capturedAt)*1000
                    result = .success(scene)
                } catch { result = .failure(Failure.analysis(error)) }
            } catch { result = .failure(error) }
            let captureSucceeded = captured
            await MainActor.run {
                self.busy = false
                defer { self.onIdle?() }
                guard token == self.generation else { return }
                if captureSucceeded { self.hasCaptureAccess = true; self.permissionDenied = false }
                if case .failure(let error) = result, BackdropCapture.isPermissionFailure(error) {
                    self.hasCaptureAccess = false; self.permissionDenied = true
                }
                completion(result)
            }
        }
    }
}
