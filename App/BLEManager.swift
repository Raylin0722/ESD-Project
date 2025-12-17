
import Foundation
import CoreBluetooth
import Combine

/// BLE 管理器：負責連線樹莓派並收發文字指令
final class BLEManager: NSObject, ObservableObject {
    // MARK: - Published 狀態給 UI 用
    @Published var isPoweredOn: Bool = false
    @Published var isConnected: Bool = false
    @Published var statusText: String = "未連線"
    @Published var discoveredDevices: [DiscoveredDevice] = []

    /// 最近一次讀到的 RSSI
    @Published var currentRSSI: Int? = nil

    // MARK: - 內部 CoreBluetooth 物件
    private var central: CBCentralManager!
    private var targetPeripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?

    // MARK: - 對外 Publisher：收到的文字
    let receivedText = PassthroughSubject<String, Never>()

    // Pi 端 service / characteristic UUID
    private let targetName = "Pi-BLE"
    private let serviceUUID = CBUUID(string: "12341000-1234-1234-1234-1234567890ab")
    private let charUUID    = CBUUID(string: "12341001-1234-1234-1234-1234567890ab")

    private var cancellables = Set<AnyCancellable>()

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    // MARK: - Public API

    func connect() {
        guard isPoweredOn else {
            statusText = "請開啟藍牙"
            return
        }
        statusText = "掃描裝置中..."
        discoveredDevices.removeAll()
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    func disconnect() {
        if let p = targetPeripheral {
            central.cancelPeripheralConnection(p)
        }
    }

    func send(text: String) {
        guard let p = targetPeripheral,
              let c = writeCharacteristic else {
            print("[BLE] no connected peripheral/characteristic")
            return
        }
        let payload = (text + "\n")
        guard let data = payload.data(using: .utf8) else { return }
        p.writeValue(data, for: c, type: .withResponse)
        print("[BLE] send:", payload)
    }

    func requestRSSI() {
        targetPeripheral?.readRSSI()
    }
}

// MARK: - CBCentralManagerDelegate
extension BLEManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            isPoweredOn = true
            statusText = "藍牙已開啟"
        case .poweredOff:
            isPoweredOn = false
            isConnected = false
            statusText = "藍牙未開啟"
        default:
            isPoweredOn = false
            statusText = "藍牙狀態：\(central.state.rawValue)"
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String : Any],
                        rssi RSSI: NSNumber) {
        // 先拿廣播的 local name，再退而求其次用 peripheral.name
        let localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let fallbackName = peripheral.name
        let displayName = localName ?? fallbackName ?? "Unknown"
        
        // debug：把掃到的東西都印出來
        print("[BLE] scanned: \(displayName) (\(RSSI.intValue) dBm)")

        // 如果連 localName + peripheral.name 都沒有，就當未知裝置略過
        guard let matchName = localName ?? fallbackName, !matchName.isEmpty else {
            print("[BLE] unknown device (no name), ignore")
            return
        }
        
        // ★ 這裡用 localName / peripheral.name 去比對 targetName
        if matchName == targetName {
            print("[BLE] found target by name: \(matchName)")
            statusText = "連線中..."
            targetPeripheral = peripheral
            peripheral.delegate = self
            central.stopScan()
            central.connect(peripheral, options: nil)
            return
        }
        
        // 其他有名字的裝置，只是記錄在列表（如果你之後要做列表 UI）
        let device = DiscoveredDevice(id: peripheral.identifier,
                                      name: displayName,
                                      rssi: RSSI.intValue)
        if !discoveredDevices.contains(device) {
            discoveredDevices.append(device)
        }
    }


    func centralManager(_ central: CBCentralManager,
                        didConnect peripheral: CBPeripheral) {
        print("[BLE] connected to", peripheral.name ?? "")
        isConnected = true
        statusText = "已連線：\(peripheral.name ?? "")"
        peripheral.discoverServices([serviceUUID])
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        print("[BLE] failed to connect:", error ?? "")
        isConnected = false
        statusText = "連線失敗"
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        print("[BLE] disconnected:", error ?? "")
        isConnected = false
        statusText = "已中斷連線"
        targetPeripheral = nil
        writeCharacteristic = nil
    }
}

// MARK: - CBPeripheralDelegate
extension BLEManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverServices error: Error?) {
        if let error = error {
            print("[BLE] discoverServices error:", error)
            return
        }
        guard let services = peripheral.services else { return }
        for service in services where service.uuid == serviceUUID {
            print("[BLE] found service")
            peripheral.discoverCharacteristics([charUUID], for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        if let error = error {
            print("[BLE] discoverCharacteristics error:", error)
            return
        }
        guard let chars = service.characteristics else { return }
        for ch in chars where ch.uuid == charUUID {
            print("[BLE] found characteristic, enable notify")
            writeCharacteristic = ch
            peripheral.setNotifyValue(true, for: ch)
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let error = error {
            print("[BLE] didUpdateValue error:", error)
            return
        }
        guard let data = characteristic.value else { return }
        if let text = String(data: data, encoding: .utf8) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            print("[BLE] received:", trimmed)
            receivedText.send(trimmed)
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didReadRSSI RSSI: NSNumber,
                    error: Error?) {
        if let error = error {
            print("[BLE] readRSSI error:", error)
            return
        }
        currentRSSI = RSSI.intValue
        print("[BLE] RSSI =", currentRSSI ?? 0)
    }
}
