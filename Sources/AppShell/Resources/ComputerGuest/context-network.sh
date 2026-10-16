#!/bin/sh
set -eu

if [ "$(id -u)" -ne 0 ] || [ "${REMOTECODE_CONTEXT_NETWORK_POLICY:-}" != "private-egress-v1" ]; then
    printf '%s\n' 'rc-context-network requires root and private-egress-v1 context' >&2
    exit 1
fi

iptables-restore --noflush <<'RULES4'
*filter
:RC_CONTEXT_NETWORK - [0:0]
-F RC_CONTEXT_NETWORK
-A RC_CONTEXT_NETWORK -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
-A RC_CONTEXT_NETWORK -o lo -j ACCEPT
-A RC_CONTEXT_NETWORK -d 0.0.0.0/8 -m conntrack --ctstate NEW -j REJECT
-A RC_CONTEXT_NETWORK -d 10.0.0.0/8 -m conntrack --ctstate NEW -j REJECT
-A RC_CONTEXT_NETWORK -d 100.64.0.0/10 -m conntrack --ctstate NEW -j REJECT
-A RC_CONTEXT_NETWORK -d 169.254.0.0/16 -m conntrack --ctstate NEW -j REJECT
-A RC_CONTEXT_NETWORK -d 172.16.0.0/12 -m conntrack --ctstate NEW -j REJECT
-A RC_CONTEXT_NETWORK -d 192.0.0.0/24 -m conntrack --ctstate NEW -j REJECT
-A RC_CONTEXT_NETWORK -d 192.0.2.0/24 -m conntrack --ctstate NEW -j REJECT
-A RC_CONTEXT_NETWORK -d 192.168.0.0/16 -m conntrack --ctstate NEW -j REJECT
-A RC_CONTEXT_NETWORK -d 198.18.0.0/15 -m conntrack --ctstate NEW -j REJECT
-A RC_CONTEXT_NETWORK -d 198.51.100.0/24 -m conntrack --ctstate NEW -j REJECT
-A RC_CONTEXT_NETWORK -d 203.0.113.0/24 -m conntrack --ctstate NEW -j REJECT
-A RC_CONTEXT_NETWORK -d 224.0.0.0/4 -m conntrack --ctstate NEW -j REJECT
-A RC_CONTEXT_NETWORK -d 240.0.0.0/4 -m conntrack --ctstate NEW -j REJECT
COMMIT
RULES4
if ! iptables -C OUTPUT -j RC_CONTEXT_NETWORK 2>/dev/null; then
    iptables -I OUTPUT 1 -j RC_CONTEXT_NETWORK
fi
iptables -C OUTPUT -j RC_CONTEXT_NETWORK
iptables -C RC_CONTEXT_NETWORK -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -C RC_CONTEXT_NETWORK -o lo -j ACCEPT
for subnet in 0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 169.254.0.0/16 172.16.0.0/12 192.0.0.0/24 192.0.2.0/24 192.168.0.0/16 198.18.0.0/15 198.51.100.0/24 203.0.113.0/24 224.0.0.0/4 240.0.0.0/4; do
    iptables -C RC_CONTEXT_NETWORK -d "$subnet" -m conntrack --ctstate NEW -j REJECT
done

ip6tables-restore --noflush <<'RULES6'
*filter
:RC_CONTEXT_NETWORK - [0:0]
-F RC_CONTEXT_NETWORK
-A RC_CONTEXT_NETWORK -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
-A RC_CONTEXT_NETWORK -o lo -j ACCEPT
-A RC_CONTEXT_NETWORK -d fc00::/7 -m conntrack --ctstate NEW -j REJECT
-A RC_CONTEXT_NETWORK -d fe80::/10 -m conntrack --ctstate NEW -j REJECT
-A RC_CONTEXT_NETWORK -d ff00::/8 -m conntrack --ctstate NEW -j REJECT
-A RC_CONTEXT_NETWORK -d ::/128 -m conntrack --ctstate NEW -j REJECT
COMMIT
RULES6
if ! ip6tables -C OUTPUT -j RC_CONTEXT_NETWORK 2>/dev/null; then
    ip6tables -I OUTPUT 1 -j RC_CONTEXT_NETWORK
fi
ip6tables -C OUTPUT -j RC_CONTEXT_NETWORK
ip6tables -C RC_CONTEXT_NETWORK -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
ip6tables -C RC_CONTEXT_NETWORK -o lo -j ACCEPT
for subnet in fc00::/7 fe80::/10 ff00::/8 ::/128; do
    ip6tables -C RC_CONTEXT_NETWORK -d "$subnet" -m conntrack --ctstate NEW -j REJECT
done

umask 077
: > /run/remotecode-context-network-ready
chown root:root /run/remotecode-context-network-ready
chmod 0600 /run/remotecode-context-network-ready
printf '%s\n' 'context-network-policy-v1'
