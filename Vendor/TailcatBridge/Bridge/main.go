package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
	"unsafe"

	"github.com/tailscale/tailcat"
	"tailscale.com/tailcfg"
	"tailscale.com/types/key"
)

const (
	buildID                  = "tailcat-88929418b1a3f3c74904a3136d6a9e87b1b5b9bb+rcpatch1"
	preambleMagic            = "RCTC"
	preambleSize             = 144
	tailcatTargetPort uint16 = 18217
)

type result struct {
	Handle       uint64 `json:"handle,omitempty"`
	ConnBlob     string `json:"connBlob,omitempty"`
	NodePublic   string `json:"nodePublic,omitempty"`
	LoopbackPort uint16 `json:"loopbackPort,omitempty"`
	Error        string `json:"error,omitempty"`
	State        string `json:"state,omitempty"`
}

type serverRuntime struct {
	server   *tailcat.Server
	port     uint16
	secret   [32]byte
	listener [16]byte
	serverID [32]byte
	counter  atomic.Uint64
	wg       sync.WaitGroup
}

type clientRuntime struct {
	client        *tailcat.Client
	listener      net.Listener
	port          uint16
	cancel        context.CancelFunc
	wg            sync.WaitGroup
	connectionsMu sync.Mutex
	connections   map[net.Conn]struct{}
	stateMu       sync.Mutex
	state         string
}

var runtimes = struct {
	sync.Mutex
	next    uint64
	servers map[uint64]*serverRuntime
	clients map[uint64]*clientRuntime
}{
	next:    1,
	servers: make(map[uint64]*serverRuntime),
	clients: make(map[uint64]*clientRuntime),
}

func cResult(value result) *C.char {
	encoded, err := json.Marshal(value)
	if err != nil {
		encoded = []byte(`{"error":"result_encoding_failed"}`)
	}
	return C.CString(string(encoded))
}

func nextHandle() uint64 {
	runtimes.Lock()
	defer runtimes.Unlock()
	handle := runtimes.next
	runtimes.next++
	return handle
}

func parsePrivate(value string) (key.NodePrivate, error) {
	var private key.NodePrivate
	if err := private.UnmarshalText([]byte(value)); err != nil {
		return key.NodePrivate{}, errors.New("invalid_private_key")
	}
	if private.IsZero() {
		return key.NodePrivate{}, errors.New("invalid_private_key")
	}
	return private, nil
}

func parsePublic(value string) (key.NodePublic, error) {
	var public key.NodePublic
	if err := public.UnmarshalText([]byte(value)); err != nil {
		return key.NodePublic{}, errors.New("invalid_public_key")
	}
	if public.IsZero() {
		return key.NodePublic{}, errors.New("invalid_public_key")
	}
	return public, nil
}

func parseAllowed(value string) ([]key.NodePublic, error) {
	var encoded []string
	if strings.HasPrefix(strings.TrimSpace(value), "[") {
		if err := json.Unmarshal([]byte(value), &encoded); err != nil {
			return nil, errors.New("invalid_allowlist")
		}
	} else {
		encoded = []string{value}
	}
	if len(encoded) == 0 {
		return nil, errors.New("allowlist_required")
	}
	allowed := make([]key.NodePublic, 0, len(encoded))
	for _, item := range encoded {
		public, err := parsePublic(item)
		if err != nil {
			return nil, errors.New("invalid_allowlist")
		}
		allowed = append(allowed, public)
	}
	return allowed, nil
}

func marshalText(value interface{ MarshalText() ([]byte, error) }) (string, error) {
	encoded, err := value.MarshalText()
	if err != nil {
		return "", err
	}
	return string(encoded), nil
}

func makePreamble(runtime *serverRuntime, peer key.NodePublic) ([]byte, error) {
	preamble := make([]byte, preambleSize)
	copy(preamble[0:4], preambleMagic)
	preamble[4] = 1
	copy(preamble[8:24], runtime.listener[:])
	copy(preamble[24:56], runtime.serverID[:])
	binary.BigEndian.PutUint64(preamble[56:64], runtime.counter.Add(1))
	if _, err := rand.Read(preamble[64:80]); err != nil {
		return nil, err
	}
	peerRaw := peer.Raw32()
	copy(preamble[80:112], peerRaw[:])
	mac := hmac.New(sha256.New, runtime.secret[:])
	_, _ = mac.Write(preamble[:112])
	copy(preamble[112:144], mac.Sum(nil))
	return preamble, nil
}

