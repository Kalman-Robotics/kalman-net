#!/bin/bash
# ─────────────────────────────────────────────
#  kalman-net — Robot Setup
#  Uso: sudo bash robot-setup.sh
#
#  Variables requeridas (editar antes de ejecutar o exportar):
#    KALMAN_NET_SERVER  URL del servidor de control  ej: http://34.X.X.X:8080
#    ROBOT_HOSTNAME     Nombre del robot             ej: kalman-robot-1
#
#  Variables opcionales:
#    ROS_DISTRO         humble (default)
# ─────────────────────────────────────────────

set -e

KALMAN_NET_SERVER="${KALMAN_NET_SERVER:-http://localhost:8080}"
ROBOT_HOSTNAME="${ROBOT_HOSTNAME:-kalman-robot-1}"
ROS_DISTRO="${ROS_DISTRO:-humble}"
KALMAN_DIR="/var/lib/kalman-net"
WG_IFACE="wg0"
WG_PORT="51820"

# ─── Colors ───
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
log_info() { echo -e "${BLUE}[..]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[!!]${NC} $1"; }
log_err()  { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

echo
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  kalman-net — Configuración del robot${NC}"
echo -e "${BLUE}  Servidor: ${KALMAN_NET_SERVER}${NC}"
echo -e "${BLUE}  Hostname: ${ROBOT_HOSTNAME}${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo

# ─── 1. Instalar dependencias ───
log_info "Verificando dependencias..."
PKGS_NEEDED=""
command -v wg     &>/dev/null || PKGS_NEEDED="${PKGS_NEEDED} wireguard-tools"
command -v curl   &>/dev/null || PKGS_NEEDED="${PKGS_NEEDED} curl"
command -v jq     &>/dev/null || PKGS_NEEDED="${PKGS_NEEDED} jq"
command -v nmap   &>/dev/null || PKGS_NEEDED="${PKGS_NEEDED} nmap"   # para ncat STUN
python3 -c "import socket" 2>/dev/null || PKGS_NEEDED="${PKGS_NEEDED} python3"

if [ -n "${PKGS_NEEDED}" ]; then
    log_info "Instalando:${PKGS_NEEDED}..."
    apt-get update -qq
    apt-get install -y --no-install-recommends iproute2 ${PKGS_NEEDED}
fi
log_ok "Dependencias listas."

# ─── 2. Generar o cargar keypair WireGuard ───
mkdir -p "${KALMAN_DIR}"
chmod 700 "${KALMAN_DIR}"

if [ ! -f "${KALMAN_DIR}/privatekey" ]; then
    log_info "Generando keypair WireGuard..."
    wg genkey | tee "${KALMAN_DIR}/privatekey" | wg pubkey > "${KALMAN_DIR}/publickey"
    chmod 600 "${KALMAN_DIR}/privatekey"
    log_ok "Keypair generado."
else
    log_ok "Keypair existente cargado."
fi

PRIVATE_KEY=$(cat "${KALMAN_DIR}/privatekey")
PUBLIC_KEY=$(cat "${KALMAN_DIR}/publickey")

# ─── 3. Detectar IPs locales ───
log_info "Detectando IPs locales..."
LOCAL_IPS=$(ip -4 addr show scope global | grep -oP '(?<=inet )\d+\.\d+\.\d+\.\d+' | grep -v '^127\.' | tr '\n' ',' | sed 's/,$//')
LOCAL_IPS_JSON=$(echo "${LOCAL_IPS}" | tr ',' '\n' | grep -v '^$' | jq -R . | jq -s .)
log_ok "IPs locales: ${LOCAL_IPS}"

# ─── 4. STUN para obtener endpoint público (antes de levantar WireGuard) ───
log_info "Detectando endpoint público via STUN..."
# STUN desde puerto efímero — lo que importa es la IP pública, no el puerto exacto
# El puerto real de WG (51820) lo reportamos fijo después
cat > /tmp/kalman_stun.py << 'PYEOF'
import socket, struct, os
STUN_SERVER = ("stun.l.google.com", 19302)
pkt = struct.pack(">HHI12s", 0x0001, 0, 0x2112A442, os.urandom(12))
try:
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(5)
    s.sendto(pkt, STUN_SERVER)
    data, _ = s.recvfrom(512)
    s.close()
    offset = 20
    while offset < len(data) - 4:
        t = struct.unpack(">H", data[offset:offset+2])[0]
        l = struct.unpack(">H", data[offset+2:offset+4])[0]
        if t == 0x0020 and data[offset+5] == 1:
            ip = bytes(b ^ v for b, v in zip(data[offset+8:offset+12], struct.pack(">I", 0x2112A442)))
            print(f"{ip[0]}.{ip[1]}.{ip[2]}.{ip[3]}")
            break
        offset += 4 + l + (4 - l % 4) % 4
except:
    pass
PYEOF
PUBLIC_ENDPOINT=$(python3 /tmp/kalman_stun.py 2>/dev/null || echo "")

if [ -z "${PUBLIC_ENDPOINT}" ]; then
    PUBLIC_ENDPOINT=$(curl -s --max-time 5 https://api.ipify.org || echo "")
    log_warn "STUN falló, usando fallback IP: ${PUBLIC_ENDPOINT}"
fi
PUBLIC_ENDPOINT="${PUBLIC_ENDPOINT}:${WG_PORT}"
log_ok "Endpoint: ${PUBLIC_ENDPOINT}"

# ─── 5b. Bajar interfaz anterior si existe ───
wg-quick down "${WG_IFACE}" 2>/dev/null || true

# ─── 6. Registrar en el servidor de control ───
log_info "Registrando en el servidor de control..."
REGISTER_RESPONSE=$(curl -sf --max-time 15 \
    -X POST "${KALMAN_NET_SERVER}/api/peers/register" \
    -H "Content-Type: application/json" \
    -d "{\"hostname\":\"${ROBOT_HOSTNAME}\",\"public_key\":\"${PUBLIC_KEY}\",\"endpoint\":\"${PUBLIC_ENDPOINT}\",\"local_ips\":${LOCAL_IPS_JSON}}")

if [ -z "${REGISTER_RESPONSE}" ]; then
    log_err "No se pudo conectar con el servidor de control en ${KALMAN_NET_SERVER}"
fi

PEER_ID=$(echo "${REGISTER_RESPONSE}"    | jq -r '.id')
OVERLAY_IP=$(echo "${REGISTER_RESPONSE}" | jq -r '.overlay_ip')

if [ -z "${PEER_ID}" ] || [ "${PEER_ID}" = "null" ]; then
    log_err "Respuesta inválida del servidor: ${REGISTER_RESPONSE}"
fi

echo "${PEER_ID}"           > "${KALMAN_DIR}/peer_id"
echo "${OVERLAY_IP}"        > "${KALMAN_DIR}/overlay_ip"
echo "${KALMAN_NET_SERVER}" > "${KALMAN_DIR}/server_url"
log_ok "Registrado. Peer ID: ${PEER_ID} | IP overlay: ${OVERLAY_IP}"

# ─── 7. Levantar interfaz WireGuard con IP overlay asignada ───
log_info "Configurando interfaz WireGuard (${WG_IFACE})..."
mkdir -p /etc/wireguard

cat > /etc/wireguard/wg0.conf << WGEOF
[Interface]
PrivateKey = ${PRIVATE_KEY}
Address = ${OVERLAY_IP}/24
ListenPort = ${WG_PORT}
WGEOF
chmod 600 /etc/wireguard/wg0.conf

wg-quick up "${WG_IFACE}"
log_ok "Interfaz ${WG_IFACE} activa. IP: ${OVERLAY_IP}"

# ─── 8. Instalar kalman-net-sync (daemon de sincronización WireGuard) ───
log_info "Instalando daemon de sincronización..."

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cp "${SCRIPT_DIR}/kalman-net-sync-robot.sh" /usr/local/bin/kalman-net-sync.sh
chmod +x /usr/local/bin/kalman-net-sync.sh

# DEPRECATED HEREDOC — reemplazado por archivo kalman-net-sync-robot.sh
# Dejamos el bloque comentado como referencia
: << 'SYNCEOF'
#!/bin/bash
# kalman-net-sync: mantiene WireGuard sincronizado y ejecuta hole punching P2P

KALMAN_DIR="/var/lib/kalman-net"
WG_IFACE="wg0"
WG_PORT="51820"

PEER_ID=$(cat "${KALMAN_DIR}/peer_id" 2>/dev/null || echo "")
SERVER_URL=$(cat "${KALMAN_DIR}/server_url" 2>/dev/null || echo "")

[ -z "${PEER_ID}" ] || [ -z "${SERVER_URL}" ] && { echo "kalman-net-sync: sin peer_id o server_url"; exit 1; }

# ─── Aplicar network map ───
apply_network_map() {
    local MAP_JSON="$1"
    [ -z "${MAP_JSON}" ] && return

    PEERS_JSON=$(echo "${MAP_JSON}" | jq -c '.peers // []')
    PEER_COUNT=$(echo "${PEERS_JSON}" | jq 'length')

    for existing_key in $(wg show "${WG_IFACE}" peers 2>/dev/null); do
        wg set "${WG_IFACE}" peer "${existing_key}" remove
    done

    i=0
    while [ $i -lt "${PEER_COUNT}" ]; do
        PUBKEY=$(echo "${PEERS_JSON}"   | jq -r ".[${i}].public_key")
        PEER_IP=$(echo "${PEERS_JSON}"  | jq -r ".[${i}].overlay_ip")
        ENDPOINT=$(echo "${PEERS_JSON}" | jq -r ".[${i}].endpoint // empty")
        HOSTNAME=$(echo "${PEERS_JSON}" | jq -r ".[${i}].hostname")

        if [ -n "${PUBKEY}" ] && [ "${PUBKEY}" != "null" ]; then
            if [ -n "${ENDPOINT}" ] && [ "${ENDPOINT}" != "null" ] && \
               [ "${ENDPOINT}" != ":51820" ] && [ "${ENDPOINT}" != ":51821" ]; then
                wg set "${WG_IFACE}" peer "${PUBKEY}" \
                    allowed-ips "${PEER_IP}/32" \
                    endpoint "${ENDPOINT}" \
                    persistent-keepalive 25
            else
                wg set "${WG_IFACE}" peer "${PUBKEY}" \
                    allowed-ips "${PEER_IP}/32" \
                    persistent-keepalive 25
            fi
            logger -t kalman-net-sync "peer aplicado: ${HOSTNAME} (${PEER_IP}) endpoint=${ENDPOINT}"
        fi
        i=$((i + 1))
    done
    logger -t kalman-net-sync "network map aplicado: ${PEER_COUNT} peers"
}

# ─── Ejecutar hole punch UDP ───
# El servidor envía las candidatas del otro peer; enviamos paquetes UDP vacíos
# a cada endpoint candidato para abrir el puerto en nuestro NAT simultáneamente
do_punch() {
    local SIGNAL_JSON="$1"
    local TARGET_PUBKEY=$(echo "${SIGNAL_JSON}" | jq -r '.wg_public_key')
    local TARGET_IP=$(echo "${SIGNAL_JSON}"     | jq -r '.overlay_ip')
    local TARGET_ENDPOINT=$(echo "${SIGNAL_JSON}" | jq -r '.endpoint // empty')
    local TARGET_LOCAL_IPS=$(echo "${SIGNAL_JSON}" | jq -r '.local_ips[]? // empty')

    logger -t kalman-net-sync "[punch] iniciando hacia ${TARGET_ENDPOINT}"

    # Agregar peer con endpoint público para que WireGuard intente alcanzarlo
    if [ -n "${TARGET_PUBKEY}" ] && [ "${TARGET_PUBKEY}" != "null" ]; then
        if [ -n "${TARGET_ENDPOINT}" ] && [ "${TARGET_ENDPOINT}" != "null" ]; then
            wg set "${WG_IFACE}" peer "${TARGET_PUBKEY}" \
                allowed-ips "${TARGET_IP}/32" \
                endpoint "${TARGET_ENDPOINT}" \
                persistent-keepalive 5
        fi

        # Enviar paquetes UDP al endpoint público para abrir NAT
        if command -v python3 &>/dev/null && [ -n "${TARGET_ENDPOINT}" ]; then
            TARGET_HOST=$(echo "${TARGET_ENDPOINT}" | cut -d: -f1)
            TARGET_PORT=$(echo "${TARGET_ENDPOINT}" | cut -d: -f2)
            python3 -c "
import socket, time
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
s.bind(('0.0.0.0', ${WG_PORT}))
for _ in range(5):
    try:
        s.sendto(b'\\x00', ('${TARGET_HOST}', ${TARGET_PORT}))
    except:
        pass
    time.sleep(0.1)
s.close()
" 2>/dev/null || true
        fi

        # También probar IPs locales si están en la misma red
        for LOCAL_IP in ${TARGET_LOCAL_IPS}; do
            NETWORK=$(echo "${LOCAL_IP}" | cut -d. -f1-3)
            MY_NETWORK=$(ip -4 addr show "${WG_IFACE}" 2>/dev/null | grep -oP '(?<=inet )\d+\.\d+\.\d+' | head -1 || echo "")
            # Solo si parecen estar en la misma subred privada
            case "${LOCAL_IP}" in
                192.168.*|10.*|172.1[6-9].*|172.2[0-9].*|172.3[0-1].*)
                    logger -t kalman-net-sync "[punch] probando LAN: ${LOCAL_IP}:${WG_PORT}"
                    wg set "${WG_IFACE}" peer "${TARGET_PUBKEY}" \
                        endpoint "${LOCAL_IP}:${WG_PORT}" 2>/dev/null || true
                    ;;
            esac
        done

        # Restaurar keepalive normal después del punch
        sleep 2
        wg set "${WG_IFACE}" peer "${TARGET_PUBKEY}" persistent-keepalive 25 2>/dev/null || true

        logger -t kalman-net-sync "[punch] completado hacia ${TARGET_ENDPOINT}"
    fi
}

# ─── Actualizar endpoint vía STUN y notificar al servidor ───
update_stun_endpoint() {
    NEW_ENDPOINT=$(python3 /tmp/kalman_stun.py 2>/dev/null || echo "")
    [ -z "${NEW_ENDPOINT}" ] && return
    NEW_ENDPOINT="${NEW_ENDPOINT}:51820"

    LOCAL_IPS=$(ip -4 addr show scope global | grep -oP '(?<=inet )\d+\.\d+\.\d+\.\d+' | grep -v '^127\.' | jq -R . | jq -s .)
    curl -sf --max-time 5 -X POST \
        "${SERVER_URL}/api/peers/${PEER_ID}/heartbeat" \
        -H "Content-Type: application/json" \
        -d "{\"endpoint\":\"${NEW_ENDPOINT}\",\"local_ips\":${LOCAL_IPS}}" > /dev/null 2>&1 || true
}

# ─── Heartbeat en background ───
heartbeat_loop() {
    while true; do
        curl -sf --max-time 5 -X POST \
            "${SERVER_URL}/api/peers/${PEER_ID}/heartbeat" \
            -H "Content-Type: application/json" \
            -d "{}" > /dev/null 2>&1 || true
        sleep 30
    done
}
heartbeat_loop &
HEARTBEAT_PID=$!

# ─── Loop principal ───
if command -v websocat &>/dev/null; then
    WS_URL=$(echo "${SERVER_URL}" | sed 's|http://|ws://|' | sed 's|https://|wss://|')
    logger -t kalman-net-sync "conectando WebSocket ${WS_URL}/ws?peer_id=${PEER_ID}"

    while true; do
        websocat --no-close -t "${WS_URL}/ws?peer_id=${PEER_ID}" 2>/dev/null | while IFS= read -r line; do
            [ -z "${line}" ] && continue
            MSG_TYPE=$(echo "${line}" | jq -r '.type // empty' 2>/dev/null)
            PAYLOAD=$(echo "${line}"  | jq -c '.payload // empty' 2>/dev/null)
            case "${MSG_TYPE}" in
                network_map)
                    apply_network_map "${PAYLOAD}"
                    ;;
                punch)
                    do_punch "${PAYLOAD}"
                    ;;
                relay)
                    logger -t kalman-net-sync "relay pkt recibido (ignorado en robot)"
                    ;;
                "")
                    apply_network_map "${line}"
                    ;;
            esac
        done
        logger -t kalman-net-sync "WebSocket desconectado, reconectando en 5s..."
        sleep 5
    done
