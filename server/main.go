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
	ID        string    `json:"id"`
	Hostname  string    `json:"hostname"`
	PublicKey string    `json:"public_key"`
	OverlayIP string    `json:"overlay_ip"`
	Endpoint  string    `json:"endpoint"` // IP:puerto público del peer
	LastSeen  time.Time `json:"last_seen"`
	Online    bool      `json:"online"`
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

// NetworkMap es lo que recibe cada agente: sus peers en el grupo
type NetworkMap struct {
	SelfIP string  `json:"self_ip"`
	Peers  []Peer  `json:"peers"`
}

// ─────────────────────────────────────────────
// Estado global
// ─────────────────────────────────────────────

type State struct {
	mu         sync.RWMutex
	peers      map[string]*Peer      // id → peer
	groups     map[string]*Group     // id → group
	joinCodes  map[string]*JoinCode  // code → joincode
	ipCounter  int                   // próxima IP a asignar (10.99.0.X)
	wsClients  map[string]*wsClient  // peer_id → wsClient
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

// networkMapForPeer construye el mapa de red que debe recibir un peer:
// todos los peers de todos sus grupos (excepto él mismo)
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

// pushToGroup notifica a todos los agentes WS en un grupo que el network map cambió
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
		nm := s.networkMapForPeer(pid)
		data, _ := json.Marshal(nm)
		s.mu.RLock()
		client, ok := s.wsClients[pid]
		s.mu.RUnlock()
		if ok {
			select {
			case client.send <- data:
			default:
			}
		}
	}
}

// authAdmin valida el token de administrador
func authAdmin(r *http.Request) bool {
	token := r.Header.Get("X-Admin-Token")
	return token == state.adminToken
}

// respond escribe JSON con status code
func respond(w http.ResponseWriter, code int, v interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	json.NewEncoder(w).Encode(v)
}

// ─────────────────────────────────────────────
// Handlers — Peers
// ─────────────────────────────────────────────

