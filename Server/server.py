#!/usr/bin/env python3
from __future__ import annotations

import time
import threading
from dataclasses import dataclass
from typing import Optional

from bluezero import peripheral, adapter
import psutil
import RPi.GPIO as GPIO
import spidev

# DS18B20 optional
try:
    from w1thermsensor import W1ThermSensor, NoSensorFoundError
except ImportError:
    W1ThermSensor = None
    NoSensorFoundError = Exception

# ===== BLE / protocol constants =====
ADV_NAME   = 'Pi-BLE'
SERVICE_ID = '12341000-1234-1234-1234-1234567890ab'
CHAR_ID    = '12341001-1234-1234-1234-1234567890ab'

# ===== Auto wind control (依溫度選 target) =====
# < 26°  → wind 1.0, level 1
# 26–30° → wind 1.8, level 3
# > 30°  → wind 2.6, level 5
TEMP_LOW_MAX  = 26.0
TEMP_MID_MAX  = 30.0

TARGET_WIND_LOW  = 1.7
TARGET_WIND_MID  = 2.2
TARGET_WIND_HIGH = 2.7


TARGET_LEVEL_LOW  = 1
TARGET_LEVEL_MID  = 3
TARGET_LEVEL_HIGH = 5

# 風速判斷容許誤差，避免一直跳級
WIND_TOLERANCE = 0.2  # m/s

# ===== RSSI / timer auto-off =====
RSSI_THRESHOLD = -75     # dBm
RSSI_TIMEOUT   = 300  # 3 分鐘（秒）

COMFORTABLE_TMP = 26.0  # 預設舒適溫度，可由 App 修改
AUTO_ADJUST_ENABLED = True  # 是否啟用自動調整風扇（auto wind）


