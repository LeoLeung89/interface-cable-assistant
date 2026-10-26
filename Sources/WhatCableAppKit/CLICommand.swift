public struct CLICommand: Sendable {
    public let flagNames: Set<String>
    public let helpLines: String
    /// Whether this command reads cable/port data from the hardware, and so
    /// has nothing to show on an unsupported (Intel) Mac. Drives the
    /// unsupported-hardware warning in the CLI.
    ///
    /// Defaults to false because the safe answer is to say nothing: warning
    /// "the output below will be empty" on a command that works fine (e.g.
    /// `--activate`, which is pure network + UserDefaults and works on any
    /// Mac) is worse than staying quiet. Commands that do read hardware opt in.
    public let readsCableData: Bool
    public let matches: @Sendable ([String]) -> Bool
    public let run: @MainActor @Sendable ([String]) async -> Void

    public init(
        flagNames: Set<String>,
        helpLines: String,
        readsCableData: Bool = false,
        matches: @Sendable @escaping ([String]) -> Bool,
        run: @MainActor @Sendable @escaping ([String]) async -> Void
    ) {
        self.flagNames = flagNames
        self.helpLines = helpLines
        self.readsCableData = readsCableData
        self.matches = matches
        self.run = run
    }
}
