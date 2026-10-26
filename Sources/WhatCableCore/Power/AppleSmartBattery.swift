import Foundation

/// Full representation of the AppleSmartBattery IOKit service.
/// One instance per machine (laptops only; desktops have no battery service).
public struct AppleSmartBattery: Equatable, Sendable {
    // MARK: - Battery identity

    public let batteryInstalled: Bool
    public let deviceName: String
    public let serial: String
    public let designCapacity: Int
    public let nominalChargeCapacity: Int
    public let designCycleCount: Int
    public let gasGaugeFirmwareVersion: Int

    // MARK: - Battery state

    public let currentCapacity: Int
    public let maxCapacity: Int
    public let voltage: Int
    public let amperage: Int
    public let instantAmperage: Int
    public let temperature: Int
    public let virtualTemperature: Int
    public let cycleCount: Int
    public let isCharging: Bool
    public let fullyCharged: Bool
    public let externalConnected: Bool
    public let externalChargeCapable: Bool
    public let atCriticalLevel: Bool
    public let timeRemaining: Int
    public let avgTimeToFull: Int
    public let avgTimeToEmpty: Int

    // MARK: - Raw readings

    public let rawCurrentCapacity: Int
    public let rawMaxCapacity: Int
    public let rawBatteryVoltage: Int
    public let rawExternalConnected: Bool

    // MARK: - Configuration

    public let chargerConfiguration: Int
    public let packReserve: Int
    public let postChargeWaitSeconds: Int
    public let postDischargeWaitSeconds: Int
    public let batteryInvalidWakeSeconds: Int
    public let bootVoltage: Int
    public let permanentFailureStatus: Int
    public let batteryCellDisconnectCount: Int

    // MARK: - Timestamps

    public let updateTime: Int
    public let fullPathUpdated: Int
    public let bootPathUpdated: Int
    public let userVisiblePathUpdated: Int

    // MARK: - Charger data

    public let chargerData: ChargerData?

    // MARK: - Carrier mode

    public let carrierMode: CarrierMode?

    // MARK: - Battery shutdown reason

    public let batteryShutdownReason: BatteryShutdownReason?

    // MARK: - Sub-structures (referencing existing types)

    public let adapterDetails: AdapterInfo?
    public let powerTelemetryData: PowerTelemetrySystemData?
    public let portControllerInfo: [PortControllerEntry]
    public let federatedIdentities: [FederatedIdentity]

    public init(
        batteryInstalled: Bool = false,
        deviceName: String = "",
        serial: String = "",
        designCapacity: Int = 0,
        nominalChargeCapacity: Int = 0,
        designCycleCount: Int = 0,
        gasGaugeFirmwareVersion: Int = 0,
        currentCapacity: Int = 0,
        maxCapacity: Int = 0,
        voltage: Int = 0,
        amperage: Int = 0,
        instantAmperage: Int = 0,
        temperature: Int = 0,
        virtualTemperature: Int = 0,
        cycleCount: Int = 0,
        isCharging: Bool = false,
        fullyCharged: Bool = false,
        externalConnected: Bool = false,
        externalChargeCapable: Bool = false,
        atCriticalLevel: Bool = false,
        timeRemaining: Int = 0,
        avgTimeToFull: Int = 0,
        avgTimeToEmpty: Int = 0,
        rawCurrentCapacity: Int = 0,
        rawMaxCapacity: Int = 0,
        rawBatteryVoltage: Int = 0,
        rawExternalConnected: Bool = false,
        chargerConfiguration: Int = 0,
        packReserve: Int = 0,
        postChargeWaitSeconds: Int = 0,
        postDischargeWaitSeconds: Int = 0,
        batteryInvalidWakeSeconds: Int = 0,
        bootVoltage: Int = 0,
        permanentFailureStatus: Int = 0,
        batteryCellDisconnectCount: Int = 0,
        updateTime: Int = 0,
        fullPathUpdated: Int = 0,
        bootPathUpdated: Int = 0,
        userVisiblePathUpdated: Int = 0,
        chargerData: ChargerData? = nil,
        carrierMode: CarrierMode? = nil,
        batteryShutdownReason: BatteryShutdownReason? = nil,
        adapterDetails: AdapterInfo? = nil,
        powerTelemetryData: PowerTelemetrySystemData? = nil,
        portControllerInfo: [PortControllerEntry] = [],
        federatedIdentities: [FederatedIdentity] = []
    ) {
        self.batteryInstalled = batteryInstalled
        self.deviceName = deviceName
        self.serial = serial
        self.designCapacity = designCapacity
        self.nominalChargeCapacity = nominalChargeCapacity
        self.designCycleCount = designCycleCount
        self.gasGaugeFirmwareVersion = gasGaugeFirmwareVersion
        self.currentCapacity = currentCapacity
        self.maxCapacity = maxCapacity
        self.voltage = voltage
        self.amperage = amperage
        self.instantAmperage = instantAmperage
        self.temperature = temperature
        self.virtualTemperature = virtualTemperature
        self.cycleCount = cycleCount
        self.isCharging = isCharging
        self.fullyCharged = fullyCharged
        self.externalConnected = externalConnected
        self.externalChargeCapable = externalChargeCapable
        self.atCriticalLevel = atCriticalLevel
        self.timeRemaining = timeRemaining
        self.avgTimeToFull = avgTimeToFull
        self.avgTimeToEmpty = avgTimeToEmpty
        self.rawCurrentCapacity = rawCurrentCapacity
        self.rawMaxCapacity = rawMaxCapacity
        self.rawBatteryVoltage = rawBatteryVoltage
        self.rawExternalConnected = rawExternalConnected
        self.chargerConfiguration = chargerConfiguration
        self.packReserve = packReserve
        self.postChargeWaitSeconds = postChargeWaitSeconds
        self.postDischargeWaitSeconds = postDischargeWaitSeconds
        self.batteryInvalidWakeSeconds = batteryInvalidWakeSeconds
        self.bootVoltage = bootVoltage
        self.permanentFailureStatus = permanentFailureStatus
        self.batteryCellDisconnectCount = batteryCellDisconnectCount
        self.updateTime = updateTime
        self.fullPathUpdated = fullPathUpdated
        self.bootPathUpdated = bootPathUpdated
        self.userVisiblePathUpdated = userVisiblePathUpdated
        self.chargerData = chargerData
        self.carrierMode = carrierMode
        self.batteryShutdownReason = batteryShutdownReason
        self.adapterDetails = adapterDetails
        self.powerTelemetryData = powerTelemetryData
        self.portControllerInfo = portControllerInfo
        self.federatedIdentities = federatedIdentities
    }
}

