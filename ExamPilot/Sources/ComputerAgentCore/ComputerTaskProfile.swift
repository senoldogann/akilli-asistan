public struct ComputerTaskProfile: Equatable, Sendable {
    public let maxActions: Int
    public let maxWaitMilliseconds: Int
    public let maxAbsoluteScroll: Int

    public init(
        maxActions: Int = 12,
        maxWaitMilliseconds: Int = 5_000,
        maxAbsoluteScroll: Int = 1_400
    ) {
        self.maxActions = maxActions
        self.maxWaitMilliseconds = maxWaitMilliseconds
        self.maxAbsoluteScroll = maxAbsoluteScroll
    }
}