# ========= FanHardware: 硬體 & 模擬層 =========
class FanHardware:
    # L298N pins (BCM)
    IN3_PIN = 23   # L298N IN3
    IN4_PIN = 13   # L298N IN4
    ENB_PIN = 24   # L298N ENB (PWM)

    # SG90 servo pin
    PIN_SERVO = 25

    # MCP3008 SPI
    SPI_BUS = 0
    SPI_DEV = 0
    WIND_CHANNEL = 0

    # level -> PWM duty
    LEVEL_TO_DUTY = {
        1: 60,
        2: 70,
        3: 80,
        4: 90,
        5: 100,
    }

    def __init__(self):
        # ---- L298N ----
        GPIO.setmode(GPIO.BCM)

        GPIO.setup(self.IN3_PIN, GPIO.OUT)
        GPIO.setup(self.IN4_PIN, GPIO.OUT)
        GPIO.setup(self.ENB_PIN, GPIO.OUT)

        # 一開始先停止
        GPIO.output(self.IN3_PIN, GPIO.LOW)
        GPIO.output(self.IN4_PIN, GPIO.LOW)

        # 建立 PWM 物件，初始 duty=0%
        self.fan_pwm = GPIO.PWM(self.ENB_PIN, 1000)
        self.fan_pwm.start(0)
         
        # ---- SG90 ----
        GPIO.setup(self.PIN_SERVO, GPIO.OUT)
        self.servo_pwm = GPIO.PWM(self.PIN_SERVO, 50)  # 50Hz
        self.servo_pwm.start(0)

        self._swing_thread: Optional[threading.Thread] = None
        self._swing_stop = threading.Event()

        # ---- DS18B20 (room temp, optional) ----
        self.temp_sensor = None
        if W1ThermSensor is not None:
            try:
                self.temp_sensor = W1ThermSensor()
                print("[HW] DS18B20 sensor detected")
            except NoSensorFoundError:
                print("[HW] WARNING: No DS18B20 found, using simulated room temperature")
        else:
            print("[HW] WARNING: w1thermsensor not installed, using simulated room temperature")

        # ---- MCP3008 (wind sensor, optional) ----
        self.spi = None
        self.has_wind_sensor = False
        try:
            self.spi = spidev.SpiDev()
            self.spi.open(self.SPI_BUS, self.SPI_DEV)
            self.spi.max_speed_hz = 1350000
            raw = self._read_adc_raw(self.WIND_CHANNEL)

            if raw in (0, 1023):
                print(f"[HW] WARNING: MCP3008 may not be connected (adc={raw}), using simulated wind")
                self.spi.close()
                self.spi = None
                self.has_wind_sensor = False
            else:
                self.has_wind_sensor = True
                print("[HW] MCP3008 wind sensor ACTIVE")
        except Exception as e:
            print("[HW] WARNING: cannot init MCP3008, using simulated wind speed:", e)
            self.spi = None
            self.has_wind_sensor = False

        self.sim_temp: Optional[float] = None      
        self.sim_wind: Optional[float] = None     
        self.sim_pi_temp: Optional[float] = None   

    def set_sim_temp(self, value: Optional[float]):
        self.sim_temp = value
        print(f"[SIM] room_temp -> {value if value is not None else 'REAL'}")

    def set_sim_wind(self, value: Optional[float]):
        self.sim_wind = value
        print(f"[SIM] wind_speed -> {value if value is not None else 'REAL'}")

    def set_sim_pi_temp(self, value: Optional[float]):
        self.sim_pi_temp = value
        print(f"[SIM] pi_temp -> {value if value is not None else 'REAL'}")

    # ===== Fan control  =====
    def set_power(self, on: bool):
        if not on:
            self.fan_pwm.ChangeDutyCycle(0)
            GPIO.output(self.IN3_PIN, GPIO.LOW)
            GPIO.output(self.IN4_PIN, GPIO.LOW)
        print(f"[HW] Power {'ON' if on else 'OFF'}")

    def set_level(self, level: int, on: bool):
        if on:
            level = max(1, min(5, level))
            duty = self.LEVEL_TO_DUTY.get(level, 20)
            print(duty)
            GPIO.output(self.IN3_PIN, GPIO.HIGH)
            GPIO.output(self.IN4_PIN, GPIO.LOW)
            self.fan_pwm.ChangeDutyCycle(duty)
            print(f"[HW] set_level -> L{level} (duty={duty}%)")

    def _angle_to_duty(self, angle: float) -> float:
        return 2.5 + (angle / 180.0) * 10.0

    def _swing_worker(self):
        angle_min = 30
        angle_max = 150
        step = 5
        angle = angle_min
        direction = 1

        while not self._swing_stop.is_set():
            duty = self._angle_to_duty(angle)
            self.servo_pwm.ChangeDutyCycle(duty)
            time.sleep(0.03)

            angle += step * direction
            if angle >= angle_max:
                angle = angle_max
                direction = -1
            elif angle <= angle_min:
                angle = angle_min
                direction = 1

        duty = self._angle_to_duty(90)
        self.servo_pwm.ChangeDutyCycle(duty)
        time.sleep(0.3)
        self.servo_pwm.ChangeDutyCycle(0)

    def set_swing(self, on: bool):
        if on:
            if self._swing_thread and self._swing_thread.is_alive():
                return
            self._swing_stop.clear()
            self._swing_thread = threading.Thread(target=self._swing_worker, daemon=True)
            self._swing_thread.start()
            print("[HW] swing ON")
        else:
            self._swing_stop.set()
            print("[HW] swing OFF")

    # ===== Sensors =====
    def read_room_temp(self) -> float:
        """
        室溫：
          - 如果有 sim_temp → 用模擬值
          - 否則用 DS18B20；沒有就 fallback 27°C
        """
        if self.sim_temp is not None:
            return self.sim_temp

        if self.temp_sensor is None:
            return 27.0

        try:
            return self.temp_sensor.get_temperature()
        except Exception as e:
            print("[HW] read_room_temp error, using simulated value:", e)
            return 27.0

    def _read_adc_raw(self, channel: int) -> int:
        if self.spi is None:
            return 512
        r = self.spi.xfer2([1, (8 + channel) << 4, 0])
        return ((r[1] & 3) << 8) | r[2]

    def _read_adc(self, channel: int) -> int:
        if not self.has_wind_sensor or self.spi is None:
            return 512
        return self._read_adc_raw(channel)

    def read_wind_speed(self) -> float:
        """
        風速：
          - 有 sim_wind → 模擬
          - 有 MCP3008 → 依電壓換算風速
          - 否則 fallback 1.8 m/s
        """
        if self.sim_wind is not None:
            return self.sim_wind

        if not self.has_wind_sensor or self.spi is None:
            return 1.8

        try:
            # 1. 讀取原始 ADC 值 (0-1023)
            # 假設 CH0 是 Wind RV, CH1 是 Temp TMP
            rv_wind_adunits = self._read_adc(0)
            tmp_therm_adunits = self._read_adc(1)

            # 2. 定義參考電壓轉換常數
            # Arduino 原版: 5.0 / 1024 = 0.0048828
            # RPi MCP3008: 3.3 / 1024 = 0.0032226
            V_REF_RATIO = 3.3 / 1024.0

            # 3. 計算電壓
            rv_wind_volts = rv_wind_adunits * V_REF_RATIO
            
            # 4. 溫度補償計算 (保持原版回歸公式)
            # 注意：雖然 ADC 讀值因為 3.3V 變小了，但如果你的電路有先分壓，
            # 理論上比例是一樣的。但精確做法是反推回 5V 基準的單位
            # 這裡我們將 RPi 的讀值對標回 5V 的單位，以符合原廠公式的常數
            scaled_adunits_5v = (rv_wind_volts / 5.0) * 1024.0 # 雖然實務上不用這行，但為了公式準確
            # 或是更簡單：直接將 RPi 讀值乘以 (5.0/3.3) 模擬 Arduino 讀值
            adj_tmp_units = tmp_therm_adunits * (5.0 / 3.3)
            adj_rv_units = rv_wind_adunits * (5.0 / 3.3)
            adj_rv_volts = adj_rv_units * 0.0048828125

            # --- 開始核心演算法 ---
            # 計算零風速時的基準單位 (Zero Wind Offset)
            zero_wind_adunits = (
                -0.0006 * (adj_tmp_units**2) + 
                1.0727 * adj_tmp_units + 
                47.172
            )
            
            zero_wind_adjustment = 0.2 # 補償值，可依實驗調整
            zero_wind_volts = (zero_wind_adunits * 0.0048828125) - zero_wind_adjustment

            # 防止負值 (避免 pow 運算報錯)
            diff_volts = max(0, adj_rv_volts - zero_wind_volts)

            # 計算風速 (MPH)
            # Vraw = V0 + b * WindSpeed ^ c -> WindSpeed = ((Vraw - V0)/b)^(1/c)
            wind_speed_mph = pow((diff_volts / 0.2300), 2.7265)
            
            # 轉換為公制 m/s (1 mph = 0.44704 m/s)
            wind_speed_ms = wind_speed_mph * 0.44704

            return wind_speed_ms
        except Exception as e:
            print("[HW] read_wind_speed error, using simulated value:", e)
            return 1.8

    def read_pi_temp(self) -> float:
        if self.sim_pi_temp is not None:
            return self.sim_pi_temp

        try:
            with open("/sys/class/thermal/thermal_zone0/temp", "r") as f:
                t_milli = int(f.read().strip())
            return t_milli / 1000.0
        except Exception:
            return 0.0

    # ===== clean =====
    def cleanup(self):
        self._swing_stop.set()
        time.sleep(0.1)
        try:
            self.fan_pwm.stop()
            self.servo_pwm.stop()
        except Exception:
            pass
        GPIO.cleanup()
        if self.spi is not None:
            try:
                self.spi.close()
            except Exception:
                pass


