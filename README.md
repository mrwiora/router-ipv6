# Dual-Stack IPv4/IPv6 Router Configuration

This configuration sets up a Linux system as a dual-stack router with automatic failover between two WAN connections.

## Network Topology

- **LAN Interface**: `enp1s0` (172.17.0.0/24 for IPv4, delegated prefix for IPv6)
- **WAN1 (Failover)**: `enp7s0` (172.17.254.102/24 for IPv4, DHCPv6 PD for IPv6)
- **WAN2 (Primary)**: `enp8s0` (192.168.8.102/24 for IPv4, SLAAC for IPv6)

## Architecture Overview

### IPv4 Configuration
- **Primary Path**: Traffic from LAN (172.17.0.0/24) is routed via WAN2 (enp8s0) and NAT'd to 192.168.8.x
- **Failover Path**: If WAN2 is down, traffic automatically fails over to WAN1 (enp7s0) and NAT'd to 172.17.254.x
- **Routing Tables**:
  - Table 200: Primary routes via enp8s0 (metric 200, priority 100)
  - Table 100: Failover routes via enp7s0 (metric 300, priority 200)

### IPv6 Configuration
- **Delegated Prefix**: 2a00:1f:c0:9bfa::/64 (received from WAN1 via DHCPv6-PD)
- **Primary Path**: Traffic is NAT66'd via WAN2 (enp8s0) using masquerade
- **Failover Path**: If WAN2 is down, traffic uses native routing via WAN1 (enp7s0) with the delegated prefix
- **Routing Tables**: Same as IPv4 (tables 200 and 100)

## File Structure

```
router-ipv6/
├── nftables.conf                          # Main firewall configuration
├── etc/
│   ├── sysctl.d/
│   │   └── 30-ipforward.conf              # Enable IPv4 and IPv6 forwarding
│   └── systemd/
│       └── network/
│           ├── 10-enp1s0.network          # LAN interface configuration
│           ├── 10-enp7s0.network          # WAN1 (failover) configuration
│           └── 10-enp8s0.network          # WAN2 (primary) configuration
```

## Key Features

### 1. Automatic Failover
The routing policy rules ensure seamless failover:
- **Priority 100** (higher): Routes via WAN2 (table 200) - used when available
- **Priority 200** (lower): Routes via WAN1 (table 100) - used as backup

When WAN2 goes down, the routing policies automatically switch to WAN1 without manual intervention.

**Important**: The configuration includes exclusion rules (priority 20) that ensure traffic destined for WAN local networks (172.17.254.0/24 and 192.168.8.0/24) always uses the main routing table. This keeps both WAN gateways reachable even during failover, allowing you to access devices on those networks.

### 2. NAT Configuration
#### IPv4 NAT (NAT44)
- Both WAN interfaces perform masquerading for LAN traffic
- Traffic is automatically NAT'd through whichever interface is active

#### IPv6 NAT (NAT66)
- WAN2 performs NAT66 masquerading for the delegated prefix
- WAN1 uses native routing (no NAT) with the delegated prefix