func waitForServerRelay(server *tailcat.Server, timeout time.Duration) bool {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if server.DERPReady() {
			return true
		}
		time.Sleep(10 * time.Millisecond)
	}
	return false
}

func acceptsTailcatTargetPort(port uint16) bool {
	return port == tailcatTargetPort
}

func (runtime *serverRuntime) handle(peer key.NodePublic, incoming net.Conn) {
	defer incoming.Close()
	loopback, err := net.DialTimeout("tcp", net.JoinHostPort("127.0.0.1", strconv.Itoa(int(runtime.port))), 2*time.Second)
	if err != nil {
		return
	}
	defer loopback.Close()
	preamble, err := makePreamble(runtime, peer)
	if err != nil {
		return
	}
	if _, err := loopback.Write(preamble); err != nil {
		return
	}
	done := make(chan struct{}, 1)
	go func() {
		_, _ = io.Copy(loopback, incoming)
		if closer, ok := loopback.(interface{ CloseWrite() error }); ok {
			_ = closer.CloseWrite()
		}
		done <- struct{}{}
	}()
	_, _ = io.Copy(incoming, loopback)
	if closer, ok := incoming.(interface{ CloseWrite() error }); ok {
		_ = closer.CloseWrite()
	}
	_ = incoming.Close()
	_ = loopback.Close()
	<-done
}

func (runtime *clientRuntime) accept(ctx context.Context) {
	defer runtime.wg.Done()
	for {
		connection, err := runtime.listener.Accept()
		if err != nil {
			return
		}
		runtime.setState("accepted")
		runtime.wg.Add(1)
		go func(local net.Conn) {
			defer runtime.wg.Done()
			runtime.addConnection(local)
			defer runtime.removeConnection(local)
			defer local.Close()
			dialCtx, cancel := context.WithTimeout(ctx, 12*time.Second)
			remote, err := runtime.client.DialTCPPort(dialCtx, runtime.port)
			cancel()
			if err != nil {
				if errors.Is(err, context.DeadlineExceeded) {
					runtime.setState("tailcat_dial_timeout")
				} else {
					runtime.setState("tailcat_dial_failed")
				}
				return
			}
			runtime.setState("connected")
			runtime.addConnection(remote)
			defer runtime.removeConnection(remote)
			defer remote.Close()
			done := make(chan struct{}, 1)
			go func() {
				_, _ = io.Copy(remote, local)
				if closer, ok := remote.(interface{ CloseWrite() error }); ok {
					_ = closer.CloseWrite()
				}
				done <- struct{}{}
			}()
			_, _ = io.Copy(local, remote)
			if closer, ok := local.(interface{ CloseWrite() error }); ok {
				_ = closer.CloseWrite()
			}
			_ = local.Close()
			_ = remote.Close()
			<-done
			runtime.setState("completed")
		}(connection)
	}
}

func (runtime *clientRuntime) addConnection(connection net.Conn) {
	runtime.connectionsMu.Lock()
	runtime.connections[connection] = struct{}{}
	runtime.connectionsMu.Unlock()
}

func (runtime *clientRuntime) removeConnection(connection net.Conn) {
	runtime.connectionsMu.Lock()
	delete(runtime.connections, connection)
	runtime.connectionsMu.Unlock()
}

func (runtime *clientRuntime) closeConnections() {
	runtime.connectionsMu.Lock()
	connections := make([]net.Conn, 0, len(runtime.connections))
	for connection := range runtime.connections {
		connections = append(connections, connection)
	}
	runtime.connectionsMu.Unlock()
	for _, connection := range connections {
		_ = connection.Close()
	}
}

func (runtime *clientRuntime) setState(state string) {
	runtime.stateMu.Lock()
	runtime.state = state
	runtime.stateMu.Unlock()
}

func (runtime *clientRuntime) getState() string {
	runtime.stateMu.Lock()
	defer runtime.stateMu.Unlock()
	return runtime.state
}

//export RCTailcatBuildID
func RCTailcatBuildID() *C.char {
	return C.CString(buildID)
}

