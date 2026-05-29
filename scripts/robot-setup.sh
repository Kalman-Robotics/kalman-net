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
OVERLAY_SUBNET="10.99.0.0/24"

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

# ─── 1. Instalar WireGuard ───
log_info "Verificando WireGuard..."
if ! command -v wg &>/dev/null; then
    log_info "Instalando WireGuard..."
    apt-get update -qq
    apt-get install -y --no-install-recommends wireguard-tools iproute2 curl jq
    log_ok "WireGuard instalado."
else
    log_ok "WireGuard ya instalado."
fi

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

# ─── 3. Detectar endpoint público (IP:puerto) ───
log_info "Detectando IP pública..."
PUBLIC_IP=$(curl -s --max-time 5 https://api.ipify.org || echo "")
ENDPOINT="${PUBLIC_IP}:${WG_PORT}"
log_ok "Endpoint: ${ENDPOINT}"

# ─── 4. Registrar en el servidor de control ───
log_info "Registrando en el servidor de control..."
REGISTER_RESPONSE=$(curl -sf --max-time 15 \
    -X POST "${KALMAN_NET_SERVER}/api/peers/register" \
    -H "Content-Type: application/json" \
    -d "{\"hostname\":\"${ROBOT_HOSTNAME}\",\"public_key\":\"${PUBLIC_KEY}\",\"endpoint\":\"${ENDPOINT}\"}")

if [ -z "${REGISTER_RESPONSE}" ]; then
    log_err "No se pudo conectar con el servidor de control en ${KALMAN_NET_SERVER}"
fi

PEER_ID=$(echo "${REGISTER_RESPONSE}"    | jq -r '.id')
OVERLAY_IP=$(echo "${REGISTER_RESPONSE}" | jq -r '.overlay_ip')

if [ -z "${PEER_ID}" ] || [ "${PEER_ID}" = "null" ]; then
    log_err "Respuesta inválida del servidor: ${REGISTER_RESPONSE}"
fi

echo "${PEER_ID}"   | tee "${KALMAN_DIR}/peer_id"   > /dev/null
echo "${OVERLAY_IP}" | tee "${KALMAN_DIR}/overlay_ip" > /dev/null
echo "${KALMAN_NET_SERVER}" | tee "${KALMAN_DIR}/server_url" > /dev/null
log_ok "Registrado. Peer ID: ${PEER_ID} | IP overlay: ${OVERLAY_IP}"

# ─── 5. Levantar interfaz WireGuard ───
log_info "Configurando interfaz WireGuard (${WG_IFACE})..."

# Derribar interfaz anterior si existe
ip link del "${WG_IFACE}" 2>/dev/null || true

ip link add dev "${WG_IFACE}" type wireguard
wg set "${WG_IFACE}" private-key "${KALMAN_DIR}/privatekey" listen-port "${WG_PORT}"
ip addr add "${OVERLAY_IP}/24" dev "${WG_IFACE}"
ip link set "${WG_IFACE}" up

log_ok "Interfaz ${WG_IFACE} activa. IP: ${OVERLAY_IP}"

# ─── 6. Instalar kalman-net-sync (daemon de sincronización WireGuard) ───
log_info "Instalando daemon de sincronización..."

cat > /usr/local/bin/kalman-net-sync.sh << 'SYNCEOF'
#!/bin/bash
# Daemon que mantiene WireGuard sincronizado con el servidor de control
# Usa WebSocket para recibir actualizaciones en tiempo real; polling como fallback

KALMAN_DIR="/var/lib/kalman-net"
WG_IFACE="wg0"

PEER_ID=$(cat "${KALMAN_DIR}/peer_id" 2>/dev/null || echo "")
SERVER_URL=$(cat "${KALMAN_DIR}/server_url" 2>/dev/null || echo "")
PRIVATE_KEY_FILE="${KALMAN_DIR}/privatekey"

[ -z "${PEER_ID}" ] || [ -z "${SERVER_URL}" ] && { echo "kalman-net-sync: sin peer_id o server_url"; exit 1; }

apply_network_map() {
    local MAP_JSON="$1"
    [ -z "${MAP_JSON}" ] && return

    SELF_IP=$(echo "${MAP_JSON}" | jq -r '.self_ip // empty')
    PEERS_JSON=$(echo "${MAP_JSON}" | jq -c '.peers // []')
    PEER_COUNT=$(echo "${PEERS_JSON}" | jq 'length')

    # Limpiar peers actuales de WireGuard
    for existing_key in $(wg show "${WG_IFACE}" peers 2>/dev/null); do
        wg set "${WG_IFACE}" peer "${existing_key}" remove
    done

    # Aplicar nuevos peers
    i=0
    while [ $i -lt "${PEER_COUNT}" ]; do
        PUBKEY=$(echo "${PEERS_JSON}"   | jq -r ".[${i}].public_key")
        PEER_IP=$(echo "${PEERS_JSON}"  | jq -r ".[${i}].overlay_ip")
        ENDPOINT=$(echo "${PEERS_JSON}" | jq -r ".[${i}].endpoint // empty")
        HOSTNAME=$(echo "${PEERS_JSON}" | jq -r ".[${i}].hostname")

        if [ -n "${PUBKEY}" ] && [ "${PUBKEY}" != "null" ]; then
            if [ -n "${ENDPOINT}" ] && [ "${ENDPOINT}" != "null" ] && [ "${ENDPOINT}" != ":51820" ]; then
                wg set "${WG_IFACE}" peer "${PUBKEY}" \
                    allowed-ips "${PEER_IP}/32" \
                    endpoint "${ENDPOINT}" \
                    persistent-keepalive 25
            else
                wg set "${WG_IFACE}" peer "${PUBKEY}" \
                    allowed-ips "${PEER_IP}/32" \
                    persistent-keepalive 25
            fi
            logger -t kalman-net-sync "peer aplicado: ${HOSTNAME} (${PEER_IP})"
        fi
        i=$((i + 1))
    done

    logger -t kalman-net-sync "network map aplicado: ${PEER_COUNT} peers"
}

# Intentar WebSocket primero (requiere websocat si está disponible)
# Si no está, usar polling HTTP
if command -v websocat &>/dev/null; then
    WS_URL=$(echo "${SERVER_URL}" | sed 's|http://|ws://|' | sed 's|https://|wss://|')
    logger -t kalman-net-sync "conectando WebSocket ${WS_URL}/ws?peer_id=${PEER_ID}"

    while true; do
        websocat --no-close -t "${WS_URL}/ws?peer_id=${PEER_ID}" 2>/dev/null | while IFS= read -r line; do
            [ -z "${line}" ] && continue
            apply_network_map "${line}"
        done
        logger -t kalman-net-sync "WebSocket desconectado, reconectando en 5s..."
        sleep 5
    done
else
    # Fallback: polling cada 30s vía HTTP
    logger -t kalman-net-sync "websocat no disponible, usando polling HTTP cada 30s"
    while true; do
        MAP=$(curl -sf --max-time 10 \
            "${SERVER_URL}/api/peers/${PEER_ID}/network-map" 2>/dev/null || echo "")
        [ -n "${MAP}" ] && apply_network_map "${MAP}"

        # Heartbeat
        curl -sf --max-time 5 -X POST \
            "${SERVER_URL}/api/peers/${PEER_ID}/heartbeat" \
            -H "Content-Type: application/json" \
            -d "{}" > /dev/null 2>&1 || true

        sleep 30
    done
fi
SYNCEOF

chmod +x /usr/local/bin/kalman-net-sync.sh

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

# ─── 7. Configurar CycloneDDS sobre wg0 ───
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

# Variables ROS2 en .bashrc (del usuario que ejecuta el script)
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