### 3. Firewall Rules (nftables)
The firewall implements a restrictive policy with explicit allow rules:
- **INPUT**: Drop by default, allow established connections, ICMP, SSH, DNS from LAN
- **FORWARD**: Drop by default, allow LAN→WAN traffic and established return traffic
- **OUTPUT**: Accept all (for router's own traffic)

### 4. Router Advertisement (IPv6)
The LAN interface advertises the delegated prefix (2a00:1f:c0:9bfa::/64) to clients via SLAAC.

## Installation

### 1. Copy Configuration Files

```bash
# Copy nftables configuration
sudo cp nftables.conf /etc/nftables.conf

# Copy sysctl configuration
sudo cp etc/sysctl.d/30-ipforward.conf /etc/sysctl.d/

# Copy network configurations
sudo cp etc/systemd/network/*.network /etc/systemd/network/
```

### 2. Apply System Settings

```bash
# Apply sysctl settings
sudo sysctl --system

# Restart systemd-networkd
sudo systemctl restart systemd-networkd

# Enable and start nftables
sudo systemctl enable nftables
sudo systemctl restart nftables
```

### 3. Verify Configuration

```bash
# Check forwarding is enabled
sysctl net.ipv4.ip_forward
sysctl net.ipv6.conf.all.forwarding

# Check routing tables
ip route show table 100
ip route show table 200
ip -6 route show table 100
ip -6 route show table 200

# Check routing policy rules
ip rule show
ip -6 rule show

# Check nftables rules
sudo nft list ruleset

# Check network interface status
networkctl status enp1s0
networkctl status enp7s0
networkctl status enp8s0
```

## How It Works

### Routing Decision Process

1. **Packet arrives from LAN** (172.17.0.0/24 for IPv4 or 2a00:1f:c0:9bfa::/64 for IPv6)

2. **Routing policy rules are checked**:
   - First, priority 100 rule matches → looks up table 200 (WAN2 route)
   - If no route available in table 200 (WAN2 down) → continues to next rule
   - Priority 200 rule matches → looks up table 100 (WAN1 route)

3. **Packet is routed** through the selected interface

4. **NAT is applied** by nftables:
   - IPv4: Masquerade via the outgoing interface (WAN1 or WAN2)
   - IPv6: Masquerade via WAN2, or use native routing via WAN1

5. **Firewall rules allow** the forwarded packet

### Example Scenarios

#### Scenario 1: Normal Operation (WAN2 Active)
- LAN client sends packet to internet
- Policy rule priority 100 → table 200 → route via enp8s0 (WAN2)
- NAT masquerades source to WAN2 address
- Packet exits via enp8s0

#### Scenario 2: WAN2 Down (Failover Active)
- LAN client sends packet to internet
- Policy rule priority 100 → table 200 → no route (WAN2 down)
- Policy rule priority 200 → table 100 → route via enp7s0 (WAN1)
- NAT masquerades source to WAN1 address
- Packet exits via enp7s0

#### Scenario 3: WAN2 Recovers
- enp8s0 comes back online
- systemd-networkd repopulates table 200
- New connections automatically use WAN2 again (priority 100)
- Established connections via WAN1 continue until they close

## Manual Failover Control

The included `failover-control.sh` script allows you to manually trigger failover without taking interfaces down. This is useful because:
- **Problem**: Taking an interface down (`ip link set enp8s0 down`) triggers failover BUT makes devices on that network unreachable
- **Solution**: Flush the routing table instead, which triggers failover while keeping the interface UP

### Usage

```bash
# Trigger manual failover to WAN1 (keeps WAN2 interface up for local access)
sudo ./failover-control.sh failover

# Check current routing status
sudo ./failover-control.sh status

# Restore WAN2 as primary
sudo ./failover-control.sh restore

# Test specific interface connectivity
sudo ./failover-control.sh test-wan1
sudo ./failover-control.sh test-wan2
```

### How It Works

1. **Failover command**: Flushes routes from table 200 (WAN2), causing policy routing to fall through to table 100 (WAN1)
2. **Interface stays UP**: WAN2 interface remains operational, allowing direct access to 192.168.8.0/24 network
3. **Both gateways reachable**: The priority 20 routing policy rules ensure both WAN gateways remain accessible:
   - Traffic TO 172.17.254.0/24 → main table (direct route via enp7s0)
   - Traffic TO 192.168.8.0/24 → main table (direct route via enp8s0)
   - Traffic FROM LAN to internet → table 200 or 100 (policy routing)

### Example

```bash
# Before failover
$ sudo ./failover-control.sh status
Interface Status:
  enp7s0: UP
  enp8s0: UP

Active Routes:
  IPv4 (to 8.8.8.8): via enp8s0 (Primary)

Local Connectivity:
  172.17.254.1 (enp7s0 gateway): REACHABLE
  192.168.8.1 (enp8s0 gateway): REACHABLE

# Trigger failover
$ sudo ./failover-control.sh failover
Forcing failover to WAN1 (enp7s0)...
✓ Failover complete
  - Traffic now routes via WAN1 (enp7s0)
  - Interface enp8s0 remains UP and locally accessible
  - You can still reach 192.168.8.1 and devices on 192.168.8.0/24

Active Routes:
  IPv4 (to 8.8.8.8): via enp7s0 (Failover)

Local Connectivity:
  172.17.254.1 (enp7s0 gateway): REACHABLE
  192.168.8.1 (enp8s0 gateway): REACHABLE  ← Still reachable!

# You can still ping/access devices on WAN2's network
$ ping 192.168.8.1
PING 192.168.8.1 56(84) bytes of data.
64 bytes from 192.168.8.1: icmp_seq=1 ttl=64 time=0.5 ms
```

## Automated Health Monitoring (Optional)

For automatic failover based on connectivity checks, you can use the included `wan-healthcheck.sh` script and systemd service:

```bash
# Install the health check script
sudo cp wan-healthcheck.sh /usr/local/bin/
sudo chmod +x /usr/local/bin/wan-healthcheck.sh

# Install and enable the systemd service
sudo cp etc/systemd/system/wan-healthcheck.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable wan-healthcheck.service
sudo systemctl start wan-healthcheck.service

# Monitor health check logs
sudo journalctl -u wan-healthcheck.service -f
```

The health check monitors WAN2 connectivity and automatically triggers failover when failures are detected, while keeping the interface up for local access.

## Monitoring and Troubleshooting

### Check Active Routes
```bash
# See which interface is being used for internet traffic
ip route get 8.8.8.8
ip -6 route get 2001:4860:4860::8888

# Check both routing tables
ip route show table 100
ip route show table 200
```

### Monitor Failover Events
```bash
# Watch routing changes
watch -n 1 'ip route show table 200; echo "---"; ip route show table 100'

# Monitor interface status
watch -n 1 'networkctl status enp7s0 enp8s0'
```

### Check NAT Statistics
```bash
# View nftables counters (if enabled)
sudo nft list table ip nat
sudo nft list table ip6 nat

# Check connection tracking
sudo conntrack -L
```

### Test Failover

**Using the failover control script (recommended):**
```bash
# Trigger failover while keeping interface up
sudo ./failover-control.sh failover

# Verify traffic switches to WAN1 but gateway remains reachable
ip route get 8.8.8.8
ping 192.168.8.1  # Should still work!

# Restore WAN2
sudo ./failover-control.sh restore
```

**Using interface down (not recommended if you need local access):**
```bash
# Simulate WAN2 failure by taking interface down
sudo ip link set enp8s0 down

# Verify traffic switches to WAN1
ip route get 8.8.8.8

# Note: 192.168.8.1 will NOT be reachable with this method

# Restore WAN2
sudo ip link set enp8s0 up
```

## Customization

### Changing Network Ranges
Edit the network files and nftables configuration:
- LAN IPv4: Change `172.17.0.0/24` in all files
- Delegated IPv6 prefix: Change `2a00:1f:c0:9bfa::/64` in nftables.conf and routing rules

### Adjusting Failover Behavior
Modify metrics and priorities in the network configuration files:
- Lower metric = preferred route (within same table)
- Lower priority number = checked first (for policy rules)

### Adding Services
Edit `nftables.conf` to allow additional services through the firewall.

## Security Considerations

1. **Default Drop Policy**: All unsolicited incoming traffic is dropped
2. **Stateful Firewall**: Only established/related connections are allowed back
3. **LAN Isolation**: Only LAN can initiate connections to WAN
4. **Service Restriction**: Only necessary services (SSH, DNS) are exposed to LAN

## License

This configuration is provided as-is for educational and operational purposes.