# ========= System state =========
@dataclass
class FanSystemState:
    power_on: bool = False
    level: int = 1
    swing_on: bool = False

    timer_deadline: Optional[float] = None  # tim: 秒數

    last_rssi: Optional[int] = None
    last_rssi_time: Optional[float] = None
    auto_off_deadline: Optional[float] = None  # RSSI 過遠 3 分鐘後 auto off

    auto_target_wind: Optional[float] = None
    auto_target_level: Optional[int] = None
    rssi_debug_override: bool = False

    def update_rssi(self, value: int, from_debug: bool = False):
        print(from_debug)
        if from_debug:
            self.rssi_debug_override = True
        elif self.rssi_debug_override:
            # 已被 CLI 接管，忽略 BLE 的 RSSI 更新
            return

        now = time.time()
        self.last_rssi = value
        self.last_rssi_time = now
        if value > RSSI_THRESHOLD:
            self.auto_off_deadline = None
        else:
            if self.auto_off_deadline is None:
                self.auto_off_deadline = now + RSSI_TIMEOUT

    def should_auto_power_off(self) -> bool:
        return self.auto_off_deadline is not None and time.time() >= self.auto_off_deadline

    def should_timer_power_off(self) -> bool:
        return self.timer_deadline is not None and time.time() >= self.timer_deadline

    def update_target_from_temp(self, room_temp: float):
        if room_temp < COMFORTABLE_TMP+4:
            self.auto_target_wind = TARGET_WIND_LOW
            self.auto_target_level = TARGET_LEVEL_LOW
        elif room_temp <= COMFORTABLE_TMP:
            self.auto_target_wind = TARGET_WIND_MID
            self.auto_target_level = TARGET_LEVEL_MID
        else:
            self.auto_target_wind = TARGET_WIND_HIGH
            self.auto_target_level = TARGET_LEVEL_HIGH


# ========= Instance =========
state = FanSystemState()
hw = FanHardware()


