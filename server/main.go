package main

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"sync"
	"time"

	"github.com/google/uuid"
	"github.com/gorilla/websocket"
)

// ─────────────────────────────────────────────
// Modelos
// ─────────────────────────────────────────────

type Peer struct {
	ID         string    `json:"id"`
	Hostname   string    `json:"hostname"`
	PublicKey  string    `json:"public_key"`
	OverlayIP  string    `json:"overlay_ip"`
	Endpoint   string    `json:"endpoint"`    // IP:puerto público (vía STUN)
	LocalIPs   []string  `json:"local_ips"`   // IPs locales LAN
	LastSeen   time.Time `json:"last_seen"`
	Online     bool      `json:"online"`
}

type Group struct {
	ID      string   `json:"id"`
	Name    string   `json:"name"`
	PeerIDs []string `json:"peer_ids"`
}

type JoinCode struct {
	Code      string    `json:"code"`
	GroupID   string    `json:"group_id"`
	ExpiresAt time.Time `json:"expires_at"`
}

// NetworkMap — lo que recibe cada agente
type NetworkMap struct {
	SelfIP string `json:"self_ip"`
	Peers  []Peer `json:"peers"`
}

// WsMessage — mensajes tipados via WebSocket
type WsMessage struct {
	Type    string          `json:"type"`
	Payload json.RawMessage `json:"payload"`
}

// PunchSignal — señal de hole punch que el servidor envía a un peer
type PunchSignal struct {
	PeerID       string   `json:"peer_id"`
	Endpoint     string   `json:"endpoint"`      // endpoint público del otro peer
	LocalIPs     []string `json:"local_ips"`     // IPs locales del otro peer
	WGPublicKey  string   `json:"wg_public_key"` // clave WG del otro peer
	OverlayIP    string   `json:"overlay_ip"`    // IP overlay del otro peer
}

// RelayPacket — paquete WireGuard encapsulado para relay via WebSocket
type RelayPacket struct {
	FromPeerID string `json:"from"`
	ToPeerID   string `json:"to"`
	Data       []byte `json:"data"` // payload WireGuard cifrado (opaco)
}

// ─────────────────────────────────────────────
// Estado global
// ─────────────────────────────────────────────

type State struct {
	mu         sync.RWMutex
	peers      map[string]*Peer
	groups     map[string]*Group
	joinCodes  map[string]*JoinCode
	ipCounter  int
	wsClients  map[string]*wsClient
	adminToken string
}

type wsClient struct {
	conn   *websocket.Conn
	peerID string
	send   chan []byte
}

var state *State

var upgrader = websocket.Upgrader{
	CheckOrigin: func(r *http.Request) bool { return true },
}

// ─────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────

func (s *State) allocateIP() string {
	s.ipCounter++
	return fmt.Sprintf("10.99.0.%d", s.ipCounter)
}

func (s *State) getPeerByID(id string) (*Peer, bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	p, ok := s.peers[id]
	return p, ok
}

func (s *State) networkMapForPeer(peerID string) NetworkMap {
	s.mu.RLock()
	defer s.mu.RUnlock()

	self, ok := s.peers[peerID]
	if !ok {
		return NetworkMap{}
	}

	seen := map[string]bool{}
	var peers []Peer
	for _, g := range s.groups {
		inGroup := false
		for _, pid := range g.PeerIDs {
			if pid == peerID {
				inGroup = true
				break
			}
		}
		if !inGroup {
			continue
		}
		for _, pid := range g.PeerIDs {
			if pid == peerID || seen[pid] {
				continue
			}
			if p, ok := s.peers[pid]; ok {
				peers = append(peers, *p)
				seen[pid] = true
			}
		}
	}
	return NetworkMap{SelfIP: self.OverlayIP, Peers: peers}
}

// sendToClient envía un mensaje tipado a un peer via WebSocket
func (s *State) sendToClient(peerID string, msgType string, payload interface{}) {
	data, err := json.Marshal(payload)
	if err != nil {
		return
	}
	msg := WsMessage{Type: msgType, Payload: json.RawMessage(data)}
	raw, err := json.Marshal(msg)
	if err != nil {
		return
	}
	s.mu.RLock()
	client, ok := s.wsClients[peerID]
	s.mu.RUnlock()
	if ok {
		select {
		case client.send <- raw:
		default:
		}
	}
}

