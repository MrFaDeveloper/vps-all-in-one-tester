#!/usr/bin/env bash
# VPS BENCH / ALL-IN-ONE
# A single, readable runner for the VPS checks commonly used in the VPS topic.
#
# Usage:
#   bash vps-bench.sh
#   bash vps-bench.sh --dry-run
#   VPS_BENCH_TIMEOUT=900 bash vps-bench.sh
#
# The script installs only missing test dependencies when a supported package
# manager and root/passwordless sudo are available. Use --no-install to opt out.

set -u
set -o pipefail

readonly APP_NAME="VPS BENCH / ALL-IN-ONE"
readonly APP_VERSION="1.1.0"
readonly RUN_ID="$(date -u +%Y%m%d-%H%M%S)"
readonly START_EPOCH="$(date +%s)"
readonly LOG_FILE="${VPS_BENCH_LOG_FILE:-./vps-bench-${RUN_ID}.log}"
TEST_TIMEOUT="${VPS_BENCH_TIMEOUT:-900}"
readonly DOWNLOAD_TIMEOUT="${VPS_BENCH_DOWNLOAD_TIMEOUT:-45}"

# Some non-interactive SSH sessions do not export TERM. Several upstream
# terminal-oriented checks expect it to exist even when they only emit text.
TERM="${TERM:-xterm-256color}"
export TERM

DRY_RUN=0
USE_NO_COLOR=0
AUTO_INSTALL="${VPS_BENCH_AUTO_INSTALL:-1}"
BASH_MAJOR="${BASH_VERSINFO[0]:-0}"
CURRENT_TEST=""
TOTAL=0
PASSED=0
FAILED=0
SKIPPED=0
WARNINGS=0

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_RESET=$'\033[0m'
  C_DIM=$'\033[2m'
  C_BOLD=$'\033[1m'
  C_CYAN=$'\033[38;5;81m'
  C_BLUE=$'\033[38;5;111m'
  C_GREEN=$'\033[38;5;114m'
  C_YELLOW=$'\033[38;5;221m'
  C_RED=$'\033[38;5;203m'
  C_WHITE=$'\033[38;5;255m'
else
  C_RESET=""
  C_DIM=""
  C_BOLD=""
  C_CYAN=""
  C_BLUE=""
  C_GREEN=""
  C_YELLOW=""
  C_RED=""
  C_WHITE=""
fi

usage() {
  cat <<'EOF'
VPS BENCH / ALL-IN-ONE

Runs the VPS checks used in the VPS topic and prints a unified report.

Options:
  --dry-run       Render the complete UI without executing network tests.
  --no-install    Do not install missing packages automatically.
  --no-color      Disable ANSI colors.
  --timeout SEC   Per-test timeout (default: 900 seconds).
  --help          Show this help.

Environment:
  VPS_BENCH_LOG_FILE       Exact path for the raw combined log.
  VPS_BENCH_AUTO_INSTALL   Set to 0 to disable dependency installation.
  VPS_BENCH_TIMEOUT        Per-test timeout in seconds.
  VPS_BENCH_DOWNLOAD_TIMEOUT
                           Timeout for downloading third-party scripts.
EOF
}

