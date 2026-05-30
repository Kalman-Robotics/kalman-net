#!/bin/bash
# ─────────────────────────────────────────────
#  kalman-net — Student Setup
#  Uso: sudo bash student-setup.sh JOIN_CODE
#
#  Variables requeridas:
#    $1 (argumento)     Join code generado por el admin/plataforma
#    KALMAN_NET_SERVER  URL del servidor de control  ej: http://34.X.X.X:8080
#
#  Variables opcionales:
#    STUDENT_HOSTNAME   Nombre de este PC en la VPN  (default: alumno-$(hostname))
#    ROS_DISTRO         humble (default)
#    REQUIRES_ROS       true/false (default: true)
# ─────────────────────────────────────────────

set -e

JOIN_CODE="${1:-}"
KALMAN_NET_SERVER="${KALMAN_NET_SERVER:-http://localhost:8080}"
STUDENT_HOSTNAME="${STUDENT_HOSTNAME:-alumno-$(hostname)}"
ROS_DISTRO="${ROS_DISTRO:-humble}"
REQUIRES_ROS="${REQUIRES_ROS:-true}"
KALMAN_DIR="/var/lib/kalman-net"
WG_IFACE="wg0"
WG_PORT="51821"   # Puerto distinto al del robot para evitar conflictos en mismo host

# ─── Colors ───
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_ok()   { echo -e "${GREEN}✓${NC} $1"; }
log_info() { echo -e "${BLUE}[..]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[!!]${NC} $1"; }
log_err()  { echo -e "${RED}✗ Error:${NC} $1"; exit 1; }

if [ -z "${JOIN_CODE}" ]; then
    echo -e "${RED}Uso: sudo bash student-setup.sh JOIN_CODE${NC}"
    echo -e "  Obtén el JOIN_CODE del administrador o de la plataforma Kalman."
    exit 1
fi

