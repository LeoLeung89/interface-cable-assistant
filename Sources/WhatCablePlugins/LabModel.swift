import Foundation
import Combine
import AppKit
import WhatCableCore
import WhatCableDarwinBackend

@MainActor
final class LabModel: ObservableObject {
    @Published private(set) var snapshot: CableSnapshot?
    @Published private(set) var power: PowerMonitorSnapshot?
    @Published private(set) var history = LabHistory()
    @Published var names: [NamedCable] = []
    @Published var nativeLabels = LabNativeLabels()
    var nativeLabelsWritable = true
    @Published private(set) var bindings = LabBindings()
    @Published var error: String?
    @Published var selectedPort: String = ""
    @Published var chartSeries: String = "system"
    @Published var engine = LabArchiveEngine()
    @Published var storageError: String?
    let recordsArchive: Bool
    let storageDirectory: URL
    let archiveStore: LabArchiveStore
    var archiveWritable = true
    var lastFlush = Date.distantPast
    var lastPowerSource: Bool?
    var windowVisible = true
    var archive: LabArchive { engine.archive }
    let widgetWriter = LabWidgetWriter()
    let service: PowerService
    private let hub = WatcherHub.shared
    private var subscriptions = Set<AnyCancellable>()
    private var running = false
    private var nameStoreReadable = true
    private let namesURL: URL

    init(storageDirectory: URL? = nil, recordsArchive: Bool = false) {
        self.recordsArchive = recordsArchive
        service = PowerService(smcReader: WatcherHub.shared.smcReader)
        self.storageDirectory = storageDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WhatCableLab")
        namesURL = self.storageDirectory.appendingPathComponent("cables.json")
        archiveStore = LabArchiveStore(url: self.storageDirectory.appendingPathComponent("archive-v1.json"))
        do {
            if FileManager.default.fileExists(atPath: namesURL.path) {
                names = try JSONDecoder().decode([NamedCable].self, from: Data(contentsOf: namesURL))
            }
        } catch {
            nameStoreReadable = false
            self.error = "线缆名称文件读取失败，已暂停写入以保护现有记录：\(error.localizedDescription)"
        }
        do {
            let url = self.storageDirectory.appendingPathComponent("native-display-labels-v1.json")
            if FileManager.default.fileExists(atPath: url.path) {
                nativeLabels = try LabNativeLabels.decode(Data(contentsOf: url))
            }
        } catch {
            nativeLabelsWritable = false
            self.error = "HDMI 名称文件读取失败，已暂停写入以保护记录。"
        }
        if recordsArchive {
            do { engine = LabArchiveEngine(archive: try archiveStore.load()) }
            catch {
                archiveWritable = false
                storageError = "历史文件读取失败，已停止历史写入：\(error.localizedDescription)"
            }
        }
    }

    var context: CableSnapshotContext? { snapshot.map(CableSnapshotContext.init) }
    var ports: [CableSnapshotContext.PortContext] { context?.portContexts ?? [] }
    var selected: CableSnapshotContext.PortContext? { ports.first { $0.port.portKey == selectedPort } }
    var selectedName: NamedCable? {
        guard let id = bindings.assignments[selectedPort] else { return nil }
        return names.first { $0.id == id }
    }

