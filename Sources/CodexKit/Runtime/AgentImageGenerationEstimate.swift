import Foundation

/// Presentation-only elapsed-time estimate, matching the inspected desktop loader.
/// This is not provider progress or an ETA. It never reports completion.
public enum AgentImageGenerationEstimate {
    public static func percent(elapsedSeconds: TimeInterval) -> Int {
        guard elapsedSeconds.isFinite else { return elapsedSeconds > 0 ? 99 : 3 }
        let time = max(0, elapsedSeconds) / 45
        let anchors: [(Double, Double)] = [(0, 3), (0.1, 25), (0.55, 58), (0.85, 88), (1, 90)]
        for index in 1..<anchors.count {
            let (startTime, startValue) = anchors[index - 1]
            let (endTime, endValue) = anchors[index]
            if time <= endTime {
                let fraction = (time - startTime) / (endTime - startTime)
                return Int(floor(startValue + fraction * (endValue - startValue)))
            }
        }
        return min(99, Int(floor(90 + 10 * (1 - exp(-1.5 * (time - 1))))))
    }
}