while (($#)); do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      ;;
    --no-install)
      AUTO_INSTALL=0
      ;;
    --no-color)
      USE_NO_COLOR=1
      C_RESET=""; C_DIM=""; C_BOLD=""; C_CYAN=""; C_BLUE=""
      C_GREEN=""; C_YELLOW=""; C_RED=""; C_WHITE=""
      ;;
    --timeout)
      if [[ $# -lt 2 || ! "$2" =~ ^[0-9]+$ || "$2" -lt 1 ]]; then
        printf 'Invalid --timeout value.\n' >&2
        exit 2
      fi
      TEST_TIMEOUT="$2"
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      printf 'Unknown option: %s\n\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

if [[ ! "$TEST_TIMEOUT" =~ ^[0-9]+$ || "$TEST_TIMEOUT" -lt 1 ]]; then
  printf 'VPS_BENCH_TIMEOUT must be a positive integer.\n' >&2
  exit 2
fi

if [[ "$AUTO_INSTALL" != 0 && "$AUTO_INSTALL" != 1 ]]; then
  printf 'VPS_BENCH_AUTO_INSTALL must be 0 or 1.\n' >&2
  exit 2
fi

if ! mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null; then
  printf 'Cannot create log directory for %s\n' "$LOG_FILE" >&2
  exit 2
fi

: >"$LOG_FILE" || {
  printf 'Cannot write log file: %s\n' "$LOG_FILE" >&2
  exit 2
}

timestamp() { date -u '+%Y-%m-%d %H:%M:%S UTC'; }

term_width() {
  local width
  width="$(tput cols 2>/dev/null || true)"
  [[ "$width" =~ ^[0-9]+$ ]] || width=100
  ((width < 78)) && width=78
  ((width > 118)) && width=118
  printf '%s' "$width"
}

WIDTH="$(term_width)"

repeat_char() {
  local char="$1" count="$2"
  local out=""
  while ((count-- > 0)); do out+="$char"; done
  printf '%s' "$out"
}

box_line() {
  printf '%s%s%s%s%s\n' "$C_CYAN" '╭' "$(repeat_char '─' $((WIDTH - 2)))" '╮' "$C_RESET"
}

box_bottom() {
  printf '%s%s%s%s%s\n' "$C_CYAN" '╰' "$(repeat_char '─' $((WIDTH - 2)))" '╯' "$C_RESET"
}

box_text() {
  local text="$1"
  local max=$((WIDTH - 5))
  text="${text:0:max}"
  printf '%s│%s %-*s %s│%s\n' "$C_CYAN" "$C_WHITE" "$((WIDTH - 4))" "$text" "$C_CYAN" "$C_RESET"
}

status_tag() {
  case "$1" in
    PASS) printf '%sPASS%s' "$C_GREEN" "$C_RESET" ;;
    FAIL) printf '%sFAIL%s' "$C_RED" "$C_RESET" ;;
    SKIP) printf '%sSKIP%s' "$C_YELLOW" "$C_RESET" ;;
    WARN) printf '%sWARN%s' "$C_YELLOW" "$C_RESET" ;;
    RUN)  printf '%sRUN %s' "$C_BLUE" "$C_RESET" ;;
    *)    printf '%s%s%s' "$C_WHITE" "$1" "$C_RESET" ;;
  esac
}

append_log() {
  printf '%s %s\n' "[$(timestamp)]" "$*" >>"$LOG_FILE"
}

command_present() {
  command -v "$1" >/dev/null 2>&1
}

missing_requirements() {
  command_present curl || printf '%s\n' curl
  command_present wget || printf '%s\n' wget
  command_present timeout || command_present gtimeout || printf '%s\n' timeout
  command_present iperf3 || printf '%s\n' iperf3
  command_present sysbench || printf '%s\n' sysbench
  command_present fio || printf '%s\n' fio
  command_present jq || printf '%s\n' jq
  command_present bc || printf '%s\n' bc
  command_present openssl || printf '%s\n' openssl
  if [[ ! -f /etc/ssl/certs/ca-certificates.crt && ! -f /etc/pki/tls/certs/ca-bundle.crt ]]; then
    printf '%s\n' ca-certificates
  fi
}

detect_package_manager() {
  if command_present apt-get; then
    printf '%s' apt
  elif command_present dnf; then
    printf '%s' dnf
  elif command_present yum; then
    printf '%s' yum
  elif command_present apk; then
    printf '%s' apk
  elif command_present zypper; then
    printf '%s' zypper
  elif command_present pacman; then
    printf '%s' pacman
  else
    return 1
  fi
}

