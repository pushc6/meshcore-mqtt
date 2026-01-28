#!/usr/bin/env bash
#
# MeshCore MQTT Bridge Remote Installer
# Installs and configures meshcore-mqtt on a remote device (Raspberry Pi, etc.)
#

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Default values
DEFAULT_MQTT_PORT=1883
DEFAULT_MQTT_PREFIX="meshcore"
DEFAULT_MQTT_QOS=0
DEFAULT_BAUDRATE=115200
DEFAULT_TCP_PORT=5000
DEFAULT_INSTALL_DIR="/opt/meshcore-mqtt"

print_banner() {
    echo -e "${CYAN}"
    echo "============================================================"
    echo "       MeshCore MQTT Bridge - Remote Installer"
    echo "============================================================"
    echo -e "${NC}"
}

print_step() {
    echo -e "\n${BLUE}==>${NC} ${GREEN}$1${NC}"
}

print_info() {
    echo -e "${CYAN}    $1${NC}"
}

print_warn() {
    echo -e "${YELLOW}!   $1${NC}"
}

print_error() {
    echo -e "${RED}X   $1${NC}"
}

print_success() {
    echo -e "${GREEN}OK  $1${NC}"
}

prompt_with_default() {
    local prompt="$1"
    local default="$2"
    local var_name="$3"

    if [[ -n "$default" ]]; then
        read -rp "$(echo -e "${CYAN}$prompt${NC} [${GREEN}$default${NC}]: ")" value
        value="${value:-$default}"
    else
        read -rp "$(echo -e "${CYAN}$prompt${NC}: ")" value
    fi

    eval "$var_name='$value'"
}

prompt_password() {
    local prompt="$1"
    local var_name="$2"

    read -srp "$(echo -e "${CYAN}$prompt${NC}: ")" value
    echo
    eval "$var_name='$value'"
}

prompt_yes_no() {
    local prompt="$1"
    local default="$2"

    if [[ "$default" == "y" ]]; then
        read -rp "$(echo -e "${CYAN}$prompt${NC} [${GREEN}Y${NC}/n]: ")" response
        response="${response:-y}"
    else
        read -rp "$(echo -e "${CYAN}$prompt${NC} [y/${GREEN}N${NC}]: ")" response
        response="${response:-n}"
    fi

    [[ "$response" =~ ^[Yy] ]]
}

# Run command on remote device
run_remote() {
    sshpass -p "$DEVICE_PASSWORD" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 "${DEVICE_USER}@${DEVICE_IP}" "$1"
}

# Run command on remote device with timeout
run_remote_timeout() {
    local timeout="$1"
    local cmd="$2"
    sshpass -p "$DEVICE_PASSWORD" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 "${DEVICE_USER}@${DEVICE_IP}" "timeout $timeout $cmd"
}

# Copy content to remote file
copy_to_remote() {
    local content="$1"
    local remote_path="$2"
    echo "$content" | sshpass -p "$DEVICE_PASSWORD" ssh -o StrictHostKeyChecking=no "${DEVICE_USER}@${DEVICE_IP}" "cat > $remote_path"
}

check_local_dependencies() {
    print_step "Checking local dependencies..."

    if ! command -v sshpass &> /dev/null; then
        print_error "sshpass is required but not installed."
        echo
        if [[ "$(uname)" == "Darwin" ]]; then
            echo "Install with: brew install sshpass"
            echo "Note: You may need: brew install hudochenkov/sshpass/sshpass"
        else
            echo "Install with: apt install sshpass  (or your package manager)"
        fi
        exit 1
    fi
    print_success "sshpass found"
}

get_device_info() {
    print_step "Remote Device Configuration"
    echo
    print_info "Enter the connection details for your Raspberry Pi or Linux device."
    echo

    prompt_with_default "Device IP address" "" "DEVICE_IP"
    prompt_with_default "SSH username" "root" "DEVICE_USER"
    prompt_password "SSH password" "DEVICE_PASSWORD"

    # Test connection
    print_info "Testing connection..."
    if ! run_remote "echo 'connected'" &>/dev/null; then
        print_error "Could not connect to ${DEVICE_USER}@${DEVICE_IP}"
        exit 1
    fi
    print_success "Connected to ${DEVICE_IP}"
}

install_remote_dependencies() {
    print_step "Installing dependencies on remote device..."

    # Detect package manager and install dependencies
    run_remote "
        if command -v apt-get &>/dev/null; then
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -qq
            apt-get install -y -qq python3 python3-venv python3-pip git bluez > /dev/null 2>&1
        elif command -v dnf &>/dev/null; then
            dnf install -y -q python3 python3-pip git bluez
        elif command -v pacman &>/dev/null; then
            pacman -Sy --noconfirm python python-pip git bluez
        fi
        echo 'Dependencies installed'
    "
    print_success "Dependencies installed"
}

