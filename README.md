# IPv4 Router Configuration

This configuration sets up a Linux system as an IPv4 router with NAT between a LAN and WAN interface.

## Network Topology

- **LAN Interface**: `enp1s0` — `10.1.1.1/24`, serves DHCP to `10.1.1.0/24`
- **WAN Interface**: `enp7s0` — `10.89.223.12/29`, gateway `10.89.223.9`

## Architecture Overview

### IPv4 Configuration
- LAN clients receive addresses in `10.1.1.0/24` via DHCP (served by `systemd-networkd`)
- Distributed DNS servers: `10.50.250.1`, `10.83.252.11`
- Traffic from LAN is masqueraded (NAT44) via the WAN interface (`enp7s0`)
- IP forwarding is enabled via sysctl

### Firewall (nftables)
- Default drop policy on input and forward chains
- Stateful connection tracking (established/related accepted)
- LAN clients can reach the internet via NAT
- ICMP, SSH, DNS, DHCP allowed from LAN to router
- No unsolicited inbound traffic from WAN

## File Structure

```
router-ipv6/
├── README.md
└── etc/
    ├── nftables.conf
    ├── sysctl.d/
    │   └── 30-ipforward.conf
    └── systemd/
        └── network/
            ├── 10-enp1s0.network    # LAN interface configuration
            └── 10-enp7s0.network    # WAN interface configuration
```

## Installation

### 1. Copy Configuration Files

```bash
# Copy nftables configuration
sudo cp etc/nftables.conf /etc/nftables.conf

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

# Check interface addresses
ip -4 addr show enp1s0
ip -4 addr show enp7s0

# Check default route
ip route show default

# Check nftables rules
sudo nft list ruleset

# Check network interface status
networkctl status enp1s0
networkctl status enp7s0

# Check DHCP leases
networkctl status enp1s0 --no-pager
```

## How It Works

### Routing Decision Process

1. **Packet arrives from LAN** (`10.1.1.0/24`)
2. **Kernel routing table** forwards the packet via the default gateway on `enp7s0` (`10.89.223.9`)
3. **NAT is applied** by nftables — source address is masqueraded to `10.89.223.12`
4. **Firewall rules allow** the forwarded packet (LAN → WAN is permitted)
5. **Return traffic** matches the established connection state and is allowed back to the LAN client

### DHCP

`systemd-networkd` provides a built-in DHCP server on the LAN interface. Clients connecting to `enp1s0` will receive:

- An IP address in the `10.1.1.0/24` range (pool managed automatically, router IP `10.1.1.1` excluded)
- Default gateway: `10.1.1.1`
- DNS servers: `10.50.250.1`, `10.83.252.11`

## Monitoring and Troubleshooting

### Check Active Routes
```bash
# See which interface is being used for internet traffic
ip route get 8.8.8.8
```

### Check NAT
```bash
# View nftables NAT table
sudo nft list table ip nat

# Check connection tracking
sudo conntrack -L
```

### Check DHCP Server
```bash
# View leases
sudo networkctl status enp1s0

# Check systemd-networkd logs
journalctl -u systemd-networkd -f
```

## Customization

### Changing Network Ranges
Edit the network files and `nftables.conf`:
- LAN subnet: Change `10.1.1.0/24` and `10.1.1.1` in all files
- WAN address: Change `10.89.223.12/29` and gateway `10.89.223.9` in `10-enp7s0.network`
- DNS servers: Change the `EmitDNS` / `DNS` values in `10-enp1s0.network`

### Adding Port Forwarding
Add DNAT rules in `nftables.conf` to expose LAN services to the WAN. For example:

```
table ip nat {
    chain prerouting {
        type nat hook prerouting priority dstnat; policy accept;
        iifname "enp7s0" tcp dport 8080 dnat to 10.1.1.100:80
    }
}
```

### Adding Services
Edit `nftables.conf` to allow additional services through the firewall.

## Security Considerations

1. **Default Drop Policy**: All unsolicited incoming traffic is dropped
2. **Stateful Firewall**: Only established/related connections are allowed back
3. **LAN Isolation**: Only LAN can initiate connections to WAN
4. **Service Restriction**: Only necessary services (SSH, DNS, DHCP) are exposed to LAN

## License

This configuration is provided as-is for educational and operational purposes.