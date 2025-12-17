
import Foundation
import Combine

/// Smart Fan 的邏輯層，負責把 UI 操作轉成 BLE 指令 & 解析 STAT 回報
final class SmartFanViewModel: ObservableObject {
    // 來自 BLE
    @Published var isConnected: Bool = false
    @Published var connectionStatus: String = "未連線"
    @Published var lastRSSI: Int = 0
    @Published var lastRSSISaved: Bool = false

    // 控制狀態（送給伺服器）
    @Published var fanOn: Bool = false
    @Published var level: Int = 3       // 1~5
    @Published var swingOn: Bool = false
    @Published var timerHours: Int = 0      // 0~23
    @Published var timerMinutes: Int = 0    // 0~59
    @Published var remainingSeconds: Int = 0    // 剩餘秒數
    @Published var timerActive: Bool = false    // 是否有定時
    @Published var timerEnded: Bool = false     // 是否剛結束（顯示提示用）

    // 伺服器回傳狀態
    @Published var cpuUsage: Double = 0
    @Published var piTemp: Double = 0
    @Published var roomTemp: Double = 0
    @Published var windSpeed: Double = 0
    @Published var targetWind: Double = 0
    @Published var targetLevel: Int = 3
    @Published var comfortTempText: String = ""
    @Published var comfortTempCurrent: Double = 0.0
    @Published var autoAdjustOn: Bool = true



    private var countdownTimer: AnyCancellable?

    private let ble: BLEManager
    private var cancellables = Set<AnyCancellable>()

    init(ble: BLEManager) {
        self.ble = ble
        
        // 連線狀態綁定（純粹把 BLE 的 isConnected 映射到 VM）
        ble.$isConnected
            .receive(on: DispatchQueue.main)
            .assign(to: &self.$isConnected)
        
        // ★ 連線 / 斷線時要做的事
        ble.$isConnected
            .removeDuplicates()
            .sink { [weak self] connected in
                guard let self = self else { return }
                if connected {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        self.setFan(on: true)   // 連線後預設開風扇
                        self.requestState()     // 立刻刷新狀態
                        self.sendRSSI()         // 可選：順便觸發 RSSI→STAT
                    }
                } else {
                    // 斷線時可以順便清一些 UI 狀態（看你要不要）
                    self.timerActive = false
                    self.countdownTimer?.cancel()
                    self.remainingSeconds = 0
                    self.timerEnded = false
                }
            }
            .store(in: &cancellables)
        
        ble.$statusText
            .receive(on: DispatchQueue.main)
            .assign(to: &self.$connectionStatus)
        
        ble.$currentRSSI
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .assign(to: &self.$lastRSSI)
        
        // 收到文字 → 處理 STAT
        ble.receivedText
            .sink { [weak self] text in
                self?.handleIncoming(text: text)
            }
            .store(in: &cancellables)
        
