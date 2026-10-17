import AppKit
import CoreGraphics

enum WindowSeatSelectionChecks {
    static func run() throws {
        let primary=NSScreen.screens.first!,area=primary.visibleFrame
        let ownPID=ProcessInfo.processInfo.processIdentifier,otherPID=ownPID+10000
        func row(_ id:CGWindowID,_ frame:NSRect,pid:pid_t = 0,layer:Int = 0,alpha:Double = 1)->[String:Any] {
            let cg=CGRect(x:frame.minX,y:primary.frame.maxY-frame.maxY,width:frame.width,height:frame.height)
            return [kCGWindowNumber as String:NSNumber(value:id),kCGWindowOwnerPID as String:NSNumber(value:pid==0 ? otherPID : pid),
                    kCGWindowOwnerName as String:"Existing app",kCGWindowLayer as String:layer,kCGWindowAlpha as String:alpha,
                    kCGWindowBounds as String:cg.dictionaryRepresentation]
        }
        var scales:[[String:Any]]=[]
        for scale in [0.5,1.0,2.0] {
            let width=max(520,400*scale),height=max(300,270*scale)
            let frame=NSRect(x:area.midX-width/2,y:area.minY+40,width:width,height:height)
            let below=NSRect(x:area.minX,y:area.minY,width:147*scale,height:226*scale)
            let selection=DesktopWindowTarget.chooseSeatPreview(near:below,scale:scale,rows:[row(103,frame)])!
            precondition(selection.target.id==103 && selection.target.frame==frame && !selection.needsActivation)
            precondition(selection.original.size==below.size,"Finding an upper edge must preserve the display scale")
            precondition(area.contains(WindowSeatGeometry.entryBounds(character:selection.original,window:frame,scale:scale)),"The complete rise/jog/seat path fits on screen")
            precondition(WindowSeatGeometry.fits(character:selection.original,window:frame,scale:scale,area:area))
            scales.append(["scale":scale,"target":selection.target.id,"preservesScale":true,"entryFits":true])
        }
        let start=NSRect(x:area.midX-73.5,y:area.minY,width:147,height:226)
        let good=NSRect(x:area.midX-400,y:area.minY+40,width:800,height:300)
        let nearTop=NSRect(x:good.minX,y:area.maxY-180-300,width:800,height:300)
        for rows in [[],[row(103,good,pid:ownPID)],[row(103,good,layer:3)],[row(103,good,alpha:0.5)],
                     [row(103,primary.frame)],[row(103,nearTop)]] {
            precondition(DesktopWindowTarget.chooseSeatPreview(near:start,scale:1,rows:rows)==nil,"Invalid targets never become a practice window or a clipped preview")
        }
        let selected=DesktopWindowTarget.chooseSeatPreview(near:start,scale:1,onlyWindow:104,rows:[row(103,good),row(104,good.offsetBy(dx:0,dy:10),pid:otherPID+1)])!
        precondition(selected.target.id==104 && selected.needsActivation)
        // Existing windows hidden by a different app can be shown by activating
        // their owner; a covering window from the same app cannot be fixed that way.
        let covered=DesktopWindowTarget.chooseSeatPreview(near:start,scale:1,rows:[row(102,area,pid:otherPID+1),row(103,good)])!
        precondition(covered.target.id==103 && covered.needsActivation)
        precondition(DesktopWindowTarget.chooseSeatPreview(near:start,scale:1,rows:[row(102,area),row(103,good)])==nil)
        let leftCover=NSRect(x:area.minX,y:area.minY,width:good.minX-area.minX+good.width*0.6,height:area.height)
        let clearRight=DesktopWindowTarget.chooseSeatPreview(near:start,scale:1,rows:[row(102,leftCover),row(103,good)])!
        precondition(!clearRight.needsActivation && clearRight.original.midX>leftCover.maxX,"Use an exposed top span before activating another app")
        let noTarget=WindowPeekController()
        precondition(!noTarget.start(from:start,scale:1,targetID:CGWindowID.max,forceFixture:true,previewSeat:true))
        precondition(noTarget.fixture==nil && !noTarget.isRunning && noTarget.target==nil,"No suitable real target must fail without a generated window")
        precondition(noTarget.status.contains("没有找到"))
        let output=ProcessInfo.processInfo.environment["CAPTIONS_WINDOW_PEEK_OUTPUT"].map{URL(fileURLWithPath:$0)}
            ?? URL(fileURLWithPath:"output/deepseek-seat-real-preview")
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        let result:[String:Any]=["passed":true,"scales":scales,"noTargetCreatesNoWindow":true,"backgroundTargetActivation":true,"sameAppOcclusionRejected":true,"exposedSpanPreferred":true]
        try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("selection-validation.json"))
        print("PASS: real-window preview selection, complete entry bounds, exposed spans and no practice-window fallback")
    }
}
