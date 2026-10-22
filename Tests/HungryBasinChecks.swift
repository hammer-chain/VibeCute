import AppKit
import ImageIO
import UniformTypeIdentifiers
import CaptionCore
@testable import CodexCaptions

@main struct HungryBasinChecks {
 static func main() throws {
    var motion = HungryBasinMotion()
    for _ in 0..<100 { motion.advance(requested:false,allowed:true) }
    precondition(motion.frame == nil)
    var hits=0
    var hitTicks: [Int] = []
    for tick in 0..<40 { if motion.advance(requested:true,allowed:true) {
        precondition(motion.frame == 4); hits += 1; hitTicks.append(tick)
    } }
    precondition(hits == 4)
    precondition(hitTicks == [6,10,25,29], "Sound must use the exact contact ticks")
    motion.advance(requested:true,allowed:false); precondition(motion.frame == nil)
    motion.advance(requested:true,allowed:true); precondition(motion.frame == 0)
    for _ in 0..<5 {precondition(!motion.advance(requested:false,allowed:true))}
    precondition(motion.frame == nil)
    let app=NSApplication.shared;app.setActivationPolicy(.accessory);app.finishLaunching()
    precondition(!NSScreen.screens.isEmpty,"Native checks require a graphical session")
    let start=ProcessInfo.processInfo.systemUptime
    let art=DeepSeekHungryArtwork.shared
    precondition(art.available)
    let decodeMS=(ProcessInfo.processInfo.systemUptime-start)*1000
    let overlays=ProjectOverlays()
    func update(_ low:Bool,_ kind:CharacterChoice = .deepseek) {
        overlays.update([],font:14,opacity:1,bottom:80,screenIndex:0,movable:true,focusedID:"",
          restingMascots:[.deepseek],characterBindings:[.deepseek:kind],
          fallbackMetrics:[.deepseek:OverlayHoverMetrics(averageSpeed:nil,quotaText:"测试余额",persistent:low)],
          hungrySoundVolume:0.02)
    }
    update(true)
    let character=overlays.character(for:.deepseek)!
    func wait(_ seconds:Double) { RunLoop.main.run(until:Date().addingTimeInterval(seconds)) }
    let output=URL(fileURLWithPath:FileManager.default.currentDirectoryPath+"/output/hungry-basin")
    let gif=CGImageDestinationCreateWithURL(output.appendingPathComponent("native-preview.gif") as CFURL,UTType.gif.identifier as CFString,30,nil)!
    CGImageDestinationSetProperties(gif,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFLoopCount:0]] as CFDictionary)
    var observed=Set<Int>()
    for _ in 0..<30 {
        wait(0.165)
        if let f=character.subtitle.balanceHungryFrame {observed.insert(f)}
        let view=character.subtitle
        let rep=view.bitmapImageRepForCachingDisplay(in:view.bounds)!
        view.cacheDisplay(in:view.bounds,to:rep)
        CGImageDestinationAddImage(gif,rep.cgImage!,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFDelayTime:0.16]] as CFDictionary)
    }
    precondition(CGImageDestinationFinalize(gif));precondition(observed == Set(0..<5))
    let sound = character.subtitle.hungryBasinSound
    precondition(sound.playCount == 4, "One native audio play per contact, including first strike")
    for _ in 0..<10 {character.subtitle.needsDisplay = true;character.subtitle.displayIfNeeded()}
    precondition(sound.playCount == 4, "Repaints must never repeat a sound")
    sound.configure(enabled:false,volume:0.02)
    precondition(!sound.strike() && sound.playCount == 4)
    sound.configure(enabled:true,volume:0)
    precondition(!sound.strike() && sound.playCount == 4)
    sound.configure(enabled:true,volume:0.02)
    character.subtitle.setAudioMouth(0);wait(0.4)
    precondition(character.subtitle.balanceHungryFrame != nil,"Ambient lip tracking must not suppress the alert")
    character.subtitle.setAudioMouth(nil)
    character.subtitle.setRainShelterPose(RainShelterPose(frame:2,mirrored:false));wait(0.2)
    precondition(character.subtitle.balanceHungryFrame == nil)
    character.subtitle.setRainShelterPose(nil);wait(0.2)
    precondition(character.subtitle.balanceHungryFrame != nil)
    character.subtitle.enterScreenEdge(.left);wait(0.2)
    precondition(character.subtitle.balanceHungryFrame == nil)
    character.subtitle.screenEdgeDock = nil;wait(0.2)
    precondition(character.subtitle.balanceHungryFrame != nil)
    update(false);wait(1)
    precondition(character.subtitle.balanceHungryFrame == nil,"Balance recovery must finish the exit")
    let stoppedCount = sound.playCount
    wait(0.8);precondition(sound.playCount == stoppedCount)
    update(true,.orangeHoodie);wait(0.4)
    precondition(overlays.character(for:.deepseek)!.subtitle.balanceHungryFrame == nil,"Other artwork must not play fish animation")
    update(false,.orangeHoodie)
    let report:[String:Any] = ["passed":true,"observedFrames":observed.sorted(),"decodeMS":decodeMS,
      "decodedPixelBytes":5*384*512*4,"tickHz":6.25,"newTimers":0,"newNetworkRequests":0,
      "soundContactTicks":hitTicks,"nativeInitialSoundPlays":4,
      "scope":"native fixture with actual ProjectOverlays and SubtitleView, not a live account balance mutation"]
    try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("checks.json"))
    print(String(data:try JSONSerialization.data(withJSONObject:report,options:.sortedKeys),encoding:.utf8)!)
 }
}