        // 每 30 秒觸發一次 RSSI 流程
        Timer.publish(every: 30, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.sendRSSI()
            }
            .store(in: &cancellables)
    }


    // MARK: - 封裝操作給 UI 呼叫

    func connectOrDisconnect() {
        if isConnected {
            ble.disconnect()
        } else {
            ble.connect()
        }
    }

    func setLevel(_ newLevel: Int) {
        guard isConnected else { return }
        let lv = max(1, min(5, newLevel))
        level = lv
        ble.send(text: "level:L\(lv)")
    }

    func setFan(on: Bool) {
        guard isConnected else { return }
        fanOn = on
        ble.send(text: "fan:\(on ? "on" : "off")")
    }

    func setSwing(on: Bool) {
        guard isConnected else { return }
        swingOn = on
        ble.send(text: "sw:\(on ? "on" : "off")")
    }

    func setTimer() {
        guard isConnected else { return }
        
        // 限制 0~23 / 0~59，避免超過 23:59
        let clampedHours = min(max(timerHours, 0), 23)
        let clampedMinutes = min(max(timerMinutes, 0), 59)
        timerHours = clampedHours
        timerMinutes = clampedMinutes
        
        let totalSeconds = clampedHours * 3600 + clampedMinutes * 60
        
        // 送給伺服器
        ble.send(text: "tim:\(totalSeconds)")
        
        // 本地倒數初始化
        countdownTimer?.cancel()
        remainingSeconds = totalSeconds
        timerEnded = false
        timerActive = totalSeconds > 0
        
        if totalSeconds > 0 {
            countdownTimer = Timer.publish(every: 1, on: .main, in: .common)
                .autoconnect()
                .sink { [weak self] _ in
                    self?.tickCountdown()
                }
        }
    }
    private func tickCountdown() {
        guard timerActive else { return }
        if remainingSeconds > 0 {
            remainingSeconds -= 1
        } else {
            timerActive = false
            timerEnded = true
            countdownTimer?.cancel()
        }
    }

    func setComfortTemp() {
        guard isConnected else { return }
        let trimmed = comfortTempText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let v = Double(trimmed) else { return }
        ble.send(text: "ctmp:\(v)")
        requestState() // 設定後立刻要一次狀態校準
    }


    func requestState() {
        guard isConnected else { return }
        ble.send(text: "state?")
    }
    
    func toggleAutoAdjust() {
        autoAdjustOn.toggle()
        guard isConnected else { return }
        ble.send(text: "auto:\(autoAdjustOn ? "on" : "off")")
        requestState()
    }


    private func sendRSSI() {
        guard isConnected else { return }
        // 簡單版本：直接用目前已知的 lastRSSI
        if let rssi = ble.currentRSSI {
            ble.send(text: "RSSI:\(rssi)")
        } else {
            // 若還沒讀到，先要求 peripheral 讀一次
            ble.requestRSSI()
        }
    }

    // MARK: - 解析 STAT 回報

    private func handleIncoming(text: String) {
        guard text.hasPrefix("STAT ") else { return }
        let body = String(text.dropFirst(5))
        let parts = body.split(separator: " ")
        var dict: [String: String] = [:]
        for p in parts {
            let kv = p.split(separator: "=", maxSplits: 1)
            if kv.count == 2 {
                dict[String(kv[0])] = String(kv[1])
            }
        }

        DispatchQueue.main.async {
            if let cpu = dict["cpu"], let v = Double(cpu) { self.cpuUsage = v }
            if let tpi = dict["temp_pi"], let v = Double(tpi) { self.piTemp = v }
            if let tr = dict["temp_room"], let v = Double(tr) { self.roomTemp = v }
            if let wind = dict["wind"], let v = Double(wind) { self.windSpeed = v }
            if let lvl = dict["level"], lvl.hasPrefix("L"),
               let v = Int(lvl.dropFirst()) { self.level = v }
            if let fan = dict["fan"] { self.fanOn = (fan == "on") }
            if let sw = dict["sw"] { self.swingOn = (sw == "on") }
            if let tw = dict["target_wind"], let v = Double(tw) { self.targetWind = v }
            if let tl = dict["target_level"], tl.hasPrefix("L"),
               let v = Int(tl.dropFirst()) { self.targetLevel = v }
            if let rssiStr = dict["rssi"], let v = Int(rssiStr) { self.lastRSSI = v }
            if let ok = dict["rssi_saved"] { self.lastRSSISaved = (ok == "1") }
            if let c = dict["comfort"], let v = Double(c) { self.comfortTempCurrent = v }
            if let a = dict["auto"] { self.autoAdjustOn = (a == "on") }

        }
        
        // timer_remain 來自伺服器，用來校準本地倒數
        if let trm = dict["timer_remain"], let v = Int(trm) {
            let remain = max(0, v)
            self.remainingSeconds = remain
            self.timerActive = remain > 0
            
            if remain == 0 {
                // 伺服器認定定時已到，若風扇也關了，就視為定時結束
                if !self.fanOn {
                    self.timerEnded = true
                }
                self.countdownTimer?.cancel()
            } else {
                // 還有剩餘時間：確保 countdown 有在跑
                if self.countdownTimer == nil {
                    self.countdownTimer = Timer.publish(every: 1, on: .main, in: .common)
                        .autoconnect()
                        .sink { [weak self] _ in
                            self?.tickCountdown()
                        }
                }
            }
        }

    }
}