clone_repository() {
    print_step "Installing meshcore-mqtt on remote device..."

    prompt_with_default "Installation directory" "$DEFAULT_INSTALL_DIR" "INSTALL_DIR"

    run_remote "
        if [[ -d '$INSTALL_DIR' ]]; then
            cd '$INSTALL_DIR' && git pull
        else
            git clone https://github.com/pushc6/meshcore-mqtt.git '$INSTALL_DIR'
        fi
    "

    run_remote "
        cd '$INSTALL_DIR'
        python3 -m venv venv
        venv/bin/pip install --upgrade pip -q
        venv/bin/pip install -r requirements.txt -q
    "
    print_success "Repository cloned and dependencies installed"
}

select_connection_type() {
    print_step "MeshCore Connection Type"
    echo
    echo -e "  ${GREEN}1)${NC} Serial (USB) - ${CYAN}Recommended${NC}"
    echo -e "      Connect via USB cable to your MeshCore device"
    echo
    echo -e "  ${GREEN}2)${NC} BLE (Bluetooth Low Energy)"
    echo -e "      Connect wirelessly via Bluetooth"
    echo
    echo -e "  ${GREEN}3)${NC} TCP (Network)"
    echo -e "      Connect to a MeshCore device with TCP server enabled"
    echo

    while true; do
        read -rp "$(echo -e "${CYAN}Select connection type${NC} [${GREEN}1${NC}]: ")" conn_choice
        conn_choice="${conn_choice:-1}"

        case "$conn_choice" in
            1) CONNECTION_TYPE="serial"; break ;;
            2) CONNECTION_TYPE="ble"; break ;;
            3) CONNECTION_TYPE="tcp"; break ;;
            *) print_error "Invalid choice. Please enter 1, 2, or 3." ;;
        esac
    done
}

configure_serial() {
    print_step "Serial Configuration"
    echo

    # List available serial ports on remote
    print_info "Detecting serial ports on remote device..."
    local ports
    ports=$(run_remote "ls /dev/ttyUSB* /dev/ttyACM* 2>/dev/null || echo 'none'")

    local -a PORT_LIST=()

    if [[ "$ports" != "none" && -n "$ports" ]]; then
        echo "Available serial ports:"
        echo
        local i=1
        while read -r port; do
            [[ -z "$port" ]] && continue
            PORT_LIST+=("$port")
            echo -e "  ${GREEN}$i)${NC} $port"
            ((i++))
        done <<< "$ports"
        echo -e "  ${GREEN}$i)${NC} Enter path manually"
        echo

        local max_choice=$i
        while true; do
            read -rp "$(echo -e "${CYAN}Select serial port [1-$max_choice]:${NC} ")" choice

            if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= max_choice )); then
                if (( choice == max_choice )); then
                    # Manual entry
                    prompt_with_default "Serial port" "/dev/ttyACM0" "SERIAL_PORT"
                else
                    SERIAL_PORT="${PORT_LIST[$((choice-1))]}"
                    print_success "Selected: $SERIAL_PORT"
                fi
                break
            else
                print_error "Invalid choice. Please enter 1-$max_choice."
            fi
        done
    else
        print_warn "No serial ports detected. Make sure your device is connected."
        prompt_with_default "Serial port" "/dev/ttyACM0" "SERIAL_PORT"
    fi

    echo
    prompt_with_default "Baud rate" "$DEFAULT_BAUDRATE" "SERIAL_BAUDRATE"

    MESHCORE_ADDRESS="$SERIAL_PORT"
}

