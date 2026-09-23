package main

import (
    "bufio"
    "crypto/tls"
    "encoding/binary"
    "errors"
    "fmt"
    "io"
    "log"
    "net"
    "os"
    "strconv"
    "strings"
    "sync"
    "time"
)

type cfg struct {
    UpstreamHost string
    UpstreamPort string
    Username     string
    Password     string
    Listen       string
}

func envCfg() cfg {
    port := os.Getenv("AG_UPSTREAM_PORT")
    if port == "" { port = "1080" }
    listen := os.Getenv("AG_LOCAL_ADDR")
    if listen == "" { listen = "127.0.0.1:17890" }
    return cfg{
        UpstreamHost: os.Getenv("AG_UPSTREAM_HOST"),
        UpstreamPort: port,
        Username: os.Getenv("AG_UPSTREAM_USER"),
        Password: os.Getenv("AG_UPSTREAM_PASS"),
        Listen: listen,
    }
}

func main() {
    c := envCfg()
    if c.UpstreamHost == "" {
        log.Fatal("AG_UPSTREAM_HOST is required")
    }
    if len(os.Args) > 1 && os.Args[1] == "--check" {
        ip, err := checkIP(c)
        if err != nil { log.Fatal(err) }
        fmt.Println(ip)
        return
    }
    ln, err := net.Listen("tcp", c.Listen)
    if err != nil { log.Fatal(err) }
    log.Printf("AG RouteGuard bridge listening on %s -> %s:%s", c.Listen, c.UpstreamHost, c.UpstreamPort)
    for {
        conn, err := ln.Accept()
        if err != nil { log.Printf("accept: %v", err); continue }
        go handleClient(conn, c)
    }
}

func handleClient(client net.Conn, c cfg) {
    defer client.Close()
    _ = client.SetDeadline(time.Now().Add(20 * time.Second))
    r := bufio.NewReader(client)

    // Local side: SOCKS5 no-auth server.
    hdr := make([]byte, 2)
    if _, err := io.ReadFull(r, hdr); err != nil || hdr[0] != 5 { return }
    methods := make([]byte, int(hdr[1]))
    if _, err := io.ReadFull(r, methods); err != nil { return }
    supportsNoAuth := false
    for _, m := range methods { if m == 0x00 { supportsNoAuth = true } }
    if !supportsNoAuth { _, _ = client.Write([]byte{5, 0xff}); return }
    if _, err := client.Write([]byte{5, 0x00}); err != nil { return }

    reqHead := make([]byte, 4)
    if _, err := io.ReadFull(r, reqHead); err != nil { return }
    if reqHead[0] != 5 || reqHead[1] != 1 { writeReply(client, 0x07); return }
    target, rawAddr, err := readTarget(r, reqHead[3])
    if err != nil { writeReply(client, 0x08); return }

    upstream, err := net.DialTimeout("tcp", net.JoinHostPort(c.UpstreamHost, c.UpstreamPort), 12*time.Second)
    if err != nil { writeReply(client, 0x04); return }
    defer upstream.Close()
    _ = upstream.SetDeadline(time.Now().Add(20 * time.Second))

    if err := upstreamHandshake(upstream, c.Username, c.Password); err != nil { writeReply(client, 0x01); return }
    if _, err := upstream.Write(append([]byte{5, 1, 0}, append([]byte{reqHead[3]}, rawAddr...)...)); err != nil { writeReply(client, 0x01); return }
    rep, err := readUpstreamReply(upstream)
    if err != nil { writeReply(client, 0x01); return }
    if rep != 0x00 { writeReply(client, rep); return }

    // Reply success with 0.0.0.0:0; client does not need actual bind address for CONNECT.
    if _, err := client.Write([]byte{5, 0, 0, 1, 0, 0, 0, 0, 0, 0}); err != nil { return }
    _ = client.SetDeadline(time.Time{})
    _ = upstream.SetDeadline(time.Time{})
    log.Printf("CONNECT %s", target)

    var wg sync.WaitGroup
    wg.Add(2)
    go func(){ defer wg.Done(); _, _ = io.Copy(upstream, r) }()
    go func(){ defer wg.Done(); _, _ = io.Copy(client, upstream) }()
    wg.Wait()
}

func upstreamHandshake(conn net.Conn, user, pass string) error {
    if len(user) > 255 || len(pass) > 255 { return errors.New("proxy username/password too long") }
    // Offer username/password when credentials exist, else no-auth.
    if user != "" || pass != "" {
        if _, err := conn.Write([]byte{5, 1, 2}); err != nil { return err }
        resp := make([]byte, 2)
        if _, err := io.ReadFull(conn, resp); err != nil { return err }
        if resp[0] != 5 || resp[1] != 2 { return fmt.Errorf("upstream did not accept username/password auth: %v", resp) }
        auth := []byte{1, byte(len(user))}
        auth = append(auth, []byte(user)...)
        auth = append(auth, byte(len(pass)))
        auth = append(auth, []byte(pass)...)
        if _, err := conn.Write(auth); err != nil { return err }
        aresp := make([]byte, 2)
        if _, err := io.ReadFull(conn, aresp); err != nil { return err }
        if aresp[1] != 0 { return errors.New("upstream proxy authentication failed") }
        return nil
    }
    if _, err := conn.Write([]byte{5, 1, 0}); err != nil { return err }
    resp := make([]byte, 2)
    if _, err := io.ReadFull(conn, resp); err != nil { return err }
    if resp[0] != 5 || resp[1] != 0 { return fmt.Errorf("upstream no-auth failed: %v", resp) }
    return nil
}

