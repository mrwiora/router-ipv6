#!/bin/bash
# Manual failover control script
# This allows you to trigger failover without taking interfaces down,
# so you can still reach devices on the local network segment.

set -e

WAN1_IF="enp7s0"
WAN2_IF="enp8s0"
WAN1_GW4="172.17.254.1"
WAN2_GW4="192.168.8.1"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to check if running as root
check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}Error: This script must be run as root${NC}"
        exit 1
    fi
}

# Force failover to WAN1 by flushing WAN2 routing table
failover_to_wan1() {
    echo -e "${YELLOW}Forcing failover to WAN1 ($WAN1_IF)...${NC}"

    # Flush routes from table 200 (WAN2 routing table)
    # This removes WAN2 from policy routing without taking interface down
    ip route flush table 200 2>/dev/null || true
    ip -6 route flush table 200 2>/dev/null || true

    echo -e "${GREEN}✓ Failover complete${NC}"
    echo -e "  - Traffic now routes via WAN1 ($WAN1_IF)"
    echo -e "  - Interface $WAN2_IF remains UP and locally accessible"
    echo -e "  - You can still reach $WAN2_GW4 and devices on 192.168.8.0/24"
}

# Restore WAN2 as primary by reloading systemd-networkd
restore_wan2() {
    echo -e "${YELLOW}Restoring WAN2 ($WAN2_IF) as primary...${NC}"

    # Option 1: Restart networkd (reloads all interfaces)
    echo "Restarting systemd-networkd..."
    systemctl restart systemd-networkd

    # Wait a moment for routes to be established
    sleep 2

    echo -e "${GREEN}✓ WAN2 restored as primary${NC}"
}

# Alternative: Restore WAN2 by re-adding routes manually
restore_wan2_manual() {
    echo -e "${YELLOW}Manually restoring WAN2 ($WAN2_IF) routes...${NC}"

    # Re-add IPv4 default route to table 200
    ip route add default via $WAN2_GW4 dev $WAN2_IF table 200 metric 200 2>/dev/null || \
        echo "  Note: IPv4 route already exists or cannot be added"

    # Re-add IPv6 default route to table 200 (if WAN2 has IPv6)
    # Get the link-local gateway from RA
    WAN2_GW6=$(ip -6 route show dev $WAN2_IF | grep "^default" | head -1 | awk '{print $3}')
    if [ -n "$WAN2_GW6" ]; then
        ip -6 route add default via $WAN2_GW6 dev $WAN2_IF table 200 metric 200 2>/dev/null || \
            echo "  Note: IPv6 route already exists or cannot be added"
    fi

    echo -e "${GREEN}✓ WAN2 routes restored${NC}"
}