# ========= get sensor value =========
def read_sensors():
    room_temp = hw.read_room_temp()
    wind = hw.read_wind_speed()
    return room_temp, wind

def get_pi_temp():
    return hw.read_pi_temp()

def format_status(rssi_saved: bool) -> str:
    cpu = psutil.cpu_percent(interval=None)
    pi_temp = get_pi_temp()
    room_temp, wind_speed = read_sensors()
    state.update_target_from_temp(room_temp)

    # calculate time left (no set timmer => 0)
    if state.timer_deadline is not None:
        remain = max(0, int(state.timer_deadline - time.time()))
    else:
        remain = 0

    return (
            f"STAT cpu={cpu:.1f} "
            f"temp_pi={pi_temp:.1f} "
            f"temp_room={room_temp:.1f} "
            f"wind={wind_speed:.2f} "
            f"level=L{state.level} "
            f"fan={'on' if state.power_on else 'off'} "
            f"sw={'on' if state.swing_on else 'off'} "
            f"target_wind={state.auto_target_wind:.2f} "
            f"target_level=L{state.auto_target_level} "
            f"comfort={COMFORTABLE_TMP:.1f} "
            f"auto={'on' if AUTO_ADJUST_ENABLED else 'off'} "
            f"timer_remain={remain} "
            f"rssi_remain={state.last_rssi if state.last_rssi is not None else 0} "
        )



# ========= BLE =========
def apply_level():
    lvl = max(1, min(5, state.level))
    state.level = lvl
    hw.set_level(lvl, state.power_on)

def handle_command(text: str, source: str = "ble") -> Optional[str]:
    text = text.strip()
    if not text:
        return None

    print(f"[CMD][{source}] {text}")
    rssi_saved = False

    if text.startswith("level:"):
        lv = text.split(":", 1)[1]
        if lv in ("L1", "L2", "L3", "L4", "L5"):
            state.level = int(lv[1])
            apply_level()

    elif text.startswith("fan:"):
        v = text.split(":", 1)[1]
        state.power_on = (v == "on")
        hw.set_power(state.power_on)

        if state.power_on:
            apply_level() 

    elif text.startswith("sw:"):
        v = text.split(":", 1)[1]
        state.swing_on = (v == "on")
        hw.set_swing(state.swing_on)

    elif text.startswith("tim:"):
        sec_str = text.split(":", 1)[1]
        try:
            sec = int(sec_str)
            if sec > 0:
                state.timer_deadline = time.time() + sec
            else:
                state.timer_deadline = None
        except ValueError:
            pass

    elif text.startswith("RSSI:"):
        v = text.split(":", 1)[1]
        try:
            rssi = int(v)
            state.update_rssi(rssi, (source == "cli"))
            rssi_saved = True
        except ValueError:
            pass
    elif text.startswith("ctmp:"):
        global COMFORTABLE_TMP
        v = text.split(":", 1)[1]
        try:
            COMFORTABLE_TMP = float(v)
            TEMP_LOW_MAX = COMFORTABLE_TMP 
            TEMP_MID_MAX = COMFORTABLE_TMP + 4
            
            print(f"[SYS] COMFORTABLE_TMP -> {COMFORTABLE_TMP}")
        except ValueError:
            pass

    # ==== 以下為 debug 模擬指令 ====
    elif text.startswith("temp:"):
        v = text.split(":", 1)[1]
        try:
            t = float(v)
            hw.set_sim_temp(t)
        except ValueError:
            print("[CMD][sim] invalid temp value")

    elif text.startswith("wind:"):
        v = text.split(":", 1)[1]
        try:
            w = float(v)
            hw.set_sim_wind(w)
        except ValueError:
            print("[CMD][sim] invalid wind value")

    elif text.startswith("pi_temp:"):
        v = text.split(":", 1)[1]
        try:
            p = float(v)
            hw.set_sim_pi_temp(p)
        except ValueError:
            print("[CMD][sim] invalid pi_temp value")

    elif text == "sim:clear":
        hw.set_sim_temp(None)
        hw.set_sim_wind(None)
        hw.set_sim_pi_temp(None)
        print("[SIM] all simulation values cleared")
    
    elif text.startswith("auto:"):
        global AUTO_ADJUST_ENABLED
        v = text.split(":", 1)[1].strip()

        if v == "on":
            AUTO_ADJUST_ENABLED = True
        elif v == "off":
            AUTO_ADJUST_ENABLED = False

        print(f"[SYS] AUTO_ADJUST_ENABLED -> {AUTO_ADJUST_ENABLED}")


    elif text == "state?":
        # 只回狀態
        pass

    else:
        print(f"[CMD][{source}] 未知指令")
        return None

    return format_status(rssi_saved)


