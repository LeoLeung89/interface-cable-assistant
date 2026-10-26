import Combine

@MainActor
public protocol WidgetDataContributor: AnyObject {
    func start()
    func stop()
    var changes: AnyPublisher<Void, Never> { get }
    func recentPower(forPortKey key: String) -> [Double]?
    // Current system power in watts plus recent samples. Pro implements this; free returns nil.
    func latestSystemPower() -> (current: Double, history: [Double])?
}

extension WidgetDataContributor {
    public func latestSystemPower() -> (current: Double, history: [Double])? { nil }
}