configure_ble() {
    print_step "BLE Configuration"
    echo

    local -a DEVICE_MACS=()
    local -a DEVICE_NAMES=()

    if prompt_yes_no "Scan for BLE devices on remote?" "y"; then
        print_info "Scanning for BLE devices (this may take 15 seconds)..."

        # Install bleak in venv and scan
        run_remote "
            cd '$INSTALL_DIR'
            venv/bin/pip install bleak -q
        "

        local scan_result
        scan_result=$(run_remote "cd '$INSTALL_DIR' && venv/bin/python3 -c '
import asyncio
from bleak import BleakScanner

async def scan():
    devices = []
    def callback(device, adv):
        name = device.name or adv.local_name or \"Unknown\"
        rssi = adv.rssi if hasattr(adv, \"rssi\") else None
        if not any(d[0] == device.address for d in devices):
            devices.append((device.address, name, rssi))

    scanner = BleakScanner(detection_callback=callback)
    await scanner.start()
    await asyncio.sleep(10)
    await scanner.stop()

    # Sort by RSSI, prioritize MeshCore devices
    meshcore_devices = []
    other_devices = []
    for addr, name, rssi in devices:
        is_meshcore = any(x in name.upper() for x in [\"MESH\", \"LORA\", \"HELTEC\", \"RAK\", \"NODE\", \"COMPANION\"])
        if is_meshcore:
            meshcore_devices.append((addr, name, rssi))
        elif name != \"Unknown\":
            other_devices.append((addr, name, rssi))

    # Sort each by RSSI
    meshcore_devices.sort(key=lambda x: x[2] or -999, reverse=True)
    other_devices.sort(key=lambda x: x[2] or -999, reverse=True)

    # Output meshcore devices first, then others (limit to 10 others)
    for addr, name, rssi in meshcore_devices + other_devices[:10]:
        rssi_str = f\"RSSI:{rssi}\" if rssi else \"\"
        print(f\"{addr}|{name}|{rssi_str}\")

asyncio.run(scan())
' 2>/dev/null")

        echo
        if [[ -n "$scan_result" ]]; then
            echo "Found devices:"
            echo
            local i=1
            while IFS='|' read -r mac name rssi; do
                DEVICE_MACS+=("$mac")
                DEVICE_NAMES+=("$name")
                # Check if likely MeshCore device
                if [[ "${name^^}" =~ MESH|LORA|HELTEC|RAK|NODE|COMPANION ]]; then
                    echo -e "  ${GREEN}$i)${NC} $name ${CYAN}($mac)${NC} $rssi ${YELLOW}<-- Likely MeshCore${NC}"
                else
                    echo -e "  ${GREEN}$i)${NC} $name ${CYAN}($mac)${NC} $rssi"
                fi
                ((i++))
            done <<< "$scan_result"
            echo -e "  ${GREEN}$i)${NC} Enter MAC address manually"
            echo

            local max_choice=$i
            while true; do
                read -rp "$(echo -e "${CYAN}Select device [1-$max_choice]:${NC} ")" choice

                if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= max_choice )); then
                    if (( choice == max_choice )); then
                        # Manual entry
                        break
                    else
                        BLE_ADDRESS="${DEVICE_MACS[$((choice-1))]}"
                        print_success "Selected: ${DEVICE_NAMES[$((choice-1))]} ($BLE_ADDRESS)"
                        MESHCORE_ADDRESS="$BLE_ADDRESS"
                        return
                    fi
                else
                    print_error "Invalid choice. Please enter 1-$max_choice."
                fi
            done
        else
            print_warn "No devices found. You'll need to enter the MAC address manually."
        fi
    fi

    echo
    echo -e "${YELLOW}Enter the BLE MAC address of your MeshCore device${NC}"
    echo -e "${CYAN}Format: AA:BB:CC:DD:EE:FF${NC}"
    echo

    while true; do
        prompt_with_default "BLE MAC Address" "" "BLE_ADDRESS"

        if [[ "$BLE_ADDRESS" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]]; then
            BLE_ADDRESS=$(echo "$BLE_ADDRESS" | tr '[:lower:]' '[:upper:]')
            break
        else
            print_error "Invalid MAC address format. Please use format: AA:BB:CC:DD:EE:FF"
        fi
    done

    MESHCORE_ADDRESS="$BLE_ADDRESS"
}

configure_tcp() {
    print_step "TCP Configuration"
    echo

    prompt_with_default "MeshCore device IP address" "192.168.1.100" "TCP_ADDRESS"
    prompt_with_default "TCP port" "$DEFAULT_TCP_PORT" "TCP_PORT"

    MESHCORE_ADDRESS="$TCP_ADDRESS"
}

configure_mqtt() {
    print_step "MQTT Broker Configuration"
    echo

    prompt_with_default "MQTT broker address" "localhost" "MQTT_BROKER"
    prompt_with_default "MQTT port" "$DEFAULT_MQTT_PORT" "MQTT_PORT"

    if prompt_yes_no "Does your MQTT broker require authentication?" "n"; then
        prompt_with_default "MQTT username" "" "MQTT_USERNAME"
        prompt_password "MQTT password" "MQTT_PASSWORD"
    else
        MQTT_USERNAME=""
        MQTT_PASSWORD=""
    fi

    prompt_with_default "MQTT topic prefix" "$DEFAULT_MQTT_PREFIX" "MQTT_PREFIX"
    prompt_with_default "MQTT QoS (0, 1, or 2)" "$DEFAULT_MQTT_QOS" "MQTT_QOS"

    if prompt_yes_no "Enable TLS/SSL for MQTT?" "n"; then
        MQTT_TLS="true"
        if [[ "$MQTT_PORT" == "1883" ]]; then
            MQTT_PORT="8883"
            print_info "Port changed to 8883 for TLS"
        fi
    else
        MQTT_TLS="false"
    fi
}

generate_config() {
    print_step "Generating configuration..."

    # Build events array
    local events='"CONTACT_MSG_RECV","CHANNEL_MSG_RECV","BATTERY","DEVICE_INFO","NEW_CONTACT","ADVERTISEMENT","TELEMETRY_RESPONSE"'

    # Build meshcore config based on connection type
    local meshcore_config
    case "$CONNECTION_TYPE" in
        serial)
            meshcore_config="\"connection_type\": \"serial\",
    \"address\": \"$MESHCORE_ADDRESS\",
    \"baudrate\": $SERIAL_BAUDRATE"
            ;;
        ble)
            meshcore_config="\"connection_type\": \"ble\",
    \"address\": \"$MESHCORE_ADDRESS\""
            ;;
        tcp)
            meshcore_config="\"connection_type\": \"tcp\",
    \"address\": \"$MESHCORE_ADDRESS\",
    \"port\": $TCP_PORT"
            ;;
    esac

    # Build MQTT auth section
    local mqtt_auth=""
    if [[ -n "$MQTT_USERNAME" ]]; then
        mqtt_auth="\"username\": \"$MQTT_USERNAME\",
    \"password\": \"$MQTT_PASSWORD\","
    fi

    local config="{
  \"mqtt\": {
    \"broker\": \"$MQTT_BROKER\",
    \"port\": $MQTT_PORT,
    $mqtt_auth
    \"topic_prefix\": \"$MQTT_PREFIX\",
    \"qos\": $MQTT_QOS,
    \"retain\": false,
    \"tls_enabled\": $MQTT_TLS
  },
  \"meshcore\": {
    $meshcore_config,
    \"timeout\": 10,
    \"auto_fetch_restart_delay\": 5,
    \"message_initial_delay\": 15.0,
    \"message_send_delay\": 15.0,
    \"events\": [$events]
  },
  \"log_level\": \"INFO\"
}"

    copy_to_remote "$config" "$INSTALL_DIR/config.json"
    print_success "Configuration saved"
}