else
    # Fallback: polling HTTP cada 30s
    logger -t kalman-net-sync "websocat no disponible, usando polling HTTP"
    STUN_TICK=0
    while true; do
        MAP=$(curl -sf --max-time 10 \
            "${SERVER_URL}/api/peers/${PEER_ID}/network-map" 2>/dev/null || echo "")
        [ -n "${MAP}" ] && apply_network_map "${MAP}"

        curl -sf --max-time 5 -X POST \
            "${SERVER_URL}/api/peers/${PEER_ID}/heartbeat" \
            -H "Content-Type: application/json" \
            -d "{}" > /dev/null 2>&1 || true

        STUN_TICK=$((STUN_TICK + 1))
        [ $((STUN_TICK % 10)) -eq 0 ] && update_stun_endpoint

        sleep 30
    done
fi
SYNCEOF

# Servicio systemd
cat > /etc/systemd/system/kalman-net-sync.service << EOF
[Unit]
Description=kalman-net WireGuard sync daemon
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/kalman-net-sync.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable kalman-net-sync --quiet
systemctl restart kalman-net-sync
log_ok "Daemon kalman-net-sync activo."

# ─── 9. Configurar CycloneDDS sobre wg0 ───
log_info "Configurando CycloneDDS sobre WireGuard..."

