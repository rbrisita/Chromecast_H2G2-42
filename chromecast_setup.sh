#!/usr/bin/env bash
# =============================================================================
# chromecast_setup.sh
# Automates WiFi configuration of a factory-reset Chromecast H2G2-42.
#
# Authorship:
#   Original research scripts (connect_wifi.sh, commit_wifi.sh,
#   encrypt_password.sh, create_pem.sh, create_key_rsa.sh, get_info.sh,
#   verify_wifi.sh) written by @rbrisita (https://github.com/rbrisita).
#   This all-in-one script inlines and extends that original work.
#   Developed with AI assistance (Claude, by Anthropic).
#
# Tested on:
#   Debian 11 / Chromecast H2G2-42
#
# Hard requires : openssl, curl
# Soft requires : arp-scan (IP discovery fallback; usually needs sudo)
# WiFi tool     : nmcli (preferred) -> iwctl -> wpa_cli -> wpa_supplicant+sudo
# =============================================================================

set -euo pipefail

# ─── Chromecast API constants ─────────────────────────────────────────────────

readonly CC_PORT="8008"
readonly CC_HOTSPOT_IP="192.168.255.249"        # Static IP Chromecast assigns itself
readonly CC_EUREKA_PATH="/setup/eureka_info"
readonly CC_CONFIGURED_NETWORKS_PATH="/setup/configured_networks"

# ─── Temp workspace — scrubbed on exit ───────────────────────────────────────

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

# ─── Globals populated during execution ──────────────────────────────────────

IFACE=""        # Wireless interface (e.g. wlan0)
WIFI_TOOL=""    # Detected WiFi manager
CC_SSID=""      # Chosen Chromecast hotspot SSID
CC_IP=""        # Chromecast reachable IP or hostname

# =============================================================================
# SECTION 1: Logging & Guards
# =============================================================================

log() { printf '\n[*] %s\n' "$*"; }
ok()  { printf '    ✓ %s\n' "$*"; }
err() { printf '[!] %s\n' "$*" >&2; }
die() { err "$*"; exit 1; }

require_cmd() {
    command -v "$1" &>/dev/null || die "Required command not found: '$1'. Please install it."
}

# =============================================================================
# SECTION 2: Wireless Interface Detection
# =============================================================================

