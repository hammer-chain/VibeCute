import AppKit

/// Window-server order describes visibility independently of keyboard focus.
/// Screen coordinates use AppKit's bottom-left origin.
enum CrabPetVisibility {
    struct Window {
        let id:CGWindowID
        let pid:pid_t
        let frame:CGRect
        let visibleRects:[CGRect]
        func contains(_ rect:CGRect)->Bool { visibleRects.contains {$0.contains(rect)} }
    }
    static let supported:Set<String> = ["com.cmuxterm.app","com.apple.terminal","com.googlecode.iterm2","com.mitchellh.ghostty","dev.warp.warp-stable","com.github.wez.wezterm","net.kovidgoyal.kitty","com.microsoft.vscode","com.todesktop.230313mzl4w4u92"]

    static func subtract(_ obstacle:CGRect,from rect:CGRect)->[CGRect] {
        let cut=rect.intersection(obstacle)
        guard !cut.isNull,!cut.isEmpty else {return [rect]}
        return [CGRect(x:rect.minX,y:rect.minY,width:rect.width,height:cut.minY-rect.minY),
                CGRect(x:rect.minX,y:cut.maxY,width:rect.width,height:rect.maxY-cut.maxY),
                CGRect(x:rect.minX,y:cut.minY,width:cut.minX-rect.minX,height:cut.height),
                CGRect(x:cut.maxX,y:cut.minY,width:rect.maxX-cut.maxX,height:cut.height)]
            .filter {$0.width>=2 && $0.height>=2}
    }
    static func windows(on screen:CGRect)->[Window] {
        let pids=Set(NSWorkspace.shared.runningApplications.filter {supported.contains($0.bundleIdentifier?.lowercased() ?? "")}.map(\.processIdentifier))
        let ownPID=ProcessInfo.processInfo.processIdentifier
        let desktopTop=NSScreen.screens.first?.frame.maxY ?? 0
        let rows=CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements],kCGNullWindowID) as? [[String:Any]] ?? []
        var occluders:[CGRect]=[],result:[Window]=[]
        for row in rows {
            guard let pid=row[kCGWindowOwnerPID as String] as? Int,pid != Int(ownPID),
                  (row[kCGWindowLayer as String] as? Int ?? -1)>=0,
                  (row[kCGWindowAlpha as String] as? Double ?? 1)>0.01,
                  let raw=row[kCGWindowBounds as String] as? [String:CGFloat],
                  let x=raw["X"],let y=raw["Y"],let w=raw["Width"],let h=raw["Height"] else {continue}
            let frame=CGRect(x:x,y:desktopTop-y-h,width:w,height:h).intersection(screen)
            guard !frame.isNull,!frame.isEmpty else {continue}
            if pids.contains(pid_t(pid)),(row[kCGWindowLayer as String] as? Int)==0,w>100,h>100,
               let id=row[kCGWindowNumber as String] as? UInt32 {
                var visible=[frame]
                for blocker in occluders {
                    visible=visible.flatMap {subtract(blocker,from:$0)}
                    if visible.count>128 {visible=[];break}
                }
                if !visible.isEmpty {result.append(Window(id:id,pid:pid_t(pid),frame:frame,visibleRects:visible))}
            }
            occluders.append(frame)
        }
        return result
    }
    static func normalized(_ rect:CGRect,on screen:CGRect)->CGRect {
        CGRect(x:(rect.minX-screen.minX)/screen.width,y:(screen.maxY-rect.maxY)/screen.height,
               width:rect.width/screen.width,height:rect.height/screen.height)
    }
}
