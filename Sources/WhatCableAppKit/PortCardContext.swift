public struct PortCardContext: Sendable {
    public let portKey: String?
    public let portNumber: Int?
    public let serviceName: String
    public let portTypeDescription: String?
    /// Raw pin configuration dict from IOKit, e.g. ["tx1": "6", "rx1": "5", ...].
    public let pinConfiguration: [String: String]
    /// Plug orientation from IOKit. 0 = unknown, 1 = normal, 2 = flipped.
    public let plugOrientation: Int?

    public init(
        portKey: String?,
        portNumber: Int?,
        serviceName: String,
        portTypeDescription: String?,
        pinConfiguration: [String: String] = [:],
        plugOrientation: Int? = nil
    ) {
        self.portKey = portKey
        self.portNumber = portNumber
        self.serviceName = serviceName
        self.portTypeDescription = portTypeDescription
        self.pinConfiguration = pinConfiguration
        self.plugOrientation = plugOrientation
    }
}