create_systemd_service() {
    print_step "Creating systemd service..."

    local service="[Unit]
Description=MeshCore MQTT Bridge
After=network-online.target bluetooth.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=$INSTALL_DIR
ExecStart=$INSTALL_DIR/venv/bin/python -m meshcore_mqtt.main --config-file $INSTALL_DIR/config.json
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target"

    copy_to_remote "$service" "/etc/systemd/system/meshcore-mqtt.service"

    run_remote "systemctl daemon-reload && systemctl enable meshcore-mqtt"
    print_success "Systemd service created and enabled"
}

print_summary() {
    echo
    echo -e "${CYAN}============================================================${NC}"
    echo -e "${GREEN}            Installation Complete!${NC}"
    echo -e "${CYAN}============================================================${NC}"
    echo
    echo -e "${GREEN}Device:${NC} ${DEVICE_USER}@${DEVICE_IP}"
    echo -e "${GREEN}Install directory:${NC} $INSTALL_DIR"
    echo -e "${GREEN}Connection type:${NC} $CONNECTION_TYPE"
    echo -e "${GREEN}Device address:${NC} $MESHCORE_ADDRESS"
    echo -e "${GREEN}MQTT broker:${NC} $MQTT_BROKER:$MQTT_PORT"
    echo
    echo -e "${YELLOW}Commands:${NC}"
    echo "  Start:   ssh ${DEVICE_USER}@${DEVICE_IP} 'systemctl start meshcore-mqtt'"
    echo "  Stop:    ssh ${DEVICE_USER}@${DEVICE_IP} 'systemctl stop meshcore-mqtt'"
    echo "  Logs:    ssh ${DEVICE_USER}@${DEVICE_IP} 'journalctl -u meshcore-mqtt -f'"
    echo "  Status:  ssh ${DEVICE_USER}@${DEVICE_IP} 'systemctl status meshcore-mqtt'"
    echo

    if prompt_yes_no "Start the service now?" "y"; then
        run_remote "systemctl start meshcore-mqtt"
        print_success "Service started"
        echo
        print_info "Showing logs (Ctrl+C to exit)..."
        sleep 2
        run_remote "journalctl -u meshcore-mqtt -n 20 --no-pager"
    fi
}

# Main execution
main() {
    print_banner
    check_local_dependencies
    get_device_info
    install_remote_dependencies
    clone_repository
    select_connection_type

    case "$CONNECTION_TYPE" in
        serial) configure_serial ;;
        ble) configure_ble ;;
        tcp) configure_tcp ;;
    esac

    configure_mqtt
    generate_config
    create_systemd_service
    print_summary
}

main "$@"