// pushNetworkMap envía el network map actualizado a un peer
func (s *State) pushNetworkMap(peerID string) {
	nm := s.networkMapForPeer(peerID)
	s.sendToClient(peerID, "network_map", nm)
}

// pushToGroup notifica a todos los peers del grupo
func (s *State) pushToGroup(groupID string) {
	s.mu.RLock()
	g, ok := s.groups[groupID]
	if !ok {
		s.mu.RUnlock()
		return
	}
	peerIDs := make([]string, len(g.PeerIDs))
	copy(peerIDs, g.PeerIDs)
	s.mu.RUnlock()

	for _, pid := range peerIDs {
		s.pushNetworkMap(pid)
	}
}

// triggerPunch coordina el hole punch entre dos peers del mismo grupo
// Envía a cada uno los endpoints del otro simultáneamente
func (s *State) triggerPunch(peerA, peerB *Peer) {
	log.Printf("[punch] coordinando %s ↔ %s", peerA.Hostname, peerB.Hostname)

	signalA := PunchSignal{
		PeerID:      peerB.ID,
		Endpoint:    peerB.Endpoint,
		LocalIPs:    peerB.LocalIPs,
		WGPublicKey: peerB.PublicKey,
		OverlayIP:   peerB.OverlayIP,
	}
	signalB := PunchSignal{
		PeerID:      peerA.ID,
		Endpoint:    peerA.Endpoint,
		LocalIPs:    peerA.LocalIPs,
		WGPublicKey: peerA.PublicKey,
		OverlayIP:   peerA.OverlayIP,
	}

	// Enviar simultáneamente a ambos
	go s.sendToClient(peerA.ID, "punch", signalA)
	go s.sendToClient(peerB.ID, "punch", signalB)
}

// triggerPunchForGroup lanza hole punch entre todos los pares del grupo
func (s *State) triggerPunchForGroup(groupID string) {
	s.mu.RLock()
	g, ok := s.groups[groupID]
	if !ok {
		s.mu.RUnlock()
		return
	}
	peerIDs := make([]string, len(g.PeerIDs))
	copy(peerIDs, g.PeerIDs)
	s.mu.RUnlock()

	// Combinar todos los pares posibles
	for i := 0; i < len(peerIDs); i++ {
		for j := i + 1; j < len(peerIDs); j++ {
			s.mu.RLock()
			pA, okA := s.peers[peerIDs[i]]
			pB, okB := s.peers[peerIDs[j]]
			s.mu.RUnlock()
			if okA && okB && pA.Online && pB.Online {
				s.triggerPunch(pA, pB)
			}
		}
	}
}

func authAdmin(r *http.Request) bool {
	return r.Header.Get("X-Admin-Token") == state.adminToken
}

func respond(w http.ResponseWriter, code int, v interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	json.NewEncoder(w).Encode(v)
}

// ─────────────────────────────────────────────
// Handlers — Peers
// ─────────────────────────────────────────────

