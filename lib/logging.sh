#!/usr/bin/env bash

# ========== Configurable Options ==========
LOG_TIMESTAMP_FORMAT="%Y-%m-%d %H:%M:%S"
LOG_LEVEL="${LOG_LEVEL:-DEBUG}"  # Set to DEBUG, INFO, WARN, ERROR, etc.
NO_COLOR="${NO_COLOR:-0}"        # Set to 1 to disable color output

# ========== Colors ==========
if [[ "$NO_COLOR" -eq 1 ]]; then
  RED=''; GREEN=''; YELLOW=''; BLUE=''; PURPLE=''; CYAN=''; NC=''
else
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[1;33m'
  BLUE='\033[0;34m'
  PURPLE='\033[0;35m'
  CYAN='\033[0;36m'
  NC='\033[0m'
fi

# ========== Internal ==========
_log_ts() {
  date +"$LOG_TIMESTAMP_FORMAT"
}

_log() {
  local level="$1"
  local color="$2"
  shift 2
  echo -e "${color}[$(_log_ts)] [$level]${NC} $*" >&2
}

# ========== Log Functions ==========

log_info()     { [[ "$LOG_LEVEL" =~ INFO|DEBUG|TRACE ]] && _log "INFO"    "$GREEN"  "$@"; }
log_warn()     { [[ "$LOG_LEVEL" =~ WARN|INFO|DEBUG|TRACE ]] && _log "WARN"    "$YELLOW" "$@"; }
log_error()    { [[ "$LOG_LEVEL" =~ ERROR|WARN|INFO|DEBUG|TRACE ]] && _log "ERROR"   "$RED"    "$@"; }
log_debug()    { [[ "$LOG_LEVEL" =~ DEBUG|TRACE ]] && _log "DEBUG"   "$BLUE"   "$@"; }
log_trace()    { [[ "$LOG_LEVEL" =~ TRACE ]] && _log "TRACE"   "$CYAN"   "$@"; }
log_success()  { [[ "$LOG_LEVEL" =~ INFO|DEBUG|TRACE ]] && _log "SUCCESS" "$GREEN"  "$@"; }
log_fatal()    { _log "FATAL" "$RED" "$@"; exit 1; }
log_start()    { [[ "$LOG_LEVEL" =~ INFO|DEBUG|TRACE ]] && _log "START"   "$YELLOW" "$@"; }
log_note()     { [[ "$LOG_LEVEL" =~ INFO|DEBUG|TRACE ]] && _log "NOTE"    "$PURPLE" "$@"; }