package_name() {
  local manager="$1" requirement="$2"
  case "$manager:$requirement" in
    apt:curl|dnf:curl|yum:curl|apk:curl|zypper:curl|pacman:curl) printf '%s' curl ;;
    apt:wget|dnf:wget|yum:wget|apk:wget|zypper:wget|pacman:wget) printf '%s' wget ;;
    apt:timeout|dnf:timeout|yum:timeout|apk:timeout|zypper:timeout|pacman:timeout) printf '%s' coreutils ;;
    apt:iperf3|dnf:iperf3|yum:iperf3|apk:iperf3|zypper:iperf3|pacman:iperf3) printf '%s' iperf3 ;;
    apt:sysbench|dnf:sysbench|yum:sysbench|apk:sysbench|zypper:sysbench|pacman:sysbench) printf '%s' sysbench ;;
    apt:fio|dnf:fio|yum:fio|apk:fio|zypper:fio|pacman:fio) printf '%s' fio ;;
    apt:jq|dnf:jq|yum:jq|apk:jq|zypper:jq|pacman:jq) printf '%s' jq ;;
    apt:bc|dnf:bc|yum:bc|apk:bc|zypper:bc|pacman:bc) printf '%s' bc ;;
    apt:openssl|dnf:openssl|yum:openssl|apk:openssl|zypper:openssl|pacman:openssl) printf '%s' openssl ;;
    apt:ca-certificates|dnf:ca-certificates|yum:ca-certificates|apk:ca-certificates|zypper:ca-certificates|pacman:ca-certificates) printf '%s' ca-certificates ;;
    *) return 1 ;;
  esac
}

contains_word() {
  case " $1 " in
    *" $2 "*) return 0 ;;
    *) return 1 ;;
  esac
}

run_privileged() {
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    "$@"
    return $?
  fi
  if command_present sudo && sudo -n true 2>/dev/null; then
    sudo -n "$@"
    return $?
  fi
  return 126
}

install_with_manager() {
  local manager="$1" rc
  shift
  case "$manager" in
    apt)
      run_privileged env DEBIAN_FRONTEND=noninteractive apt-get update -qq 2>&1 | tee -a "$LOG_FILE"
      rc="${PIPESTATUS[0]}"
      ((rc == 0)) || return "$rc"
      run_privileged env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@" 2>&1 | tee -a "$LOG_FILE"
      return "${PIPESTATUS[0]}"
      ;;
    dnf)
      dnf_args=("$@")
      run_privileged dnf install -y "${dnf_args[@]}" 2>&1 | tee -a "$LOG_FILE"
      return "${PIPESTATUS[0]}"
      ;;
    yum)
      yum_args=("$@")
      run_privileged yum install -y "${yum_args[@]}" 2>&1 | tee -a "$LOG_FILE"
      return "${PIPESTATUS[0]}"
      ;;
    apk)
      apk_args=("$@")
      run_privileged apk add --no-cache "${apk_args[@]}" 2>&1 | tee -a "$LOG_FILE"
      return "${PIPESTATUS[0]}"
      ;;
    zypper)
      zypper_args=("$@")
      run_privileged zypper --non-interactive install --no-recommends "${zypper_args[@]}" 2>&1 | tee -a "$LOG_FILE"
      return "${PIPESTATUS[0]}"
      ;;
    pacman)
      pacman_args=("$@")
      run_privileged pacman -Sy --noconfirm --needed "${pacman_args[@]}" 2>&1 | tee -a "$LOG_FILE"
      return "${PIPESTATUS[0]}"
      ;;
    *)
      return 127
      ;;
  esac
}

