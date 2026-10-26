import Foundation

public struct LiquidDetectionStatus: Codable, Sendable, Equatable {
    public let liquidDetected: Bool
    public let state: String
    public let measurementStatus: Int
    public let mitigationsEnabled: Bool

    public init(
        liquidDetected: Bool,
        state: String,
        measurementStatus: Int,
        mitigationsEnabled: Bool
    ) {
        self.liquidDetected = liquidDetected
        self.state = state
        self.measurementStatus = measurementStatus
        self.mitigationsEnabled = mitigationsEnabled
    }
}