echo
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  kalman-net — Conectando al laboratorio${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo

# ─── 1. Instalar dependencias ───
log_info "Verificando dependencias..."
PKGS_NEEDED=""
command -v wg     &>/dev/null || PKGS_NEEDED="${PKGS_NEEDED} wireguard-tools"
command -v curl   &>/dev/null || PKGS_NEEDED="${PKGS_NEEDED} curl"
command -v jq     &>/dev/null || PKGS_NEEDED="${PKGS_NEEDED} jq"
python3 -c "import socket" 2>/dev/null || PKGS_NEEDED="${PKGS_NEEDED} python3"

if [ -n "${PKGS_NEEDED}" ]; then
    log_info "Instalando:${PKGS_NEEDED}..."
    apt-get update -qq
    apt-get install -y --no-install-recommends iproute2 ${PKGS_NEEDED}
fi
log_ok "Dependencias listas."

# ─── 2. Limpiar sesión anterior si existe ───
if [ -f "${KALMAN_DIR}/peer_id" ]; then
    log_info "Limpiando sesión anterior..."
    systemctl stop kalman-net-sync 2>/dev/null || true
    ip link del "${WG_IFACE}" 2>/dev/null || true
    rm -f "${KALMAN_DIR}/peer_id" "${KALMAN_DIR}/overlay_ip" "${KALMAN_DIR}/group_id"
    log_ok "Sesión anterior limpiada."
fi

# ─── 3. Generar o reutilizar keypair WireGuard ───
mkdir -p "${KALMAN_DIR}"
chmod 700 "${KALMAN_DIR}"

if [ ! -f "${KALMAN_DIR}/privatekey" ]; then
    log_info "Generando keypair WireGuard..."
    wg genkey | tee "${KALMAN_DIR}/privatekey" | wg pubkey > "${KALMAN_DIR}/publickey"
    chmod 600 "${KALMAN_DIR}/privatekey"
    log_ok "Keypair generado."
else
    log_ok "Reutilizando keypair existente."
fi

PUBLIC_KEY=$(cat "${KALMAN_DIR}/publickey")

# ─── 4. Detectar IPs locales ───
log_info "Detectando IPs locales..."
LOCAL_IPS=$(ip -4 addr show scope global | grep -oP '(?<=inet )\d+\.\d+\.\d+\.\d+' | grep -v '^127\.' | tr '\n' ',' | sed 's/,$//')
LOCAL_IPS_JSON=$(echo "${LOCAL_IPS}" | tr ',' '\n' | grep -v '^$' | jq -R . | jq -s .)
log_ok "IPs locales: ${LOCAL_IPS}"

# ─── 5. STUN para obtener IP pública (antes de levantar WireGuard) ───
log_info "Detectando endpoint público via STUN..."
PRIVATE_KEY=$(cat "${KALMAN_DIR}/privatekey")
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

# ─── 7. Hacer join ───
log_info "Uniéndose al grupo de la sesión..."
JOIN_RESPONSE=$(curl -sf --max-time 15 \
    -X POST "${KALMAN_NET_SERVER}/api/join" \
    -H "Content-Type: application/json" \
    -d "{\"join_code\":\"${JOIN_CODE}\",\"hostname\":\"${STUDENT_HOSTNAME}\",\"public_key\":\"${PUBLIC_KEY}\",\"endpoint\":\"${PUBLIC_ENDPOINT}\",\"local_ips\":${LOCAL_IPS_JSON}}" 2>/dev/null || echo "")

if [ -z "${JOIN_RESPONSE}" ]; then
    log_err "No se pudo conectar con el servidor de control en ${KALMAN_NET_SERVER}"
fi

ERROR=$(echo "${JOIN_RESPONSE}" | jq -r '.error // empty')
if [ -n "${ERROR}" ]; then
    log_err "El servidor rechazó el join: ${ERROR}"
fi

PEER_ID=$(echo "${JOIN_RESPONSE}"    | jq -r '.peer.id')
OVERLAY_IP=$(echo "${JOIN_RESPONSE}" | jq -r '.peer.overlay_ip')
GROUP_ID=$(echo "${JOIN_RESPONSE}"   | jq -r '.group_id')

if [ -z "${PEER_ID}" ] || [ "${PEER_ID}" = "null" ]; then
    log_err "Respuesta inválida del servidor: ${JOIN_RESPONSE}"
fi

echo "${PEER_ID}"           > "${KALMAN_DIR}/peer_id"
echo "${OVERLAY_IP}"        > "${KALMAN_DIR}/overlay_ip"
echo "${GROUP_ID}"          > "${KALMAN_DIR}/group_id"
echo "${KALMAN_NET_SERVER}" > "${KALMAN_DIR}/server_url"
log_ok "Unido al grupo. IP overlay: ${OVERLAY_IP}"

# ─── 8. Levantar interfaz WireGuard con IP overlay asignada ───
log_info "Levantando interfaz WireGuard..."
mkdir -p /etc/wireguard

cat > /etc/wireguard/wg0.conf << WGEOF
[Interface]
PrivateKey = ${PRIVATE_KEY}
Address = ${OVERLAY_IP}/24
ListenPort = ${WG_PORT}
WGEOF
chmod 600 /etc/wireguard/wg0.conf

wg-quick down "${WG_IFACE}" 2>/dev/null || true
wg-quick up "${WG_IFACE}"
log_ok "Interfaz ${WG_IFACE} activa. IP: ${OVERLAY_IP}"

# ─── 9. Instalar kalman-net-sync ───
log_info "Instalando daemon de sincronización..."

cat > /usr/local/bin/kalman-net-sync.sh << 'SYNCEOF'
#!/bin/bash
# kalman-net-sync: mantiene WireGuard sincronizado y ejecuta hole punching P2P

KALMAN_DIR="/var/lib/kalman-net"
WG_IFACE="wg0"
WG_PORT="51821"

PEER_ID=$(cat "${KALMAN_DIR}/peer_id" 2>/dev/null || echo "")
SERVER_URL=$(cat "${KALMAN_DIR}/server_url" 2>/dev/null || echo "")

[ -z "${PEER_ID}" ] || [ -z "${SERVER_URL}" ] && exit 1

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
        PUBKEY=$(echo "${PEERS_JSON}"    | jq -r ".[${i}].public_key")
        PEER_IP=$(echo "${PEERS_JSON}"   | jq -r ".[${i}].overlay_ip")
        ENDPOINT=$(echo "${PEERS_JSON}"  | jq -r ".[${i}].endpoint // empty")
        HOSTNAME=$(echo "${PEERS_JSON}"  | jq -r ".[${i}].hostname")

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
do_punch() {
    local SIGNAL_JSON="$1"
    local TARGET_PUBKEY=$(echo "${SIGNAL_JSON}" | jq -r '.wg_public_key')
    local TARGET_IP=$(echo "${SIGNAL_JSON}"     | jq -r '.overlay_ip')
    local TARGET_ENDPOINT=$(echo "${SIGNAL_JSON}" | jq -r '.endpoint // empty')
    local TARGET_LOCAL_IPS=$(echo "${SIGNAL_JSON}" | jq -r '.local_ips[]? // empty')

    logger -t kalman-net-sync "[punch] iniciando hacia ${TARGET_ENDPOINT}"

    if [ -n "${TARGET_PUBKEY}" ] && [ "${TARGET_PUBKEY}" != "null" ]; then
        # Configurar peer en WireGuard con endpoint del robot
        if [ -n "${TARGET_ENDPOINT}" ] && [ "${TARGET_ENDPOINT}" != "null" ]; then
            wg set "${WG_IFACE}" peer "${TARGET_PUBKEY}" \
                allowed-ips "${TARGET_IP}/32" \
                endpoint "${TARGET_ENDPOINT}" \
                persistent-keepalive 5
        fi

        # Enviar paquetes UDP desde nuestro puerto WG para abrir NAT
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

        # Probar IPs locales (LAN directa)
        for LOCAL_IP in ${TARGET_LOCAL_IPS}; do
            case "${LOCAL_IP}" in
                192.168.*|10.*|172.1[6-9].*|172.2[0-9].*|172.3[0-1].*)
                    logger -t kalman-net-sync "[punch] probando LAN: ${LOCAL_IP}:51820"
                    wg set "${WG_IFACE}" peer "${TARGET_PUBKEY}" \
                        endpoint "${LOCAL_IP}:51820" 2>/dev/null || true
                    ;;
            esac
        done

        sleep 2
        wg set "${WG_IFACE}" peer "${TARGET_PUBKEY}" persistent-keepalive 25 2>/dev/null || true
        logger -t kalman-net-sync "[punch] completado hacia ${TARGET_ENDPOINT}"
    fi
}

