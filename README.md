# Pi Simple Fan Control

A lightweight PWM fan controller that uses the Linux sysfs PWM interface. Tested on an **Orange Pi 5 Ultra** but intended to work on other boards (including Raspberry Pi) that expose a compatible `/sys/class/pwm/pwmchip*/pwm*` device. The goal is to let that PWM pin drive any fan type: the onboard 5V header, a higher-voltage (e.g., 12 V) fan switched through a small driver/MOSFET, or the PWM lead on a 4-wire fan.

![fan control](images/pisimplefancontrol.png)

## Features
- Controls a PWM fan based on CPU temperature with a linear ramp
- Uses sysfs PWM (no `gpio` dependency), works with inverted PWM wiring
- Configurable thresholds, poll interval, and startup “kick” to overcome stall
- Output-only: does not read a tach wire; it just drives PWM/duty to the fan
- Install via script or manual copy; systemd service included

## Requirements
- Bash, curl, and systemd
- Root access (writes to `/sys/class/pwm`, `/etc`, `/usr/local/bin`)
- A board that exposes a PWM channel (defaults to `pwmchip0/pwm0`)
- For Raspberry Pi, make sure a PWM channel is enabled via device-tree overlay so it appears under `/sys/class/pwm`
- On Orange Pi 5 Ultra the official docs show a 2-pin 1.25 mm 5V fan header that is PWM-controlled, and the stock Orange Pi images ship a `pwm-fan.service` for it—disable/mask it to avoid conflicts:
  ```bash
  sudo systemctl disable pwm-fan.service
  sudo systemctl mask pwm-fan.service
  ```

### Example: driving a 12 V fan with a MOSFET
- Use a logic-level N-channel MOSFET or low-side driver (e.g., AO3400/IRLZ44N/TIP122) to switch the fan’s ground.
- Wire: board PWM pin → 100–220 Ω gate/base resistor on the MOSFET/driver; source/emitter → ground; drain/collector → fan ground; fan +12 V → 12 V supply. Add a flyback diode across the fan (1N5819/1N4007) with the stripe on +12 V.
- Share grounds between the Orange Pi/Raspberry Pi and the 12 V supply. Add a 100 kΩ pull-down on the gate (yes, also for AO3400) to keep the fan off at boot and avoid a floating gate.
- When to use: this MOSFET path is for 2-wire or 3-wire fans (no dedicated PWM lead). If you have a 4-wire fan with a PWM control wire, feed that wire from the board’s PWM pin (level-compatible) while powering the fan directly from 12 V; no low-side switching needed.

## Enabling PWM
You must enable a PWM channel so it shows up under `/sys/class/pwm`.

Example (Debian, Orange Pi 5 Ultra):
- Use `orangepi-config`: go to **System** → **Hardware** and enable the PWM (pwm3-m3) entry that maps to header pin 7. Reboot.
- Or edit `/boot/orangepiEnv.txt` and add:
  ```bash
  overlays=pwm3-m3
  ```
  then reboot. This exposes `/sys/class/pwm/pwmchip0/pwm0` for pin 7 on the Orange Pi 5 Ultra header.

> For more information check the [oficial documentation](http://www.orangepi.org/orangepiwiki/index.php/Orange_Pi_5_Ultra#How_to_test_PWM_using_.2Fsys.2Fclass.2Fpwm)

## Quick start (install script)
Supported installation methods: script or manual copy (no packages).

```bash
# run as root or with sudo
curl -sSL https://raw.githubusercontent.com/ericogr/pisimplefancontrol/main/install.sh | sudo bash
```

The script installs the binary to `/usr/local/bin`, creates `/etc/pisimplefancontrol.conf` if missing, installs the systemd unit, reloads systemd, enables, and starts the service.

## Manual installation
1) Copy the script and make it executable:
```bash
sudo cp pisimplefancontrol.sh /usr/local/bin/pisimplefancontrol.sh
sudo chmod +x /usr/local/bin/pisimplefancontrol.sh
```
2) Copy the config (edit to fit your board):
```bash
sudo cp pisimplefancontrol.conf.example /etc/pisimplefancontrol.conf
```
3) Install the systemd unit:
```bash
sudo cp pisimplefancontrol.service /etc/systemd/system/pisimplefancontrol.service
sudo systemctl daemon-reload
sudo systemctl enable --now pisimplefancontrol.service
```

## Configuration
Defaults live in `/etc/pisimplefancontrol.conf` (Celsius temps, percent duty). Example:
```bash
# Hardware
INVERT_PWM=1                 # 0 = normal, 1 = inverted (active-low)
PWMCHIP="/sys/class/pwm/pwmchip0"
PWM_CHANNEL=0
TEMP_SENSOR="/sys/class/thermal/thermal_zone0/temp"

# Fan curve (temperatures in Celsius, duty in percent)
FREQUENCY=25                 # PWM frequency in Hz. 2-wire power switching: stay low (25-100 Hz). 4-wire PWM lead: use 25000 for 25 kHz.
MIN_TEMP=50                  # Minimum temp for the curve (C). Below this, apply MIN_DUTY.
MAX_TEMP=70                  # Maximum temp for the curve (C). Fan reaches MAX_DUTY here.
MIN_DUTY=20                  # Minimum duty (%) used at MIN_TEMP.
MAX_DUTY=100                 # Maximum duty (%) reached at MAX_TEMP.

# Startup kick
KICK_DUTY=100                # percent (converted to raw internally)
KICK_TIME_SECONDS=2

# Behavior
TEMP_POLL_SECONDS=5
DEBUG=false
```
Key tuning points:
- `INVERT_PWM`: set to `1` for active-low wiring (Orange Pi default), `0` for Raspberry Pi–style active-high.
- `PWMCHIP` / `PWM_CHANNEL`: point to the PWM device for your board.
- `FREQUENCY`: PWM frequency in Hz. For 4-wire fans driven on the PWM lead, 25 kHz (25000 Hz) follows the common spec. For 2-wire fans that are power-switched with a MOSFET and have bulk capacitance on the board, use a lower frequency (e.g., 25-100 Hz) to avoid the cap averaging the PWM to "always on." If you see the fan pegged at 100% even at 1 kHz (1000 Hz), drop closer to 25 Hz.
- `MIN_TEMP`/`MAX_TEMP` (C) and `MIN_DUTY`/`MAX_DUTY` (percent): define the linear ramp.
- `TEMP_POLL_SECONDS`: how often to read temperature.
- `DEBUG=true`: enable verbose logs from the service.

If your PWM hardware cannot hit 25 kHz or you see the fan stuck at 100% when power-switching a 2-wire fan, lower `FREQUENCY` (e.g., to 25 Hz).

## Usage
- Check status: `sudo systemctl status pisimplefancontrol.service`
- Tail logs: `sudo journalctl -u pisimplefancontrol.service -f`
- Run ad-hoc: `sudo pisimplefancontrol.sh --config /etc/pisimplefancontrol.conf --debug`

## Uninstall
```bash
sudo systemctl stop pisimplefancontrol.service
sudo systemctl disable pisimplefancontrol.service
sudo rm -f /etc/systemd/system/pisimplefancontrol.service
sudo rm -f /usr/local/bin/pisimplefancontrol.sh
sudo rm -f /etc/pisimplefancontrol.conf
sudo systemctl daemon-reload
```

## Repository & License
- Repo: https://github.com/ericogr/pisimplefancontrol
- License: MIT (see `LICENSE`)
