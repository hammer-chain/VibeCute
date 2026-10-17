import Foundation

/// Eye coordinates loaded once with the animation artwork.
struct ThinkingGazeRegistration: Decodable {
    struct Eye: Decodable {
        let irisCenter: [Double], irisScale: [Double]
        let rotationDegrees: Double
        /// Move point followed by cubic controls/end points, top origin.
        let aperture: [[Double]]
    }
    let referenceCenters: [[Double]], maximumOffset: [Double]
    /// Top-origin coordinates of each pose. Empty eyes mean fully closed.
    let frames: [[Eye]]

    // Array shapes required by the renderer; no character or asset comparison.
    var drawable: Bool {
        referenceCenters.count == 2 && referenceCenters.allSatisfy { $0.count == 2 }
            && maximumOffset.count == 2
            && frames.allSatisfy { eyes in
                (eyes.isEmpty || eyes.count == 2) && eyes.allSatisfy {
                    $0.irisCenter.count == 2 && $0.irisScale.count == 2
                        && !$0.aperture.isEmpty
                        && $0.aperture.enumerated().allSatisfy { index, points in
                            points.count == (index == 0 ? 2 : 6)
                        }
                }
            }
    }
}
