#!/bin/bash
# kalman-net-sync: mantiene WireGuard sincronizado y ejecuta hole punching P2P
# Instalado en /usr/local/bin/kalman-net-sync.sh por robot-setup.sh

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
do_punch() {
    local SIGNAL_JSON="$1"
    local TARGET_PUBKEY=$(echo "${SIGNAL_JSON}" | jq -r '.wg_public_key')
    local TARGET_IP=$(echo "${SIGNAL_JSON}"     | jq -r '.overlay_ip')
    local TARGET_ENDPOINT=$(echo "${SIGNAL_JSON}" | jq -r '.endpoint // empty')

    logger -t kalman-net-sync "[punch] iniciando hacia ${TARGET_ENDPOINT}"

    if [ -n "${TARGET_PUBKEY}" ] && [ "${TARGET_PUBKEY}" != "null" ]; then
        if [ -n "${TARGET_ENDPOINT}" ] && [ "${TARGET_ENDPOINT}" != "null" ]; then
            wg set "${WG_IFACE}" peer "${TARGET_PUBKEY}" \
                allowed-ips "${TARGET_IP}/32" \
                endpoint "${TARGET_ENDPOINT}" \
                persistent-keepalive 5

            TARGET_HOST=$(echo "${TARGET_ENDPOINT}" | cut -d: -f1)
            TARGET_PORT=$(echo "${TARGET_ENDPOINT}" | cut -d: -f2)
            python3 -c "
import socket, time
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
s.bind(('0.0.0.0', ${WG_PORT}))
for _ in range(5):
    try: s.sendto(b'\\x00', ('${TARGET_HOST}', ${TARGET_PORT}))
    except: pass
    time.sleep(0.1)
s.close()
" 2>/dev/null || true
        fi

        sleep 2
        wg set "${WG_IFACE}" peer "${TARGET_PUBKEY}" persistent-keepalive 25 2>/dev/null || true
        logger -t kalman-net-sync "[punch] completado hacia ${TARGET_ENDPOINT}"
    fi
}

# ─── Heartbeat en background ───
(while true; do
    curl -sf --max-time 5 -X POST \
        "${SERVER_URL}/api/peers/${PEER_ID}/heartbeat" \
        -H "Content-Type: application/json" \
        -d "{}" > /dev/null 2>&1 || true
    sleep 30
done) &

# ─── Loop principal ───
if command -v websocat > /dev/null 2>&1; then
    WS_URL=$(echo "${SERVER_URL}" | sed 's|http://|ws://|' | sed 's|https://|wss://|')
    logger -t kalman-net-sync "conectando WebSocket ${WS_URL}/ws?peer_id=${PEER_ID}"

    while true; do
        websocat --no-close -t "${WS_URL}/ws?peer_id=${PEER_ID}" 2>/dev/null | while IFS= read -r line; do
            [ -z "${line}" ] && continue
            MSG_TYPE=$(echo "${line}" | jq -r '.type // empty' 2>/dev/null)
            PAYLOAD=$(echo "${line}"  | jq -c '.payload // empty' 2>/dev/null)
            case "${MSG_TYPE}" in
                network_map) apply_network_map "${PAYLOAD}" ;;
                punch)       do_punch "${PAYLOAD}" ;;
                "")          apply_network_map "${line}" ;;
            esac
        done
        logger -t kalman-net-sync "WebSocket desconectado, reconectando en 5s..."
        sleep 5
    done
else
    logger -t kalman-net-sync "websocat no disponible, usando polling HTTP"
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