//export RCTailcatGeneratePrivateKey
func RCTailcatGeneratePrivateKey() *C.char {
	private := key.NewNode()
	privateText, err := marshalText(private)
	if err != nil {
		return cResult(result{Error: "key_generation_failed"})
	}
	publicText, err := marshalText(private.Public())
	if err != nil {
		return cResult(result{Error: "key_generation_failed"})
	}
	return cResult(result{ConnBlob: privateText, NodePublic: publicText})
}

//export RCTailcatPublicKey
func RCTailcatPublicKey(privateValue *C.char) *C.char {
	private, err := parsePrivate(C.GoString(privateValue))
	if err != nil {
		return cResult(result{Error: err.Error()})
	}
	publicText, err := marshalText(private.Public())
	if err != nil {
		return cResult(result{Error: "key_encoding_failed"})
	}
	return cResult(result{NodePublic: publicText})
}

func serverStart(privateValue, allowedValue, secretValue, listenerValue, serverIDValue *C.char, loopbackPort C.ushort, region *tailcfg.DERPRegion, regionID int) *C.char {
	private, err := parsePrivate(C.GoString(privateValue))
	if err != nil {
		return cResult(result{Error: err.Error()})
	}
	allowed, err := parseAllowed(C.GoString(allowedValue))
	if err != nil {
		return cResult(result{Error: err.Error()})
	}
	secret, err := hex.DecodeString(C.GoString(secretValue))
	if err != nil || len(secret) != 32 {
		return cResult(result{Error: "invalid_listener_secret"})
	}
	defer clear(secret)
	listenerID, err := hex.DecodeString(C.GoString(listenerValue))
	if err != nil || len(listenerID) != 16 {
		return cResult(result{Error: "invalid_listener_id"})
	}
	defer clear(listenerID)
	serverID := C.GoString(serverIDValue)
	if serverID == "" || loopbackPort == 0 {
		return cResult(result{Error: "invalid_server_configuration"})
	}
	runtime := &serverRuntime{port: uint16(loopbackPort), serverID: sha256.Sum256([]byte(serverID))}
	copy(runtime.secret[:], secret)
	copy(runtime.listener[:], listenerID)
	server := &tailcat.Server{
		Key:            private,
		AllowedClients: allowed,
		Region:         region,
		RegionID:       regionID,
		Logf:           func(string, ...any) {},
	}
	server.OnTCPWithPeer = func(peer key.NodePublic, port uint16) func(net.Conn) {
		if !acceptsTailcatTargetPort(port) {
			return nil
		}
		return func(connection net.Conn) {
			runtime.wg.Add(1)
			defer runtime.wg.Done()
			runtime.handle(peer, connection)
		}
	}
	if err := server.Start(); err != nil {
		return cResult(result{Error: "server_start_failed"})
	}
	if !waitForServerRelay(server, 30*time.Second) {
		_ = server.Close()
		return cResult(result{Error: "server_start_timeout"})
	}
	runtime.server = server
	handle := nextHandle()
	runtimes.Lock()
	runtimes.servers[handle] = runtime
	runtimes.Unlock()
	publicText, _ := marshalText(private.Public())
	return cResult(result{Handle: handle, ConnBlob: string(server.ConnBlob()), NodePublic: publicText})
}

//export RCTailcatServerStart
func RCTailcatServerStart(privateValue, allowedValue, secretValue, listenerValue, serverIDValue *C.char, loopbackPort C.ushort) *C.char {
	return serverStart(privateValue, allowedValue, secretValue, listenerValue, serverIDValue, loopbackPort, nil, 301)
}

//export RCTailcatServerStartWithDERP
func RCTailcatServerStartWithDERP(privateValue, allowedValue, secretValue, listenerValue, serverIDValue, derpHostValue, derpIPv4Value *C.char, loopbackPort, derpPort, stunPort C.ushort, regionID C.uint) *C.char {
	host := C.GoString(derpHostValue)
	ipv4 := C.GoString(derpIPv4Value)
	region, err := customDERPRegion(host, ipv4, uint16(derpPort), uint16(stunPort), uint32(regionID))
	if err != nil {
		return cResult(result{Error: "invalid_derp_configuration"})
	}
	return serverStart(privateValue, allowedValue, secretValue, listenerValue, serverIDValue, loopbackPort, region, int(regionID))
}

