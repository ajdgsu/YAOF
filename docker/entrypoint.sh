#!/usr/bin/env bash
set -euo pipefail

readonly PROXY_HOST=192.168.1.1
readonly PROXY_PORT=1091
readonly REDSOCKS_PORT=12345
readonly READY_FILE=/run/yaof-ready
readonly REDSOCKS_USER=redsocks
readonly STUBBY_USER=stubby

redsocks_pid=''
stubby_pid=''
workload_pid=''

cleanup() {
    local pid

    rm -f "$READY_FILE"
    for pid in "$workload_pid" "$stubby_pid" "$redsocks_pid"; do
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
        fi
    done
    for pid in "$workload_pid" "$stubby_pid" "$redsocks_pid"; do
        if [[ -n "$pid" ]]; then
            wait "$pid" 2>/dev/null || true
        fi
    done
}

trap cleanup EXIT INT TERM

write_redsocks_config() {
    cat > /run/redsocks.conf <<EOF
base {
    log_debug = off;
    log_info = on;
    log = "stderr";
    daemon = off;
    redirector = iptables;
}

redsocks {
    local_ip = 127.0.0.1;
    local_port = ${REDSOCKS_PORT};
    ip = "${PROXY_HOST}";
    port = ${PROXY_PORT};
    type = socks5;
}
EOF
}

write_stubby_config() {
    cat > /run/stubby.yml <<'EOF'
resolution_type: GETDNS_RESOLUTION_STUB
dns_transport_list:
  - GETDNS_TRANSPORT_TLS
tls_authentication: GETDNS_AUTHENTICATION_REQUIRED
tls_ca_path: "/etc/ssl/certs/"
round_robin_upstreams: 1
listen_addresses:
  - 127.0.0.1
upstream_recursive_servers:
  - address_data: 1.1.1.2
    tls_auth_name: "security.cloudflare-dns.com"
    tls_port: 853
  - address_data: 1.0.0.2
    tls_auth_name: "security.cloudflare-dns.com"
    tls_port: 853
EOF
}

configure_resolver() {
    printf '%s\n' \
        'nameserver 127.0.0.1' \
        'options timeout:2 attempts:2' \
        > /etc/resolv.conf
}

configure_firewall() {
    local redsocks_uid

    redsocks_uid="$(id -u "$REDSOCKS_USER")"

    # This container has a dedicated network namespace, so its filter tables are safe to own.
    iptables -F
    iptables -t mangle -F
    iptables -t nat -F
    iptables -P INPUT DROP
    iptables -P FORWARD DROP
    iptables -P OUTPUT DROP

    iptables -A INPUT -i lo -j ACCEPT
    iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    iptables -A OUTPUT -o lo -j ACCEPT
    iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

    # The SOCKS endpoint itself must stay direct so redsocks cannot redirect its own tunnel.
    iptables -t nat -A OUTPUT -o lo -j RETURN
    iptables -t nat -A OUTPUT -p tcp -d "$PROXY_HOST" --dport "$PROXY_PORT" \
        -m owner --uid-owner "$redsocks_uid" -j RETURN
    iptables -t mangle -A OUTPUT -p tcp --dport 53 -j MARK --set-mark 53
    iptables -t mangle -A OUTPUT -p tcp -d "$PROXY_HOST" --dport "$PROXY_PORT" \
        -m owner --uid-owner "$redsocks_uid" -j ACCEPT
    iptables -t mangle -A OUTPUT -p tcp -d "$PROXY_HOST" --dport "$PROXY_PORT" \
        -j MARK --set-mark 1091
    iptables -t nat -A OUTPUT -p tcp -j REDIRECT --to-ports "$REDSOCKS_PORT"
    iptables -A OUTPUT -p tcp -d "$PROXY_HOST" --dport "$PROXY_PORT" \
        -m owner --uid-owner "$redsocks_uid" -j ACCEPT
    iptables -A OUTPUT -m mark --mark 53 -j REJECT
    iptables -A OUTPUT -m mark --mark 1091 -j REJECT

    # Stubby uses only authenticated TLS over TCP; reject all UDP, including plaintext DNS.
    iptables -A OUTPUT -p udp -j REJECT
    iptables -A OUTPUT -p tcp -j ACCEPT
    iptables -A OUTPUT -j REJECT

    # IPv6 is disabled by Compose and also blocked here to avoid a fallback bypass.
    ip6tables -F
    ip6tables -P INPUT DROP
    ip6tables -P FORWARD DROP
    ip6tables -P OUTPUT DROP
    ip6tables -A INPUT -i lo -j ACCEPT
    ip6tables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    ip6tables -A OUTPUT -o lo -j ACCEPT
    ip6tables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
}

wait_for_stubby() {
    local attempt

    for attempt in $(seq 1 120); do
        if ss -ltnH | grep -q '127.0.0.1:53' \
            && getent ahostsv4 downloads.openwrt.org >/dev/null 2>&1; then
            touch "$READY_FILE"
            return 0
        fi
        sleep 0.5
    done

    echo "Stubby did not complete an authenticated DoT lookup through SOCKS" >&2
    return 1
}

write_redsocks_config
gosu "$REDSOCKS_USER" redsocks -c /run/redsocks.conf &
redsocks_pid=$!
printf '%s\n' "$redsocks_pid" > /run/redsocks.pid

configure_firewall

write_stubby_config
configure_resolver
gosu "$STUBBY_USER" stubby -C /run/stubby.yml &
stubby_pid=$!
printf '%s\n' "$stubby_pid" > /run/stubby.pid
wait_for_stubby

# DoT encrypts DNS transport and uses Cloudflare malware filtering; it does not prove source integrity.
gosu builder "$@" &
workload_pid=$!

exited_pid=''
if wait -n -p exited_pid "$redsocks_pid" "$stubby_pid" "$workload_pid"; then
    child_status=0
else
    child_status=$?
fi

if [[ "$exited_pid" == "$workload_pid" ]]; then
    exit "$child_status"
fi

echo "Critical network daemon exited (pid=$exited_pid, status=$child_status)" >&2
exit 1