// MARK: - Nested types

public struct ChargerData: Equatable, Sendable {
    public let chargingVoltage: Int
    public let chargingCurrent: Int
    public let notChargingReason: Int
    public let slowChargingReason: Int
    public let chargerID: Int
    public let chargerResetCounter: Int
    public let chargerInhibitReason: Int
    public let timeChargingThermallyLimited: Int
    public let vacVoltageLimit: Int

    public init(
        chargingVoltage: Int = 0,
        chargingCurrent: Int = 0,
        notChargingReason: Int = 0,
        slowChargingReason: Int = 0,
        chargerID: Int = 0,
        chargerResetCounter: Int = 0,
        chargerInhibitReason: Int = 0,
        timeChargingThermallyLimited: Int = 0,
        vacVoltageLimit: Int = 0
    ) {
        self.chargingVoltage = chargingVoltage
        self.chargingCurrent = chargingCurrent
        self.notChargingReason = notChargingReason
        self.slowChargingReason = slowChargingReason
        self.chargerID = chargerID
        self.chargerResetCounter = chargerResetCounter
        self.chargerInhibitReason = chargerInhibitReason
        self.timeChargingThermallyLimited = timeChargingThermallyLimited
        self.vacVoltageLimit = vacVoltageLimit
    }
}

public struct CarrierMode: Equatable, Sendable {
    public let lowVoltage: Int
    public let highVoltage: Int
    public let status: Int

    public init(lowVoltage: Int = 0, highVoltage: Int = 0, status: Int = 0) {
        self.lowVoltage = lowVoltage
        self.highVoltage = highVoltage
        self.status = status
    }
}

public struct BatteryShutdownReason: Equatable, Sendable {
    public let shutDownVoltage: Int
    public let shutDownTemperature: Int
    public let shutDownTimestamp: Int
    public let shutDownFullChargeCapacity: Int
    public let shutDownNominalChargeCapacity: Int
    public let shutDownRemainingCapacity: Int
    public let shutDownPassedCharge: Int
    public let dataError: Int
    public let criticalFlags: Int

    public init(
        shutDownVoltage: Int = 0,
        shutDownTemperature: Int = 0,
        shutDownTimestamp: Int = 0,
        shutDownFullChargeCapacity: Int = 0,
        shutDownNominalChargeCapacity: Int = 0,
        shutDownRemainingCapacity: Int = 0,
        shutDownPassedCharge: Int = 0,
        dataError: Int = 0,
        criticalFlags: Int = 0
    ) {
        self.shutDownVoltage = shutDownVoltage
        self.shutDownTemperature = shutDownTemperature
        self.shutDownTimestamp = shutDownTimestamp
        self.shutDownFullChargeCapacity = shutDownFullChargeCapacity
        self.shutDownNominalChargeCapacity = shutDownNominalChargeCapacity
        self.shutDownRemainingCapacity = shutDownRemainingCapacity
        self.shutDownPassedCharge = shutDownPassedCharge
        self.dataError = dataError
        self.criticalFlags = criticalFlags
    }
}