// POST /api/peers/register
func handleRegisterPeer(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Hostname  string   `json:"hostname"`
		PublicKey string   `json:"public_key"`
		Endpoint  string   `json:"endpoint"`
		LocalIPs  []string `json:"local_ips"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.PublicKey == "" || req.Hostname == "" {
		respond(w, 400, map[string]string{"error": "hostname y public_key requeridos"})
		return
	}

	state.mu.Lock()
	var peer *Peer
	for _, p := range state.peers {
		if p.Hostname == req.Hostname {
			peer = p
			break
		}
	}
	if peer != nil {
		peer.PublicKey = req.PublicKey
		peer.Endpoint = req.Endpoint
		peer.LocalIPs = req.LocalIPs
		peer.LastSeen = time.Now()
		peer.Online = true
	} else {
		peer = &Peer{
			ID:        uuid.NewString(),
			Hostname:  req.Hostname,
			PublicKey: req.PublicKey,
			OverlayIP: state.allocateIP(),
			Endpoint:  req.Endpoint,
			LocalIPs:  req.LocalIPs,
			LastSeen:  time.Now(),
			Online:    true,
		}
		state.peers[peer.ID] = peer
	}
	state.mu.Unlock()

	log.Printf("[register] peer=%s ip=%s endpoint=%s", peer.Hostname, peer.OverlayIP, peer.Endpoint)
	respond(w, 200, peer)
}

// GET /api/peers
func handleListPeers(w http.ResponseWriter, r *http.Request) {
	if !authAdmin(r) {
		respond(w, 401, map[string]string{"error": "unauthorized"})
		return
	}
	state.mu.RLock()
	peers := make([]*Peer, 0, len(state.peers))
	for _, p := range state.peers {
		peers = append(peers, p)
	}
	state.mu.RUnlock()
	respond(w, 200, peers)
}

// POST /api/peers/:id/heartbeat
func handleHeartbeat(w http.ResponseWriter, r *http.Request) {
	peerID := r.PathValue("id")
	var req struct {
		Endpoint string   `json:"endpoint"`
		LocalIPs []string `json:"local_ips"`
	}
	json.NewDecoder(r.Body).Decode(&req)

	state.mu.Lock()
	p, ok := state.peers[peerID]
	if !ok {
		state.mu.Unlock()
		respond(w, 404, map[string]string{"error": "peer not found"})
		return
	}
	p.LastSeen = time.Now()
	p.Online = true
	if req.Endpoint != "" {
		p.Endpoint = req.Endpoint
	}
	if len(req.LocalIPs) > 0 {
		p.LocalIPs = req.LocalIPs
	}
	state.mu.Unlock()

	respond(w, 200, map[string]string{"ok": "1"})
}

// GET /api/peers/:id/network-map — fallback polling para agentes sin WebSocket activo
func handleNetworkMap(w http.ResponseWriter, r *http.Request) {
	peerID := r.PathValue("id")
	if _, ok := state.getPeerByID(peerID); !ok {
		respond(w, 404, map[string]string{"error": "peer not found"})
		return
	}
	nm := state.networkMapForPeer(peerID)
	respond(w, 200, nm)
}

// ─────────────────────────────────────────────
// Handlers — Grupos
// ─────────────────────────────────────────────

func handleCreateGroup(w http.ResponseWriter, r *http.Request) {
	if !authAdmin(r) {
		respond(w, 401, map[string]string{"error": "unauthorized"})
		return
	}
	var req struct {
		Name string `json:"name"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.Name == "" {
		respond(w, 400, map[string]string{"error": "name requerido"})
		return
	}
	g := &Group{ID: uuid.NewString(), Name: req.Name, PeerIDs: []string{}}
	state.mu.Lock()
	state.groups[g.ID] = g
	state.mu.Unlock()
	log.Printf("[group] creado id=%s name=%s", g.ID, g.Name)
	respond(w, 200, g)
}

func handleListGroups(w http.ResponseWriter, r *http.Request) {
	if !authAdmin(r) {
		respond(w, 401, map[string]string{"error": "unauthorized"})
		return
	}
	state.mu.RLock()
	groups := make([]*Group, 0, len(state.groups))
	for _, g := range state.groups {
		groups = append(groups, g)
	}
	state.mu.RUnlock()
	respond(w, 200, groups)
}

func handleGetGroup(w http.ResponseWriter, r *http.Request) {
	if !authAdmin(r) {
		respond(w, 401, map[string]string{"error": "unauthorized"})
		return
	}
	gid := r.PathValue("id")
	state.mu.RLock()
	g, ok := state.groups[gid]
	state.mu.RUnlock()
	if !ok {
		respond(w, 404, map[string]string{"error": "group not found"})
		return
	}
	respond(w, 200, g)
}

