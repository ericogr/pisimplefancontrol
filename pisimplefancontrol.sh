#!/bin/bash
# Disable the default fan service (Orange Pi)
# - the default service only supports on/off and 50%
# sudo systemctl disable pwm-fan.service
# sudo systemctl mask pwm-fan.service

PISIMPLEFAN_VERSION="1.1.0"

# Default values
INVERT_PWM=1                 # 0 = normal (raspberry), 1 = inverted (active-low orange pi)
PWMCHIP="/sys/class/pwm/pwmchip0"
PWM_CHANNEL=0
PWM="$PWMCHIP/pwm$PWM_CHANNEL"
TEMP_SENSOR="/sys/class/thermal/thermal_zone0/temp"

PERIOD=40000000              # 25 Hz
MIN_TEMP=45000               # 45 C
MAX_TEMP=75000               # 75 C
MIN_DUTY=8000000             # 20%
MAX_DUTY=40000000            # 100%
KICK_DUTY=40000000
KICK_TIME=2
TEMP_POLL_SECONDS=5
DEBUG=false

CONFIG_FILE="/etc/pisimplefancontrol.conf"
CLI_DEBUG_OVERRIDE=""

usage() {
  cat <<EOF
pisimplefancontrol v$PISIMPLEFAN_VERSION

Usage: $(basename "$0") [options]
  -c, --config <file>      Path to configuration file (default: $CONFIG_FILE)
  -d, --debug              Enable verbose logging (overrides config)
  -h, --help               Show this help
EOF
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      -c|--config)
        if [ -z "$2" ]; then
          echo "Error: missing file path for $1"
          exit 1
        fi
        CONFIG_FILE="$2"
        shift 2
        ;;
      -d|--debug)
        CLI_DEBUG_OVERRIDE=true
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        echo "Unknown option: $1"
        usage
        exit 1
        ;;
    esac
  done
}

debug() {
  if [ "$DEBUG" = true ]; then
    echo "$1"
  fi
}

ensure_pwm_paths() {
  if [ ! -d "$PWMCHIP" ]; then
    echo "Error: PWM device not found at $PWMCHIP"
    exit 1
  fi

  if [ ! -d "$PWM" ]; then
    echo 0 > "$PWMCHIP/export"
  fi
}

apply_duty() {
  local duty=$1
  if [ "$INVERT_PWM" -eq 1 ]; then
    echo $(( PERIOD - duty )) > "$PWM/duty_cycle"
  else
    echo "$duty" > "$PWM/duty_cycle"
  fi
}

setup_pwm() {
  ensure_pwm_paths
  echo "$PERIOD" > "$PWM/period"
  apply_duty 0
  echo 1 > "$PWM/enable"
}

kick_start_fan() {
  echo "[INIT] Kick start: 100%"
  apply_duty "$KICK_DUTY"
  sleep "$KICK_TIME"
}

read_temp_raw() {
  cat "$TEMP_SENSOR"
}

read_temp_c() {
  local raw
  raw=$(read_temp_raw)
  echo $(( raw / 1000 ))
}

select_target_duty() {
  local temp_raw=$1
  if [ "$temp_raw" -le "$MIN_TEMP" ]; then
    TARGET_DUTY=$MIN_DUTY
    TARGET_MODE="MIN"
  elif [ "$temp_raw" -ge "$MAX_TEMP" ]; then
    TARGET_DUTY=$MAX_DUTY
    TARGET_MODE="MAX"
  else
    TARGET_DUTY=$(( MIN_DUTY + (temp_raw - MIN_TEMP) * (MAX_DUTY - MIN_DUTY) / (MAX_TEMP - MIN_TEMP) ))
    TARGET_MODE="RAMP"
  fi
}

print_startup_info() {
  echo "Starting pisimplefancontrol (v$PISIMPLEFAN_VERSION) ..."
  echo "PWM chip: $PWMCHIP"
  echo "PWM channel: $PWM_CHANNEL"
  echo "GPIO path: $PWM"
  echo "Temperature sensor: $TEMP_SENSOR"
  echo "Period: $PERIOD"
  echo "Temperature range (mC): $MIN_TEMP - $MAX_TEMP"
  echo "Duty range: $MIN_DUTY - $MAX_DUTY"
  echo "Poll interval: $TEMP_POLL_SECONDS s"
  if [ "$DEBUG" = true ]; then
    echo "Debug enabled"
  else
    echo "Debug disabled (use --debug or set DEBUG=true in the config file)"
  fi
}

cleanup() {
  echo "Exiting and turning fan off (duty 0)"
  apply_duty 0
  echo 0 > "$PWM/enable"
  exit 0
}

main_loop() {
  while true; do
    local temp_raw temp_c pct
    temp_raw=$(read_temp_raw)
    temp_c=$(( temp_raw / 1000 ))

    select_target_duty "$temp_raw"
    pct=$(( TARGET_DUTY * 100 / PERIOD ))

    debug "[DEBUG] Temp raw=${temp_raw}  Mode=${TARGET_MODE}  Duty=${TARGET_DUTY} (${pct}%)"
    apply_duty "$TARGET_DUTY"

    echo "[FAN] Temp=${temp_c}C  Mode=${TARGET_MODE}  Duty=${pct}%"
    sleep "$TEMP_POLL_SECONDS"
  done
}

parse_args "$@"

if [ -r "$CONFIG_FILE" ]; then
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
else
  echo "Warning: configuration file not found at $CONFIG_FILE. Using default values."
fi

if [ -n "$CLI_DEBUG_OVERRIDE" ]; then
  DEBUG=$CLI_DEBUG_OVERRIDE
fi

PWM=${PWM:-$PWMCHIP/pwm${PWM_CHANNEL:-0}}
TEMP_SENSOR=${TEMP_SENSOR:-${TEMP:-/sys/class/thermal/thermal_zone0/temp}}

trap cleanup EXIT

print_startup_info
setup_pwm
kick_start_fan
main_loop
