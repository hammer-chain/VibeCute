import AppKit
import QuartzCore
@main struct RainPerformanceChecks {
    static func main() throws {
        _ = NSApplication.shared
        var rows: [[String: Any]] = []
        for count in [0,40,160] {
            for preview in DesktopWeatherPreview.allCases {
              for basinCount in [0,2] {
                let view = RainView(frame: NSRect(x: 0, y: 0, width: 2560, height: 1440),
                                    region: RainRect(x: 0, y: 0, width: 2560, height: 1440))
                let field = RoofField(windows: (0..<count).map { RainRect(x: Double($0 * 25), y: 1600, width: 120, height: 180) })
                var basins: [RainBasinSurface] = []
                for i in 0..<basinCount {
                    var points: [RainPoint] = []
                    for j in 0..<9 {
                        let x = Double(100+i*1000+j*12)
                        let offset = Double(j-4)
                        let y = Double(500+i*200)+offset*offset
                        points.append(RainPoint(x:x,y:y))
                    }
                    basins.append(RainBasinSurface(source:String(i),points:points,scale:1)!)
                }
                var times: [Double] = [], peak = 0
                for frame in 0..<450 {
                    let start = CACurrentMediaTime()
                    view.step(dt: 1/30, field: field, enabled: true, settings: preview.settings,basins:basins)
                    let ms = (CACurrentMediaTime() - start) * 1000
                    if frame >= 150 { times.append(ms) }
                    peak = max(peak, view.particleCount)
                }
                times.sort(); let p95 = times[Int(Double(times.count-1)*0.95)]
                precondition(peak <= (preview == .snow ? 240 : 2200))
                precondition(p95 < 16, "Optimized simulation consumes over half the 30 FPS frame budget")
                rows.append(["style": preview.rawValue, "roofs":count,"basins":basinCount, "width":2560, "height":1440,
                             "frames":300, "peakParticles":peak, "p95StepMs":p95,
                             "meanStepMs":times.reduce(0,+)/Double(times.count)])
              }
            }
        }
        try JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys,.prettyPrinted])
            .write(to: URL(fileURLWithPath:"output/desktop-rain/optimized-performance.json"))
        // Separate software bitmap drawing from simulation. Same view/backing size,
        // no window capture or desktop content; export a few actual bolt variants.
        let render = RainView(frame:NSRect(x:0,y:0,width:1280,height:800),
                              region:RainRect(x:0,y:0,width:1280,height:800))
        let bitmap = render.bitmapImageRepForCachingDisplay(in:render.bounds)!
        var drawing: [[String:Any]] = []
        for flashing in [false,true] {
            var samples: [Double] = []
            for i in 0..<60 {
                let cycle = i/15
                let event = WeatherStormTiming.event(at:Double(cycle)*12,seed:42)
                render.step(dt:0,field:RoofField(),enabled:true,settings:RainSettings(style:.thunder),
                            weatherTime:flashing ? event.lightningAt+0.025 : Double(cycle)*12,stormSeed:42)
                let start = CACurrentMediaTime()
                render.cacheDisplay(in:render.bounds,to:bitmap)
                if i >= 10 { samples.append((CACurrentMediaTime()-start)*1000) }
                if flashing && i%15 == 0 {
                    let flat = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:bitmap.pixelsWide,pixelsHigh:bitmap.pixelsHigh,
                        bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
                    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:flat)
                    let rect = NSRect(x:0,y:0,width:flat.pixelsWide,height:flat.pixelsHigh)
                    NSColor(calibratedRed:0.04,green:0.07,blue:0.12,alpha:1).setFill(); rect.fill()
                    NSGraphicsContext.current!.cgContext.draw(bitmap.cgImage!,in:rect)
                    NSGraphicsContext.restoreGraphicsState()
                    try flat.representation(using:.png,properties:[:])!.write(to:
                        URL(fileURLWithPath:"output/desktop-rain/lightning-\(cycle).png"))
                }
            }
            samples.sort()
            drawing.append(["flashing":flashing,"p95DrawMs":samples[Int(Double(samples.count-1)*0.95)],
                            "samples":samples.count,"bitmapWidth":bitmap.pixelsWide,"bitmapHeight":bitmap.pixelsHigh])
        }
        try JSONSerialization.data(withJSONObject:drawing,options:[.sortedKeys,.prettyPrinted])
            .write(to:URL(fileURLWithPath:"output/desktop-rain/lightning-draw-performance.json"))
        print("Optimized weather simulation budget passed for \(DesktopWeatherPreview.allCases.count) styles × 0/40/160 roofs × 0/2 basins")
    }
}
