import Foundation
import AVFoundation

// Seek both real packaged tracks close to the seam and observe the audio clock
// through a wrap, rather than waiting two full minutes or testing play() alone.
let paths = Array(CommandLine.arguments.dropFirst())
precondition(paths.count == 2)
var players: [AVAudioPlayer] = []
var starting: [Double] = [], deviceStarts: [Double] = [], previous: [Double] = []
var wraps = [0,0], maxClockDrift = [0.0,0.0]
for path in paths {
    let p = try AVAudioPlayer(contentsOf:URL(fileURLWithPath:path))
    p.volume = 0; p.numberOfLoops = -1
    precondition(p.prepareToPlay())
    precondition(p.duration > 120)
    p.currentTime = p.duration-0.35
    starting.append(p.currentTime); previous.append(p.currentTime)
    deviceStarts.append(p.deviceCurrentTime)
    precondition(p.play()); players.append(p)
}
let deadline = Date().addingTimeInterval(1.4)
while Date() < deadline {
    RunLoop.current.run(until:Date().addingTimeInterval(0.01))
    for i in players.indices {
        let p = players[i], position = p.currentTime
        precondition(p.isPlaying,"Rain stopped at the loop boundary")
        if position < previous[i]-0.1 { wraps[i] += 1 }
        let audioElapsed = position-starting[i]+Double(wraps[i])*p.duration
        let deviceElapsed = p.deviceCurrentTime-deviceStarts[i]
        maxClockDrift[i] = max(maxClockDrift[i],abs(audioElapsed-deviceElapsed))
        previous[i] = position
    }
}
for i in players.indices {
    precondition(wraps[i] == 1,"Did not cross the actual file boundary")
    precondition(maxClockDrift[i] < 0.12,"Loop paused relative to the output device clock")
}
let report: [String:Any] = ["tracks":paths.map { URL(fileURLWithPath:$0).lastPathComponent },
    "durations":players.map(\.duration),"wraps":wraps,"maxAudioDeviceClockDriftSeconds":maxClockDrift,
    "volume":0,"actualPlaybackBoundaryVerified":true]
players.forEach { $0.stop() }
print(String(data:try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]),encoding:.utf8)!)
