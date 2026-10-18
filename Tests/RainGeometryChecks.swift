// bash test.sh compiles the actual Sources/Geometry.swift, without AppKit.
var assertions = 0
func check(_ condition: @autoclosure () -> Bool, _ name: String) {
    assertions += 1
    if !condition() { fatalError("FAIL: \(name)") }
}
func p(_ x: Double, _ y: Double) -> RainPoint { RainPoint(x: x, y: y) }
func close(_ a: Double?, _ b: Double) -> Bool { a.map { abs($0 - b) < 1e-8 } ?? false }
let upper = RainRect(x: 100, y: 200, width: 300, height: 150)
let lower = RainRect(x: 250, y: 400, width: 300, height: 150)
var field = RoofField(windows: [lower, upper])
check(close(field.firstImpact(from: p(300, 0), to: p(300, 800))?.point.y, 200), "nearest overlapping roof wins")
check(close(field.firstImpact(from: p(300, 190), to: p(300, 230))?.point.y, 200), "swept collision cannot tunnel")
check(field.isSheltered(p(300, 2000), wind: 0), "infinite vertical shadow")
check(!field.isSheltered(p(99, 2000), wind: 0), "outside vertical column")
check(field.isSheltered(p(100, 300), wind: 0), "exact left contact is blocked")
check(field.isSheltered(p(550, 500), wind: 0), "exact right contact is blocked")
check(!field.isSheltered(p(551, 500), wind: 0), "outside right contact is clear")
check(!field.isSheltered(p(300, 199), wind: 0), "above roof")
field.windows = [lower]
check(!field.isSheltered(p(150, 800), wind: 0), "removing window exposes old column")
field.windows = [RainRect(x: -800, y: -400, width: 400, height: 100)]
check(field.isSheltered(p(-600, 0), wind: 0), "negative screen coordinates")
let screen = quartzRect(appKit: RainRect(x: -1200, y: 200, width: 1200, height: 900), mainDisplayTop: 900)
check(screen == RainRect(x: -1200, y: -200, width: 1200, height: 900), "multi-screen conversion")
field.windows = [RainRect(x: 100, y: 100, width: 100, height: 100)]
check(field.isSheltered(p(300, 300), wind: 1), "rightward diagonal rain shadow")
check(!field.isSheltered(p(110, 350), wind: 1), "old vertical shadow is exposed in wind")
check(field.isSheltered(p(0, 300), wind: -1), "leftward diagonal shadow")
check(!field.isSheltered(p(190, 350), wind: -1), "left wind exposes old vertical shadow")
check(field.isSheltered(p(150, 150), wind: 0.85), "window interior is always sheltered")
check(!field.isSheltered(p(90, 150), wind: 0.85), "windward side exposed")
let leftHit = field.firstImpact(from: p(50, 120), to: p(150, 170))
check(leftHit?.point == p(100, 145), "angled ray hits side, not just roof")
check(leftHit?.normal == p(-1, 0), "left side outward normal")
let rightHit = field.firstImpact(from: p(250, 120), to: p(150, 170))
check(rightHit?.point == p(200, 145), "left wind hits right side")
check(rightHit?.normal == p(1, 0), "right side outward normal")
check(field.firstImpact(from: p(0, 0), to: p(50, 50)) == nil, "intersection beyond segment rejected")
check(field.firstImpact(from: p(50, 110), to: p(250, 190)) != nil, "thin traversal cannot tunnel")
check(field.isSheltered(p(99.5, 160), wind: 0, padding: 1), "render radius protected")
check(!field.isSheltered(p(99.5, 160), wind: 0), "unpadded exterior clear")
check(rayHit(origin: p(50, 150), direction: p(0, -1), rect: field.windows[0]) == nil, "parallel ray misses slab")
check(rayHit(origin: p(150, 150), direction: p(0, 0), rect: field.windows[0]) == nil, "zero direction rejected")
let floor = floorImpact(from: p(10, 90), to: p(30, 110), floorY: 100)
check(floor?.point == p(20, 100), "floor intersection interpolates angled x")
check(floor?.normal == p(0, -1), "floor normal launches splash upward")
check(close(floor?.time, 0.5), "floor collision segment fraction")
check(floorImpact(from: p(10, 90), to: p(30, 80), floorY: 100) == nil, "upward splash is not a floor hit")
check(floorImpact(from: p(10, 80), to: p(30, 90), floorY: 100) == nil, "floor not yet crossed")
let splashStart = floor!.point + floor!.normal * 2
let splashNext = splashStart + p(40, -80) * (1.0 / 30.0)
check(splashNext.y + 1 < 100, "new floor splash survives first frame above bottom")
field.windows = [RainRect(x: 0, y: 0, width: 0, height: 200)]
check(!field.isSheltered(p(0, 100), wind: 0), "degenerate rectangle ignored")
// Changing wind keeps exposed particles and removes only newly sheltered ones.
field.windows = [RainRect(x: 100, y: 100, width: 100, height: 100)]
let movingDrop = p(300, 300)
check(!field.isSheltered(movingDrop, wind: 0), "existing drop exposed before wind change")
check(field.isSheltered(movingDrop, wind: 1), "new angled shadow rejects existing drop")
check(!field.isSheltered(p(20, 300), wind: 0.85), "unaffected drop survives new wind")
check(!field.isSheltered(p(20, 300), wind: 0.85, padding: 1.15), "size growth keeps far exposed drops")
print("Passed \(assertions) geometry assertions.")
