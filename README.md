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

App 的部分我們是使用 iOS 18 進行開發，因此只需將資料夾 App 下的檔案放入xcode並且進行編譯即可。