func readTarget(r *bufio.Reader, atyp byte) (string, []byte, error) {
    switch atyp {
    case 1:
        b := make([]byte, 4+2)
        if _, err := io.ReadFull(r, b); err != nil { return "", nil, err }
        ip := net.IP(b[:4]).String(); port := binary.BigEndian.Uint16(b[4:])
        return net.JoinHostPort(ip, strconv.Itoa(int(port))), b, nil
    case 3:
        l, err := r.ReadByte(); if err != nil { return "", nil, err }
        b := make([]byte, int(l)+2)
        if _, err := io.ReadFull(r, b); err != nil { return "", nil, err }
        host := string(b[:len(b)-2]); port := binary.BigEndian.Uint16(b[len(b)-2:])
        raw := append([]byte{l}, b...)
        return net.JoinHostPort(host, strconv.Itoa(int(port))), raw, nil
    case 4:
        b := make([]byte, 16+2)
        if _, err := io.ReadFull(r, b); err != nil { return "", nil, err }
        ip := net.IP(b[:16]).String(); port := binary.BigEndian.Uint16(b[16:])
        return net.JoinHostPort(ip, strconv.Itoa(int(port))), b, nil
    default:
        return "", nil, errors.New("unsupported address type")
    }
}

func readUpstreamReply(conn net.Conn) (byte, error) {
    h := make([]byte, 4)
    if _, err := io.ReadFull(conn, h); err != nil { return 0, err }
    if h[0] != 5 { return 0, errors.New("bad upstream SOCKS version") }
    var n int
    switch h[3] {
    case 1: n = 4 + 2
    case 4: n = 16 + 2
    case 3:
        one := make([]byte, 1); if _, err := io.ReadFull(conn, one); err != nil { return 0, err }
        n = int(one[0]) + 2
    default: return 0, errors.New("bad upstream reply address type")
    }
    rest := make([]byte, n)
    if _, err := io.ReadFull(conn, rest); err != nil { return 0, err }
    return h[1], nil
}

func writeReply(conn net.Conn, rep byte) {
    _, _ = conn.Write([]byte{5, rep, 0, 1, 0, 0, 0, 0, 0, 0})
}

func dialViaUpstream(c cfg, host string, port uint16) (net.Conn, error) {
    conn, err := net.DialTimeout("tcp", net.JoinHostPort(c.UpstreamHost, c.UpstreamPort), 12*time.Second)
    if err != nil { return nil, err }
    ok := false
    defer func(){ if !ok { _ = conn.Close() } }()
    _ = conn.SetDeadline(time.Now().Add(20 * time.Second))
    if err := upstreamHandshake(conn, c.Username, c.Password); err != nil { return nil, err }
    hb := []byte(host)
    if len(hb) > 255 { return nil, errors.New("hostname too long") }
    req := []byte{5,1,0,3,byte(len(hb))}
    req = append(req, hb...)
    p := make([]byte,2); binary.BigEndian.PutUint16(p, port); req = append(req,p...)
    if _, err := conn.Write(req); err != nil { return nil, err }
    rep, err := readUpstreamReply(conn)
    if err != nil { return nil, err }
    if rep != 0 { return nil, fmt.Errorf("upstream CONNECT failed with code %d", rep) }
    _ = conn.SetDeadline(time.Time{})
    ok = true
    return conn, nil
}

func checkIP(c cfg) (string, error) {
    raw, err := dialViaUpstream(c, "api.ipify.org", 443)
    if err != nil { return "", err }
    defer raw.Close()
    tlsConn := tls.Client(raw, &tls.Config{ServerName: "api.ipify.org", MinVersion: tls.VersionTLS12})
    if err := tlsConn.Handshake(); err != nil { return "", err }
    if _, err := io.WriteString(tlsConn, "GET / HTTP/1.1\r\nHost: api.ipify.org\r\nConnection: close\r\nUser-Agent: AGRouteGuard/0.1\r\n\r\n"); err != nil { return "", err }
    b, err := io.ReadAll(tlsConn)
    if err != nil { return "", err }
    parts := strings.SplitN(string(b), "\r\n\r\n", 2)
    if len(parts) != 2 { return "", errors.New("unexpected ipify response") }
    return strings.TrimSpace(parts[1]), nil
}