// POST /api/peers/register
// Body: { hostname, public_key, endpoint }
// Responde: peer completo con overlay_ip asignada
func handleRegisterPeer(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Hostname  string `json:"hostname"`
		PublicKey string `json:"public_key"`
		Endpoint  string `json:"endpoint"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.PublicKey == "" || req.Hostname == "" {
		respond(w, 400, map[string]string{"error": "hostname y public_key requeridos"})
		return
	}

	state.mu.Lock()
	// Buscar si ya existe por hostname (re-registro)
	var existing *Peer
	for _, p := range state.peers {
		if p.Hostname == req.Hostname {
			existing = p
			break
		}
	}
	var peer *Peer
	if existing != nil {
		existing.PublicKey = req.PublicKey
		existing.Endpoint = req.Endpoint
		existing.LastSeen = time.Now()
		existing.Online = true
		peer = existing
	} else {
		peer = &Peer{
			ID:        uuid.NewString(),
			Hostname:  req.Hostname,
			PublicKey: req.PublicKey,
			OverlayIP: state.allocateIP(),
			Endpoint:  req.Endpoint,
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
// Body: { endpoint }
func handleHeartbeat(w http.ResponseWriter, r *http.Request) {
	peerID := r.PathValue("id")
	var req struct {
		Endpoint string `json:"endpoint"`
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
	state.mu.Unlock()

	respond(w, 200, map[string]string{"ok": "1"})
}

// ─────────────────────────────────────────────
// Handlers — Grupos
// ─────────────────────────────────────────────

// POST /api/groups
// Body: { name }
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
	g := &Group{
		ID:      uuid.NewString(),
		Name:    req.Name,
		PeerIDs: []string{},
	}
	state.mu.Lock()
	state.groups[g.ID] = g
	state.mu.Unlock()

	log.Printf("[group] creado id=%s name=%s", g.ID, g.Name)
	respond(w, 200, g)
}

// GET /api/groups
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

// GET /api/groups/:id
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

// POST /api/groups/:id/members
// Body: { peer_id }
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
	// Evitar duplicados
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
	respond(w, 200, g)
}

// DELETE /api/groups/:id/members/:peer_id
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

	log.Printf("[group] peer=%s eliminado de group=%s", pid, gid)
	go state.pushToGroup(gid)
	respond(w, 200, g)
}

// DELETE /api/groups/:id
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

	// Notificar a todos los peers que el grupo fue disuelto (network map vacío)
	for _, pid := range peerIDs {
		nm := NetworkMap{Peers: []Peer{}}
		data, _ := json.Marshal(nm)
		state.mu.RLock()
		client, ok := state.wsClients[pid]
		state.mu.RUnlock()
		if ok {
			select {
			case client.send <- data:
			default:
			}
		}
	}
	respond(w, 200, map[string]string{"ok": "1"})
}

// ─────────────────────────────────────────────
// Handlers — Join Codes
// ─────────────────────────────────────────────

// POST /api/groups/:id/join-code
// Genera un join code temporal para que un agente se una al grupo
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

	log.Printf("[joincode] creado code=%s group=%s expires=%s", jc.Code, gid, jc.ExpiresAt.Format(time.RFC3339))
	respond(w, 200, jc)
}

// POST /api/join
// Body: { join_code, hostname, public_key, endpoint }
// El agente usa esto para registrarse y unirse al grupo de la sesión
func handleJoin(w http.ResponseWriter, r *http.Request) {
	var req struct {
		JoinCode  string `json:"join_code"`
		Hostname  string `json:"hostname"`
		PublicKey string `json:"public_key"`
		Endpoint  string `json:"endpoint"`
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
	// El join code es de un solo uso
	delete(state.joinCodes, req.JoinCode)

	// Registrar o actualizar peer
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
			LastSeen:  time.Now(),
			Online:    true,
		}
		state.peers[peer.ID] = peer
	} else {
		peer.PublicKey = req.PublicKey
		peer.Endpoint = req.Endpoint
		peer.LastSeen = time.Now()
		peer.Online = true
	}

	// Agregar al grupo
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

	respond(w, 200, map[string]interface{}{
		"peer":     peer,
		"group_id": groupID,
	})
}

// ─────────────────────────────────────────────
// Handler — WebSocket (actualizaciones en tiempo real)
// ─────────────────────────────────────────────

// GET /ws?peer_id=XXX
// El agente abre esta conexión y recibe pushes cuando su network map cambia
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

	client := &wsClient{
		conn:   conn,
		peerID: peerID,
		send:   make(chan []byte, 8),
	}
	state.mu.Lock()
	state.wsClients[peerID] = client
	state.mu.Unlock()

	log.Printf("[ws] peer=%s conectado", peerID)

	// Enviar network map inmediatamente al conectar
	nm := state.networkMapForPeer(peerID)
	data, _ := json.Marshal(nm)
	client.send <- data

	// Goroutine de escritura
	go func() {
		defer conn.Close()
		for msg := range client.send {
			if err := conn.WriteMessage(websocket.TextMessage, msg); err != nil {
				break
			}
		}
	}()

	// Loop de lectura (mantiene la conexión, detecta desconexión)
	for {
		_, _, err := conn.ReadMessage()
		if err != nil {
			break
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

// ─────────────────────────────────────────────
// Background: marcar peers offline por timeout
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
		ipCounter:  1, // empieza en 10.99.0.2 (10.99.0.1 es el servidor)
		adminToken: adminToken,
	}

	startOfflineChecker()

	mux := http.NewServeMux()

	// Peers
	mux.HandleFunc("POST /api/peers/register", handleRegisterPeer)
	mux.HandleFunc("GET /api/peers", handleListPeers)
	mux.HandleFunc("POST /api/peers/{id}/heartbeat", handleHeartbeat)

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

	// Network map (fallback polling para agentes sin websocat)
	mux.HandleFunc("GET /api/peers/{id}/network-map", func(w http.ResponseWriter, r *http.Request) {
		peerID := r.PathValue("id")
		if _, ok := state.getPeerByID(peerID); !ok {
			respond(w, 404, map[string]string{"error": "peer not found"})
			return
		}
		nm := state.networkMapForPeer(peerID)
		respond(w, 200, nm)
	})

	// WebSocket
	mux.HandleFunc("GET /ws", handleWebSocket)

	// Health check
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