func handleAddMember(w http.ResponseWriter, r *http.Request) {
	if !authAdmin(r) {
		respond(w, 401, map[string]string{"error": "unauthorized"})
		return
	}
	gid := r.PathValue("id")
	var req struct {
		PeerID string `json:"peer_id"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.PeerID == "" {
		respond(w, 400, map[string]string{"error": "peer_id requerido"})
		return
	}

	state.mu.Lock()
	g, ok := state.groups[gid]
	if !ok {
		state.mu.Unlock()
		respond(w, 404, map[string]string{"error": "group not found"})
		return
	}
	if _, ok := state.peers[req.PeerID]; !ok {
		state.mu.Unlock()
		respond(w, 404, map[string]string{"error": "peer not found"})
		return
	}
	for _, pid := range g.PeerIDs {
		if pid == req.PeerID {
			state.mu.Unlock()
			respond(w, 200, g)
			return
		}
	}
	g.PeerIDs = append(g.PeerIDs, req.PeerID)
	state.mu.Unlock()

	log.Printf("[group] peer=%s agregado a group=%s", req.PeerID, gid)
	go state.pushToGroup(gid)
	go state.triggerPunchForGroup(gid)
	respond(w, 200, g)
}

func handleRemoveMember(w http.ResponseWriter, r *http.Request) {
	if !authAdmin(r) {
		respond(w, 401, map[string]string{"error": "unauthorized"})
		return
	}
	gid := r.PathValue("id")
	pid := r.PathValue("peer_id")

	state.mu.Lock()
	g, ok := state.groups[gid]
	if !ok {
		state.mu.Unlock()
		respond(w, 404, map[string]string{"error": "group not found"})
		return
	}
	newList := []string{}
	for _, id := range g.PeerIDs {
		if id != pid {
			newList = append(newList, id)
		}
	}
	g.PeerIDs = newList
	state.mu.Unlock()

	go state.pushToGroup(gid)
	respond(w, 200, g)
}

func handleDeleteGroup(w http.ResponseWriter, r *http.Request) {
	if !authAdmin(r) {
		respond(w, 401, map[string]string{"error": "unauthorized"})
		return
	}
	gid := r.PathValue("id")
	state.mu.Lock()
	g, ok := state.groups[gid]
	if !ok {
		state.mu.Unlock()
		respond(w, 404, map[string]string{"error": "group not found"})
		return
	}
	peerIDs := make([]string, len(g.PeerIDs))
	copy(peerIDs, g.PeerIDs)
	g.PeerIDs = []string{}
	delete(state.groups, gid)
	state.mu.Unlock()

	// Notificar network map vacío a todos los peers
	for _, pid := range peerIDs {
		state.sendToClient(pid, "network_map", NetworkMap{Peers: []Peer{}})
	}
	respond(w, 200, map[string]string{"ok": "1"})
}

// ─────────────────────────────────────────────
// Handlers — Join Codes
// ─────────────────────────────────────────────

func handleCreateJoinCode(w http.ResponseWriter, r *http.Request) {
	if !authAdmin(r) {
		respond(w, 401, map[string]string{"error": "unauthorized"})
		return
	}
	gid := r.PathValue("id")
	state.mu.RLock()
	_, ok := state.groups[gid]
	state.mu.RUnlock()
	if !ok {
		respond(w, 404, map[string]string{"error": "group not found"})
		return
	}

	jc := &JoinCode{
		Code:      uuid.NewString(),
		GroupID:   gid,
		ExpiresAt: time.Now().Add(30 * time.Minute),
	}
	state.mu.Lock()
	state.joinCodes[jc.Code] = jc
	state.mu.Unlock()

	log.Printf("[joincode] creado code=%s group=%s", jc.Code, gid)
	respond(w, 200, jc)
}

func handleJoin(w http.ResponseWriter, r *http.Request) {
	var req struct {
		JoinCode  string   `json:"join_code"`
		Hostname  string   `json:"hostname"`
		PublicKey string   `json:"public_key"`
		Endpoint  string   `json:"endpoint"`
		LocalIPs  []string `json:"local_ips"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		respond(w, 400, map[string]string{"error": "json inválido"})
		return
	}
	if req.JoinCode == "" || req.Hostname == "" || req.PublicKey == "" {
		respond(w, 400, map[string]string{"error": "join_code, hostname y public_key requeridos"})
		return
	}

	state.mu.Lock()
	jc, ok := state.joinCodes[req.JoinCode]
	if !ok || time.Now().After(jc.ExpiresAt) {
		state.mu.Unlock()
		respond(w, 401, map[string]string{"error": "join_code inválido o expirado"})
		return
	}
	groupID := jc.GroupID
	delete(state.joinCodes, req.JoinCode)

	var peer *Peer
	for _, p := range state.peers {
		if p.Hostname == req.Hostname {
			peer = p
			break
		}
	}
	if peer == nil {
		peer = &Peer{
			ID:        uuid.NewString(),
			Hostname:  req.Hostname,
			PublicKey: req.PublicKey,
			OverlayIP: state.allocateIP(),
			Endpoint:  req.Endpoint,
			LocalIPs:  req.LocalIPs,
			LastSeen:  time.Now(),
			Online:    true,
		}
		state.peers[peer.ID] = peer
	} else {
		peer.PublicKey = req.PublicKey
		peer.Endpoint = req.Endpoint
		peer.LocalIPs = req.LocalIPs
		peer.LastSeen = time.Now()
		peer.Online = true
	}

	g := state.groups[groupID]
	alreadyIn := false
	for _, pid := range g.PeerIDs {
		if pid == peer.ID {
			alreadyIn = true
			break
		}
	}
	if !alreadyIn {
		g.PeerIDs = append(g.PeerIDs, peer.ID)
	}
	state.mu.Unlock()

	log.Printf("[join] peer=%s ip=%s group=%s", peer.Hostname, peer.OverlayIP, groupID)
	go state.pushToGroup(groupID)
	go state.triggerPunchForGroup(groupID)

	respond(w, 200, map[string]interface{}{
		"peer":     peer,
		"group_id": groupID,
	})
}

