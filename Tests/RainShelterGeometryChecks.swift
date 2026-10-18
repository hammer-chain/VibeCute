import Foundation
import CoreGraphics

@main struct RainShelterGeometryChecks {
    static func main() throws {
        var assertions = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) { precondition(value(),message); assertions += 1 }
        let body = CGRect(x:0,y:8,width:147,height:184), area = CGRect(x:-800,y:-400,width:2200,height:1200)
        let window = CGRect(x:400,y:250,width:420,height:420), origin = CGPoint(x:40,y:20)
        func target(_ route: RainShelterRoute) -> CGPoint? { if case .shelter(let p) = route { return p }; return nil }
        func verifyDry(_ p: CGPoint, body: CGRect, window: CGRect, wind: Double, top: Double = 900) {
            let roof = quartzRect(appKit:RainRect(x:window.minX,y:window.minY,width:window.width,height:window.height),mainDisplayTop:top)
            let field = RoofField(windows:[roof])
            for x in [body.minX,body.maxX] { for y in [body.minY,body.maxY] {
                check(field.isSheltered(RainPoint(x:p.x+x,y:top-p.y-y),wind:wind),"Planner disagrees with actual rain shadow")
            }}
        }
        for wind in [-0.8,-0.35,0,0.35,0.8] {
            let route = RainShelterPlanner.route(origin:origin,anchor:origin,body:body,allowed:area,window:window,wind:wind,scale:1)
            guard let p = target(route) else { fatalError("Suitable foreground window rejected") }
            check(area.contains(p),"Target left allowed screen origins")
            check(window.insetBy(dx:7.9,dy:7.9).contains(body.offsetBy(dx:p.x,dy:p.y)),"Actor stopped in the shadow outside the window")
            check(abs(p.y+body.minY-window.minY-8)<0.01,"Below-window start did not use the bottom inside edge")
            verifyDry(p,body:body,window:window,wind:wind)
        }
        // Negative display origins and a window straddling screens use the same geometry.
        let secondary = CGRect(x:-700,y:-200,width:420,height:350)
        let secondaryRoute = RainShelterPlanner.route(origin:CGPoint(x:-790,y:-300),anchor:origin,body:body,allowed:area,window:secondary,wind:0.4,scale:1)
        verifyDry(target(secondaryRoute)!,body:body,window:secondary,wind:0.4)
        let high = CGPoint(x:40,y:window.minY+60)
        let highTarget = target(RainShelterPlanner.route(origin:high,anchor:high,body:body,allowed:area,window:window,wind:0,scale:1))!
        check(abs(highTarget.y+body.minY-window.minY-8)<0.01,"Above-bottom start did not descend to bottom inside edge")
        check(window.contains(body.offsetBy(dx:highTarget.x,dy:highTarget.y)),"High arrival not completely inside")
        for scale in [0.7,1.0,1.5] {
            let scaledBody = CGRect(x:body.minX*scale,y:body.minY*scale,width:body.width*scale,height:body.height*scale)
            for y in [-300.0,20,250,310,800] { for x in [40.0,1200] {
                let start = CGPoint(x:x,y:y)
                let p = target(RainShelterPlanner.route(origin:start,anchor:start,body:scaledBody,allowed:area,window:window,wind:0,scale:scale))!
                check(abs(p.y+scaledBody.minY-window.minY-8*scale)<0.01,"Start height or scale changed bottom alignment")
                check(window.contains(scaledBody.offsetBy(dx:p.x,dy:p.y)),"Bottom alignment clipped artwork")
            }}
        }
        let clippedArea = CGRect(x:area.minX,y:window.minY+50,width:area.width,height:area.height)
        check(target(RainShelterPlanner.route(origin:high,anchor:high,body:body,allowed:clippedArea,window:window,wind:0,scale:1)) == nil,
              "Off-screen bottom edge silently became a mid-window destination")
        check(target(RainShelterPlanner.route(origin:origin,anchor:origin,body:body,allowed:area,window:CGRect(x:400,y:250,width:420,height:100),wind:0,scale:1)) == nil,"Short window accepted a dry shadow outside its rectangle")
        let fallback = RainShelterPlanner.route(origin:origin,anchor:origin,body:body,allowed:area,window:CGRect(x:500,y:200,width:40,height:300),wind:0,scale:1)
        if case .pace(let lo,let hi,let y) = fallback {
            check(hi-lo <= 112,"Fallback expanded beyond the local band"); check(y == origin.y,"Fallback changed the floor")
        } else { fatalError("Tiny window accepted") }
        check(target(RainShelterPlanner.route(origin:origin,anchor:origin,body:body,allowed:area,window:nil,wind:0,scale:1)) == nil,"Missing foreground window accepted")
        let cramped = RainShelterPlanner.route(origin:origin,anchor:origin,body:body,allowed:CGRect(x:0,y:0,width:0,height:0),window:nil,wind:0,scale:1)
        if case .pace(let lo,let hi,_) = cramped { check(lo == hi,"Zero-space fallback invented travel") }
        let destination = CGPoint(x:360,y:20)
        var motion = RainShelterMotion(origin:origin,at:0)
        var sample = motion.update(at:0,raining:true,route:.shelter(destination),scale:1)
        check(sample.phase == .raising && sample.frame == 0,"Rain must begin with basin entry")
        for i in 0..<8 {
            sample = motion.update(at:Double(i)*0.2+0.05,raining:true,route:.shelter(destination),scale:1)
            check(sample.frame == i && sample.origin == origin,"Entry skipped a frame or slid while seated")
        }
        var runFrames = Set<Int>(), lowerFrames = Set<Int>(), stowFrames = Set<Int>()
        var exitSequence: [Int] = []
        for i in 96...600 {
            sample = motion.update(at:Double(i)/60,raining:true,route:.shelter(destination),scale:1)
            if sample.phase == .running { runFrames.insert(sample.frame!); check((8...15).contains(sample.frame!),"Run leaked an entry/exit frame") }
            if sample.phase == .lowering { lowerFrames.insert(sample.frame!) }
            if sample.phase == .stowing { stowFrames.insert(sample.frame!) }
            if (sample.phase == .lowering || sample.phase == .stowing), exitSequence.last != sample.frame {
                exitSequence.append(sample.frame!)
            }
        }
        check(runFrames == Set(8...15),"Run omitted a key pose")
        check(lowerFrames == Set(16...21),"Arrival must place the basin at frame 22 without sitting upright at 23/24")
        check(stowFrames == Set(24...31),"Arrival omitted a stow frame")
        check(exitSequence == Array(16...21)+Array(24...31),"Basin placement must proceed directly from frame 22 to 25")
        check(sample.phase == .sheltered && sample.origin == destination && sample.frame == nil,"Arrival did not release artwork to thinking")
        sample = motion.update(at:11,raining:true,route:.shelter(destination),scale:1)
        check(sample.phase == .sheltered,"Same roof restarted entry")
        sample = motion.update(at:12,raining:false,route:.shelter(destination),scale:1)
        check(sample.phase == .idle && sample.frame == nil,"Dry weather left an owned animation")
        var alreadyDry = RainShelterMotion(origin:destination,at:0)
        sample = alreadyDry.update(at:0,raining:true,route:.shelter(destination),scale:1)
        check(sample.phase == .sheltered && sample.frame == nil,"Already sheltered character unnecessarily took out basin")
        var pace = RainShelterMotion(origin:origin,at:0), directions = Set<Bool>()
        let band = RainShelterRoute.pace(minX:0,maxX:96,y:20)
        for i in 0..<1200 {
            sample = pace.update(at:Double(i)/60,raining:true,route:band,scale:1)
            check(sample.origin.x >= 0 && sample.origin.x <= 96,"Fallback overshot its band")
            check(sample.origin.y == 20,"Fallback drifted vertically")
            if sample.phase == .running { directions.insert(sample.mirrored) }
        }
        check(directions.count == 2,"Fallback never alternated directions")
        sample = pace.update(at:20,raining:false,route:band,scale:1)
        check(sample.phase == .lowering,"Rain stop did not start putting basin down")
        sample = pace.update(at:21.6,raining:false,route:band,scale:1)
        check(sample.phase == .stowing,"Rain stop skipped basin stow")
        sample = pace.update(at:22.8,raining:false,route:band,scale:1)
        check(sample.phase == .idle,"Rain stop never completed")
        // Warm deterministic planner benchmark: 50k foreground changes, no OS queries.
        var samples: [Double] = [], checksum = 0.0
        for batch in 0..<100 {
            let start = ProcessInfo.processInfo.systemUptime
            for i in 0..<500 {
                let roof = window.offsetBy(dx:Double((i+batch)%100),dy:0)
                if let p = target(RainShelterPlanner.route(origin:origin,anchor:origin,body:body,allowed:area,window:roof,wind:0.35,scale:1)) { checksum += p.x }
            }
            samples.append((ProcessInfo.processInfo.systemUptime-start)*1000)
        }
        samples.sort(); check(checksum > 0,"Benchmark optimized away")
        check(samples[95] < 50,"500 bounded plans exceeded 50ms")
        let report: [String:Any] = ["assertions":assertions,"plannerCalls":50000,"batchSize":500,"p95BatchMs":samples[95],"windowQueries":0,"networkRequests":0,"runKeys":runFrames.sorted(),"exitKeys":lowerFrames.sorted()]
        try FileManager.default.createDirectory(atPath:"output/rain-shelter",withIntermediateDirectories:true)
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:"output/rain-shelter/geometry-performance.json"))
        print("Rain shelter geometry/motion passed: \(assertions) assertions; 500-plan p95 \(samples[95])ms")
    }
}