/// System-level power telemetry from AppleSmartBattery's PowerTelemetryData key.
public struct PowerTelemetrySystemData: Equatable, Sendable {
    public let systemVoltageIn: Int
    public let systemCurrentIn: Int
    public let systemPowerIn: Int
    public let systemLoad: Int
    public let batteryPower: Int
    public let wallEnergyEstimate: Int
    public let adapterEfficiencyLoss: Int
    public let systemEnergyConsumed: Int
    public let powerTelemetryErrorCount: Int
    public let accumulatedSystemPowerIn: Int
    public let accumulatedSystemLoad: Int
    public let accumulatedSystemEnergyConsumed: Int
    public let accumulatedWallEnergyEstimate: Int
    public let accumulatedBatteryPower: Int
    public let accumulatedBatteryDischarge: Int
    public let accumulatedAdapterEfficiencyLoss: Int
    public let systemPowerInAccumulatorCount: Int
    public let systemLoadAccumulatorCount: Int
    public let batteryPowerAccumulatorCount: Int
    public let batteryDischargeAccumulatorCount: Int
    public let adapterEfficiencyLossAccumulatorCount: Int

    public init(
        systemVoltageIn: Int = 0,
        systemCurrentIn: Int = 0,
        systemPowerIn: Int = 0,
        systemLoad: Int = 0,
        batteryPower: Int = 0,
        wallEnergyEstimate: Int = 0,
        adapterEfficiencyLoss: Int = 0,
        systemEnergyConsumed: Int = 0,
        powerTelemetryErrorCount: Int = 0,
        accumulatedSystemPowerIn: Int = 0,
        accumulatedSystemLoad: Int = 0,
        accumulatedSystemEnergyConsumed: Int = 0,
        accumulatedWallEnergyEstimate: Int = 0,
        accumulatedBatteryPower: Int = 0,
        accumulatedBatteryDischarge: Int = 0,
        accumulatedAdapterEfficiencyLoss: Int = 0,
        systemPowerInAccumulatorCount: Int = 0,
        systemLoadAccumulatorCount: Int = 0,
        batteryPowerAccumulatorCount: Int = 0,
        batteryDischargeAccumulatorCount: Int = 0,
        adapterEfficiencyLossAccumulatorCount: Int = 0
    ) {
        self.systemVoltageIn = systemVoltageIn
        self.systemCurrentIn = systemCurrentIn
        self.systemPowerIn = systemPowerIn
        self.systemLoad = systemLoad
        self.batteryPower = batteryPower
        self.wallEnergyEstimate = wallEnergyEstimate
        self.adapterEfficiencyLoss = adapterEfficiencyLoss
        self.systemEnergyConsumed = systemEnergyConsumed
        self.powerTelemetryErrorCount = powerTelemetryErrorCount
        self.accumulatedSystemPowerIn = accumulatedSystemPowerIn
        self.accumulatedSystemLoad = accumulatedSystemLoad
        self.accumulatedSystemEnergyConsumed = accumulatedSystemEnergyConsumed
        self.accumulatedWallEnergyEstimate = accumulatedWallEnergyEstimate
        self.accumulatedBatteryPower = accumulatedBatteryPower
        self.accumulatedBatteryDischarge = accumulatedBatteryDischarge
        self.accumulatedAdapterEfficiencyLoss = accumulatedAdapterEfficiencyLoss
        self.systemPowerInAccumulatorCount = systemPowerInAccumulatorCount
        self.systemLoadAccumulatorCount = systemLoadAccumulatorCount
        self.batteryPowerAccumulatorCount = batteryPowerAccumulatorCount
        self.batteryDischargeAccumulatorCount = batteryDischargeAccumulatorCount
        self.adapterEfficiencyLossAccumulatorCount = adapterEfficiencyLossAccumulatorCount
    }
}

/// Per-port controller state from AppleSmartBattery's PortControllerInfo array.
public struct PortControllerEntry: Equatable, Sendable {
    public let portIndex: Int
    public let firmwareVersion: Int
    public let powerState: Int
    public let portMode: Int
    public let maxPower: Int
    public let activeContractRdo: UInt32
    public let numberOfPDOs: Int
    public let numberOfEprPDOs: Int
    public let portPDOs: [UInt32]
    public let fetStatus: Int
    public let bootFlags: Int
    public let capMismatch: Int
    public let attachCount: Int
    public let detachCount: Int
    public let hardResetCount: Int
    public let dataRoleSwapCount: Int
    public let dataRoleSwapFailCount: Int
    public let pwrRoleSwapCount: Int
    public let pwrRoleSwapFailCount: Int
    public let vdoFailCount: Int
    public let shortDetectCount: Int
    public let wakeFailCount: Int
    public let wakeTimeoutCount: Int
    public let sleepCmdFailCount: Int
    public let wakeCmdFailCount: Int
    public let stuckCmdCount: Int
    public let surpriseAckCount: Int
    public let surpriseNackCount: Int
    public let srdyCount: Int
    public let srdoCount: Int
    public let srdyRejectCount: Int
    public let srdoRejectCount: Int
    public let srdoRetryCount: Int
    public let hvEnRecoveryCount: Int
    public let inpFetEnFailCount: Int
    public let i2cErrCount: Int
    public let loserReason: Int
    public let electionFailReason: Int
    public let uvdmStatus: Int
    public let srcTypes: Int
    public let dnSt: Int
    public let pdSt: Int
    public let isSleepEnabled: Bool
    public let sleepDisableTime: Int
    public let sleepDisableCause: Int