// ─────────────────────────────────────────────
// Handler — Relay de paquetes WireGuard
// POST /api/relay
// El agente usa esto cuando P2P falla: encapsula paquetes WireGuard en HTTP
// ─────────────────────────────────────────────

func handleRelay(w http.ResponseWriter, r *http.Request) {
	var pkt RelayPacket
	if err := json.NewDecoder(r.Body).Decode(&pkt); err != nil || pkt.ToPeerID == "" {
		respond(w, 400, map[string]string{"error": "invalid relay packet"})
		return
	}

	// Reenviar via WebSocket al peer destino
	state.mu.RLock()
	client, ok := state.wsClients[pkt.ToPeerID]
	state.mu.RUnlock()

	if !ok {
		respond(w, 404, map[string]string{"error": "peer destino no conectado"})
		return
	}

	raw, _ := json.Marshal(WsMessage{
		Type:    "relay",
		Payload: mustMarshal(pkt),
	})
	select {
	case client.send <- raw:
		respond(w, 200, map[string]string{"ok": "1"})
	default:
		respond(w, 503, map[string]string{"error": "peer buffer lleno"})
	}
}

func mustMarshal(v interface{}) json.RawMessage {
	b, _ := json.Marshal(v)
	return b
}

// ─────────────────────────────────────────────
// Handler — WebSocket
// ─────────────────────────────────────────────

func handleWebSocket(w http.ResponseWriter, r *http.Request) {
	peerID := r.URL.Query().Get("peer_id")
	if peerID == "" {
		http.Error(w, "peer_id requerido", 400)
		return
	}
	state.mu.RLock()
	_, ok := state.peers[peerID]
	state.mu.RUnlock()
	if !ok {
		http.Error(w, "peer not found", 404)
		return
	}

	conn, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		log.Printf("[ws] error upgrade peer=%s: %v", peerID, err)
		return
	}

	client := &wsClient{conn: conn, peerID: peerID, send: make(chan []byte, 16)}
	state.mu.Lock()
	state.wsClients[peerID] = client
	state.mu.Unlock()
	log.Printf("[ws] peer=%s conectado", peerID)

	// Enviar network map inmediatamente
	go state.pushNetworkMap(peerID)

	// Goroutine de escritura
	go func() {
		defer conn.Close()
		for msg := range client.send {
			if err := conn.WriteMessage(websocket.TextMessage, msg); err != nil {
				break
			}
		}
	}()

	// Loop de lectura — procesar mensajes entrantes del agente
	for {
		_, raw, err := conn.ReadMessage()
		if err != nil {
			break
		}
		var msg WsMessage
		if err := json.Unmarshal(raw, &msg); err != nil {
			continue
		}
		switch msg.Type {
		case "punch_ok":
			// El peer confirmó que el hole punch fue exitoso
			var payload struct {
				PeerID string `json:"peer_id"`
			}
			if err := json.Unmarshal(msg.Payload, &payload); err == nil {
				log.Printf("[punch] %s confirmó P2P con %s", peerID, payload.PeerID)
			}
		case "endpoint_update":
			// El peer actualizó su endpoint público (después de STUN)
			var payload struct {
				Endpoint string   `json:"endpoint"`
				LocalIPs []string `json:"local_ips"`
			}
			if err := json.Unmarshal(msg.Payload, &payload); err == nil {
				state.mu.Lock()
				if p, ok := state.peers[peerID]; ok {
					p.Endpoint = payload.Endpoint
					p.LocalIPs = payload.LocalIPs
				}
				state.mu.Unlock()
				log.Printf("[endpoint] peer=%s nuevo endpoint=%s", peerID, payload.Endpoint)
				// Re-triggerear punch con peers del grupo
				groups := state.getGroupsForPeer(peerID)
				for _, g := range groups {
					go state.triggerPunchForGroup(g.ID)
				}
			}
		}
	}

	state.mu.Lock()
	delete(state.wsClients, peerID)
	if p, ok := state.peers[peerID]; ok {
		p.Online = false
	}
	state.mu.Unlock()
	close(client.send)
	log.Printf("[ws] peer=%s desconectado", peerID)
}

