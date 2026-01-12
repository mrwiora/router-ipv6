#!/bin/bash
# WAN Health Check Script
# Monitors WAN connectivity and automatically fails over by flushing routing tables
# This keeps interfaces UP so local devices remain reachable

set -e

# Configuration
WAN1_IF="enp7s0"
WAN2_IF="enp8s0"
WAN2_GW4="192.168.8.1"
WAN2_TEST_HOST="8.8.8.8"  # Test connectivity through WAN2
PING_COUNT=3
PING_TIMEOUT=2
CHECK_INTERVAL=10  # Seconds between health checks
FAILURE_THRESHOLD=3  # Failed checks before triggering failover

# State file
STATE_FILE="/var/run/wan-healthcheck.state"
LOG_FILE="/var/log/wan-healthcheck.log"

# Counters
wan2_failure_count=0
wan2_is_failed=false

# Logging function
log() {
    local level=$1
    shift
    local message="$@"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $message" | tee -a "$LOG_FILE"
}

# Initialize state
init_state() {
    if [ -f "$STATE_FILE" ]; then
        source "$STATE_FILE"
    else
        wan2_is_failed=false
        wan2_failure_count=0
        save_state
    fi
}

# Save state
save_state() {
    cat > "$STATE_FILE" << EOF
wan2_is_failed=$wan2_is_failed
wan2_failure_count=$wan2_failure_count
EOF
}

# Check if WAN2 is healthy
check_wan2_health() {
    # First check if interface is up
    if ! ip link show "$WAN2_IF" up &>/dev/null; then
        log "WARN" "WAN2 interface $WAN2_IF is DOWN"
        return 1
    fi

    # Check if we can ping the gateway
    if ! ping -I "$WAN2_IF" -c 1 -W "$PING_TIMEOUT" "$WAN2_GW4" &>/dev/null; then
        log "WARN" "Cannot reach WAN2 gateway $WAN2_GW4"
        return 1
    fi

    # Check if we have routes in table 200
    if ! ip route show table 200 | grep -q "default"; then
        log "WARN" "No default route in table 200 (WAN2)"
        return 1
    fi

    # Check internet connectivity through WAN2
    # Use the source address from WAN2 to ensure traffic goes through it
    local wan2_ip=$(ip -4 addr show dev "$WAN2_IF" | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
    if [ -n "$wan2_ip" ]; then
        if ! ping -I "$wan2_ip" -c "$PING_COUNT" -W "$PING_TIMEOUT" "$WAN2_TEST_HOST" &>/dev/null; then
            log "WARN" "Cannot reach internet ($WAN2_TEST_HOST) via WAN2"
            return 1
        fi
    fi

    return 0
}

# Trigger failover to WAN1
trigger_failover() {
    log "ERROR" "WAN2 has failed! Triggering failover to WAN1..."

    # Flush table 200 routes (WAN2) to trigger failover
    ip route flush table 200 2>/dev/null || true
    ip -6 route flush table 200 2>/dev/null || true

    # Mark as failed
    wan2_is_failed=true
    save_state

    log "INFO" "Failover complete. Traffic now routes via WAN1 ($WAN1_IF)"
    log "INFO" "Interface $WAN2_IF remains UP for local access to 192.168.8.0/24"

    # Optionally send notification
    # notify_admin "WAN2 Failover" "WAN2 ($WAN2_IF) has failed. Traffic switched to WAN1."
}

# Restore WAN2 as primary
restore_wan2() {
    log "INFO" "WAN2 is healthy again. Restoring as primary..."

    # Restart systemd-networkd to restore routes
    systemctl restart systemd-networkd

    # Wait for routes to be established
    sleep 3

    # Verify routes are back
    if ip route show table 200 | grep -q "default"; then
        wan2_is_failed=false
        wan2_failure_count=0
        save_state
        log "INFO" "WAN2 restored as primary successfully"
        # notify_admin "WAN2 Restored" "WAN2 ($WAN2_IF) is healthy and restored as primary."
    else
        log "ERROR" "Failed to restore WAN2 routes"
    fi
}

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "Error: This script must be run as root"
    exit 1
fi

# Initialize
init_state
log "INFO" "WAN health check started (interval: ${CHECK_INTERVAL}s, threshold: $FAILURE_THRESHOLD)"

# Main monitoring loop
while true; do
    if check_wan2_health; then
        # WAN2 is healthy
        if [ "$wan2_is_failed" = true ]; then
            # WAN2 was failed but is now healthy - restore it
            restore_wan2
        else
            # WAN2 is working normally
            wan2_failure_count=0
            save_state
            log "DEBUG" "WAN2 health check: OK"
        fi
    else
        # WAN2 health check failed
        ((wan2_failure_count++))
        save_state
        log "WARN" "WAN2 health check failed ($wan2_failure_count/$FAILURE_THRESHOLD)"

        if [ "$wan2_failure_count" -ge "$FAILURE_THRESHOLD" ] && [ "$wan2_is_failed" = false ]; then
            # Threshold reached - trigger failover
            trigger_failover
        fi
    fi

    sleep "$CHECK_INTERVAL"
done