    public init(
        portIndex: Int = 0,
        firmwareVersion: Int = 0,
        powerState: Int = 0,
        portMode: Int = 0,
        maxPower: Int = 0,
        activeContractRdo: UInt32 = 0,
        numberOfPDOs: Int = 0,
        numberOfEprPDOs: Int = 0,
        portPDOs: [UInt32] = [],
        fetStatus: Int = 0,
        bootFlags: Int = 0,
        capMismatch: Int = 0,
        attachCount: Int = 0,
        detachCount: Int = 0,
        hardResetCount: Int = 0,
        dataRoleSwapCount: Int = 0,
        dataRoleSwapFailCount: Int = 0,
        pwrRoleSwapCount: Int = 0,
        pwrRoleSwapFailCount: Int = 0,
        vdoFailCount: Int = 0,
        shortDetectCount: Int = 0,
        wakeFailCount: Int = 0,
        wakeTimeoutCount: Int = 0,
        sleepCmdFailCount: Int = 0,
        wakeCmdFailCount: Int = 0,
        stuckCmdCount: Int = 0,
        surpriseAckCount: Int = 0,
        surpriseNackCount: Int = 0,
        srdyCount: Int = 0,
        srdoCount: Int = 0,
        srdyRejectCount: Int = 0,
        srdoRejectCount: Int = 0,
        srdoRetryCount: Int = 0,
        hvEnRecoveryCount: Int = 0,
        inpFetEnFailCount: Int = 0,
        i2cErrCount: Int = 0,
        loserReason: Int = 0,
        electionFailReason: Int = 0,
        uvdmStatus: Int = 0,
        srcTypes: Int = 0,
        dnSt: Int = 0,
        pdSt: Int = 0,
        isSleepEnabled: Bool = false,
        sleepDisableTime: Int = 0,
        sleepDisableCause: Int = 0
    ) {
        self.portIndex = portIndex
        self.firmwareVersion = firmwareVersion
        self.powerState = powerState
        self.portMode = portMode
        self.maxPower = maxPower
        self.activeContractRdo = activeContractRdo
        self.numberOfPDOs = numberOfPDOs
        self.numberOfEprPDOs = numberOfEprPDOs
        self.portPDOs = portPDOs
        self.fetStatus = fetStatus
        self.bootFlags = bootFlags
        self.capMismatch = capMismatch
        self.attachCount = attachCount
        self.detachCount = detachCount
        self.hardResetCount = hardResetCount
        self.dataRoleSwapCount = dataRoleSwapCount
        self.dataRoleSwapFailCount = dataRoleSwapFailCount
        self.pwrRoleSwapCount = pwrRoleSwapCount
        self.pwrRoleSwapFailCount = pwrRoleSwapFailCount
        self.vdoFailCount = vdoFailCount
        self.shortDetectCount = shortDetectCount
        self.wakeFailCount = wakeFailCount
        self.wakeTimeoutCount = wakeTimeoutCount
        self.sleepCmdFailCount = sleepCmdFailCount
        self.wakeCmdFailCount = wakeCmdFailCount
        self.stuckCmdCount = stuckCmdCount
        self.surpriseAckCount = surpriseAckCount
        self.surpriseNackCount = surpriseNackCount
        self.srdyCount = srdyCount
        self.srdoCount = srdoCount
        self.srdyRejectCount = srdyRejectCount
        self.srdoRejectCount = srdoRejectCount
        self.srdoRetryCount = srdoRetryCount
        self.hvEnRecoveryCount = hvEnRecoveryCount
        self.inpFetEnFailCount = inpFetEnFailCount
        self.i2cErrCount = i2cErrCount
        self.loserReason = loserReason
        self.electionFailReason = electionFailReason
        self.uvdmStatus = uvdmStatus
        self.srcTypes = srcTypes
        self.dnSt = dnSt
        self.pdSt = pdSt
        self.isSleepEnabled = isSleepEnabled
        self.sleepDisableTime = sleepDisableTime
        self.sleepDisableCause = sleepDisableCause
    }
}