    func start() {
        guard !running else { return }
        running = true
        hub.start()
        hub.setSurfaceVisible(true, surface: "independent-lab")
        hub.didRefresh.sink { [weak self] in self?.capture() }.store(in: &subscriptions)
        service.$latestSnapshot.compactMap { $0 }.sink { [weak self] sample in
            guard let self else { return }
            self.power = sample
            self.history.append(sample)
            self.recordPower(sample)
            self.widgetWriter.publish(model: self)
        }.store(in: &subscriptions)
        capture()
        service.start()
        if recordsArchive {
            NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
                .sink { [weak self] _ in self?.shutdown() }.store(in: &subscriptions)
            NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)
                .sink { [weak self] _ in
                    self?.engine.invalidatePower(); self?.flush(force: true)
                }.store(in: &subscriptions)
        }
    }

    func stop() {
        guard running else { return }
        running = false
        shutdown()
        subscriptions.removeAll()
        service.stop()
        power = nil
        hub.setSurfaceVisible(false, surface: "independent-lab")
        bindings = LabBindings()
        history = LabHistory()
    }

    func refresh() { hub.refreshAll() }

    func capture() {
        let battery = AppleSmartBatteryReader.read()
        let current = CableSnapshot(
            ports: hub.portWatcher.ports, powerSources: hub.powerWatcher.sources,
            identities: hub.pdWatcher.identities, usbDevices: hub.deviceWatcher.devices,
            adapter: SystemPower.currentAdapter(), thunderboltSwitches: hub.tbWatcher.switches,
            isDesktopMac: battery.isDesktopMac, federatedIdentities: battery.federatedIdentities,
            usb3Transports: hub.usb3Watcher.transports, trmTransports: hub.trmWatcher.transports,
            cioCapabilities: hub.trmWatcher.cioCapabilities,
            accessoryIdentities: hub.uvdmWatcher.identities,
            displayPorts: hub.displayWatcher.statuses.map(\.status),
            batteryFullyCharged: battery.battery?.fullyCharged,
            batteryIsCharging: battery.battery?.isCharging,
            batteryChargeState: hub.powerWatcher.batteryChargeState)
        let ctx = CableSnapshotContext(snapshot: current)
        if let previous = context {
            for pc in ctx.portContexts {
                guard let key = pc.port.portKey,
                      let old = previous.portContexts.first(where: { $0.port.portKey == key }),
                      let a = LabCableIdentity.fingerprint(old.cableEmarker),
                      let b = LabCableIdentity.fingerprint(pc.cableEmarker), a != b else { continue }
                bindings.assign(nil, to: key)
                history.breakSeries(key)
                if key == power?.resistancePortKey { service.resetResistanceBaseline() }
            }
        }
        let tokens = Dictionary(uniqueKeysWithValues: ctx.portContexts.compactMap { pc -> (String, String)? in
            guard let key = pc.port.portKey, let token = LabCableIdentity.sessionToken(pc) else { return nil }
            return (key, token)
        })
        for key in Set(bindings.tokens.keys).union(tokens.keys) where bindings.tokens[key] != tokens[key] {
            history.breakSeries(key)
            if key == power?.resistancePortKey { service.resetResistanceBaseline() }
        }
        bindings.update(tokens)
        snapshot = current
        service.updatePorts(current.ports)
        if !ctx.portContexts.contains(where: { $0.port.portKey == selectedPort }) {
            selectedPort = ctx.portContexts.first(where: { $0.port.connectionActive == true })?.port.portKey
                ?? ctx.portContexts.first?.port.portKey ?? ""
        }
        recordConnections()
        widgetWriter.publish(model: self)
    }

    func assign(_ id: UUID?) {
        bindings.assign(id, to: selectedPort)
        engine.assign(id, port: selectedPort)
        flush(force: true)
        widgetWriter.publish(model: self, force: true)
    }

    func saveName(_ input: String) {
        let name = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80, bindings.tokens[selectedPort] != nil else { return }
        guard nameStoreReadable else { return }
        var updated = names
        let id: UUID
        if let existing = selectedName, let index = updated.firstIndex(where: { $0.id == existing.id }) {
            updated[index].name = name
            id = existing.id
        } else {
            let entry = NamedCable(name: name, fingerprint: LabCableIdentity.fingerprint(selected?.cableEmarker))
            updated.append(entry)
            id = entry.id
        }
        do {
            try persist(updated)
            names = updated
            assign(id)
            error = nil
        } catch { self.error = "名称保存失败：\(error.localizedDescription)" }
    }

    func deleteName(_ id: UUID) {
        guard nameStoreReadable else { return }
        let updated = names.filter { $0.id != id }
        do {
            try persist(updated)
            names = updated
            for (port, assigned) in bindings.assignments where assigned == id { bindings.assign(nil, to: port) }
        } catch { self.error = "名称删除失败：\(error.localizedDescription)" }
    }

    func persist(_ records: [NamedCable]) throws {
        try FileManager.default.createDirectory(at: namesURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(records).write(to: namesURL, options: .atomic)
    }

    func charging(_ pc: CableSnapshotContext.PortContext) -> ChargingDiagnostic? {
        guard let c = context else { return nil }
        return ChargingDiagnostic(port: pc.port, sources: pc.portSources, identities: pc.portIdentities,
            adapter: c.adapter, wattageSource: pc.chargerWattageSource,
            batteryFullyCharged: c.batteryFullyCharged, batteryIsCharging: c.batteryIsCharging,
            batteryChargeState: c.batteryChargeState, anotherPortActivelyCharging: pc.anotherPortActivelyCharging,
            federatedIdentities: c.federatedIdentities)
    }

    func dataLink(_ pc: CableSnapshotContext.PortContext) -> DataLinkDiagnostic? {
        DataLinkDiagnostic(port: pc.port, identities: pc.portIdentities, devices: pc.attributedDevices,
            usb3Transports: pc.portUSB3, cio: pc.portCIO, thunderboltSwitches: snapshot?.thunderboltSwitches ?? [])
    }

    func display(_ dp: IOPortTransportStateDisplayPort, pc: CableSnapshotContext.PortContext?) -> DisplayDiagnostic? {
        DisplayDiagnostic(dp: dp, cable: pc?.cableEmarker,
            billboardPresent: pc.map { $0.port.hasBillboardDevice(among: $0.attributedDevices) } ?? false,
            port: pc?.port)
    }

    func exportCSV() -> String {
        var output = "timestamp,series,segment,power_W\n"
        let formatter = ISO8601DateFormatter()
        for p in history.points {
            output += "\(formatter.string(from: p.timestamp)),\(p.series),\(p.segment),\(String(format: "%.4f", locale: Locale(identifier: "en_US_POSIX"), p.watts))\n"
        }
        return output
    }
}
