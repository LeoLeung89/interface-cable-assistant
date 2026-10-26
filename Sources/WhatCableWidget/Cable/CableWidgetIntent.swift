import AppIntents
import WidgetKit

struct CableWidgetIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Cable Status"
    static var description = IntentDescription("Choose which ports to show.")

    @Parameter(title: "Pin a port")
    var selectedPort: PortChoice?

    @Parameter(title: "Ports to show")
    var selectedPorts: [PortChoice]?
}
