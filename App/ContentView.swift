
import SwiftUI

struct ContentView: View {
    @StateObject var ble = BLEManager()
    @StateObject var vm: SmartFanViewModel

    init() {
        let ble = BLEManager()
        _ble = StateObject(wrappedValue: ble)
        _vm = StateObject(wrappedValue: SmartFanViewModel(ble: ble))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 20) {
                    connectionCard

                    Group {
                        powerCard
                        levelCard
                        comfortTempCard
                        timerCard
                        statusCard
                    }
                    .disabled(!vm.isConnected)
                    .opacity(vm.isConnected ? 1.0 : 0.4)
                }
                .padding()
            }
        }
    }

    // MARK: - UI Cards

    private var connectionCard: some View {
        Card {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("藍牙連線")
                        .font(.headline)
                        .foregroundColor(.white)
                    Text(vm.connectionStatus)
                        .font(.subheadline)
                        .foregroundColor(.gray)
                }
                Spacer()
                Button(action: {
                    vm.connectOrDisconnect()
                }) {
                    Text(vm.isConnected ? "中斷連線" : "連線裝置")
                        .fontWeight(.semibold)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(24)
                }
            }
        }
    }

    private var powerCard: some View {
        Card {
            HStack {
                Text("電源")
                    .font(.headline)
                    .foregroundColor(.white)
                Spacer()
                Toggle(isOn: Binding(
                    get: { vm.fanOn },
                    set: { vm.setFan(on: $0) }
                )) {
                    Text(vm.fanOn ? "開" : "關")
                        .foregroundColor(.white)
                }
                .labelsHidden()
                .toggleStyle(SwitchToggleStyle(tint: .green))
            }
        }
    }

    private var levelCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Text("風量")
                    .font(.headline)
                    .foregroundColor(.white)
                HStack(spacing: 12) {
                    ForEach(1...5, id: \.self) { lv in
                        Button(action: {
                            vm.setLevel(lv)
                        }) {
                            Text("L\(lv)")
                                .fontWeight(.semibold)
                                .frame(width: 54, height: 36)
                                .background(vm.level == lv ? Color.blue : Color.gray.opacity(0.6))
                                .foregroundColor(.white)
                                .cornerRadius(10)
                        }
                    }
                    Spacer()
                }
            }
        }
    }
    
    private func fmt1(_ v: Double) -> String {
        String(format: "%.1f", v)
    }


    private var comfortTempCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Text("舒適溫度")
                    .font(.headline)
                    .foregroundColor(.white)

                HStack(spacing: 12) {
                    TextField("例如 27.5", text: $vm.comfortTempText)
                        .keyboardType(.decimalPad)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)

                    Text("°C")
                        .foregroundColor(.white)

                    Button("設定") {
                        vm.setComfortTemp()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(20)
                    
                    Button(vm.autoAdjustOn ? "智能：開" : "智能：關") {
                        vm.toggleAutoAdjust()
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .background(vm.autoAdjustOn ? Color.green : Color.gray)
                    .foregroundColor(.white)
                    .cornerRadius(20)
                }


                if vm.comfortTempCurrent > 0 {
                    Text("目前舒適溫度：\(fmt1(vm.comfortTempCurrent)) °C")
                        .font(.footnote)
                        .foregroundColor(.gray)
                }
            }
        }
    }


    private var timerCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Text("定時關機")
                    .font(.headline)
                    .foregroundColor(.white)
                
                HStack(spacing: 16) {
                    // 小時選擇 0~23
                    VStack(alignment: .leading) {
                        Text("小時")
                            .font(.footnote)
                            .foregroundColor(.gray)
                        Picker("", selection: $vm.timerHours) {
                            ForEach(0..<24) { h in
                                Text("\(h) 小時").tag(h)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 110)
                        .clipped()
                    }
                    
                    // 分鐘選擇 0~59
                    VStack(alignment: .leading) {
                        Text("分鐘")
                            .font(.footnote)
                            .foregroundColor(.gray)
                        Picker("", selection: $vm.timerMinutes) {
                            ForEach(0..<60) { m in
                                Text(String(format: "%02d 分", m)).tag(m)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 110)
                        .clipped()
                    }
                    
                    Spacer()
                }
                
                // 顯示剩餘時間（取代原本「目前設定」那行）
                HStack {
                    Text("剩餘時間：\(formatRemaining(vm.remainingSeconds))")
                        .foregroundColor(.white)
                        .font(.subheadline)
                    Spacer()
                    Button("設定") {
                        vm.setTimer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(20)
                }
                
                // 若定時結束，顯示一個提示
                if vm.timerEnded {
                    Text("定時時間已到，風扇已關閉（如伺服器有關機）")
                        .font(.footnote)
                        .foregroundColor(.yellow)
                }
            }
        }
    }


    private var statusCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("系統狀態")
                        .font(.headline)
                        .foregroundColor(.white)
                    Spacer()
                    Button(action: {
                        vm.requestState()
                    }) {
                        Image(systemName: "arrow.clockwise")
                            .foregroundColor(.white)
                    }
                }

                Group {
                    HStack {
                        Text("CPU 使用率")
                        Spacer()
                        Text(String(format: "%.0f %%", vm.cpuUsage))
                    }
                    HStack {
                        Text("樹莓派溫度")
                        Spacer()
                        Text(String(format: "%.1f °C", vm.piTemp))
                    }
                    HStack {
                        Text("室溫")
                        Spacer()
                        Text(String(format: "%.1f °C", vm.roomTemp))
                    }
                    HStack {
                        Text("風速")
                        Spacer()
                        Text(String(format: "%.2f m/s", vm.windSpeed))
                    }
                    HStack {
                        Text("目標風速 / 段位")
                        Spacer()
                        Text(String(format: "%.2f / L%d", vm.targetWind, vm.targetLevel))
                    }
                    HStack {
                        Text("目前風量段位")
                        Spacer()
                        Text("L\(vm.level)")
                    }
                    HStack {
                        Text("RSSI")
                        Spacer()
                        Text("\(vm.lastRSSI) dBm")
                    }
                }
                .foregroundColor(.white)
                .font(.subheadline)

                if vm.lastRSSISaved {
                    Text("伺服器已更新最新 RSSI")
                        .font(.footnote)
                        .foregroundColor(.green)
                }
            }
        }
    }
    
    private func formatRemaining(_ seconds: Int) -> String {
        let s = max(0, seconds)
        let h = s / 3600
        let m = (s % 3600) / 60
        let sec = s % 60
        return String(format: "%02d:%02d:%02d", h, m, sec)
    }

}

struct Card<Content: View>: View {
    let content: () -> Content

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(white: 0.15))
            content()
                .padding()
        }
    }
}
