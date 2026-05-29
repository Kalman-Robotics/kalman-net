#!/bin/bash
# ─────────────────────────────────────────────
#  kalman-net — Student End Session
#  Uso: sudo bash student-end.sh
# ─────────────────────────────────────────────

KALMAN_DIR="/var/lib/kalman-net"
WG_IFACE="wg0"

GREEN='\033[0;32m'; BLUE='\033[0;34m'; NC='\033[0m'

echo -e "${BLUE}Desconectando del laboratorio...${NC}"

systemctl stop kalman-net-sync 2>/dev/null || true
systemctl disable kalman-net-sync 2>/dev/null || true

ip link del "${WG_IFACE}" 2>/dev/null || true

# Limpiar .bashrc
REAL_USER="${SUDO_USER:-$(whoami)}"
REAL_HOME=$(eval echo "~${REAL_USER}")
sed -i '/# kalman-net/,/^$/d' "${REAL_HOME}/.bashrc" 2>/dev/null || true

# Guardar keypair pero limpiar estado de sesión
rm -f "${KALMAN_DIR}/peer_id" "${KALMAN_DIR}/overlay_ip" \
      "${KALMAN_DIR}/group_id" "${KALMAN_DIR}/server_url" \
      "${KALMAN_DIR}/cyclonedds.xml"

echo -e "${GREEN}✓ Desconectado correctamente.${NC}"