# ========= BLE bridge (新版 bluezero Peripheral API) =========
class FanBLE:
    tx_char = None  # 用來發 notify 回 iOS 的 characteristic

    @classmethod
    def notify_cb(cls, notifying, characteristic):
        if notifying:
            cls.tx_char = characteristic
            print("[BLE] notifications enabled")
        else:
            cls.tx_char = None
            print("[BLE] notifications disabled")

    @classmethod
    def on_write(cls, value, options):
        # bluezero 0.7 這裡的 value 是 list[int]，要自己轉 bytes
        try:
            text = bytes(value).decode('utf-8', errors='ignore').strip()
        except Exception as e:
            print("[BLE] decode error:", e)
            return
        resp = handle_command(text, source="ble")
        if resp:
            notify_status(resp)


def notify_status(text: str):
    """把狀態透過 notify 回傳給 iOS（如果有開 notify）"""
    if FanBLE.tx_char is None:
        return
    print("[BLE] send:", text)
    data = (text + "\n").encode('utf-8')
    FanBLE.tx_char.set_value(list(data))


# ========= Timer threads =========
def safety_loop():
    """每秒檢查 RSSI / timmer 自動關機"""
    while True:
        try:
            # print(time.time() - (state.last_rssi_time if state.last_rssi_time is not None else time.time()), RSSI_TIMEOUT)
            if state.should_auto_power_off() or state.should_timer_power_off() or time.time() - (state.last_rssi_time if state.last_rssi_time is not None else time.time()) > RSSI_TIMEOUT:
                if state.power_on:
                    print("[SYS] auto power off (RSSI or timer)")
                    state.power_on = False
                    hw.set_power(False)
        except Exception as e:
            print("[SAFETY] error:", e)
        time.sleep(1)


def auto_wind_loop():
    while True:
        try:
            if not AUTO_ADJUST_ENABLED:
                time.sleep(1)
                continue

            room_temp = hw.read_room_temp()
            state.update_target_from_temp(room_temp)

            if state.power_on:
                wind = hw.read_wind_speed()
                target = state.auto_target_wind

                if target is not None:
                    print(f"[AUTO] temp={room_temp:.2f}°C, wind={wind:.2f}, target={target:.2f}, level=L{state.level}")

                    if wind > target + WIND_TOLERANCE and state.level > 1:
                        state.level -= 1
                        print(f"[AUTO] wind > target → level -> L{state.level}")
                        apply_level()

                    elif wind < target - WIND_TOLERANCE and state.level < 5:
                        state.level += 1
                        print(f"[AUTO] wind < target → level -> L{state.level}")
                        apply_level()

        except Exception as e:
            print("[AUTO] error:", e)

        time.sleep(30)



# ========= BLE 初始化 =========
def init_ble():
    # Adapter.available() 回傳的是 generator，所以先轉成 list
    adapters_gen = adapter.Adapter.available()
    adapters_list = list(adapters_gen)

    if not adapters_list:
        raise RuntimeError("No Bluetooth adapter found")

    bt_adapter = adapters_list[0]
    adapter_addr = bt_adapter.address
    print("[BLE] using adapter", adapter_addr)

    # 建立 Peripheral，綁定這個 adapter
    ble = peripheral.Peripheral(adapter_address=adapter_addr, local_name=ADV_NAME)

    # 加入 Service
    ble.add_service(srv_id=1, uuid=SERVICE_ID, primary=True)

    # 加入 Characteristic（write + notify）
    ble.add_characteristic(
        srv_id=1,
        chr_id=1,
        uuid=CHAR_ID,
        value=[],
        notifying=False,
        flags=['write', 'write-without-response', 'notify'],
        write_callback=FanBLE.on_write,
        read_callback=None,
        notify_callback=FanBLE.notify_cb,
    )

    return ble


# ========= main =========
def main():
    try:
        # 開機依室溫設定初始風速 level
        room_temp = hw.read_room_temp()
        state.update_target_from_temp(room_temp)
        state.level = state.auto_target_level or 1
        apply_level()

        # background threads
        threading.Thread(target=safety_loop, daemon=True).start()
        threading.Thread(target=auto_wind_loop, daemon=True).start()
        
        # BLE
        ble = init_ble()
        print("[BLE] advertising, 等待 iOS 連線…")
        ble.publish()
    except KeyboardInterrupt:
        print("\n[SYS] KeyboardInterrupt, exiting...")
    finally:
        hw.cleanup()


if __name__ == '__main__':
    main()
