import AppKit
@main struct CrossDisplayPlannerChecks {
    static func image(texture: Bool, width: Int = 900, height: Int = 600) -> CGImage {
        let context = CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,
            space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(NSColor.white.cgColor); context.fill(CGRect(x:0,y:0,width:width,height:height))
        if texture {
            context.setFillColor(NSColor.black.cgColor)
            for y in stride(from:0,to:height,by:12) { for x in stride(from:0,to:width,by:12) {
                context.fill(CGRect(x:x,y:y,width:6,height:6))
            } }
        }
        return context.makeImage()!
    }
    static func main() throws {
        let silhouette = BackdropSilhouette(image:image(texture:false,width:24,height:32))
        let origin = CGPoint(x:200,y:120), sprite = CGRect(x:200,y:120,width:126,height:168)
        let primary = try BackdropScene.analyze(image(texture:true),frame:CGRect(x:0,y:0,width:900,height:600),at:0)
        precondition(primary.isObstructed(silhouette:silhouette,sprite:sprite))
        let empty = BackdropAvoidancePlanner.plan(scene:primary,silhouette:silhouette,sprite:sprite,
            panelOrigin:origin,allowedOrigins:CGRect(x:30,y:30,width:600,height:300),scale:1)
        precondition(empty == nil)
        for frame in [CGRect(x:-900,y:96,width:900,height:600),CGRect(x:900,y:0,width:900,height:600),CGRect(x:0,y:600,width:900,height:600)] {
            let scene = try BackdropScene.analyze(image(texture:false),frame:frame,at:0)
            let plan = BackdropAvoidancePlanner.plan(scene:scene,silhouette:silhouette,sprite:sprite,
                panelOrigin:origin,allowedOrigins:frame.insetBy(dx:180,dy:180),scale:1,requireObstruction:false)!
            precondition(scene.isBlank(plan.destinationBody))
            precondition(frame.contains(plan.destinationBody))
            precondition(!primary.isBlank(plan.destinationBody))
            let invalid = BackdropAvoidancePlanner.plan(scene:scene,silhouette:silhouette,sprite:sprite,
                panelOrigin:origin,allowedOrigins:.null,scale:1,requireObstruction:false)
            precondition(invalid == nil)
        }
        print("PASS cross-display coordinates: negative X, right display, vertical display, frame boundaries, unavailable search area")
    }
}