# ─── Loop principal ───
if command -v websocat &>/dev/null; then
    WS_URL=$(echo "${SERVER_URL}" | sed 's|http://|ws://|' | sed 's|https://|wss://|')
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
                "")
                    apply_network_map "${line}"
                    ;;
            esac
        done
        sleep 5
    done
else
    # Fallback polling
    while true; do
        MAP=$(curl -sf --max-time 10 \
            "${SERVER_URL}/api/peers/${PEER_ID}/network-map" 2>/dev/null || echo "")
        [ -n "${MAP}" ] && apply_network_map "${MAP}"

        curl -sf --max-time 5 -X POST \
            "${SERVER_URL}/api/peers/${PEER_ID}/heartbeat" \
            -H "Content-Type: application/json" \
            -d "{}" > /dev/null 2>&1 || true

        sleep 30
    done
fi
SYNCEOF

chmod +x /usr/local/bin/kalman-net-sync.sh

cat > /etc/systemd/system/kalman-net-sync.service << EOF
[Unit]
Description=kalman-net WireGuard sync daemon (student)
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

# ─── 10. Esperar que se aplique el network map ───
log_info "Esperando que el network map se aplique..."
sleep 3

ROBOT_IP=$(curl -sf --max-time 5 "${KALMAN_NET_SERVER}/api/peers/${PEER_ID}/network-map" 2>/dev/null \
    | jq -r '.peers[0].overlay_ip // empty' || echo "")

if [ -n "${ROBOT_IP}" ]; then
    log_info "Verificando conectividad con el robot (${ROBOT_IP})..."
    MAX=20; I=0
    while ! ping -c 1 -W 1 "${ROBOT_IP}" &>/dev/null; do
        I=$((I+1))
        [ $I -ge $MAX ] && { log_warn "Robot no responde ping aún — puede necesitar unos segundos más."; break; }
        sleep 1
    done
    [ $I -lt $MAX ] && log_ok "Robot alcanzable en ${I}s."
fi

# ─── 11. Configurar ROS2 (opcional) ───
if [ "${REQUIRES_ROS}" = "true" ]; then
    log_info "Configurando CycloneDDS sobre WireGuard..."
    cat > "${KALMAN_DIR}/cyclonedds.xml" << 'DDSEOF'
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
DDSEOF
    log_ok "CycloneDDS configurado."

    REAL_USER="${SUDO_USER:-$(whoami)}"
    REAL_HOME=$(eval echo "~${REAL_USER}")
    BASHRC="${REAL_HOME}/.bashrc"

    sed -i '/# kalman-net/,/^$/d' "${BASHRC}" 2>/dev/null || true
    cat >> "${BASHRC}" << ENVEOF

# kalman-net ROS2 environment
source /opt/ros/${ROS_DISTRO}/setup.bash 2>/dev/null || true
export RMW_IMPLEMENTATION=rmw_cyclonedds_cpp
export CYCLONEDDS_URI=file://${KALMAN_DIR}/cyclonedds.xml
export ROS_DOMAIN_ID=0
ENVEOF
    log_ok "Entorno ROS2 configurado en .bashrc."
fi

# ─── Resumen final ───
echo
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  ✓ Conectado al laboratorio${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "  IP overlay: ${OVERLAY_IP}"
echo -e "  Endpoint:   ${PUBLIC_ENDPOINT}"
echo -e "  Grupo:      ${GROUP_ID}"
echo
if [ "${REQUIRES_ROS}" = "true" ]; then
    echo -e "  Abre una nueva terminal y verifica:"
    echo -e "  ${YELLOW}ros2 topic list${NC}"
    echo -e "  ${YELLOW}ping ${ROBOT_IP:-10.99.0.X}${NC}"
fi
echo
echo -e "  Para verificar si la conexión es P2P o relay:"
echo -e "  ${YELLOW}wg show wg0${NC}  — ver latencia del handshake"
echo -e "  ${YELLOW}ping -c 10 ${ROBOT_IP:-10.99.0.X}${NC}  — si < 50ms probablemente P2P"
echo
echo -e "  Para desconectarte:"
echo -e "  ${YELLOW}sudo bash student-end.sh${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
