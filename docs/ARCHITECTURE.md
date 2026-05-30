# kalman-net — Arquitectura y Decisiones de Diseño

## Por qué no Husarnet

Husarnet fue nuestro punto de partida. Después de analizarlo en profundidad identificamos estos problemas estructurales:

| Problema | Causa en Husarnet | Nuestra solución |
|----------|-------------------|-----------------|
| Propagación lenta (3–15 s) | Websetup Server usa UDP eventual-consistency | WebSocket push instantáneo |
| Dependencia de infraestructura externa | `app.husarnet.com` es el único control plane | Servidor propio en EC2 |
| Protocolo propio sobre libsodium | Más complejo, no estándar | WireGuard (kernel nativo) |
| Nodos Husarnet como relay intermedio | No controlamos la ruta | EC2 propio como relay |
| Direcciones IPv6 `fc94::/16` | Requiere stack IPv6, complica debugging | IPv4 overlay `10.99.0.0/24` |
| Sin modelo de sesión/grupo | Cualquier peer ve a cualquier peer | Grupos con join codes (30 min) |
| Sin control sobre quién se conecta | Token global de red, no por sesión | Join code de un solo uso por sesión |

---

## Qué tomamos de Husarnet (lo bueno)

- **Idea central**: overlay VPN donde los robots tienen IPs fijas y los estudiantes se unen temporalmente.
- **CycloneDDS sobre la interfaz VPN**: `wg0` en lugar de `hnet0`, misma lógica — forzar ROS2 a usar solo esa interfaz.
- **Persistir keypair**: el robot genera su keypair una vez y lo reutiliza. Su peer_id (y overlay_ip) son estables entre reinicios.
- **Daemon de sincronización**: proceso en background que mantiene WireGuard actualizado. En Husarnet es `husarnet-daemon`, aquí es `kalman-net-sync`.

---

## Arquitectura actual (PoC)

```
                     ┌─────────────────────────────┐
                     │   EC2 — kalman-net-server    │
                     │   :8080 HTTP + WebSocket     │
                     │                              │
                     │  peers    groups  join_codes  │
                     │  (en memoria, sin persist.)  │
                     └──────────┬──────────┬────────┘
                                │          │
               ┌────────────────┘          └──────────────────┐
               │  WebSocket (push)                            │  WebSocket (push)
               ▼                                              ▼
  ┌────────────────────┐                        ┌────────────────────────┐
  │   Robot (pi5)      │                        │   PC Estudiante        │
  │   wg0: 10.99.0.2   │◄══ WireGuard UDP ═════►│   wg0: 10.99.0.3       │
  │   puerto: 51820    │   (via EC2 por ahora)  │   puerto: 51821        │
  └────────────────────┘                        └────────────────────────┘
```

**Flujo de una sesión:**
1. Robot se registra al arrancar (`POST /api/peers/register`) — queda en espera
2. Admin crea grupo y agrega el robot al grupo (`POST /api/groups/{id}/members`)
3. Admin genera join code (`POST /api/groups/{id}/join-code`) — UUID, expira 30 min, un solo uso
4. Estudiante ejecuta `student-setup.sh JOIN_CODE` → se registra, se une al grupo
5. Servidor pushea network map vía WebSocket a ambos → WireGuard configura peers
6. Servidor dispara hole punch simultáneo → intento de conexión P2P directa
7. Si P2P falla → tráfico routea por EC2 (hub-and-spoke actual)

**Latencia actual (via EC2 us-east-1, Lima):** ~142ms  
**Latencia objetivo (P2P directo, mismo ISP Lima):** ~10–20ms

---

## NAT Hole Punching (implementado en PoC)

WireGuard no implementa hole punching por sí solo — solo envía paquetes. Coordinamos el punch desde el servidor:

```
Robot                    Servidor (EC2)              Estudiante
  |                           |                           |
  |── WebSocket conectado ────►|                           |
  |                           |◄── WebSocket conectado ───|
  |                           |                           |
  |    (estudiante hace join)  |                           |
  |                           │── punch signal ──────────►|
  |◄─────────────── punch signal ──                       |
  |                           |                           |
  |══ UDP al endpoint del estudiante ══════════════════════|
  |═══════════════════════════════════ UDP al endpoint del robot ══|
  |                           |                           |
  |◄══════ handshake WireGuard directo ═══════════════════►|
```

**Qué hace `do_punch` en el daemon:**
1. Configura el peer en WireGuard con el endpoint público del otro lado
2. Envía 5 paquetes UDP vacíos desde el puerto WireGuard → abre el mapeo NAT
3. Prueba IPs locales si parecen estar en la misma LAN (mismo prefijo privado)
4. Espera 2s y reduce keepalive a 25s (normal)

**STUN desde el puerto WireGuard:**
- Critico: si hacemos STUN desde un puerto distinto, el endpoint reportado es incorrecto (NAT crea mapeo diferente por puerto)
- Usamos `SO_REUSEPORT` para ligar un socket Python al mismo puerto que WireGuard
- Google STUN (`stun.l.google.com:19302`) — no requiere cuenta, alta disponibilidad

