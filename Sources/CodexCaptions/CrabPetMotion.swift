import Foundation

struct CrabPetPose: Equatable { let frame: Int; let mirrored: Bool }
struct CrabPetSample { let origin: CGPoint; let pose: CrabPetPose?; let finished: Bool }

/// Travel and all posture transitions share the app clock; never scale a seated pose into a run.
struct CrabPetMotion {
    let from: CGPoint
    let to: CGPoint
    let startedAt: Double
    let scale: Double
    var travelDuration: Double { max(0.5, min(10, hypot(to.x-from.x,to.y-from.y)/(100*scale))) }
    var duration: Double { 1.28 + travelDuration + 1.28 + 2.56 + 1.28 + 1.28 }
    func sample(at now: Double) -> CrabPetSample {
        let t=max(0,now-startedAt), mirror=to.x<from.x
        if t>=duration {return .init(origin:to,pose:nil,finished:true)}
        func pose(_ frame:Int,_ origin:CGPoint)->CrabPetSample {
            .init(origin:origin,pose:.init(frame:frame,mirrored:mirror),finished:false)
        }
        if t<1.28 {return pose(min(7,Int(t/0.16)),from)}
        var elapsed=t-1.28
        if elapsed<travelDuration {
            let p=elapsed/travelDuration, eased=p*p*(3-2*p)
            return pose(9+Int(elapsed/0.12)%6,CGPoint(x:from.x+(to.x-from.x)*eased,y:from.y+(to.y-from.y)*eased))
        }
        elapsed -= travelDuration
        if elapsed<1.28 {return pose(16+min(7,Int(elapsed/0.16)),to)}
        elapsed -= 1.28
        if elapsed<2.56 {let loop=[20,21,22,21,20,20,21,22];return pose(loop[Int(elapsed/0.16)%loop.count],to)}
        elapsed -= 2.56
        if elapsed<1.28 {return pose(23-min(7,Int(elapsed/0.16)),to)}
        elapsed -= 1.28
        if elapsed<1.28 {return pose(7-min(7,Int(elapsed/0.16)),to)}
        return .init(origin:to,pose:nil,finished:true)
    }
}
