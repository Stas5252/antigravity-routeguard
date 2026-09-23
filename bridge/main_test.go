package main

import (
    "bufio"
    "encoding/binary"
    "fmt"
    "io"
    "net"
    "strconv"
    "strings"
    "testing"
    "time"
)

func dnsQuery(name string, qtype uint16) []byte {
    b := make([]byte, 12)
    b[0], b[1] = 0x12, 0x34
    b[2], b[3] = 0x01, 0x00
    binary.BigEndian.PutUint16(b[4:6], 1)
    for _, label := range strings.Split(name, ".") {
        b = append(b, byte(len(label)))
        b = append(b, label...)
    }
    b = append(b, 0)
    q := make([]byte, 4)
    binary.BigEndian.PutUint16(q[0:2], qtype)
    binary.BigEndian.PutUint16(q[2:4], 1)
    return append(b, q...)
}

func TestGateDNSA(t *testing.T) {
    for host, want := range gateHosts {
        resp, err := buildDNSResponse(dnsQuery(host, 1))
        if err != nil {
            t.Fatalf("%s: %v", host, err)
        }
        if got := binary.BigEndian.Uint16(resp[6:8]); got != 1 {
            t.Fatalf("%s: answer count=%d want 1", host, got)
        }
        if len(resp) < 4 || !net.IP(resp[len(resp)-4:]).Equal(want) {
            t.Fatalf("%s: wrong A answer: %v", host, resp[len(resp)-4:])
        }
    }
}

func TestGateDNSAAAANoData(t *testing.T) {
    resp, err := buildDNSResponse(dnsQuery("daily-cloudcode-pa.googleapis.com", 28))
    if err != nil {
        t.Fatal(err)
    }
    if rcode := binary.BigEndian.Uint16(resp[2:4]) & 0x000f; rcode != 0 {
        t.Fatalf("AAAA rcode=%d want NOERROR", rcode)
    }
    if answers := binary.BigEndian.Uint16(resp[6:8]); answers != 0 {
        t.Fatalf("AAAA answers=%d want 0", answers)
    }
}

func TestUnknownGateDNSNXDomain(t *testing.T) {
    resp, err := buildDNSResponse(dnsQuery("example.com", 1))
    if err != nil {
        t.Fatal(err)
    }
    if rcode := binary.BigEndian.Uint16(resp[2:4]) & 0x000f; rcode != 3 {
        t.Fatalf("rcode=%d want NXDOMAIN(3)", rcode)
    }
}

func TestParseDNSQuestionRejectsCompression(t *testing.T) {
    q := make([]byte, 18)
    q[12] = 0xc0
    q[13] = 0x0c
    if _, _, _, err := parseDNSQuestion(q); err == nil {
        t.Fatal("expected compressed qname to be rejected")
    }
}


func startFakeAuthSOCKS(t *testing.T, wantUser, wantPass, wantHost string, wantPort uint16) (cfg, <-chan error) {
    t.Helper()
    ln, err := net.Listen("tcp", "127.0.0.1:0")
    if err != nil {
        t.Fatal(err)
    }
    host, port, err := net.SplitHostPort(ln.Addr().String())
    if err != nil {
        t.Fatal(err)
    }
    done := make(chan error, 1)

    go func() {
        defer ln.Close()
        c, err := ln.Accept()
        if err != nil {
            done <- err
            return
        }
        defer c.Close()
        _ = c.SetDeadline(time.Now().Add(5 * time.Second))

        greeting := make([]byte, 3)
        if _, err := io.ReadFull(c, greeting); err != nil {
            done <- err
            return
        }
        if string(greeting) != string([]byte{5, 1, 2}) {
            done <- fmt.Errorf("unexpected greeting: %v", greeting)
            return
        }
        if _, err := c.Write([]byte{5, 2}); err != nil {
            done <- err
            return
        }

        authHead := make([]byte, 2)
        if _, err := io.ReadFull(c, authHead); err != nil {
            done <- err
            return
        }
        if authHead[0] != 1 {
            done <- fmt.Errorf("unexpected auth version: %d", authHead[0])
            return
        }
        user := make([]byte, int(authHead[1]))
        if _, err := io.ReadFull(c, user); err != nil {
            done <- err
            return
        }
        plen := make([]byte, 1)
        if _, err := io.ReadFull(c, plen); err != nil {
            done <- err
            return
        }
        pass := make([]byte, int(plen[0]))
        if _, err := io.ReadFull(c, pass); err != nil {
            done <- err
            return
        }
        if string(user) != wantUser || string(pass) != wantPass {
            _, _ = c.Write([]byte{1, 1})
            done <- fmt.Errorf("bad credentials %q/%q", user, pass)
            return
        }
        if _, err := c.Write([]byte{1, 0}); err != nil {
            done <- err
            return
        }

        head := make([]byte, 4)
        if _, err := io.ReadFull(c, head); err != nil {
            done <- err
            return
        }
        if head[0] != 5 || head[1] != 1 || head[3] != 3 {
            done <- fmt.Errorf("unexpected CONNECT head: %v", head)
            return
        }
        hlen := make([]byte, 1)
        if _, err := io.ReadFull(c, hlen); err != nil {
            done <- err
            return
        }
        hb := make([]byte, int(hlen[0]))
        if _, err := io.ReadFull(c, hb); err != nil {
            done <- err
            return
        }
        pb := make([]byte, 2)
        if _, err := io.ReadFull(c, pb); err != nil {
            done <- err
            return
        }
        gotPort := binary.BigEndian.Uint16(pb)
        if string(hb) != wantHost || gotPort != wantPort {
            done <- fmt.Errorf("target=%s:%d want %s:%d", hb, gotPort, wantHost, wantPort)
            return
        }

        if _, err := c.Write([]byte{5, 0, 0, 1, 127, 0, 0, 1, 0, 1}); err != nil {
            done <- err
            return
        }

        payload := make([]byte, 4)
        if _, err := io.ReadFull(c, payload); err != nil {
            done <- err
            return
        }
        if string(payload) != "ping" {
            done <- fmt.Errorf("payload=%q want ping", payload)
            return
        }
        if _, err := c.Write([]byte("pong")); err != nil {
            done <- err
            return
        }
        done <- nil
    }()

    return cfg{
        UpstreamHost: host,
        UpstreamPort: port,
        Username:     wantUser,
        Password:     wantPass,
        Listen:       "127.0.0.1:0",
    }, done
}