# Check current routing status
check_status() {
    echo -e "${YELLOW}=== Routing Status ===${NC}"
    echo ""

    # Check interface status
    echo -e "${GREEN}Interface Status:${NC}"
    if ip link show $WAN1_IF up &>/dev/null; then
        echo -e "  $WAN1_IF: ${GREEN}UP${NC}"
    else
        echo -e "  $WAN1_IF: ${RED}DOWN${NC}"
    fi

    if ip link show $WAN2_IF up &>/dev/null; then
        echo -e "  $WAN2_IF: ${GREEN}UP${NC}"
    else
        echo -e "  $WAN2_IF: ${RED}DOWN${NC}"
    fi
    echo ""

    # Check routing tables
    echo -e "${GREEN}IPv4 Routes:${NC}"
    echo "Table 200 (WAN2/Primary):"
    if ip route show table 200 | grep -q .; then
        ip route show table 200 | sed 's/^/  /'
    else
        echo -e "  ${RED}(empty - WAN2 not in use)${NC}"
    fi
    echo ""

    echo "Table 100 (WAN1/Fallback):"
    if ip route show table 100 | grep -q .; then
        ip route show table 100 | sed 's/^/  /'
    else
        echo -e "  ${RED}(empty - WAN1 not available)${NC}"
    fi
    echo ""

    echo -e "${GREEN}IPv6 Routes:${NC}"
    echo "Table 200 (WAN2/Primary):"
    if ip -6 route show table 200 | grep -q .; then
        ip -6 route show table 200 | sed 's/^/  /'
    else
        echo -e "  ${RED}(empty - WAN2 not in use)${NC}"
    fi
    echo ""

    echo "Table 100 (WAN1/Fallback):"
    if ip -6 route show table 100 | grep -q .; then
        ip -6 route show table 100 | sed 's/^/  /'
    else
        echo -e "  ${RED}(empty - WAN1 not available)${NC}"
    fi
    echo ""

    # Show active route
    echo -e "${GREEN}Active Routes:${NC}"
    echo -n "  IPv4 (to 8.8.8.8): "
    ROUTE_OUT=$(ip route get 8.8.8.8 2>/dev/null | head -1)
    if echo "$ROUTE_OUT" | grep -q "$WAN2_IF"; then
        echo -e "${GREEN}via $WAN2_IF (Primary)${NC}"
    elif echo "$ROUTE_OUT" | grep -q "$WAN1_IF"; then
        echo -e "${YELLOW}via $WAN1_IF (Failover)${NC}"
    else
        echo -e "${RED}No route${NC}"
    fi
    echo "    $ROUTE_OUT"

    echo -n "  IPv6 (to 2001:4860:4860::8888): "
    ROUTE_OUT6=$(ip -6 route get 2001:4860:4860::8888 2>/dev/null | head -1)
    if echo "$ROUTE_OUT6" | grep -q "$WAN2_IF"; then
        echo -e "${GREEN}via $WAN2_IF (Primary)${NC}"
    elif echo "$ROUTE_OUT6" | grep -q "$WAN1_IF"; then
        echo -e "${YELLOW}via $WAN1_IF (Failover)${NC}"
    else
        echo -e "${RED}No route${NC}"
    fi
    echo "    $ROUTE_OUT6"
    echo ""

    # Test local connectivity
    echo -e "${GREEN}Local Connectivity Tests:${NC}"
    if ping -c 1 -W 1 $WAN1_GW4 &>/dev/null; then
        echo -e "  $WAN1_GW4 ($WAN1_IF gateway): ${GREEN}REACHABLE${NC}"
    else
        echo -e "  $WAN1_GW4 ($WAN1_IF gateway): ${RED}UNREACHABLE${NC}"
    fi

    if ping -c 1 -W 1 $WAN2_GW4 &>/dev/null; then
        echo -e "  $WAN2_GW4 ($WAN2_IF gateway): ${GREEN}REACHABLE${NC}"
    else
        echo -e "  $WAN2_GW4 ($WAN2_IF gateway): ${RED}UNREACHABLE${NC}"
    fi
}

# Test connectivity through specific interface
test_interface() {
    local iface=$1
    local gateway=$2

    echo -e "${YELLOW}Testing connectivity via $iface...${NC}"

    # Ping gateway
    echo -n "  Gateway ($gateway): "
    if ping -I $iface -c 3 -W 2 $gateway &>/dev/null; then
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${RED}FAILED${NC}"
    fi

    # Try to ping internet (might fail if routing is not via this interface)
    echo -n "  Internet (8.8.8.8): "
    if ping -I $iface -c 3 -W 2 8.8.8.8 &>/dev/null; then
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${YELLOW}FAILED (expected if not active route)${NC}"
    fi
}

# Show usage
show_usage() {
    cat << EOF
Usage: $0 <command>

Commands:
    failover        Force failover to WAN1 (flush WAN2 routes)
    restore         Restore WAN2 as primary (restart networkd)
    restore-manual  Manually restore WAN2 routes without restarting networkd
    status          Show current routing status and connectivity
    test-wan1       Test connectivity via WAN1 interface
    test-wan2       Test connectivity via WAN2 interface
    help            Show this help message

Examples:
    # Trigger manual failover (keeps WAN2 interface up for local access)
    sudo $0 failover

    # Check which WAN is active
    sudo $0 status

    # Restore WAN2 as primary
    sudo $0 restore

    # Test if WAN1 is working
    sudo $0 test-wan1

Note:
    - 'failover' removes WAN2 from routing tables but keeps interface UP
    - This allows you to still reach devices on 192.168.8.0/24 network
    - Traffic automatically fails over to WAN1 via routing policy rules
    - 'restore' brings WAN2 back as primary route
EOF
}

# Main script
check_root

case "${1:-}" in
    failover)
        failover_to_wan1
        echo ""
        check_status
        ;;
    restore)
        restore_wan2
        echo ""
        check_status
        ;;
    restore-manual)
        restore_wan2_manual
        echo ""
        check_status
        ;;
    status)
        check_status
        ;;
    test-wan1)
        test_interface $WAN1_IF $WAN1_GW4
        ;;
    test-wan2)
        test_interface $WAN2_IF $WAN2_GW4
        ;;
    help|--help|-h)
        show_usage
        ;;
    *)
        echo -e "${RED}Error: Unknown command '${1:-}'${NC}"
        echo ""
        show_usage
        exit 1
        ;;
esac

exit 0
