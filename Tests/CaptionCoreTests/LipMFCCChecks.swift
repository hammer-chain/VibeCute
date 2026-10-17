import Foundation
import CaptionCore

enum LipMFCCChecks {
    static func run() {
        let mfcc = LipMFCC()
        var power = [Float](repeating: 0.001, count: 512)
        power[40] = 4; power[80] = 2; power[160] = 1
        let features = mfcc.features(power: power)!
        let quieter = mfcc.features(power: power.map { $0 * 0.01 })!
        precondition(zip(features, quieter).allSatisfy { abs($0 - $1) < 0.0001 }, "MFCC families must not depend on gain")
        precondition(mfcc.features(power: Array(repeating: 0, count: 512)) == nil)
        precondition(mfcc.features(power: [1]) == nil)
        power[20] = .nan; precondition(mfcc.features(power: power) == nil)
        let families: [MouthShape] = [.ah, .eh, .ee, .oh, .oo]
        let templates = families.enumerated().map { index, shape in
            LipVowelProfile.Template(shape: shape, features: [Float](repeating: Float(index * 4), count: 12))
        }
        let profile = LipVowelProfile(scale: Array(repeating: 1, count: 12), templates: templates)
        precondition(profile.isValid)
        for (index, shape) in families.enumerated() {
            let match = profile.match(Array(repeating: Float(index * 4), count: 12))!
            precondition(match.shape == shape && match.confidence > 0.99)
        }
        precondition(profile.match(Array(repeating: 100, count: 12))!.confidence < 0.01,
                     "Far-away spectral features must not receive a confident vowel")
        precondition(profile.match(Array(repeating: .infinity, count: 12)) == nil)
        precondition(!LipVowelProfile(scale: Array(repeating: 0, count: 12), templates: templates).isValid)
        precondition(!LipVowelProfile(scale: Array(repeating: 1, count: 12), templates: Array(templates.prefix(4))).isValid)
        let restored = try! JSONDecoder().decode(LipVowelProfile.self, from: JSONEncoder().encode(profile))
        precondition(restored.isValid && restored.match(Array(repeating: 8, count: 12))!.shape == .ee)
        print("PASS: MFCC gain invariance, invalid input/profile rejection and bounded confidence")
    }
}
