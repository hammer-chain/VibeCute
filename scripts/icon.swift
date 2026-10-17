import AppKit

let output = CommandLine.arguments[1]
let size: CGFloat = 512
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
NSColor(calibratedRed: 0.08, green: 0.13, blue: 0.15, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 20, y: 20, width: 472, height: 472), xRadius: 108, yRadius: 108).fill()
NSColor(calibratedRed: 0.55, green: 0.93, blue: 0.79, alpha: 1).setStroke()
let bubble = NSBezierPath(roundedRect: NSRect(x: 100, y: 138, width: 312, height: 236), xRadius: 45, yRadius: 45)
bubble.lineWidth = 15; bubble.stroke()
NSColor.white.setFill()
for rect in [NSRect(x: 145, y: 274, width: 220, height: 18), NSRect(x: 174, y: 224, width: 162, height: 18)] {
    NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9).fill()
}
image.unlockFocus()
// An ICNS container with a 512 px PNG element; no external image dependencies.
let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
let png = rep.representation(using: .png, properties: [:])!
func integer(_ value: Int) -> Data { var v = UInt32(value).bigEndian; return Data(bytes: &v, count: 4) }
var icns = Data("icns".utf8); icns.append(integer(png.count + 16))
icns.append(Data("ic09".utf8)); icns.append(integer(png.count + 8)); icns.append(png)
try icns.write(to: URL(fileURLWithPath: output))