**Tipos de NAT y probabilidad de éxito:**
| Tipo NAT | P2P posible | Prevalencia |
|----------|-------------|-------------|
| Full cone | Sí | ~10% |
| Restricted cone | Sí | ~40% |
| Port-restricted cone | Sí con punch coordinado | ~40% |
| Symmetric | No (relay necesario) | ~10% |

Para el ~10% symmetric NAT → relay via EC2 (actual).

---

## Estado del PoC vs Producción

### Lo que tiene el PoC ✓
- Control plane Go en EC2 (Docker)
- WireGuard overlay `10.99.0.0/24`
- WebSocket push de network map
- Join codes de un solo uso (30 min)
- Grupos de sesión (robot + estudiantes)
- Hole punching coordinado por servidor
- STUN desde puerto WireGuard
- Reporte de IPs locales (para detección LAN)
- CycloneDDS configurado sobre `wg0`
- Daemon `kalman-net-sync` con systemd

### Lo que falta para producción (en orden de prioridad)

#### Prioridad 1 — Correctness
- [ ] **Persistencia del servidor**: ahora es todo en memoria. Reiniciar = perder peers. Agregar SQLite (una tabla `peers`, una `groups`).
- [ ] **Re-registro del robot al arrancar**: si el servidor reinicia, el robot debe registrarse de nuevo. El daemon debe detectar `peer_id` inválido y re-registrar.
- [ ] **Relay verdadero**: el relay actual encapsula en HTTP, no en WebSocket. Para latencia aceptable, implementar relay WS bidireccional con buffer de paquetes.

#### Prioridad 2 — Integración con la plataforma
- [ ] **API en Laravel**: los endpoints de admin (crear grupo, join code) deben llamarse desde la plataforma cuando el instructor inicia una sesión de laboratorio.
- [ ] **Webhook o polling del estado**: la plataforma necesita saber si el robot está online (`GET /api/peers` → filtrar por `online: true`).
- [ ] **Múltiples robots por sesión**: los grupos ya soportan N peers, solo falta la UI.

#### Prioridad 3 — Robustez
- [ ] **Renovación de join code**: si el estudiante recarga la página, necesita un nuevo join code sin que el admin intervenga.
- [ ] **Desconexión limpia**: cuando el estudiante cierra sesión, el grupo debe limpiarse automáticamente (el `student-end.sh` ya hace su parte, falta el lado servidor).
- [ ] **Múltiples estudiantes simultáneos**: el modelo de grupos ya lo soporta, pero hay que probar con 5+ students en el mismo grupo y verificar el N² de punch signals.
- [ ] **websocat en los agentes**: sin `websocat` el daemon cae a polling HTTP (30s de latencia). Empaquetar el binario estático o instalarlo en el setup.

#### Prioridad 4 — Seguridad
- [ ] **mTLS en el control plane**: actualmente HTTP sin autenticación del agente. El robot se registra con cualquier hostname — agregar token de robot.
- [ ] **Rate limiting en join**: un join code mal usado puede registrar N peers. Agregar límite.
- [ ] **Rotación de admin token**: el `ADMIN_TOKEN` está en `.env`, no en secretos. Migrar a AWS Secrets Manager o similar.

#### Prioridad 5 — Observabilidad
- [ ] **Métricas**: latencia P2P vs relay, tasa de éxito de hole punching, peers activos por grupo.
- [ ] **Dashboard de sesiones**: ver en tiempo real qué robots están online, qué estudiantes conectados.

---

## Decisiones de diseño documentadas

### ¿Por qué hub-and-spoke y no mesh completo?
En el PoC, el tráfico pasa por EC2 aunque tengamos WireGuard. Esto es intencional: es más simple, siempre funciona (EC2 tiene IP pública), y permite relay cuando P2P falla. El mesh directo (P2P) es una optimización encima.

### ¿Por qué Go para el servidor?
Binary estático, sin runtime, fácil de Dockerizar, goroutines para WebSocket concurrente. Alternativa sería Node.js pero Go tiene mejor performance para manejo de sockets.

### ¿Por qué no usar TURN/STUN estándar (coturn)?
Para el PoC es over-engineering. coturn es un servidor separado, requiere configuración de certificados, y su relay usa RTP (diseñado para WebRTC). Nuestro relay directo sobre WebSocket es más simple y suficiente para los volúmenes que manejamos (< 20 estudiantes simultáneos).

### ¿Por qué puerto 51821 para estudiantes y 51820 para robots?
Si un robot y un estudiante están en el mismo host (para testing local), necesitan puertos distintos. En producción no importa, pero evita conflictos durante desarrollo.

### ¿Por qué IPv4 y no IPv6 como Husarnet?
Husarnet usa `fc94::/16` (IPv6 ULA) porque evita conflictos con cualquier red existente. Nosotros elegimos `10.99.0.0/24` porque es más familiar, más fácil de debuggear (`ping 10.99.0.2` es más claro que `ping fc94::...`), y nuestros robots siempre tienen acceso IPv4. El costo: si alguien tiene esa subred en su LAN, hay conflicto. Es un riesgo aceptable para el PoC.
