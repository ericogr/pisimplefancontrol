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

FREQUENCY=25                 # Hz. Use 25000 for 25 kHz (4-wire PWM lead) if hardware supports it.
MIN_TEMP=45                  # Celsius
MAX_TEMP=75                  # Celsius
MIN_DUTY=20                  # percent
MAX_DUTY=100                 # percent
KICK_DUTY=100                # percent
KICK_TIME_SECONDS=2
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
  echo "[INIT] Kick start: ${KICK_DUTY}%"
  apply_duty "$KICK_DUTY_RAW"
  sleep "$KICK_TIME_SECONDS"
}

read_temp_raw() {
  cat "$TEMP_SENSOR"
}

read_temp_c() {
  local raw
  raw=$(read_temp_raw)
  echo $(( raw / 1000 ))
}

percent_to_raw_duty() {
  local pct=$1
  if [ "$pct" -lt 0 ]; then
    pct=0
  elif [ "$pct" -gt 100 ]; then
    pct=100
  fi
  echo $(( pct * PERIOD / 100 ))
}

MIN_DUTY_RAW=0
MAX_DUTY_RAW=0
KICK_DUTY_RAW=0

compute_duty_bounds() {
  MIN_DUTY_RAW=$(percent_to_raw_duty "$MIN_DUTY")
  MAX_DUTY_RAW=$(percent_to_raw_duty "$MAX_DUTY")
  KICK_DUTY_RAW=$(percent_to_raw_duty "$KICK_DUTY")
}

select_target_duty() {
  local temp_c=$1
  if [ "$temp_c" -le "$MIN_TEMP" ]; then
    TARGET_DUTY=$MIN_DUTY_RAW
    TARGET_MODE="MIN"
  elif [ "$temp_c" -ge "$MAX_TEMP" ]; then
    TARGET_DUTY=$MAX_DUTY_RAW
    TARGET_MODE="MAX"
  else
    TARGET_DUTY=$(( MIN_DUTY_RAW + (temp_c - MIN_TEMP) * (MAX_DUTY_RAW - MIN_DUTY_RAW) / (MAX_TEMP - MIN_TEMP) ))
    TARGET_MODE="RAMP"
  fi
}

print_startup_info() {
  echo "Starting pisimplefancontrol (v$PISIMPLEFAN_VERSION) ..."
  echo "PWM chip: $PWMCHIP"
  echo "PWM channel: $PWM_CHANNEL"
  echo "GPIO path: $PWM"
  echo "Temperature sensor: $TEMP_SENSOR"
  echo "Frequency: ${FREQUENCY} Hz (period ${PERIOD} ns)"
  echo "Temperature range (C): $MIN_TEMP - $MAX_TEMP"
  echo "Duty range: ${MIN_DUTY}% - ${MAX_DUTY}%"
  echo "Poll interval: $TEMP_POLL_SECONDS s"
  debug "Debug enabled"
  if [ "$DEBUG" != true ]; then
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

    select_target_duty "$temp_c"
    pct=$(( TARGET_DUTY * 100 / PERIOD ))

    debug "[DEBUG] Mode=${TARGET_MODE} Temp raw=${temp_raw} Temp=${temp_c}C Duty raw=${TARGET_DUTY} Duty=${pct}%"
    apply_duty "$TARGET_DUTY"
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

# Backward compatibility: allow PERIOD in config but prefer FREQUENCY.
if [ -n "${PERIOD:-}" ] && [ -z "${FREQUENCY:-}" ]; then
  FREQUENCY=$(( 1000000000 / PERIOD ))
  echo "Warning: PERIOD is deprecated; set FREQUENCY (Hz) instead. Using FREQUENCY=${FREQUENCY} Hz derived from PERIOD=${PERIOD} ns."
fi

if [ -z "${FREQUENCY:-}" ] || [ "$FREQUENCY" -le 0 ]; then
  echo "Error: FREQUENCY must be set to a positive integer (Hz)."
  exit 1
fi

PERIOD=$(( 1000000000 / FREQUENCY ))

compute_duty_bounds
trap cleanup EXIT

print_startup_info
setup_pwm
kick_start_fan
main_loop
