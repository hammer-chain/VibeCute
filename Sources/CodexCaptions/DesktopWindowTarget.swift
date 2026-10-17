import AppKit
import CoreGraphics

struct DesktopWindowTarget {
    enum Side: String { case left, right }
    let id: CGWindowID
    let ownerPID: pid_t
    let owner: String
    let frame: NSRect
    let side: Side
    var prefersSeat=false
    var edgeX: CGFloat { side == .left ? frame.minX : frame.maxX }
    var gripY: CGFloat { frame.minY+frame.height*0.55 }
    static let cornerGripOffset: CGFloat = 16+345*147/448
    static func isBelow(_ character:NSRect,window:NSRect) -> Bool { character.midY < window.minY }
    static func nearestLowerCorner(_ character:NSRect,window:NSRect) -> Side {
        let left = hypot(character.midX-window.minX,character.midY-window.minY)
        let right = hypot(character.midX-window.maxX,character.midY-window.minY)
        return left <= right ? .left : .right
    }
    func withSide(_ side:Side) -> DesktopWindowTarget {
        DesktopWindowTarget(id:id,ownerPID:ownerPID,owner:owner,frame:frame,side:side,prefersSeat:prefersSeat)
    }

    static func windows() -> [[String: Any]] {
        CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements],kCGNullWindowID)
            as? [[String:Any]] ?? []
    }
    static func frame(from row: [String:Any]) -> NSRect? {
        guard let bounds = row[kCGWindowBounds as String] as? [String:Any],
              let cg = CGRect(dictionaryRepresentation: bounds as CFDictionary),
              let primary = NSScreen.screens.first else { return nil }
        return NSRect(x:cg.minX,y:primary.frame.maxY-cg.maxY,width:cg.width,height:cg.height)
    }
    static func resolve(_ id: CGWindowID, side: Side) -> DesktopWindowTarget? {
        guard let row = windows().first(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == id }),
              let frame = frame(from:row), frame.width >= 250, frame.height >= 260,
              (row[kCGWindowAlpha as String] as? Double ?? 1) > 0.9 else { return nil }
        return DesktopWindowTarget(id:id,ownerPID:(row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0,
            owner:row[kCGWindowOwnerName as String] as? String ?? "窗口",frame:frame,side:side)
    }
    /// A seated character follows one window. Query only that ID instead of
    /// copying the entire desktop list at the animation cadence.
    static func resolveSeatSupport(_ id:CGWindowID,side:Side)->DesktopWindowTarget? {
        guard let rows=CGWindowListCopyWindowInfo(.optionIncludingWindow,id) as? [[String:Any]],
              let row=rows.first(where:{($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value==id}),
              (row[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue == true,
              (row[kCGWindowLayer as String] as? Int)==0,
              let frame=frame(from:row),frame.width>=250,frame.height>=260,
              (row[kCGWindowAlpha as String] as? Double ?? 1)>0.9 else {return nil}
        return DesktopWindowTarget(id:id,ownerPID:(row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0,
            owner:row[kCGWindowOwnerName as String] as? String ?? "窗口",frame:frame,side:side)
    }
    static func isFullScreen(_ rect: NSRect) -> Bool {
        NSScreen.screens.contains { rect.contains($0.frame.insetBy(dx:2,dy:2)) }
    }
    struct SeatPreview {
        let target:DesktopWindowTarget
        let original:NSRect
        let needsActivation:Bool
    }
    /// Manual previews may start beside a real upper edge even when the mascot
    /// is currently below it. Take one desktop snapshot per button press.
    static func chooseSeatPreview(near start:NSRect,scale:CGFloat,onlyWindow:CGWindowID? = nil,
                                  rows suppliedRows:[[String:Any]]? = nil)->SeatPreview? {
        let ownPID=ProcessInfo.processInfo.processIdentifier
        let ownBundle=Bundle.main.bundleIdentifier
        let ownPIDs=Set([ownPID]+NSWorkspace.shared.runningApplications.filter{ownBundle != nil && $0.bundleIdentifier==ownBundle}.map{$0.processIdentifier})
        let visible=(suppliedRows ?? windows()).compactMap { row -> DesktopWindowTarget? in
            guard (row[kCGWindowLayer as String] as? Int)==0,
                  (row[kCGWindowAlpha as String] as? Double ?? 1)>0.9,
                  let id=(row[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let pid=(row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let rect=frame(from:row) else {return nil}
            return DesktopWindowTarget(id:id,ownerPID:pid,owner:row[kCGWindowOwnerName as String] as? String ?? "窗口",
                                       frame:rect,side:start.midX<rect.midX ? .left : .right,prefersSeat:true)
        }
        var fallback:SeatPreview?
        for (index,window) in visible.enumerated() {
            guard !ownPIDs.contains(window.ownerPID),window.ownerPID>0,
                  onlyWindow==nil || onlyWindow==window.id,
                  window.frame.width>=max(320,170*scale),window.frame.height>=max(300,270*scale),
                  !isFullScreen(window.frame),
                  let screen=NSScreen.screens.max(by:{$0.frame.intersection(window.frame).area<$1.frame.intersection(window.frame).area})
            else {continue}
            let area=screen.visibleFrame,front=visible.prefix(index).filter{!ownPIDs.contains($0.ownerPID)}
            let left=window.frame.minX+85*scale,right=window.frame.maxX-85*scale
            func clamp(_ x:CGFloat)->CGFloat {min(right,max(left,x))}
            // Try the nearby span first, then the center/ends and clear spans
            // beside foreground windows; never move or resize the support.
            let xs=[clamp(start.midX),window.frame.midX,left,right]
                + front.flatMap{[clamp($0.frame.minX-160*scale),clamp($0.frame.maxX+160*scale)]}
            var originals:[NSRect]=[]
            if WindowSeatGeometry.fits(character:start,window:window.frame,scale:scale,area:area) {originals.append(start)}
            originals += xs.map{NSRect(x:$0-73.5*scale,y:window.frame.maxY-8*scale,width:147*scale,height:226*scale)}
            for original in originals {
                let scene=WindowSeatGeometry.entryBounds(character:original,window:window.frame,scale:scale)
                guard WindowSeatGeometry.fits(character:original,window:window.frame,scale:scale,area:area),area.contains(scene) else {continue}
                let blocked=front.filter{$0.frame.intersection(scene).area>1}
                let target=window.withSide(original.midX<window.frame.midX ? .left : .right)
                if blocked.isEmpty {return SeatPreview(target:target,original:original,needsActivation:false)}
                // Activating an app cannot raise one of its windows above a
                // different window from the same app. Avoid that false target.
                if fallback==nil && !blocked.contains(where:{$0.ownerPID==window.ownerPID}) {
                    fallback=SeatPreview(target:target,original:original,needsActivation:true)
                }
            }
        }
        return fallback
    }
    static func choose(near start: NSRect, scale: CGFloat, onlyWindow: CGWindowID? = nil) -> DesktopWindowTarget? {
        let rows = windows(), ownPID = ProcessInfo.processInfo.processIdentifier
        var fallback:DesktopWindowTarget?
        for (index,row) in rows.enumerated() {
            guard (row[kCGWindowLayer as String] as? Int) == 0,
                  (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value != ownPID,
                  let id = (row[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  onlyWindow == nil || onlyWindow == id,
                  let rect = frame(from:row), rect.width >= max(320,170*scale), rect.height >= max(300,270*scale),
                  !isFullScreen(rect), (row[kCGWindowAlpha as String] as? Double ?? 1) > 0.9,
                  let screen = NSScreen.screens.max(by: { $0.frame.intersection(rect).area < $1.frame.intersection(rect).area })
            else { continue }
            let area = screen.visibleFrame
            // Prefer the window directly under the character. Its top can be
            // usable even when both side margins are too narrow for hiding.
            if WindowSeatGeometry.fits(character:start,window:rect,scale:scale,area:area) {
                let seat=WindowSeatGeometry.destination(character:start,window:rect,scale:scale)
                let blocked=rows.prefix(index).contains { front in
                    guard (front[kCGWindowLayer as String] as? Int) == 0,
                          (front[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value != ownPID,
                          let frontRect=frame(from:front) else { return false }
                    return frontRect.intersection(seat).area > 1
                }
                if !blocked {
                    return DesktopWindowTarget(id:id,ownerPID:(row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0,
                        owner:row[kCGWindowOwnerName as String] as? String ?? "窗口",frame:rect,
                        side:start.midX < rect.midX ? .left : .right,prefersSeat:true)
                }
            }
            if fallback != nil { continue } // Keep scanning top candidates without repeating side occlusion work.
            let below = isBelow(start,window:rect)
            let preferred: [Side] = below ? [nearestLowerCorner(start,window:rect)]
                : start.midX < rect.midX ? [.left,.right] : [.right,.left]
            let gripY = below ? rect.minY+cornerGripOffset*scale : rect.minY+rect.height*0.55
            for side in preferred {
                let edge = side == .left ? rect.minX : rect.maxX
                let outside = side == .left ? edge-area.minX : area.maxX-edge
                guard outside >= 100*scale, rect.intersection(area).height >= 260 else { continue }
                let band = NSRect(x:side == .left ? edge-85*scale : edge-15*scale,
                    y:gripY-80*scale,width:100*scale,height:180*scale)
                let covered = rows.prefix(index).contains { front in
                    guard (front[kCGWindowLayer as String] as? Int) == 0, let frontRect = frame(from:front) else { return false }
                    return frontRect.intersection(band).area > band.area*0.85
                }
                if !covered && fallback == nil {
                    fallback = DesktopWindowTarget(id:id,ownerPID:(row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0,
                        owner:row[kCGWindowOwnerName as String] as? String ?? "窗口",frame:rect,side:side)
                }
            }
        }
        return fallback
    }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : max(0,width)*max(0,height) }
}

/// Pure geometry is shared by selection and asset rendering without loading artwork.
enum WindowSeatGeometry {
    static let canvas=NSSize(width:448,height:640)
    static let anchor=NSPoint(x:210,y:205)
    static let unit:CGFloat=147.0/448
    static func destination(character:NSRect,window:NSRect,scale:CGFloat)->NSRect {
        let u=unit*scale
        let right=window.maxX-character.midX,left=character.midX-window.minX
        let x=min(window.maxX-85*scale,max(window.minX+85*scale,character.midX+(right>=left ? 72 : -72)*scale))
        return NSRect(x:x-anchor.x*u,y:window.maxY-anchor.y*u,
                      width:canvas.width*u,height:canvas.height*u)
    }
    static func fits(character:NSRect,window:NSRect,scale:CGFloat,area:NSRect)->Bool {
        let rect=destination(character:character,window:window,scale:scale)
        return character.minY >= window.maxY-12*scale
            && character.midX >= window.minX+85*scale && character.midX <= window.maxX-85*scale
            && area.contains(rect)
    }
    static func entryBounds(character:NSRect,window:NSRect,scale:CGFloat)->NSRect {
        let u=unit*scale,destination=destination(character:character,window:window,scale:scale)
        let initial=NSRect(x:character.midX-224*u,y:character.minY+8*scale,width:448*u,height:640*u)
        let landing=NSRect(x:destination.minX,y:window.maxY-20*u,width:448*u,height:640*u)
        return initial.union(landing).union(destination)
    }
}