func customDERPRegion(host, ipv4 string, derpPort, stunPort uint16, regionID uint32) (*tailcfg.DERPRegion, error) {
	parsedIPv4 := net.ParseIP(ipv4)
	if host == "" || strings.ContainsAny(host, "/: \t\r\n") || parsedIPv4 == nil || parsedIPv4.To4() == nil || regionID != 1 || derpPort == 0 || stunPort == 0 {
		return nil, errors.New("invalid_derp_configuration")
	}
	region := &tailcfg.DERPRegion{
		RegionID:   int(regionID),
		RegionCode: "rc",
		RegionName: "RemoteCode",
		Nodes: []*tailcfg.DERPNode{{
			Name:     "remotecode-1",
			RegionID: int(regionID),
			HostName: host,
			IPv4:     ipv4,
			DERPPort: int(derpPort),
			STUNPort: int(stunPort),
		}},
	}
	return region, nil
}

//export RCTailcatServerClose
func RCTailcatServerClose(handle C.ulonglong) *C.char {
	runtimes.Lock()
	runtime := runtimes.servers[uint64(handle)]
	delete(runtimes.servers, uint64(handle))
	runtimes.Unlock()
	if runtime == nil {
		return cResult(result{Error: "unknown_server"})
	}
	_ = runtime.server.Close()
	runtime.wg.Wait()
	clear(runtime.secret[:])
	clear(runtime.listener[:])
	clear(runtime.serverID[:])
	return cResult(result{})
}

//export RCTailcatClientStart
func RCTailcatClientStart(connBlobValue, privateValue *C.char, targetPort C.ushort, timeoutMillis C.uint) *C.char {
	private, err := parsePrivate(C.GoString(privateValue))
	if err != nil {
		return cResult(result{Error: err.Error()})
	}
	client := tailcat.NewClient(tailcat.ConnBlob(C.GoString(connBlobValue)))
	client.Key = private
	client.Logf = func(string, ...any) {}
	timeout := time.Duration(timeoutMillis) * time.Millisecond
	if timeout <= 0 || timeout > 30*time.Second {
		timeout = 12 * time.Second
	}
	ctx, cancelPing := context.WithTimeout(context.Background(), timeout)
	pingDone := make(chan error, 1)
	go func() {
		_, pingErr := client.Ping(ctx)
		pingDone <- pingErr
	}()
	select {
	case err = <-pingDone:
	case <-time.After(timeout):
		err = context.DeadlineExceeded
	}
	cancelPing()
	if err != nil {
		go client.Close()
		if errors.Is(err, context.DeadlineExceeded) {
			return cResult(result{Error: "client_start_timeout"})
		}
		return cResult(result{Error: "client_start_failed"})
	}
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		_ = client.Close()
		return cResult(result{Error: "loopback_start_failed"})
	}
	ctx, cancel := context.WithCancel(context.Background())
	runtime := &clientRuntime{
		client:      client,
		listener:    listener,
		port:        uint16(targetPort),
		cancel:      cancel,
		connections: make(map[net.Conn]struct{}),
		state:       "ready",
	}
	runtime.wg.Add(1)
	go runtime.accept(ctx)
	handle := nextHandle()
	runtimes.Lock()
	runtimes.clients[handle] = runtime
	runtimes.Unlock()
	publicText, _ := marshalText(private.Public())
	return cResult(result{Handle: handle, NodePublic: publicText, LoopbackPort: uint16(listener.Addr().(*net.TCPAddr).Port)})
}

//export RCTailcatClientStatus
func RCTailcatClientStatus(handle C.ulonglong) *C.char {
	runtimes.Lock()
	runtime := runtimes.clients[uint64(handle)]
	runtimes.Unlock()
	if runtime == nil {
		return cResult(result{Error: "unknown_client"})
	}
	return cResult(result{State: runtime.getState()})
}

//export RCTailcatClientClose
func RCTailcatClientClose(handle C.ulonglong) *C.char {
	runtimes.Lock()
	runtime := runtimes.clients[uint64(handle)]
	delete(runtimes.clients, uint64(handle))
	runtimes.Unlock()
	if runtime == nil {
		return cResult(result{Error: "unknown_client"})
	}
	runtime.cancel()
	_ = runtime.listener.Close()
	runtime.closeConnections()
	runtime.wg.Wait()
	_ = runtime.client.Close()
	return cResult(result{})
}

//export RCTailcatFree
func RCTailcatFree(value *C.char) {
	C.free(unsafe.Pointer(value))
}

func main() {}
