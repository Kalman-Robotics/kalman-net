# kalman-net — PoC de red overlay propia

Red VPN mesh basada en WireGuard con servidor de control propio.
Reemplaza Husarnet sin depender de servicios externos.

## Arquitectura

```
EC2 (servidor de control)          Robot (pi5)          PC Estudiante
┌────────────────────┐            ┌──────────┐          ┌──────────────┐
│  kalman-net-server │            │   wg0    │◄────────►│     wg0      │
│  :8080             │◄──register─┤10.99.0.2 │          │  10.99.0.3   │
│  REST API + WS     │◄──register─┤          │          │              │
│                    │──push map─►│          │          │              │
│  10.99.0.1         │──push map─►│          │          │              │
└────────────────────┘            └──────────┘          └──────────────┘
       │ topología hub-and-spoke: todos conectan al servidor
       │ el servidor routea entre peers del mismo grupo
```

**Protocolo:** WireGuard (kernel nativo)
**IPs overlay:** `10.99.0.0/24`
**NAT traversal:** endpoints públicos directos (sin STUN para el PoC)

---

## Paso 1 — Desplegar el servidor en EC2

```bash
# En tu instancia EC2 (Ubuntu 22.04+, con Docker instalado)
git clone <repo> kalman-net
cd kalman-net/deploy

cp .env.example .env
# Editar .env y cambiar ADMIN_TOKEN

docker compose up -d
docker compose logs -f
```

Verificar que funciona:
```bash
curl http://localhost:8080/health
# → {"status":"ok"}
```

**Security Group de EC2:** abrir puerto `8080/tcp` (API) y `51820/udp` (WireGuard del robot).

---

## Paso 2 — Configurar el robot

```bash
# En el robot (pi5 u otro Linux con Ubuntu/Raspberry Pi OS)
export KALMAN_NET_SERVER="http://<IP_EC2>:8080"
export ROBOT_HOSTNAME="kalman-robot-1"
export ROS_DISTRO="humble"

sudo -E bash robot-setup.sh
```

El script:
1. Instala WireGuard
2. Genera keypair (se guarda en `/var/lib/kalman-net/`)
3. Registra el robot en el servidor → recibe IP overlay
4. Levanta interfaz `wg0`
5. Instala daemon `kalman-net-sync` que mantiene WireGuard sincronizado

Guarda el **Peer ID** que imprime al final — lo necesitarás para crear sesiones.

---

## Paso 3 — Crear una sesión (manual vía API)

Esto lo hará la plataforma Laravel en producción. Por ahora se hace con curl.

```bash
ADMIN_TOKEN="tu-token"
SERVER="http://<IP_EC2>:8080"
ROBOT_PEER_ID="<id-del-robot>"   # del paso 2

# 3a. Crear grupo (= sesión de laboratorio)
GROUP=$(curl -s -X POST "${SERVER}/api/groups" \
    -H "X-Admin-Token: ${ADMIN_TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{"name":"sesion-lab-1"}')
GROUP_ID=$(echo $GROUP | jq -r '.id')
echo "Grupo creado: ${GROUP_ID}"

# 3b. Agregar el robot al grupo
curl -s -X POST "${SERVER}/api/groups/${GROUP_ID}/members" \
    -H "X-Admin-Token: ${ADMIN_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"peer_id\":\"${ROBOT_PEER_ID}\"}"

# 3c. Generar join code para el estudiante
JOIN_CODE_RESP=$(curl -s -X POST "${SERVER}/api/groups/${GROUP_ID}/join-code" \
    -H "X-Admin-Token: ${ADMIN_TOKEN}")
JOIN_CODE=$(echo $JOIN_CODE_RESP | jq -r '.code')
echo "Join code para el estudiante: ${JOIN_CODE}"
echo "Expira: $(echo $JOIN_CODE_RESP | jq -r '.expires_at')"
```

---

## Paso 4 — Conectar el estudiante

El estudiante ejecuta en su PC (Linux/WSL2 con Ubuntu):

```bash
export KALMAN_NET_SERVER="http://<IP_EC2>:8080"
export REQUIRES_ROS="true"   # false si no necesita ROS2

sudo -E bash student-setup.sh <JOIN_CODE>
```

El script:
1. Instala WireGuard
2. Genera su keypair
3. Hace `POST /api/join` con el join code → se registra y une al grupo
4. Levanta `wg0` con su IP overlay
5. Instala `kalman-net-sync` que recibe actualizaciones del servidor
6. Configura CycloneDDS apuntando a `wg0`

---

## Verificación

```bash
# En el robot — ver peers WireGuard activos
wg show

# En el estudiante — ping al robot
ping 10.99.0.2

# En el estudiante — topics ROS2 (nueva terminal)
source ~/.bashrc
ros2 topic list

# Ver estado del servidor
curl -H "X-Admin-Token: tu-token" http://<IP_EC2>:8080/api/peers
curl -H "X-Admin-Token: tu-token" http://<IP_EC2>:8080/api/groups
```

---

## Terminar sesión

```bash
# El estudiante ejecuta:
sudo bash student-end.sh

# El admin destruye el grupo (WireGuard se limpia solo en los agentes):
curl -X DELETE "${SERVER}/api/groups/${GROUP_ID}" \
    -H "X-Admin-Token: ${ADMIN_TOKEN}"
```

---

## API Reference

| Método | Endpoint | Auth | Descripción |
|--------|----------|------|-------------|
| `POST` | `/api/peers/register` | — | Registrar peer (robot) |
| `GET`  | `/api/peers` | Admin | Listar todos los peers |
| `POST` | `/api/peers/{id}/heartbeat` | — | Heartbeat del agente |
| `POST` | `/api/groups` | Admin | Crear grupo/sesión |
| `GET`  | `/api/groups` | Admin | Listar grupos |
| `GET`  | `/api/groups/{id}` | Admin | Ver grupo |
| `POST` | `/api/groups/{id}/members` | Admin | Agregar peer al grupo |
| `DELETE` | `/api/groups/{id}/members/{peer_id}` | Admin | Quitar peer del grupo |
| `DELETE` | `/api/groups/{id}` | Admin | Eliminar grupo |
| `POST` | `/api/groups/{id}/join-code` | Admin | Generar join code (30 min) |
| `POST` | `/api/join` | — | Join con código (estudiante) |
| `GET`  | `/ws?peer_id=XXX` | — | WebSocket actualizaciones |
| `GET`  | `/health` | — | Health check |

Auth Admin: header `X-Admin-Token: <token>`

---

## Estructura de archivos

```
kalman-net/
├── server/
│   ├── main.go          ← servidor de control completo
│   ├── go.mod
│   ├── go.sum
│   └── Dockerfile
├── scripts/
│   ├── robot-setup.sh   ← ejecutar en el robot
│   ├── student-setup.sh ← ejecutar en el PC del estudiante
│   └── student-end.sh   ← terminar sesión (estudiante)
└── deploy/
    ├── docker-compose.yml
    └── .env.example
```

## Notas del PoC

- **Sin STUN/TURN**: para el PoC asumimos que el robot tiene IP pública directa o está en la misma red que el servidor. En producción agregar coturn.
- **Sin persistencia**: el servidor guarda estado en memoria. Reiniciar = perder peers y grupos. Agregar SQLite en la siguiente iteración.
- **websocat opcional**: si no está instalado, el agente hace polling HTTP cada 30s en lugar de WebSocket. Instalar con `apt install websocat` para updates instantáneos.