bootstrap_dependencies() {
  local missing manager requirement package packages missing_display remaining
  missing="$(missing_requirements)"
  if [[ -z "$missing" ]]; then
    printf '%s  Dependencies: ready%s\n' "$C_GREEN" "$C_RESET"
    append_log 'DEPENDENCY_CHECK status=ready'
    return 0
  fi

  missing_display="$(printf '%s\n' "$missing" | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '%s  [dry-run] Missing dependencies: %s%s\n' "$C_YELLOW" "$missing_display" "$C_RESET"
    append_log "DEPENDENCY_CHECK status=dry-run missing=$missing_display"
    return 0
  fi
  if [[ "$AUTO_INSTALL" -ne 1 ]]; then
    printf '%s  Auto-install disabled. Missing: %s%s\n' "$C_YELLOW" "$missing_display" "$C_RESET"
    append_log "DEPENDENCY_CHECK status=disabled missing=$missing_display"
    return 1
  fi

  manager="$(detect_package_manager || true)"
  if [[ -z "$manager" ]]; then
    printf '%s  No supported package manager found. Missing: %s%s\n' "$C_RED" "$missing_display" "$C_RESET"
    append_log "DEPENDENCY_CHECK status=no-package-manager missing=$missing_display"
    return 1
  fi
  if [[ "${EUID:-$(id -u)}" -ne 0 ]] && ! (command_present sudo && sudo -n true 2>/dev/null); then
    printf '%s  Root or passwordless sudo is required to install: %s%s\n' "$C_RED" "$missing_display" "$C_RESET"
    append_log "DEPENDENCY_CHECK status=insufficient-privileges manager=$manager missing=$missing_display"
    return 1
  fi

  packages=""
  while IFS= read -r requirement; do
    [[ -n "$requirement" ]] || continue
    package="$(package_name "$manager" "$requirement" || true)"
    [[ -n "$package" ]] || continue
    if ! contains_word "$packages" "$package"; then
      packages="${packages:+$packages }$package"
    fi
  done <<<"$missing"

  if [[ -z "$packages" ]]; then
    printf '%s  Could not map missing dependencies for %s: %s%s\n' "$C_RED" "$manager" "$missing_display" "$C_RESET"
    append_log "DEPENDENCY_CHECK status=unmapped manager=$manager missing=$missing_display"
    return 1
  fi

  printf '%s%s DEPENDENCY BOOTSTRAP %s%s\n' "$C_BOLD" "$C_CYAN" "$C_RESET" "$(repeat_char '─' $((WIDTH - 25)))"
  printf '  Package manager: %s\n' "$manager"
  printf '  Installing missing: %s\n' "$packages"
  append_log "DEPENDENCY_INSTALL manager=$manager packages=$packages"
  if ! install_with_manager "$manager" $packages; then
    printf '%s  Package installation failed; tests will continue with available tools.%s\n' "$C_RED" "$C_RESET"
    append_log "DEPENDENCY_INSTALL status=failed manager=$manager packages=$packages"
    return 1
  fi

  remaining="$(missing_requirements)"
  if [[ -z "$remaining" ]]; then
    printf '%s  Dependencies installed and verified.%s\n' "$C_GREEN" "$C_RESET"
    append_log "DEPENDENCY_INSTALL status=verified manager=$manager packages=$packages"
    return 0
  fi
  printf '%s  Installation finished, but still missing: %s%s\n' "$C_YELLOW" "$(printf '%s\n' "$remaining" | tr '\n' ' ')" "$C_RESET"
  append_log "DEPENDENCY_INSTALL status=partial manager=$manager remaining=$remaining"
  return 1
}

print_header() {
  clear 2>/dev/null || true
  box_line
  box_text "$APP_NAME  •  v$APP_VERSION"
  box_text "Network, region, reachability, performance and system diagnostics"
  box_text "Started: $(timestamp)  •  Host: $(hostname 2>/dev/null || printf unknown)"
  box_bottom
  printf '\n'
}

print_system_snapshot() {
  local os kernel arch cpu memory disk uptime_text public_ip
  os="$(. /etc/os-release 2>/dev/null && printf '%s %s' "${PRETTY_NAME:-${NAME:-unknown}}" "${VERSION_ID:-}" || uname -s)"
  kernel="$(uname -sr 2>/dev/null || printf unknown)"
  arch="$(uname -m 2>/dev/null || printf unknown)"
  cpu="$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || printf unknown) vCPU"
  if command -v free >/dev/null 2>&1; then
    memory="$(free -h | awk '/^Mem:/ {print $3 "/" $2}')"
  else
    memory="n/a"
  fi
  disk="$(df -h / 2>/dev/null | awk 'NR==2 {print $3 "/" $2 " used (" $5 ")"}')"
  [[ -n "$disk" ]] || disk="n/a"
  uptime_text="$(uptime -p 2>/dev/null || uptime 2>/dev/null || printf unknown)"
  public_ip="n/a"
  if [[ "$DRY_RUN" -eq 0 ]] && command -v curl >/dev/null 2>&1; then
    public_ip="$(curl -4fsS --connect-timeout 5 --max-time 8 https://api.ipify.org 2>/dev/null || printf n/a)"
  fi

  printf '%s%s SYSTEM SNAPSHOT %s%s\n' "$C_BOLD" "$C_CYAN" "$C_RESET" "$(repeat_char '─' $((WIDTH - 19)))"
  printf '  %-16s %s\n' 'OS' "$os"
  printf '  %-16s %s\n' 'Bash' "${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}"
  printf '  %-16s %s\n' 'Kernel / arch' "$kernel / $arch"
  printf '  %-16s %s\n' 'CPU' "$cpu"
  printf '  %-16s %s\n' 'Memory' "$memory"
  printf '  %-16s %s\n' 'Root disk' "$disk"
  printf '  %-16s %s\n' 'Uptime' "$uptime_text"
  printf '  %-16s %s\n' 'Public IPv4' "$public_ip"
  printf '%s\n\n' "$(repeat_char '─' "$WIDTH")"
  append_log "SYSTEM OS=$os KERNEL=$kernel ARCH=$arch CPU=$cpu MEMORY=$memory DISK=$disk UPTIME=$uptime_text PUBLIC_IPV4=$public_ip"
}

