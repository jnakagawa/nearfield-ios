import CoreBluetooth

// BLE encounter sensing (spec §6.3): advertise our participant id, scan for
// peers', collect raw RSSI per peer. The 5 Hz tick drains the latest reading
// per peer into that peer's PairSensor (nil when unheard — far-timeout applies).
// Foreground only by design (performance app, screen on).
final class NeighborSensor: NSObject, ObservableObject {
    static let serviceUUID = CBUUID(string: "4E454152-4649-454C-4400-000000000001")

    @Published private(set) var bluetoothOn = false
    @Published private(set) var peerCount = 0

    private var peripheralManager: CBPeripheralManager!
    private var centralManager: CBCentralManager!
    private var myId: Int = -1
    private var latestRssi: [Int: Double] = [:]   // peerId -> most recent raw since last tick
    private var sensors: [Int: PairSensor] = [:]
    private var params: Params?

    func start(participantId: Int, params: Params) {
        myId = participantId
        self.params = params
        peripheralManager = CBPeripheralManager(delegate: self, queue: .main)
        centralManager = CBCentralManager(delegate: self, queue: .main)
    }

    /// 5 Hz: run every peer's PairSensor on the latest raw reading (or silence).
    func tick(dt: Double) -> (buckets: [Int: Bucket], encounters: [Int: Bool]) {
        guard let params else { return ([:], [:]) }
        var buckets: [Int: Bucket] = [:]
        var encounters: [Int: Bool] = [:]
        for (id, sensor) in sensors {
            let out = sensor.update(dt: dt, rawRssi: latestRssi[id])
            buckets[id] = out.bucket
            encounters[id] = out.encounterActive
        }
        latestRssi.removeAll(keepingCapacity: true)
        peerCount = sensors.count
        _ = params // silence unused warning path
        return (buckets, encounters)
    }

    private func noteReading(peerId: Int, rssi: Double) {
        guard peerId != myId, rssi < 0 else { return } // 127 = invalid reading
        if sensors[peerId] == nil, let params { sensors[peerId] = PairSensor(params: params) }
        latestRssi[peerId] = rssi
    }
}

extension NeighborSensor: CBPeripheralManagerDelegate {
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        guard peripheral.state == .poweredOn, myId >= 0 else { return }
        peripheral.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [Self.serviceUUID],
            CBAdvertisementDataLocalNameKey: "NF\(myId)",
        ])
    }
}

extension NeighborSensor: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        bluetoothOn = central.state == .poweredOn
        guard central.state == .poweredOn else { return }
        central.scanForPeripherals(withServices: [Self.serviceUUID],
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String,
              name.hasPrefix("NF"), let id = Int(name.dropFirst(2)) else { return }
        noteReading(peerId: id, rssi: RSSI.doubleValue)
    }
}