cat > "${KALMAN_DIR}/cyclonedds.xml" << 'EOF'
<?xml version="1.0" encoding="UTF-8" ?>
<CycloneDDS xmlns="https://cdds.io/config"
    xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
    xsi:schemaLocation="https://cdds.io/config https://raw.githubusercontent.com/eclipse-cyclonedds/cyclonedds/master/etc/cyclonedds.xsd">
    <Domain id="any">
        <General>
            <Interfaces>
                <NetworkInterface name="wg0"/>
            </Interfaces>
            <AllowMulticast>false</AllowMulticast>
            <MaxMessageSize>65500B</MaxMessageSize>
            <FragmentSize>4000B</FragmentSize>
        </General>
        <Discovery>
            <Peers>
                <Peer address="10.99.0.0/24"/>
            </Peers>
            <MaxAutoParticipantIndex>100</MaxAutoParticipantIndex>
            <ParticipantIndex>auto</ParticipantIndex>
        </Discovery>
        <Internal>
            <Watermarks>
                <WhcHigh>500kB</WhcHigh>
            </Watermarks>
        </Internal>
        <Tracing>
            <Verbosity>severe</Verbosity>
            <OutputFile>stdout</OutputFile>
        </Tracing>
    </Domain>
</CycloneDDS>
EOF

