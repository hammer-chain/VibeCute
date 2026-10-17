import AVFoundation
import Foundation

/// Keep the output device clock running with zero-valued PCM, without sound.
@main enum SilentOutputClock {
    static func main() throws {
        let engine = AVAudioEngine()
        let format = engine.outputNode.inputFormat(forBus: 0)
        let source = AVAudioSourceNode(format: format) { isSilence, _, _, buffers in
            isSilence.pointee = true
            for buffer in UnsafeMutableAudioBufferListPointer(buffers) {
                if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
            }
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        try engine.start()
        print("Silent output clock running")
        fflush(stdout)
        RunLoop.current.run(until: Date().addingTimeInterval(12))
        engine.stop()
    }
}
