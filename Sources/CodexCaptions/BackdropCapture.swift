import AppKit
import ScreenCaptureKit
import CoreMedia
import CoreImage

/// Capture the composited desktop beneath this app, excluding our own sprite/captions.
final class BackdropCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    enum Failure: LocalizedError {
        case permission, display, empty, timeout
        var errorDescription: String? {
            switch self {
            case .permission: return "系统未允许当前应用读取屏幕 · 请核对录屏授权项指向的应用路径"
            case .display: return "显示器暂时不可用"
            case .empty: return "尚未获取有效屏幕画面"
            case .timeout: return "屏幕读取超时 · 稍后重试"
            }
        }
    }
    private var stream: SCStream?
    private var continuation: CheckedContinuation<CGImage,Error>?
    private let queue = DispatchQueue(label:"captions.backdrop-capture",qos:.utility)
    private let imageContext = CIContext(options:[.cacheIntermediates:false])
    private var fallbackTimeout: DispatchWorkItem?

    func capture(displayID: CGDirectDisplayID) async throws -> CGImage {
        // Let the capture API enforce access. A legacy preflight result alone must not block SCK.
        let content: SCShareableContent
        do { content = try await SCShareableContent.excludingDesktopWindows(false,onScreenWindowsOnly:true) }
        catch {
            if Self.isPermissionFailure(error) { throw Failure.permission }
            throw error
        }
        return try await capture(displayID:displayID,content:content)
    }
    // Discover shareable content once per observation, rather than once per display.
    func capture(displayIDs: [CGDirectDisplayID]) async throws -> [CGImage] {
        let content = try await SCShareableContent.excludingDesktopWindows(false,onScreenWindowsOnly:true)
        var images: [CGImage] = []
        for id in displayIDs { images.append(try await capture(displayID:id,content:content)) }
        return images
    }
    private func capture(displayID: CGDirectDisplayID, content: SCShareableContent) async throws -> CGImage {
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else { throw Failure.display }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let ownApps = content.applications.filter { $0.processID == ownPID }
        let filter = SCContentFilter(display:display,excludingApplications:ownApps,exceptingWindows:[])
        let config = SCStreamConfiguration()
        config.width = display.width; config.height = display.height
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false; config.capturesAudio = false
        config.queueDepth = 3
        config.minimumFrameInterval = CMTime(value:1,timescale:5)
        if #available(macOS 14.0, *) {
            return try await SCScreenshotManager.captureImage(contentFilter:filter,configuration:config)
        }
        // macOS 13 lacks SCScreenshotManager; stop this stream after its first complete frame.
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.continuation = continuation
                let stream = SCStream(filter:filter,configuration:config,delegate:self)
                self.stream = stream
                do {
                    try stream.addStreamOutput(self,type:.screen,sampleHandlerQueue:self.queue)
                    let timeout = DispatchWorkItem { self.finish(.failure(Failure.timeout)) }
                    self.fallbackTimeout = timeout
                    self.queue.asyncAfter(deadline:.now()+4,execute:timeout)
                    stream.startCapture { error in
                        if let error { self.queue.async { self.finish(.failure(error)) } }
                    }
                } catch { self.finish(.failure(error)) }
            }
        }
    }
    static func isPermissionFailure(_ error: Error) -> Bool {
        if let failure = error as? Failure, case .permission = failure { return true }
        let error = error as NSError
        return error.domain == SCStreamErrorDomain && error.code == SCStreamError.Code.userDeclined.rawValue
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, buffer.isValid, continuation != nil,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer,createIfNecessary:false) as? [[SCStreamFrameInfo:Any]],
              let status = attachments.first?[.status] as? Int, status == SCFrameStatus.complete.rawValue,
              let pixels = buffer.imageBuffer else { return }
        let input = CIImage(cvPixelBuffer:pixels)
        guard let image = imageContext.createCGImage(input,from:input.extent) else { return }
        finish(.success(image))
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async { self.finish(.failure(error)) }
    }
    private func finish(_ result: Result<CGImage,Error>) {
        guard let continuation else { return }
        self.continuation = nil
        fallbackTimeout?.cancel(); fallbackTimeout = nil
        let previous = stream; stream = nil
        previous?.stopCapture(completionHandler:nil)
        continuation.resume(with:result)
    }
}
