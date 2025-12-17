# ESD-Project 環境建構指南

---

本系統使用 Python 作為樹莓派系統的開發語言，下方將說明如何建立環境與執行。

- 樹莓派環境工具安裝

```bash
# 安裝環境
sudo apt-get update
sudo apt-get install -y python3-dev libbluetooth-dev bluez libglib2.0-dev
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt

# 調整硬體設定
sudo raspi-config
# 進入 Interface Options 開啟SPI I2C

sudo bluetoothctl
bluetoothctl> Pairable off

# 執行server
python server.py
```

App 的部分我們是使用 iOS 18 進行開發，因此只需將資料夾 App 下的檔案放入xcode並且依照下面的步驟設定。

1. **開啟專案**：
   - 進入 App/` 資料夾。
   - 雙擊 `SmartFan.xcodeproj` 檔案，Xcode 會自動載入所有 Source Code。

2. **選擇開發裝置**：
   - 在 Xcode 上方工具列選擇你的目標裝置（例如你的 iPhone 或 Mac），版本請選 iOS18。

3. **確認編譯設定**：
   - 確保已在 `Signing & Capabilities` 中選取你的開發者帳號（Development Team）。

4. 在 Xcode 專案導覽列中找到 `Info` 設定（或點擊專案名稱 -> `Targets` -> `Info`）。
5. 在 `Custom iOS Target Properties` 中新增以下兩組 Key：

| Key                                                  | Value (說明文字)                                   |
| :--------------------------------------------------- | :------------------------------------------------- |
| **Privacy - Bluetooth Always Usage Description**     | 「此 App 需要使用藍牙以連接並控制 Raspberry Pi。」 |
| **Privacy - Bluetooth Peripheral Usage Description** | 「此 App 需要藍牙權限以進行資料傳輸。」            |

6. 編譯執行即可