detect_interface() {
    log "Detecting wireless interface..."

    # 1. Prefer wlan0 as the most common default
    if ip link show wlan0 &>/dev/null 2>&1; then
        IFACE="wlan0"

    # 2. Ask iw for any managed interface
    elif command -v iw &>/dev/null; then
        IFACE=$(iw dev 2>/dev/null | awk '$1=="Interface"{print $2; exit}')

    # 3. Walk /sys/class/net for anything with a wireless sub-directory
    else
        for d in /sys/class/net/*/wireless; do
            if [[ -d "$d" ]]; then
                IFACE=$(basename "$(dirname "$d")")
                break
            fi
        done
    fi

    [[ -z "$IFACE" ]] && die "No wireless interface found."
    ok "Interface: $IFACE"
}

# =============================================================================
# SECTION 3: WiFi Tool Detection
# =============================================================================

detect_wifi_tool() {
    log "Detecting WiFi management tool..."

    if command -v nmcli &>/dev/null && nmcli -t -f STATE g &>/dev/null 2>&1; then
        WIFI_TOOL="nmcli"

    elif command -v iwctl &>/dev/null && pgrep -x iwd &>/dev/null 2>&1; then
        WIFI_TOOL="iwctl"

    elif command -v wpa_cli &>/dev/null && wpa_cli -i "$IFACE" status &>/dev/null 2>&1; then
        WIFI_TOOL="wpa_cli"

    elif command -v wpa_supplicant &>/dev/null; then
        WIFI_TOOL="wpa_supplicant"
        err "No userspace WiFi manager detected; falling back to wpa_supplicant (requires sudo)."

    else
        die "No supported WiFi tool found (nmcli / iwctl / wpa_cli / wpa_supplicant). Cannot continue."
    fi

    ok "WiFi tool: $WIFI_TOOL"
}

# =============================================================================
# SECTION 4: Scan for Chromecast SSIDs
# =============================================================================

scan_for_chromecast() {
    log "Scanning for Chromecast hotspots..."

    local -a ssids=()

    case "$WIFI_TOOL" in
        nmcli)
            nmcli dev wifi rescan ifname "$IFACE" 2>/dev/null || true
            sleep 2
            mapfile -t ssids < <(
                nmcli -t -f SSID dev wifi list ifname "$IFACE" 2>/dev/null \
                    | grep '^Chromecast' | sort -u
            )
            ;;

        iwctl)
            iwctl station "$IFACE" scan 2>/dev/null || true
            sleep 2
            mapfile -t ssids < <(
                iwctl station "$IFACE" get-networks 2>/dev/null \
                    | grep -oP '\bChromecast\S*' | sort -u
            )
            ;;

        # wpa_cli / wpa_supplicant — use iw or iwlist directly for passive scan
        *)
            if command -v iw &>/dev/null; then
                mapfile -t ssids < <(
                    iw dev "$IFACE" scan 2>/dev/null \
                        | grep -oP '(?<=\tSSID: )Chromecast\S*' | sort -u
                )
            elif command -v iwlist &>/dev/null; then
                mapfile -t ssids < <(
                    iwlist "$IFACE" scan 2>/dev/null \
                        | grep -oP '(?<=ESSID:")[^"]+' \
                        | grep '^Chromecast' | sort -u
                )
            else
                die "No scan tool found. Install 'iw' or 'wireless-tools'."
            fi
            ;;
    esac

    [[ ${#ssids[@]} -eq 0 ]] && \
        die "No Chromecast SSIDs found. Ensure the device is factory-reset and broadcasting."

    if [[ ${#ssids[@]} -eq 1 ]]; then
        CC_SSID="${ssids[0]}"
        ok "Found: $CC_SSID"
    else
        printf '\n    Multiple Chromecasts found:\n'
        for i in "${!ssids[@]}"; do
            printf '      [%d] %s\n' "$((i+1))" "${ssids[$i]}"
        done
        local sel
        read -rp "    Select [1-${#ssids[@]}]: " sel
        [[ "$sel" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= ${#ssids[@]} )) \
            || die "Invalid selection: $sel"
        CC_SSID="${ssids[$((sel-1))]}"
        ok "Selected: $CC_SSID"
    fi
}

# =============================================================================
# SECTION 5: WiFi Connect
# =============================================================================

# Attempt to get a DHCP lease after a raw wpa_supplicant connection.
_acquire_dhcp() {
    if command -v dhclient &>/dev/null; then
        sudo dhclient "$IFACE" 2>/dev/null
    elif command -v dhcpcd &>/dev/null; then
        sudo dhcpcd "$IFACE" 2>/dev/null
    else
        err "No DHCP client found (dhclient / dhcpcd). IP assignment may fail."
    fi
}

# wifi_connect <ssid> <password>
# Pass an empty string for password to connect to an open network.
wifi_connect() {
    local ssid="$1" password="$2"
    log "Connecting to '$ssid'..."

    case "$WIFI_TOOL" in

        nmcli)
            # nmcli is synchronous — it blocks until connected or times out.
            if [[ -z "$password" ]]; then
                nmcli dev wifi connect "$ssid" ifname "$IFACE"
            else
                nmcli dev wifi connect "$ssid" password "$password" ifname "$IFACE"
            fi
            ;;

        iwctl)
            if [[ -z "$password" ]]; then
                iwctl station "$IFACE" connect "$ssid"
            else
                iwctl --passphrase "$password" station "$IFACE" connect "$ssid"
            fi
            sleep 3     # iwctl is fire-and-forget; give it a moment
            ;;

        wpa_cli)
            local net_id
            net_id=$(wpa_cli -i "$IFACE" add_network | tail -1)
            wpa_cli -i "$IFACE" set_network "$net_id" ssid "\"$ssid\""
            if [[ -z "$password" ]]; then
                wpa_cli -i "$IFACE" set_network "$net_id" key_mgmt NONE
            else
                wpa_cli -i "$IFACE" set_network "$net_id" psk       "\"$password\""
                wpa_cli -i "$IFACE" set_network "$net_id" key_mgmt  WPA-PSK
            fi
            wpa_cli -i "$IFACE" enable_network  "$net_id"
            wpa_cli -i "$IFACE" select_network  "$net_id"
            wpa_cli -i "$IFACE" reassociate
            sleep 5
            ;;

        wpa_supplicant)
            local conf="$WORK_DIR/wpa_tmp.conf"
            if [[ -z "$password" ]]; then
                printf 'network={\n    ssid="%s"\n    key_mgmt=NONE\n}\n' \
                    "$ssid" > "$conf"
            else
                printf 'network={\n    ssid="%s"\n    psk="%s"\n    key_mgmt=WPA-PSK\n}\n' \
                    "$ssid" "$password" > "$conf"
            fi
            sudo pkill -f "wpa_supplicant.*$IFACE" 2>/dev/null || true
            sleep 1
            sudo wpa_supplicant -B -i "$IFACE" -c "$conf"
            sleep 3
            _acquire_dhcp
            ;;
    esac

    ok "Connected to '$ssid'."
}

# =============================================================================
# SECTION 6: Fetch Chromecast Device Info
# Inlines get_info.sh — fetches /setup/eureka_info from the device.
# Extends it with mDNS, static IP, and arp-scan fallbacks.
# =============================================================================

fetch_eureka_info() {
    log "Fetching Chromecast device info..."
    local out="$WORK_DIR/eureka_info.json"

    # 1. mDNS hostname — works when avahi/mdns is running
    if curl -sf --max-time 5 \
            "http://chromecast.local:${CC_PORT}${CC_EUREKA_PATH}" -o "$out" 2>/dev/null; then
        CC_IP="chromecast.local"
        ok "Reached via chromecast.local"
        return
    fi

    # 2. Known static IP the Chromecast hotspot always self-assigns
    if curl -sf --max-time 5 \
            "http://${CC_HOTSPOT_IP}:${CC_PORT}${CC_EUREKA_PATH}" -o "$out" 2>/dev/null; then
        CC_IP="$CC_HOTSPOT_IP"
        ok "Reached via static IP $CC_HOTSPOT_IP"
        return
    fi

    # 3. arp-scan the hotspot subnet and probe each host
    require_cmd arp-scan
    err "mDNS and static IP failed; falling back to arp-scan..."

    local ip
    while IFS=$'\t' read -r ip _; do
        if curl -sf --max-time 3 \
                "http://${ip}:${CC_PORT}${CC_EUREKA_PATH}" -o "$out" 2>/dev/null; then
            CC_IP="$ip"
            ok "Reached via arp-scan: $ip"
            return
        fi
    done < <(sudo arp-scan -I "$IFACE" --localnet 2>/dev/null \
        | awk 'NR>2 && /^[0-9]/ {print $1"\t"$2}')

    die "Could not reach Chromecast on hotspot network. Is the device broadcasting?"
}

# Portable JSON field extractor; prefers python3, falls back to jq, then grep.
_json_field() {
    local file="$1" field="$2"

    if command -v python3 &>/dev/null; then
        python3 -c "import json; print(json.load(open('$file'))['$field'])"
    elif command -v jq &>/dev/null; then
        jq -r ".$field" "$file"
    else
        # Naive but sufficient for simple string values
        grep -o "\"${field}\":\"[^\"]*\"" "$file" | cut -d'"' -f4
    fi
}

# =============================================================================
# SECTION 7: Encrypt WiFi Password
# Inlines the three-script pipeline:
#   create_key_rsa.sh  — wrap base64 key in PKCS#1 RSA PUBLIC KEY headers
#   create_pem.sh      — convert PKCS#1 → PKCS#8 SubjectPublicKeyInfo (openssl -pubin)
#   encrypt_password.sh — RSA-OAEP encrypt, emit single-line base64
# =============================================================================

encrypt_wifi_password() {
    local pub_key_b64="$1"
    local wifi_pass="$2"

    local rsa_pem="$WORK_DIR/public_key_rsa.pem"    # PKCS#1 format
    local std_pem="$WORK_DIR/public_key.pem"         # PKCS#8 format
    local enc_bin="$WORK_DIR/encrypted.bin"

    # ── create_key_rsa.sh ──────────────────────────────────────────────────
    # Wrap the raw base64 string from eureka_info in PKCS#1 PEM headers.
    # fold -w 64 inserts the line breaks PEM format requires.
    {
        printf -- '-----BEGIN RSA PUBLIC KEY-----\n'
        printf '%s' "$pub_key_b64" | fold -w 64
        printf '\n-----END RSA PUBLIC KEY-----\n'
    } > "$rsa_pem"

    # ── create_pem.sh ──────────────────────────────────────────────────────
    # Convert PKCS#1 RSAPublicKey → PKCS#8 SubjectPublicKeyInfo.
    # openssl pkeyutl -pubin requires the latter format.
    openssl rsa -RSAPublicKey_in -in "$rsa_pem" -pubout -out "$std_pem" 2>/dev/null \
        || die "RSA key conversion failed. Verify your openssl version supports RSAPublicKey_in."

    # ── encrypt_password.sh ────────────────────────────────────────────────
    # Encrypt with the public key; -w 0 ensures single-line base64 for JSON.
    printf '%s' "$wifi_pass" \
        | openssl pkeyutl -encrypt -pubin -inkey "$std_pem" -out "$enc_bin" \
        || die "Password encryption failed."

    base64 -w 0 "$enc_bin"
}

# =============================================================================
# SECTION 8: Configure Chromecast Over Its Hotspot API
# Inlines connect_wifi.sh and commit_wifi.sh
# =============================================================================

chromecast_configure_wifi() {
    local ssid="$1" enc_passwd="$2"
    local base_url="http://${CC_IP}:${CC_PORT}"

    # ── connect_wifi.sh ────────────────────────────────────────────────────
    log "Sending WiFi credentials to Chromecast..."
    curl -sf -k --tlsv1.2 --tls-max 1.2 \
        -H "content-type: application/json" \
        -d "{\"ssid\":\"${ssid}\",\"wpa_auth\":7,\"wpa_cipher\":4,\"enc_passwd\":\"${enc_passwd}\"}" \
        "${base_url}/setup/connect_wifi" \
        || die "connect_wifi request failed."
    ok "Credentials sent."

    # ── commit_wifi.sh ─────────────────────────────────────────────────────
    # keep_hotspot_until_connected gives us time to switch back before it
    # drops the hotspot and the curl would otherwise hang.
    log "Committing WiFi configuration..."
    curl -sf -k --tlsv1.2 --tls-max 1.2 \
        -H "content-type: application/json" \
        -d '{"keep_hotspot_until_connected": true}' \
        "${base_url}/setup/save_wifi" \
        || die "save_wifi request failed."
    ok "Configuration committed."
}

# =============================================================================
# SECTION 9: Verify Chromecast on Home Network
# Inlines verify_wifi.sh — probes /setup/configured_networks on the device.
# Extends it with mDNS and arp-scan fallbacks for IP discovery.
# =============================================================================

verify_on_home_network() {
    log "Waiting 15s for Chromecast to join home network..."
    sleep 15

    local url

    # 1. Try mDNS — cheapest, no extra tools
    url="http://chromecast.local:${CC_PORT}${CC_CONFIGURED_NETWORKS_PATH}"
    if curl -sf --max-time 5 "$url" &>/dev/null; then
        ok "Chromecast is online at chromecast.local"
        return 0
    fi

    # 2. arp-scan the home subnet and probe each host
    require_cmd arp-scan
    err "mDNS lookup failed; scanning home network via arp-scan..."

    local ip
    while IFS=$'\t' read -r ip _; do
        url="http://${ip}:${CC_PORT}${CC_CONFIGURED_NETWORKS_PATH}"
        if curl -sf --max-time 3 "$url" &>/dev/null; then
            ok "Chromecast is online at $ip"
            return 0
        fi
    done < <(sudo arp-scan -I "$IFACE" --localnet 2>/dev/null \
        | awk 'NR>2 && /^[0-9]/ {print $1"\t"$2}')

    err "Chromecast not found on home network. It may still be connecting — check again in 30s."
    return 1
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    require_cmd openssl
    require_cmd curl

    # ── 1. Detect interface and WiFi tool ───────────────────────────────────
    detect_interface
    detect_wifi_tool

    # ── 2. Prompt for home WiFi credentials ────────────────────────────────
    printf '\n'
    read -rp  "  Home WiFi SSID     : " HOME_SSID
    read -rsp "  Home WiFi Password : " HOME_PASS
    printf '\n'
    [[ -z "$HOME_SSID" ]] && die "SSID cannot be empty."

    # ── 3. Scan and select Chromecast hotspot ───────────────────────────────
    scan_for_chromecast

    # ── 4. Connect to Chromecast hotspot (open network — no password) ───────
    wifi_connect "$CC_SSID" ""
    sleep 3

    # ── 5. Fetch eureka_info and extract the device's RSA public key ────────
    fetch_eureka_info
    PUBLIC_KEY=$(_json_field "$WORK_DIR/eureka_info.json" "public_key")
    [[ -z "$PUBLIC_KEY" ]] && die "Could not extract public_key from eureka_info."
    ok "RSA public key extracted."

    # ── 6. Encrypt home WiFi password with device public key ────────────────
    log "Encrypting WiFi password..."
    ENC_PASSWD=$(encrypt_wifi_password "$PUBLIC_KEY" "$HOME_PASS")
    [[ -z "$ENC_PASSWD" ]] && die "Encryption produced empty result."
    ok "Password encrypted."

    # ── 7. Push WiFi config to Chromecast and commit ────────────────────────
    chromecast_configure_wifi "$HOME_SSID" "$ENC_PASSWD"

    # ── 8. Switch controlling device back to home WiFi ──────────────────────
    wifi_connect "$HOME_SSID" "$HOME_PASS"
    sleep 5

    # ── 9. Confirm Chromecast joined home network ───────────────────────────
    verify_on_home_network

    log "Done. Chromecast '$CC_SSID' has been configured for '$HOME_SSID'."
}

main "$@"