section_header() {
  local index="$1" title="$2" subtitle="$3" source="${4:-local command}"
  CURRENT_TEST="$title"
  printf '\n%s┌─ %02d / 09  %s%s%s\n' "$C_CYAN" "$index" "$C_BOLD" "$title" "$C_RESET"
  printf '%s│  %s%s%s\n' "$C_CYAN" "$C_DIM" "$subtitle" "$C_RESET"
  printf '%s│  SOURCE  %s\n' "$C_CYAN" "$source"
  printf '%s└─ STATUS  %s%s%s\n' "$C_CYAN" "$C_BLUE" "$(status_tag RUN)" "$C_RESET"
  printf '%s' "$C_RESET"
  append_log "BEGIN [$index/09] $title | $subtitle | $source"
}

finish_test() {
  local rc="$1"; shift
  local status="$1"; shift
  TOTAL=$((TOTAL + 1))
  case "$status" in
    PASS) PASSED=$((PASSED + 1)) ;;
    FAIL) FAILED=$((FAILED + 1)) ;;
    SKIP) SKIPPED=$((SKIPPED + 1)) ;;
    WARN) WARNINGS=$((WARNINGS + 1)) ;;
  esac
  printf '\n%s└─ RESULT  %s  %s%s\n' "$C_CYAN" "$(status_tag "$status")" "${*:-}" "$C_RESET"
  append_log "END [$CURRENT_TEST] status=$status rc=$rc ${*:-}"
}

run_command() {
  local command_text="$1"
  local out_file="$2"
  local rc

  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '%s  [dry-run] %s%s\n' "$C_DIM" "$command_text" "$C_RESET" | tee -a "$out_file" "$LOG_FILE"
    return 0
  fi

  printf '%s  command: %s%s\n' "$C_DIM" "$command_text" "$C_RESET"
  append_log "COMMAND [$CURRENT_TEST] $command_text"
  set +e
  if command -v timeout >/dev/null 2>&1; then
    timeout --signal=TERM "$TEST_TIMEOUT" bash -c "$command_text" </dev/null 2>&1 | tee -a "$out_file" "$LOG_FILE"
    rc="${PIPESTATUS[0]}"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout --signal=TERM "$TEST_TIMEOUT" bash -c "$command_text" </dev/null 2>&1 | tee -a "$out_file" "$LOG_FILE"
    rc="${PIPESTATUS[0]}"
  else
    bash -c "$command_text" </dev/null 2>&1 | tee -a "$out_file" "$LOG_FILE"
    rc="${PIPESTATUS[0]}"
  fi
  set -e
  return "$rc"
}

test_file=""
new_output_file() {
  test_file="$(mktemp "${TMPDIR:-/tmp}/vps-bench.XXXXXX")"
  printf '%s' "$test_file"
}

have_downloader() {
  command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1
}

download_script() {
  local url="$1" destination="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fL --retry 2 --connect-timeout 10 --max-time "$DOWNLOAD_TIMEOUT" -sS "$url" -o "$destination"
  elif command -v wget >/dev/null 2>&1; then
    wget -q --timeout=10 --tries=2 -O "$destination" "$url"
  else
    return 127
  fi
}

