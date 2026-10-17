import AppKit

@main
enum WindowPeekIdleChecks {
    static func main() {
        let character = NSRect(x:1300,y:240,width:147,height:226)
        let window = DesktopWindowTarget(id:42,ownerPID:321,owner:"Fixture",
            frame:NSRect(x:650,y:350,width:520,height:440),side:.right)
        var trigger = WindowPeekIdleTrigger()
        precondition(trigger.delay == 120)
        func advance(_ trigger:inout WindowPeekIdleTrigger, from start:Double, through end:Double,
                     character frame:NSRect = character, target:DesktopWindowTarget? = window) -> [Double] {
            var fired:[Double] = []
            for step in 0...Int((end-start)*2) {
                let now = start+Double(step)*0.5
                if trigger.observe(character:frame,target:target,at:now) { fired.append(now) }
            }
            return fired
        }
        precondition(advance(&trigger,from:0,through:119.5).isEmpty)
        precondition(trigger.observe(character:character,target:window,at:120))
        precondition(advance(&trigger,from:120.5,through:245).isEmpty,"Only once per stationary pair")
        trigger.pause(at:1000)
        precondition(!trigger.observe(character:character,target:window,at:1000.5),"Stop must not immediately replay")
        let moved = character.offsetBy(dx:12,dy:0)
        precondition(!trigger.observe(character:moved,target:window,at:1001) && trigger.stationarySeconds == 0)
        precondition(advance(&trigger,from:1001.5,through:1121,character:moved) == [1121])
        for kind in ["move","resize","replacement","side"] {
            trigger.reset()
            precondition(advance(&trigger,from:0,through:119.5).isEmpty)
            let changed = DesktopWindowTarget(id:kind == "replacement" ? 43 : 42,ownerPID:321,owner:"Fixture",
                frame:kind == "move" ? window.frame.offsetBy(dx:1,dy:0)
                    : kind == "resize" ? NSRect(x:650,y:350,width:521,height:440) : window.frame,
                side:kind == "side" ? .left : .right)
            precondition(!trigger.observe(character:character,target:changed,at:120))
            precondition(trigger.stationarySeconds == 0 && !trigger.fired)
            precondition(advance(&trigger,from:120.5,through:240,target:changed) == [240])
        }
        trigger.reset()
        _ = advance(&trigger,from:0,through:119.5)
        precondition(!trigger.observe(character:nil,target:window,at:120) && trigger.stationarySeconds == 0)
        precondition(!trigger.observe(character:character,target:nil,at:120.5) && !trigger.fired)
        precondition(advance(&trigger,from:121,through:241) == [241])
        trigger.reset()
        _ = advance(&trigger,from:0,through:119.5)
        precondition(!trigger.observe(character:character,target:window,at:125) && trigger.stationarySeconds == 0,
                     "A suspended or stalled observer must restart")
        precondition(!trigger.observe(character:character,target:window,at:1) && trigger.stationarySeconds == 0)
        trigger.reset()
        precondition(!trigger.observe(character:character,target:window,at:0))
        precondition(!trigger.observe(character:character.offsetBy(dx:0.3,dy:0),target:window,at:0.5)
            && trigger.stationarySeconds == 0.5)
        precondition(!trigger.observe(character:character.offsetBy(dx:0.6,dy:0),target:window,at:1)
            && trigger.stationarySeconds == 0,"Small cumulative movement cannot evade reset")
        trigger.reset()
        _ = advance(&trigger,from:0,through:119.5)
        precondition(!trigger.observe(character:character,target:window,at:120,harnessIdle:false))
        precondition(trigger.stationarySeconds == 0 && !trigger.fired,"Working harness clears accumulated idle time")
        for time in stride(from:120.5,through:250.0,by:0.5) {
            precondition(!trigger.observe(character:character,target:window,at:time,harnessIdle:false))
        }
        precondition(advance(&trigger,from:250.5,through:370.5)==[370.5],"Stationary time starts anew only after the harness is idle")
        trigger.reset()
        _ = advance(&trigger,from:0,through:119.5)
        precondition(!trigger.observe(character:character,target:window,at:120,singing:true))
        precondition(trigger.stationarySeconds == 0 && !trigger.fired,"Singing clears nearly completed idle time")
        for time in stride(from:120.5,through:260.0,by:0.5) {
            precondition(!trigger.observe(character:character,target:window,at:time,singing:true))
            precondition(trigger.stationarySeconds == 0 && !trigger.fired)
        }
        precondition(advance(&trigger,from:260.5,through:380.5)==[380.5],
                     "After singing, wait a complete new stationary interval")
        var fallback = WindowPeekIdleTrigger(delay: 3)
        for t in stride(from: 0.0, through: 2.5, by: 0.5) {
            precondition(!fallback.observe(character: character, target: nil, at: t, allowNoTarget: true))
        }
        precondition(fallback.observe(character: character, target: nil, at: 3, allowNoTarget: true))
        precondition(!fallback.observe(character: character, target: nil, at: 3.5, allowNoTarget: true))
        precondition(!fallback.observe(character: character, target: window, at: 4, allowNoTarget: true))
        precondition(fallback.stationarySeconds == 0 && !fallback.fired)
        fallback.reset()
        precondition(!fallback.observe(character: character, target: nil, at: 0, allowNoTarget: true))
        precondition(!fallback.observe(character: character, target: nil, at: 1, harnessIdle: false, allowNoTarget: true))
        precondition(fallback.stationarySeconds == 0)
        print("PASS: default 120-second boundary; either position/size/identity/visibility resets; one trigger per stationary pair; observation gaps and cumulative motion")
    }
}