func (s *State) getGroupsForPeer(peerID string) []*Group {
	s.mu.RLock()
	defer s.mu.RUnlock()
	var groups []*Group
	for _, g := range s.groups {
		for _, pid := range g.PeerIDs {
			if pid == peerID {
				groups = append(groups, g)
				break
			}
		}
	}
	return groups
}

// ─────────────────────────────────────────────
// Background: marcar peers offline
// ─────────────────────────────────────────────

func startOfflineChecker() {
	go func() {
		for range time.Tick(30 * time.Second) {
			state.mu.Lock()
			for _, p := range state.peers {
				if p.Online && time.Since(p.LastSeen) > 90*time.Second {
					p.Online = false
					log.Printf("[offline] peer=%s marcado offline", p.Hostname)
				}
			}
			state.mu.Unlock()
		}
	}()
}

// ─────────────────────────────────────────────
// Main
// ─────────────────────────────────────────────

func main() {
	adminToken := os.Getenv("ADMIN_TOKEN")
	if adminToken == "" {
		adminToken = "kalman-dev-token"
		log.Println("[warn] ADMIN_TOKEN no configurado, usando token de desarrollo")
	}

	state = &State{
		peers:      map[string]*Peer{},
		groups:     map[string]*Group{},
		joinCodes:  map[string]*JoinCode{},
		wsClients:  map[string]*wsClient{},
		ipCounter:  1,
		adminToken: adminToken,
	}

	startOfflineChecker()

	mux := http.NewServeMux()

	// Peers
	mux.HandleFunc("POST /api/peers/register", handleRegisterPeer)
	mux.HandleFunc("GET /api/peers", handleListPeers)
	mux.HandleFunc("POST /api/peers/{id}/heartbeat", handleHeartbeat)
	mux.HandleFunc("GET /api/peers/{id}/network-map", handleNetworkMap)

	// Grupos
	mux.HandleFunc("POST /api/groups", handleCreateGroup)
	mux.HandleFunc("GET /api/groups", handleListGroups)
	mux.HandleFunc("GET /api/groups/{id}", handleGetGroup)
	mux.HandleFunc("POST /api/groups/{id}/members", handleAddMember)
	mux.HandleFunc("DELETE /api/groups/{id}/members/{peer_id}", handleRemoveMember)
	mux.HandleFunc("DELETE /api/groups/{id}", handleDeleteGroup)

	// Join codes
	mux.HandleFunc("POST /api/groups/{id}/join-code", handleCreateJoinCode)
	mux.HandleFunc("POST /api/join", handleJoin)

	// Relay y WebSocket
	mux.HandleFunc("POST /api/relay", handleRelay)
	mux.HandleFunc("GET /ws", handleWebSocket)

	// Health
	mux.HandleFunc("GET /health", func(w http.ResponseWriter, r *http.Request) {
		respond(w, 200, map[string]string{"status": "ok"})
	})

	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	log.Printf("[server] kalman-net control plane escuchando en :%s", port)
	if err := http.ListenAndServe(":"+port, mux); err != nil {
		log.Fatal(err)
	}
}