run_remote_script() {
  local url="$1"; shift
  local script_file="$TMP_ROOT/remote_$(printf '%s' "$url" | cksum | awk '{print $1}').sh"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '%s  [dry-run] download %s%s\n' "$C_DIM" "$url" "$C_RESET"
    printf '%s  [dry-run] execute: bash %s %s%s\n' "$C_DIM" "$script_file" "$*" "$C_RESET"
    return 0
  fi
  if [[ ! -s "$script_file" ]]; then
    if ! download_script "$url" "$script_file"; then
      printf '%s  download failed: %s%s\n' "$C_RED" "$url" "$C_RESET"
      return 1
    fi
    chmod 700 "$script_file" 2>/dev/null || true
  fi
  bash "$script_file" "$@"
}

# Remote checks are executed in a timeout-controlled child Bash. Export only
# the two helper functions and the small set of values they need.
export -f download_script run_remote_script
export TMP_ROOT DOWNLOAD_TIMEOUT DRY_RUN

run_one() {
  local index="$1" title="$2" subtitle="$3" source="$4" command_text="$5"
  local out rc status
  section_header "$index" "$title" "$subtitle" "$source"
  out="$(new_output_file)"
  if run_command "$command_text" "$out"; then
    rc=0
    status=PASS
  else
    rc=$?
    status=FAIL
  fi
  finish_test "$rc" "$status" ""
  rm -f "$out"
}

run_optional_sysbench() {
  local out rc status
  section_header 9 "CPU / SYSBENCH" "Single-thread CPU benchmark, as requested" "sysbench cpu run --threads=1"
  if ! command -v sysbench >/dev/null 2>&1 && [[ "$DRY_RUN" -eq 0 ]]; then
    printf '%s  sysbench is not installed on this VPS.%s\n' "$C_YELLOW" "$C_RESET"
    finish_test 127 SKIP "sysbench not found"
    return
  fi
  out="$(new_output_file)"
  if run_command 'sysbench cpu run --threads=1' "$out"; then
    rc=0; status=PASS
  else
    rc=$?; status=FAIL
  fi
  finish_test "$rc" "$status" ""
  rm -f "$out"
}

print_summary() {
  local elapsed
  elapsed=$(( $(date +%s) - START_EPOCH ))
  printf '\n'
  box_line
  box_text "RUN COMPLETE  •  $(timestamp)"
  box_text "PASS  $PASSED   FAIL  $FAILED   SKIP  $SKIPPED   TOTAL  $TOTAL"
  box_text "Elapsed: ${elapsed}s  •  Raw log: $LOG_FILE"
  box_bottom
  if ((FAILED > 0)); then
    printf '%s%s  One or more checks failed. Read the raw output above and the log file.%s\n' "$C_RED" "$C_BOLD" "$C_RESET"
  elif ((SKIPPED > 0)); then
    printf '%s  Completed with skipped checks. Review dependency bootstrap and rerun if needed.%s\n' "$C_YELLOW" "$C_RESET"
  else
    printf '%s  All checks returned successfully. Review the measurements, not only the exit codes.%s\n' "$C_GREEN" "$C_RESET"
  fi
  printf '\n'
  append_log "SUMMARY pass=$PASSED fail=$FAILED skip=$SKIPPED total=$TOTAL elapsed=${elapsed}s"
}

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/vps-bench.XXXXXX")"
cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

print_header
bootstrap_dependencies || true
print_system_snapshot

if ! have_downloader && [[ "$DRY_RUN" -eq 0 ]]; then
  printf '%s%s  Neither curl nor wget is available. Remote checks will be SKIP.%s\n' "$C_YELLOW" "$C_BOLD" "$C_RESET"
fi

if [[ "$DRY_RUN" -eq 0 && "$BASH_MAJOR" -lt 4 ]]; then
  printf '%s%s  Bash 4+ is required by several upstream checks; remote checks will be SKIP on this host.%s\n' "$C_YELLOW" "$C_BOLD" "$C_RESET"
fi

if [[ "$DRY_RUN" -eq 0 ]] && ! command -v timeout >/dev/null 2>&1 && ! command -v gtimeout >/dev/null 2>&1; then
  printf '%s  No timeout utility found; per-test timeout cannot be enforced on this host.%s\n' "$C_YELLOW" "$C_RESET"
