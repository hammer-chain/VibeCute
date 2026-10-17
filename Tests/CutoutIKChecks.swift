import Foundation
import CoreGraphics

@main struct CutoutIKChecks {
    static func main() {
        do {try run()} catch {fputs("FAIL: \(error)\n",stderr);exit(1)}
    }
    static func run() throws {
        func require(_ ok:Bool,_ message:String)throws {if !ok {throw CutoutError.invalid(message)}}
        let data:[String:Any]=[
            "schemaVersion":1,"canvas":[384,512],"anchor":[0,0],"pointsPerPixel":1,
            "bones":[["id":"root","position":[150,200]],
                     ["id":"head","parent":"root","position":[0,50]],
                     ["id":"upper","parent":"root","position":[-20,0]],
                     ["id":"middle","parent":"upper","position":[-10,-30]],
                     ["id":"hand","parent":"middle","position":[35,20]]],
            "slots":[],"variants":[],"defaults":[:],"motions":"qa.json",
            "twoBoneConstraints":[["id":"touch","upper":"upper","middle":"middle","end":"hand","targetBone":"head","targetPoint":[155,190],"bend":1,"matchTargetRotation":true]]]
        let rig=try JSONDecoder().decode(CutoutRig.self,from:JSONSerialization.data(withJSONObject:data))
        func keys(_ values:[Double])->[CutoutMotionLibrary.Key] {
            values.enumerated().map{.init(time:Double($0.offset),value:.init(rotation:$0.element))}
        }
        let clips:[CutoutMotionLibrary.Clip]=[
            .init(id:"neutral",title:"Neutral",duration:2,loop:true,tracks:[],constraints:[]),
            .init(id:"hold",title:"Hold",duration:2,loop:true,tracks:[.init(bone:"head",keys:keys([0,15,0])),.init(bone:"root",keys:keys([0,12,0]))],constraints:["touch"]),
            .init(id:"release",title:"Release",duration:2,loop:true,tracks:[],constraints:[])]
        let motions=CutoutMotionLibrary(schemaVersion:1,clips:clips)
        let p=try CutoutPlayer(rig:rig,motions:motions)
        p.play("hold",at:0,transition:0)
        var maximumError=0.0
        for i in 0...240 {
            p.sample(at:Double(i)/120)
            let target=CGPoint(x:5,y:-60).applying(p.world[1]),hand=CGPoint.zero.applying(p.world[4])
            maximumError=max(maximumError,hypot(hand.x-target.x,hand.y-target.y))
            let angle=atan2(p.world[4].b,p.world[4].a)-atan2(p.world[1].b,p.world[1].a)
            try require(abs(sin(angle))<1e-9,"Hand orientation lost target rotation")
            let u=CGPoint.zero.applying(p.world[2]),m=CGPoint.zero.applying(p.world[3])
            try require(abs(hypot(u.x-m.x,u.y-m.y)-hypot(10,30))<1e-9,"Upper limb length changed")
            try require(abs(hypot(hand.x-m.x,hand.y-m.y)-hypot(35,20))<1e-9,"Lower limb length changed")
        }
        try require(maximumError<1e-8,"Reachable contact drifted")
        p.sample(at:2.4)
        let before=p.world
        p.play("release",at:2.4,transition:0.4);p.sample(at:2.4)
        func displacement(_ a:[CGAffineTransform],_ b:[CGAffineTransform])->Double {
            zip(a,b).map{hypot($0.tx-$1.tx,$0.ty-$1.ty)+abs($0.a-$1.a)+abs($0.b-$1.b)}.max()!
        }
        try require(displacement(before,p.world)<1e-8,"Release jumped at transition start")
        p.sample(at:2.52);let interrupted=p.world
        p.play("hold",at:2.52,transition:0.4);p.sample(at:2.52)
        try require(displacement(interrupted,p.world)<1e-8,"Interrupted acquisition jumped")
        p.sample(at:2.520001)
        try require(displacement(interrupted,p.world)<0.001,"Acquisition has a discontinuity after start")
        var bad=rig;bad.twoBoneConstraints![0].targetBone="hand"
        do {_=try bad.validated();throw CutoutError.invalid("Cyclic target accepted")}
        catch CutoutError.invalid(let message) {try require(message != "Cyclic target accepted",message)}
        var badMotion=motions;badMotion.clips[0].constraints=["missing"]
        do {_=try CutoutPlayer(rig:rig,motions:badMotion);throw CutoutError.invalid("Unknown constraint accepted")}
        catch CutoutError.invalid(let message) {try require(message != "Unknown constraint accepted",message)}
        var unreachable=rig;unreachable.twoBoneConstraints![0].targetPoint=[1500,1500]
        let far=try CutoutPlayer(rig:unreachable,motions:motions);far.play("hold",at:0,transition:0);far.sample(at:0.5)
        try require(far.world.allSatisfy{[$0.a,$0.b,$0.c,$0.d,$0.tx,$0.ty].allSatisfy(\.isFinite)},"Unreachable target produced non-finite pose")
        var plain=rig;plain.twoBoneConstraints=nil
        var plainMotion=motions;for i in plainMotion.clips.indices {plainMotion.clips[i].constraints=nil}
        let baseline=try CutoutPlayer(rig:plain,motions:plainMotion)
        baseline.play("hold",at:0,transition:0)
        let rounds=10000
        func benchmark(_ player:CutoutPlayer)->Double {
            let start=ProcessInfo.processInfo.systemUptime
            for i in 0..<rounds {player.sample(at:Double(i)/120)}
            return (ProcessInfo.processInfo.systemUptime-start)*1000
        }
        p.play("hold",at:0,transition:0)
        let baseMS=benchmark(baseline),solveStart=p.constraintSolves,rebuildStart=p.constraintRecomputedBones
        let solveMS=benchmark(p)
        try require(p.constraintSolves-solveStart==rounds,"Constraint solve count drifted")
        try require(p.constraintRecomputedBones-rebuildStart==3*rounds,"Unexpected full-skeleton scans")
        let report:[String:Any]=["passed":true,"reachableSamples":241,"maximumContactError":maximumError,"benchmarkSamples":rounds,"bones":5,"constraints":1,"baselineMilliseconds":baseMS,"constrainedMilliseconds":solveMS,"constraintSolves":rounds,"recomputedBones":3*rounds,"scope":"Skeleton math only; native rendering and art acceptance separate"]
        let out=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("output/cutout/ik-checks.json")
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:out)
        print(String(data:try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys]),encoding:.utf8)!)
    }
}
