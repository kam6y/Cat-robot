import CoreBluetooth
import Foundation

/// All CoreBluetooth objects stay on the main queue and inside this adapter.
@MainActor
final class CoreBluetoothRobotTransport: NSObject, RobotTransport,
    @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    let events: AsyncStream<RobotTransportEvent>
    private let continuation: AsyncStream<RobotTransportEvent>.Continuation
    private let makeCentral: @MainActor (any CBCentralManagerDelegate) throws -> CBCentralManager
    private var central: CBCentralManager?
    private var known: [UUID: CBPeripheral] = [:]
    private var peripheral: CBPeripheral?
    private var service: CBService?
    private var characteristics: [RobotCharacteristic: CBCharacteristic] = [:]
    private var activeAttempt: UUID?
    private var closing = false

    init(makeCentral: @escaping @MainActor (any CBCentralManagerDelegate) throws -> CBCentralManager = {
        CBCentralManager(delegate: $0, queue: nil,
                         options: [CBCentralManagerOptionShowPowerAlertKey: false])
    }) {
        self.makeCentral = makeCentral
        let stream = AsyncStream<RobotTransportEvent>.makeStream()
        events = stream.stream
        continuation = stream.continuation
        super.init()
    }

    var canSendWriteWithoutResponse: Bool {
        !closing && activeAttempt != nil && peripheral?.state == .connected
            && characteristics[.command] != nil && peripheral?.canSendWriteWithoutResponse == true
    }

    func start() {
        guard central == nil else { return }
        do { central = try makeCentral(self) }
        catch { continuation.yield(.bluetooth(state: .unsupported)) }
    }

    func retrieve(_ id: UUID) {
        guard let central, central.state == .poweredOn else { return }
        if let found = central.retrievePeripherals(withIdentifiers: [id]).first {
            known[id] = found
            continuation.yield(.discovered(device(found, rssi: nil)))
        } else { scan() }
    }

    func scan() {
        guard let central, central.state == .poweredOn, !central.isScanning else { return }
        central.scanForPeripherals(withServices: [CBUUID(nsuuid: RobotProtocol.serviceUUID)], options: nil)
    }
    func stopScan() { central?.stopScan() }

    func connect(_ id: UUID, attempt: UUID) {
        guard activeAttempt == nil else {
            continuation.yield(.failed(attempt: attempt, reason: .notReady))
            return
        }
        activeAttempt = attempt
        closing = false
        characteristics.removeAll()
        service = nil
        guard let central, central.state == .poweredOn, let selected = known[id] else {
            continuation.yield(.failed(attempt: attempt, reason: .notReady))
            return
        }
        peripheral = selected
        selected.delegate = self
        central.connect(selected, options: nil)
    }

    func disconnect(attempt: UUID) {
        guard activeAttempt == attempt else { return }
        closing = true
        characteristics.removeAll()
        service = nil
        if let central, let peripheral {
            central.cancelPeripheralConnection(peripheral)
        } else {
            finish(attempt: attempt, reason: .cancelled)
        }
    }

    func invalidate() {
        // Detaching delegates plus manager identity isolates callbacks whose cancellation never ended.
        central?.delegate = nil
        peripheral?.delegate = nil
        central?.stopScan()
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
        central = nil
        peripheral = nil
        service = nil
        activeAttempt = nil
        closing = false
        known.removeAll()
        characteristics.removeAll()
        start()
    }

    func read(_ characteristic: RobotCharacteristic, attempt: UUID) {
        guard activeAttempt == attempt, !closing, let peripheral,
              let value = characteristics[characteristic], value.properties.contains(.read) else {
            continuation.yield(.failed(attempt: attempt, reason: .notReady))
            return
        }
        peripheral.readValue(for: value)
    }

    func setStatusNotify(_ enabled: Bool, attempt: UUID) {
        guard activeAttempt == attempt, !closing, let peripheral, let status = characteristics[.status] else {
            continuation.yield(.failed(attempt: attempt, reason: .notReady))
            return
        }
        peripheral.setNotifyValue(enabled, for: status)
    }

    func writeCommand(_ data: Data, attempt: UUID) {
        guard activeAttempt == attempt, canSendWriteWithoutResponse,
              let peripheral, let command = characteristics[.command] else {
            continuation.yield(.failed(attempt: attempt, reason: .notReady))
            return
        }
        guard data.count <= peripheral.maximumWriteValueLength(for: .withoutResponse) else {
            continuation.yield(.failed(attempt: attempt, reason: .invalidData))
            return
        }
        peripheral.writeValue(data, for: command, type: .withoutResponse)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central === self.central else { return }
        let state: RobotBluetoothState
        switch central.state {
        case .unknown: state = .unknown
        case .resetting: state = .resetting
        case .unsupported: state = .unsupported
        case .unauthorized: state = .unauthorized
        case .poweredOff: state = .poweredOff
        case .poweredOn: state = .poweredOn
        @unknown default: state = .unsupported
        }
        continuation.yield(.bluetooth(state: state))
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard central === self.central else { return }
        known[peripheral.identifier] = peripheral
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        continuation.yield(.discovered(device(peripheral, name: name, rssi: RSSI.intValue)))
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard central === self.central, peripheral === self.peripheral, activeAttempt != nil, !closing else { return }
        peripheral.discoverServices([CBUUID(nsuuid: RobotProtocol.serviceUUID)])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard central === self.central, peripheral === self.peripheral, let attempt = activeAttempt else { return }
        finish(attempt: attempt, reason: error.map(Self.failure) ?? .disconnected)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard central === self.central, peripheral === self.peripheral, let attempt = activeAttempt else { return }
        finish(attempt: attempt, reason: closing ? .cancelled : error.map(Self.failure) ?? .disconnected)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard accepts(peripheral), let attempt = activeAttempt else { return }
        if let error { fail(error, attempt: attempt); return }
        guard let service = peripheral.services?.first(where: { $0.uuid == CBUUID(nsuuid: RobotProtocol.serviceUUID) }) else {
            continuation.yield(.failed(attempt: attempt, reason: .invalidData))
            return
        }
        self.service = service
        peripheral.discoverCharacteristics(RobotCharacteristic.allCases.map { CBUUID(nsuuid: $0.uuid) }, for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard accepts(peripheral), service === self.service, let attempt = activeAttempt else { return }
        if let error { fail(error, attempt: attempt); return }
        var found: [RobotCharacteristic: CBCharacteristic] = [:]
        for kind in RobotCharacteristic.allCases {
            guard let characteristic = service.characteristics?.first(where: { $0.uuid == CBUUID(nsuuid: kind.uuid) }),
                  hasRequiredProperties(characteristic, kind: kind) else {
                continuation.yield(.failed(attempt: attempt, reason: .invalidData))
                return
            }
            found[kind] = characteristic
        }
        characteristics = found
        continuation.yield(.gattReady(attempt: attempt))
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let (attempt, kind) = accepts(peripheral, characteristic: characteristic) else { return }
        if let error { fail(error, attempt: attempt); return }
        guard let data = characteristic.value else {
            continuation.yield(.failed(attempt: attempt, reason: .invalidData))
            return
        }
        continuation.yield(.value(attempt: attempt, characteristic: kind, data: data))
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard let (attempt, kind) = accepts(peripheral, characteristic: characteristic), kind == .status else { return }
        if let error { fail(error, attempt: attempt); return }
        guard characteristic.isNotifying else {
            continuation.yield(.failed(attempt: attempt, reason: .notReady))
            return
        }
        continuation.yield(.notifyReady(attempt: attempt))
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        guard accepts(peripheral), let attempt = activeAttempt else { return }
        continuation.yield(.readyToWrite(attempt: attempt))
    }

    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        guard accepts(peripheral), let attempt = activeAttempt,
              invalidatedServices.contains(where: { $0 === service }) else { return }
        characteristics.removeAll()
        continuation.yield(.failed(attempt: attempt, reason: .invalidData))
    }

    private func accepts(_ peripheral: CBPeripheral) -> Bool {
        peripheral === self.peripheral && activeAttempt != nil && !closing
    }

    private func accepts(_ peripheral: CBPeripheral, characteristic: CBCharacteristic) -> (UUID, RobotCharacteristic)? {
        guard accepts(peripheral), let attempt = activeAttempt,
              let kind = characteristics.first(where: { $0.value === characteristic })?.key else { return nil }
        return (attempt, kind)
    }

    private func hasRequiredProperties(_ characteristic: CBCharacteristic, kind: RobotCharacteristic) -> Bool {
        switch kind {
        case .command: characteristic.properties.contains(.writeWithoutResponse)
        case .status: characteristic.properties.contains([.read, .notify])
        case .calibration, .limits, .info: characteristic.properties.contains(.read)
        }
    }

    private func device(_ peripheral: CBPeripheral, name: String? = nil, rssi: Int?) -> RobotDevice {
        RobotDevice(id: peripheral.identifier, name: name ?? peripheral.name ?? "CatRobot", rssi: rssi)
    }

    private func finish(attempt: UUID, reason: RobotLinkFailure) {
        peripheral?.delegate = nil
        peripheral = nil
        service = nil
        characteristics.removeAll()
        activeAttempt = nil
        closing = false
        continuation.yield(.disconnected(attempt: attempt, reason: reason))
    }

    private func fail(_ error: Error, attempt: UUID) {
        continuation.yield(.failed(attempt: attempt, reason: Self.failure(for: error)))
    }

    nonisolated static func failure(for error: Error) -> RobotLinkFailure {
        let error = error as NSError
        if error.domain == CBATTErrorDomain,
           [CBATTError.insufficientAuthentication, .insufficientAuthorization,
            .insufficientEncryption, .insufficientEncryptionKeySize].contains(where: { $0.rawValue == error.code }) {
            return .authenticationFailed
        }
        if error.domain == CBErrorDomain,
           [CBError.peerRemovedPairingInformation, .encryptionTimedOut].contains(where: { $0.rawValue == error.code }) {
            return .authenticationFailed
        }
        return .disconnected
    }
}