fi

IPREGION_URL="https://ipregion.vrnt.xyz"
CENSORCHECK_URL="https://github.com/vernette/censorcheck/raw/master/censorcheck.sh"
RUSSIAN_IPERF_URL="https://github.com/itdoginfo/russian-iperf3-servers/raw/main/speedtest.sh"
YABS_URL="https://yabs.sh"
IP_CHECK_URL="https://IP.Check.Place"
BENCH_URL="https://bench.sh"
IPQUALITY_URL="https://Check.Place"

if [[ "$DRY_RUN" -eq 1 || ("$BASH_MAJOR" -ge 4 && "$(have_downloader; printf '%s' "$?")" -eq 0) ]]; then
  run_one 1 "IP REGION" "IP address, ASN, geolocation and regional attribution" "$IPREGION_URL" \
    "run_remote_script '$IPREGION_URL'"
  run_one 2 "CENSORCHECK / GEOBLOCK" "Checks access to region-sensitive resources" "$CENSORCHECK_URL  --mode geoblock" \
    "run_remote_script '$CENSORCHECK_URL' --mode geoblock"
  run_one 3 "CENSORCHECK / DPI" "Checks DPI behavior for Russian services" "$CENSORCHECK_URL  --mode dpi" \
    "run_remote_script '$CENSORCHECK_URL' --mode dpi"
  run_one 4 "RUSSIAN IPERF3" "Throughput tests to Russian iPerf3 endpoints" "$RUSSIAN_IPERF_URL" \
    "run_remote_script '$RUSSIAN_IPERF_URL'"
  run_one 5 "YABS / IPv4" "CPU, memory, disk, network and benchmark bundle" "$YABS_URL  -4" \
    "run_remote_script '$YABS_URL' -4"
  run_one 6 "IP CHECK PLACE" "Checks whether the server IP is blocked by foreign services" "$IP_CHECK_URL  -l en" \
    "run_remote_script '$IP_CHECK_URL' -l en"
  run_one 7 "BENCH.SH" "Server parameters and speed to international providers" "$BENCH_URL" \
    "run_remote_script '$BENCH_URL'"
  run_one 8 "IPQUALITY / CHECK.PLACE" "IP reputation, quality and external reachability" "$IPQUALITY_URL  -EI" \
    "run_remote_script '$IPQUALITY_URL' -EI"
else
  if [[ "$BASH_MAJOR" -lt 4 && "$DRY_RUN" -eq 0 ]]; then
    skip_reason='Bash 4+ required by upstream checks'
  else
    skip_reason='curl/wget not found'
  fi
  skip_index=0
  for item in \
    'IP REGION|IP address, ASN, geolocation and regional attribution|https://ipregion.vrnt.xyz' \
    'CENSORCHECK / GEOBLOCK|Checks access to region-sensitive resources|https://github.com/vernette/censorcheck/raw/master/censorcheck.sh --mode geoblock' \
    'CENSORCHECK / DPI|Checks DPI behavior for Russian services|https://github.com/vernette/censorcheck/raw/master/censorcheck.sh --mode dpi' \
    'RUSSIAN IPERF3|Throughput tests to Russian iPerf3 endpoints|https://github.com/itdoginfo/russian-iperf3-servers/raw/main/speedtest.sh' \
    'YABS / IPv4|CPU, memory, disk, network and benchmark bundle|https://yabs.sh -4' \
    'IP CHECK PLACE|Checks whether the server IP is blocked by foreign services|https://IP.Check.Place -l en' \
    'BENCH.SH|Server parameters and speed to international providers|https://bench.sh' \
    'IPQUALITY / CHECK.PLACE|IP reputation, quality and external reachability|https://Check.Place -EI'; do
    IFS='|' read -r title subtitle source <<<"$item"
    skip_index=$((skip_index + 1))
    section_header "$skip_index" "$title" "$subtitle" "$source"
    finish_test 127 SKIP "$skip_reason"
  done
fi

run_optional_sysbench
print_summary

if ((FAILED > 0)); then
  exit 1
fi
exit 0