REAL_USER="${SUDO_USER:-$(whoami)}"
REAL_HOME=$(eval echo "~${REAL_USER}")
BASHRC="${REAL_HOME}/.bashrc"

if ! grep -q "kalman-net" "${BASHRC}" 2>/dev/null; then
    cat >> "${BASHRC}" << ENVEOF

# kalman-net ROS2 environment
source /opt/ros/${ROS_DISTRO}/setup.bash 2>/dev/null || true
export RMW_IMPLEMENTATION=rmw_cyclonedds_cpp
export CYCLONEDDS_URI=file://${KALMAN_DIR}/cyclonedds.xml
export ROS_DOMAIN_ID=0
ENVEOF
fi

log_ok "CycloneDDS configurado sobre wg0."

# ─── Resumen ───
echo
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  Robot configurado correctamente${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "  Hostname:   ${ROBOT_HOSTNAME}"
echo -e "  Peer ID:    ${PEER_ID}"
echo -e "  IP overlay: ${OVERLAY_IP}"
echo -e "  Endpoint:   ${PUBLIC_ENDPOINT}"
echo -e "  Puerto WG:  ${WG_PORT}/udp  ← abrir en firewall/security group"
echo
echo -e "  Verifica la interfaz:  ${YELLOW}wg show${NC}"
echo -e "  Ver peers activos:     ${YELLOW}wg showconf wg0${NC}"
echo -e "  Estado del daemon:     ${YELLOW}systemctl status kalman-net-sync${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo
echo -e "${YELLOW}IMPORTANTE: Para agregar este robot a una sesión, el admin debe:${NC}"
echo -e "  1. Crear un grupo en el servidor de control"
echo -e "  2. Agregar este peer (ID: ${PEER_ID}) al grupo"
echo -e "  3. Generar un join-code para el estudiante"
