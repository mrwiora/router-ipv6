#!/bin/bash
# Quick installation script for failover control functionality
# This script installs the manual failover control and optional automated health checking

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}======================================${NC}"
echo -e "${BLUE}Failover Control Installation Script${NC}"
echo -e "${BLUE}======================================${NC}"
echo ""

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Error: This script must be run as root${NC}"
    echo "Usage: sudo $0"
    exit 1
fi

# Get script directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

echo -e "${YELLOW}Step 1: Updating network configuration...${NC}"
echo "Adding routing policy rules to keep WAN gateways reachable during failover"

# Apply the network configuration with WAN exclusion rules
if [ -f "$SCRIPT_DIR/etc/systemd/network/10-enp1s0.network" ]; then
    cp "$SCRIPT_DIR/etc/systemd/network/10-enp1s0.network" /etc/systemd/network/
    echo -e "${GREEN}✓ Network configuration updated${NC}"
else
    echo -e "${RED}✗ Network configuration file not found!${NC}"
    exit 1
fi

echo ""
echo -e "${YELLOW}Step 2: Installing failover control script...${NC}"

# Install the manual failover control script
if [ -f "$SCRIPT_DIR/failover-control.sh" ]; then
    cp "$SCRIPT_DIR/failover-control.sh" /usr/local/bin/
    chmod +x /usr/local/bin/failover-control.sh
    echo -e "${GREEN}✓ Failover control script installed to /usr/local/bin/failover-control.sh${NC}"
else
    echo -e "${RED}✗ failover-control.sh not found!${NC}"
    exit 1
fi

echo ""
echo -e "${YELLOW}Step 3: Restarting systemd-networkd...${NC}"
systemctl restart systemd-networkd

# Wait for network to stabilize
echo "Waiting for network interfaces to come up..."
sleep 3

echo -e "${GREEN}✓ Network restarted${NC}"

echo ""
echo -e "${YELLOW}Step 4: Verifying routing policy rules...${NC}"
echo "Checking that WAN exclusion rules are present..."

# Check if priority 20 rules exist (WAN exclusion rules)
if ip rule show | grep -q "priority 20"; then
    echo -e "${GREEN}✓ WAN exclusion rules are active${NC}"
    ip rule show | grep "priority 20" | sed 's/^/  /'
else
    echo -e "${RED}✗ Warning: WAN exclusion rules not found in routing policy${NC}"
fi

echo ""
echo -e "${BLUE}Optional: Install automated health monitoring?${NC}"
read -p "Install wan-healthcheck service? (y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo ""
    echo -e "${YELLOW}Installing health check service...${NC}"

    if [ -f "$SCRIPT_DIR/wan-healthcheck.sh" ]; then
        cp "$SCRIPT_DIR/wan-healthcheck.sh" /usr/local/bin/
        chmod +x /usr/local/bin/wan-healthcheck.sh
        echo -e "${GREEN}✓ Health check script installed${NC}"
    else
        echo -e "${RED}✗ wan-healthcheck.sh not found!${NC}"
    fi

    if [ -f "$SCRIPT_DIR/etc/systemd/system/wan-healthcheck.service" ]; then
        cp "$SCRIPT_DIR/etc/systemd/system/wan-healthcheck.service" /etc/systemd/system/
        systemctl daemon-reload
        echo -e "${GREEN}✓ Systemd service installed${NC}"

        echo ""
        read -p "Enable and start the service now? (y/n) " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            systemctl enable wan-healthcheck.service
            systemctl start wan-healthcheck.service
            echo -e "${GREEN}✓ Health check service enabled and started${NC}"
            echo ""
            echo "Monitor logs with: journalctl -u wan-healthcheck.service -f"
        fi
    else
        echo -e "${RED}✗ wan-healthcheck.service not found!${NC}"
    fi
fi

echo ""
echo -e "${GREEN}======================================${NC}"
echo -e "${GREEN}Installation Complete!${NC}"
echo -e "${GREEN}======================================${NC}"
echo ""
echo -e "${BLUE}Usage:${NC}"
echo "  Check status:      failover-control.sh status"
echo "  Trigger failover:  failover-control.sh failover"
echo "  Restore WAN2:      failover-control.sh restore"
echo "  Test WAN1:         failover-control.sh test-wan1"
echo "  Test WAN2:         failover-control.sh test-wan2"
echo "  Show help:         failover-control.sh help"
echo ""
echo -e "${BLUE}Testing connectivity...${NC}"
/usr/local/bin/failover-control.sh status
echo ""
echo -e "${YELLOW}Note: Both WAN gateways should now be reachable at all times,${NC}"
echo -e "${YELLOW}even during failover. The exclusion rules (priority 20) ensure${NC}"
echo -e "${YELLOW}that local WAN networks always use the main routing table.${NC}"
