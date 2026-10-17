import Foundation
import CaptionCore

/// Read-only, bounded helper queries. No player automation, playback commands,
/// artwork, browser history, screen reading, or audio recording. The private
/// framework may be unavailable on a future OS; failure clears old evidence.
final class NowPlayingMonitor {
    var onUpdate: ((NowPlayingTrack?, String) -> Void)?
    private var timer: Timer?
    private var process: Process?
    private var generation = 0
    private var deadline: DispatchWorkItem?
    static let script = #"""
    ObjC.import('Foundation');
    function run() {
      try {
        var bundle = $.NSBundle.bundleWithPath('/System/Library/PrivateFrameworks/MediaRemote.framework');
        if (!bundle.load) return JSON.stringify({error:'系统媒体接口不可用'});
        var request = $.NSClassFromString('MRNowPlayingRequest');
        var item = request.localNowPlayingItem;
        var info = item.nowPlayingInfo;
        function get(key) {
          try { var v = ObjC.unwrap(info.objectForKey(key)); return v === undefined ? null : v; }
          catch(e) { return null; }
        }
        var elapsed = null, player = '', contentID = '';
        try { elapsed = item.metadata.calculatedPlaybackPosition; } catch(e) {}
        try { player = ObjC.unwrap(request.localNowPlayingPlayerPath.client.displayName) || ''; } catch(e) {}
        contentID = get('kMRMediaRemoteNowPlayingInfoExternalContentIdentifier') || '';
        return JSON.stringify({title:get('kMRMediaRemoteNowPlayingInfoTitle'),
          artist:get('kMRMediaRemoteNowPlayingInfoArtist'), album:get('kMRMediaRemoteNowPlayingInfoAlbum'),
          duration:get('kMRMediaRemoteNowPlayingInfoDuration'), elapsed:elapsed,
          rate:get('kMRMediaRemoteNowPlayingInfoPlaybackRate'), player:player, contentID:contentID});
      } catch(e) { return JSON.stringify({error:'无法读取系统当前播放信息'}); }
    }
    """#

    func setEnabled(_ enabled: Bool) {
        guard enabled != (timer != nil) else { return }
        stop()
        guard enabled else { onUpdate?(nil, "歌曲彩蛋已关闭"); return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
        self.timer = timer; RunLoop.main.add(timer, forMode: .common)
        refresh()
    }
    func refresh() {
        guard process == nil else { return }
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-l", "JavaScript", "-e", Self.script]
        process.standardOutput = output; process.standardError = FileHandle.nullDevice
        self.process = process
        let token = generation
        // Position is measured within this query; never make it fresher than
        // query start. Its <=3s latency stays visible in the freshness gate.
        let started = ProcessInfo.processInfo.systemUptime
        process.terminationHandler = { [weak self] task in
            let data = output.fileHandleForReading.readDataToEndOfFile()
            DispatchQueue.main.async {
                guard let self, token == self.generation else { return }
                self.deadline?.cancel(); self.deadline = nil; self.process = nil
                guard task.terminationStatus == 0,
                      let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                    self.onUpdate?(nil, "系统播放信息读取失败"); return
                }
                if let error = json["error"] as? String { self.onUpdate?(nil, error); return }
                guard let title = json["title"] as? String, !title.isEmpty else {
                    self.onUpdate?(nil, "系统未提供播放标题"); return
                }
                let track = NowPlayingTrack(title: title, artist: json["artist"] as? String ?? "",
                    album: json["album"] as? String ?? "", player: json["player"] as? String ?? "",
                    contentID: json["contentID"] as? String ?? "", duration: json["duration"] as? Double,
                    elapsed: json["elapsed"] as? Double, rate: json["rate"] as? Double, observedAt: started)
                self.onUpdate?(track, "")
            }
        }
        do { try process.run() } catch {
            self.process = nil; onUpdate?(nil, "无法启动系统媒体读取器"); return
        }
        let deadline = DispatchWorkItem { [weak self, weak process] in
            guard let self, token == self.generation, let process, process.isRunning else { return }
            self.onUpdate?(nil, "系统播放信息读取超时")
            process.terminate()
        }
        self.deadline = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: deadline)
    }
    func stop() {
        generation += 1; timer?.invalidate(); timer = nil; deadline?.cancel(); deadline = nil
        process?.terminationHandler = nil
        if process?.isRunning == true { process?.terminate() }
        process = nil
    }
    deinit { stop() }
}