func waitFakeSOCKS(t *testing.T, done <-chan error) {
    t.Helper()
    select {
    case err := <-done:
        if err != nil {
            t.Fatal(err)
        }
    case <-time.After(5 * time.Second):
        t.Fatal("fake SOCKS server timed out")
    }
}

func TestDialViaAuthenticatedUpstream(t *testing.T) {
    c, done := startFakeAuthSOCKS(t, "alice", "secret", "example.com", 443)
    conn, err := dialViaUpstream(c, "example.com", 443)
    if err != nil {
        t.Fatal(err)
    }
    defer conn.Close()

    if _, err := conn.Write([]byte("ping")); err != nil {
        t.Fatal(err)
    }
    out := make([]byte, 4)
    if _, err := io.ReadFull(conn, out); err != nil {
        t.Fatal(err)
    }
    if string(out) != "pong" {
        t.Fatalf("got %q want pong", out)
    }
    waitFakeSOCKS(t, done)
}

func TestLocalHTTPConnectBridge(t *testing.T) {
    setEgress("test", true)
    defer setEgress("", false)
    c, done := startFakeAuthSOCKS(t, "alice", "secret", "example.com", 443)
    client, server := net.Pipe()
    defer client.Close()
    go handleClient(server, c)

    if _, err := io.WriteString(client, "CONNECT example.com:443 HTTP/1.1\r\nHost: example.com:443\r\n\r\n"); err != nil {
        t.Fatal(err)
    }
    r := bufio.NewReader(client)
    status, err := r.ReadString('\n')
    if err != nil {
        t.Fatal(err)
    }
    if !strings.Contains(status, "200") {
        t.Fatalf("status=%q", status)
    }
    for {
        line, err := r.ReadString('\n')
        if err != nil {
            t.Fatal(err)
        }
        if line == "\r\n" || line == "\n" {
            break
        }
    }
    if _, err := client.Write([]byte("ping")); err != nil {
        t.Fatal(err)
    }
    out := make([]byte, 4)
    if _, err := io.ReadFull(r, out); err != nil {
        t.Fatal(err)
    }
    if string(out) != "pong" {
        t.Fatalf("got %q want pong", out)
    }
    waitFakeSOCKS(t, done)
}

func TestLocalSOCKSBridge(t *testing.T) {
    setEgress("test", true)
    defer setEgress("", false)
    c, done := startFakeAuthSOCKS(t, "alice", "secret", "example.com", 443)
    client, server := net.Pipe()
    defer client.Close()
    go handleClient(server, c)

    if _, err := client.Write([]byte{5, 1, 0}); err != nil {
        t.Fatal(err)
    }
    greet := make([]byte, 2)
    if _, err := io.ReadFull(client, greet); err != nil {
        t.Fatal(err)
    }
    if string(greet) != string([]byte{5, 0}) {
        t.Fatalf("greeting reply=%v", greet)
    }

    host := []byte("example.com")
    req := []byte{5, 1, 0, 3, byte(len(host))}
    req = append(req, host...)
    p := make([]byte, 2)
    binary.BigEndian.PutUint16(p, 443)
    req = append(req, p...)
    if _, err := client.Write(req); err != nil {
        t.Fatal(err)
    }
    reply := make([]byte, 10)
    if _, err := io.ReadFull(client, reply); err != nil {
        t.Fatal(err)
    }
    if reply[1] != 0 {
        t.Fatalf("SOCKS reply=%v", reply)
    }

    if _, err := client.Write([]byte("ping")); err != nil {
        t.Fatal(err)
    }
    out := make([]byte, 4)
    if _, err := io.ReadFull(client, out); err != nil {
        t.Fatal(err)
    }
    if string(out) != "pong" {
        t.Fatalf("got %q want pong", out)
    }
    waitFakeSOCKS(t, done)
}

func TestFakeProxyPortIsNumeric(t *testing.T) {
    c, done := startFakeAuthSOCKS(t, "a", "b", "example.com", 443)
    if _, err := strconv.Atoi(c.UpstreamPort); err != nil {
        t.Fatalf("port %q is not numeric: %v", c.UpstreamPort, err)
    }
    // Drive the fake server so its goroutine does not leak.
    conn, err := dialViaUpstream(c, "example.com", 443)
    if err != nil {
        t.Fatal(err)
    }
    _, _ = conn.Write([]byte("ping"))
    buf := make([]byte, 4)
    _, _ = io.ReadFull(conn, buf)
    _ = conn.Close()
    waitFakeSOCKS(t, done)
}
