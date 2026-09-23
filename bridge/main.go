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

const (
    gateDNSAddr = "127.0.0.53:53"
)

var gateHosts = map[string]net.IP{
    "cloudcode-pa.googleapis.com":       net.IPv4(127, 65, 71, 1),
    "daily-cloudcode-pa.googleapis.com": net.IPv4(127, 65, 71, 2),
}

type cfg struct {
    UpstreamHost string
    UpstreamPort string
    Username     string
    Password     string
    Listen       string
}

func envCfg() cfg {
    port := os.Getenv("AG_UPSTREAM_PORT")
    if port == "" {
        port = "1080"
    }
    listen := os.Getenv("AG_LOCAL_ADDR")
    if listen == "" {
        listen = "127.0.0.1:17890"
    }
    return cfg{
        UpstreamHost: os.Getenv("AG_UPSTREAM_HOST"),
        UpstreamPort: port,
        Username:     os.Getenv("AG_UPSTREAM_USER"),
        Password:     os.Getenv("AG_UPSTREAM_PASS"),
        Listen:       listen,
    }
}

func main() {
    c := envCfg()
    if c.UpstreamHost == "" {
        log.Fatal("AG_UPSTREAM_HOST is required")
    }

    if len(os.Args) > 1 {
        switch os.Args[1] {
        case "--check":
            ip, err := checkIP(c)
            if err != nil {
                log.Fatal(err)
            }
            fmt.Println(ip)
            return
        case "--probe-google":
            if err := probeGoogle(c); err != nil {
                log.Fatal(err)
            }
            return
        }
    }

    // The ordinary per-process path: the injected Antigravity processes connect
    // to this local no-auth SOCKS listener. It bridges to an authenticated
    // upstream SOCKS proxy.
    ln, err := net.Listen("tcp", c.Listen)
    if err != nil {
        log.Fatalf("local SOCKS listen %s: %v", c.Listen, err)
    }
    log.Printf("SOCKS bridge listening on %s -> %s:%s", c.Listen, c.UpstreamHost, c.UpstreamPort)
    go serveSOCKS(ln, c)

    // Belt-and-suspenders path for the two CloudCode gate hosts. Windows NRPT
    // sends DNS for these names to 127.0.0.53. We answer with two distinct
    // loopback IPs and carry raw TLS from :443 to the same upstream proxy.
    // No certificate is installed and TLS is never decrypted.
    for host, ip := range gateHosts {
        host := host
        addr := net.JoinHostPort(ip.String(), "443")
        gl, err := net.Listen("tcp", addr)
        if err != nil {
            log.Printf("WARNING gate listener %s (%s) unavailable: %v", host, addr, err)
            continue
        }
        log.Printf("gate listener %s -> %s", addr, host)
        go serveGate(gl, c, host)
    }

    go func() {
        if err := serveDNSUDP(gateDNSAddr); err != nil {
            log.Printf("WARNING DNS/UDP %s unavailable: %v", gateDNSAddr, err)
        }
    }()
    go func() {
        if err := serveDNSTCP(gateDNSAddr); err != nil {
            log.Printf("WARNING DNS/TCP %s unavailable: %v", gateDNSAddr, err)
        }
    }()

    select {}
}

func serveSOCKS(ln net.Listener, c cfg) {
    for {
        conn, err := ln.Accept()
        if err != nil {
            log.Printf("SOCKS accept: %v", err)
            continue
        }
        go handleClient(conn, c)
    }
}

func serveGate(ln net.Listener, c cfg, host string) {
    for {
        client, err := ln.Accept()
        if err != nil {
            log.Printf("gate %s accept: %v", host, err)
            continue
        }
        go func() {
            defer client.Close()
            upstream, err := dialViaUpstream(c, host, 443)
            if err != nil {
                log.Printf("gate %s upstream: %v", host, err)
                return
            }
            defer upstream.Close()
            log.Printf("GATE %s via upstream SOCKS", host)
            splice(client, upstream)
        }()
    }
}

func splice(a, b net.Conn) {
    var wg sync.WaitGroup
    wg.Add(2)
    go func() {
        defer wg.Done()
        _, _ = io.Copy(b, a)
        if x, ok := b.(*net.TCPConn); ok {
            _ = x.CloseWrite()
        }
    }()
    go func() {
        defer wg.Done()
        _, _ = io.Copy(a, b)
        if x, ok := a.(*net.TCPConn); ok {
            _ = x.CloseWrite()
        }
    }()
    wg.Wait()
}

func handleClient(client net.Conn, c cfg) {
    defer client.Close()
    _ = client.SetDeadline(time.Now().Add(20 * time.Second))
    r := bufio.NewReader(client)
    first, err := r.Peek(1)
    if err != nil {
        return
    }
    if first[0] != 0x05 {
        handleHTTPConnect(client, r, c)
        return
    }

    // Local side: SOCKS5 no-auth server. Only loopback can reach it.
    hdr := make([]byte, 2)
    if _, err := io.ReadFull(r, hdr); err != nil || hdr[0] != 5 {
        return
    }
    methods := make([]byte, int(hdr[1]))
    if _, err := io.ReadFull(r, methods); err != nil {
        return
    }
    supportsNoAuth := false
    for _, m := range methods {
        if m == 0x00 {
            supportsNoAuth = true
        }
    }
    if !supportsNoAuth {
        _, _ = client.Write([]byte{5, 0xff})
        return
    }
    if _, err := client.Write([]byte{5, 0x00}); err != nil {
        return
    }

    reqHead := make([]byte, 4)
    if _, err := io.ReadFull(r, reqHead); err != nil {
        return
    }
    if reqHead[0] != 5 || reqHead[1] != 1 {
        writeReply(client, 0x07)
        return
    }
    target, rawAddr, err := readTarget(r, reqHead[3])
    if err != nil {
        writeReply(client, 0x08)
        return
    }

    upstream, err := net.DialTimeout("tcp", net.JoinHostPort(c.UpstreamHost, c.UpstreamPort), 12*time.Second)
    if err != nil {
        writeReply(client, 0x04)
        return
    }
    defer upstream.Close()
    _ = upstream.SetDeadline(time.Now().Add(20 * time.Second))

    if err := upstreamHandshake(upstream, c.Username, c.Password); err != nil {
        writeReply(client, 0x01)
        return
    }
    if _, err := upstream.Write(append([]byte{5, 1, 0}, append([]byte{reqHead[3]}, rawAddr...)...)); err != nil {
        writeReply(client, 0x01)
        return
    }
    rep, err := readUpstreamReply(upstream)
    if err != nil {
        writeReply(client, 0x01)
        return
    }
    if rep != 0x00 {
        writeReply(client, rep)
        return
    }

    if _, err := client.Write([]byte{5, 0, 0, 1, 0, 0, 0, 0, 0, 0}); err != nil {
        return
    }
    _ = client.SetDeadline(time.Time{})
    _ = upstream.SetDeadline(time.Time{})
    log.Printf("CONNECT %s", target)

    // r may already contain bytes beyond the SOCKS request; copy from r rather
    // than directly from client for the client->upstream direction.
    var wg sync.WaitGroup
    wg.Add(2)
    go func() {
        defer wg.Done()
        _, _ = io.Copy(upstream, r)
    }()
    go func() {
        defer wg.Done()
        _, _ = io.Copy(client, upstream)
    }()
    wg.Wait()
}

func handleHTTPConnect(client net.Conn, r *bufio.Reader, c cfg) {
    line, err := r.ReadString('\n')
    if err != nil {
        return
    }
    parts := strings.Fields(strings.TrimSpace(line))
    if len(parts) < 3 || !strings.EqualFold(parts[0], "CONNECT") {
        _, _ = io.WriteString(client, "HTTP/1.1 405 Method Not Allowed\r\nConnection: close\r\n\r\n")
        return
    }
    target := parts[1]
    host, portText, err := net.SplitHostPort(target)
    if err != nil {
        // CONNECT commonly omits brackets only for hostname:port. Require a
        // real port instead of guessing, because this proxy is only for the
        // language server's HTTPS path.
        _, _ = io.WriteString(client, "HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n")
        return
    }
    p64, err := strconv.ParseUint(portText, 10, 16)
    if err != nil || p64 == 0 {
        _, _ = io.WriteString(client, "HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n")
        return
    }

    // Consume CONNECT headers, but do not interpret or log credentials/tokens.
    for {
        h, err := r.ReadString('\n')
        if err != nil {
            return
        }
        if h == "\r\n" || h == "\n" {
            break
        }
        if len(h) > 8192 {
            return
        }
    }

    upstream, err := dialViaUpstream(c, host, uint16(p64))
    if err != nil {
        _, _ = io.WriteString(client, "HTTP/1.1 502 Bad Gateway\r\nConnection: close\r\n\r\n")
        return
    }
    defer upstream.Close()
    if _, err := io.WriteString(client, "HTTP/1.1 200 Connection Established\r\n\r\n"); err != nil {
        return
    }
    _ = client.SetDeadline(time.Time{})
    log.Printf("HTTP CONNECT %s", target)

    var wg sync.WaitGroup
    wg.Add(2)
    go func() {
        defer wg.Done()
        _, _ = io.Copy(upstream, r)
    }()
    go func() {
        defer wg.Done()
        _, _ = io.Copy(client, upstream)
    }()
    wg.Wait()
}

func upstreamHandshake(conn net.Conn, user, pass string) error {
    if len(user) > 255 || len(pass) > 255 {
        return errors.New("proxy username/password too long")
    }
    if user != "" || pass != "" {
        if _, err := conn.Write([]byte{5, 1, 2}); err != nil {
            return err
        }
        resp := make([]byte, 2)
        if _, err := io.ReadFull(conn, resp); err != nil {
            return err
        }
        if resp[0] != 5 || resp[1] != 2 {
            return fmt.Errorf("upstream did not accept username/password auth: %v", resp)
        }
        auth := []byte{1, byte(len(user))}
        auth = append(auth, []byte(user)...)
        auth = append(auth, byte(len(pass)))
        auth = append(auth, []byte(pass)...)
        if _, err := conn.Write(auth); err != nil {
            return err
        }
        aresp := make([]byte, 2)
        if _, err := io.ReadFull(conn, aresp); err != nil {
            return err
        }
        if aresp[1] != 0 {
            return errors.New("upstream proxy authentication failed")
        }
        return nil
    }

    if _, err := conn.Write([]byte{5, 1, 0}); err != nil {
        return err
    }
    resp := make([]byte, 2)
    if _, err := io.ReadFull(conn, resp); err != nil {
        return err
    }
    if resp[0] != 5 || resp[1] != 0 {
        return fmt.Errorf("upstream no-auth failed: %v", resp)
    }
    return nil
}

func readTarget(r *bufio.Reader, atyp byte) (string, []byte, error) {
    switch atyp {
    case 1:
        b := make([]byte, 4+2)
        if _, err := io.ReadFull(r, b); err != nil {
            return "", nil, err
        }
        ip := net.IP(b[:4]).String()
        port := binary.BigEndian.Uint16(b[4:])
        return net.JoinHostPort(ip, strconv.Itoa(int(port))), b, nil
    case 3:
        l, err := r.ReadByte()
        if err != nil {
            return "", nil, err
        }
        b := make([]byte, int(l)+2)
        if _, err := io.ReadFull(r, b); err != nil {
            return "", nil, err
        }
        host := string(b[:len(b)-2])
        port := binary.BigEndian.Uint16(b[len(b)-2:])
        raw := append([]byte{l}, b...)
        return net.JoinHostPort(host, strconv.Itoa(int(port))), raw, nil
    case 4:
        b := make([]byte, 16+2)
        if _, err := io.ReadFull(r, b); err != nil {
            return "", nil, err
        }
        ip := net.IP(b[:16]).String()
        port := binary.BigEndian.Uint16(b[16:])
        return net.JoinHostPort(ip, strconv.Itoa(int(port))), b, nil
    default:
        return "", nil, errors.New("unsupported address type")
    }
}

func readUpstreamReply(conn net.Conn) (byte, error) {
    h := make([]byte, 4)
    if _, err := io.ReadFull(conn, h); err != nil {
        return 0, err
    }
    if h[0] != 5 {
        return 0, errors.New("bad upstream SOCKS version")
    }
    var n int
    switch h[3] {
    case 1:
        n = 4 + 2
    case 4:
        n = 16 + 2
    case 3:
        one := make([]byte, 1)
        if _, err := io.ReadFull(conn, one); err != nil {
            return 0, err
        }
        n = int(one[0]) + 2
    default:
        return 0, errors.New("bad upstream reply address type")
    }
    rest := make([]byte, n)
    if _, err := io.ReadFull(conn, rest); err != nil {
        return 0, err
    }
    return h[1], nil
}

func writeReply(conn net.Conn, rep byte) {
    _, _ = conn.Write([]byte{5, rep, 0, 1, 0, 0, 0, 0, 0, 0})
}

func dialViaUpstream(c cfg, host string, port uint16) (net.Conn, error) {
    conn, err := net.DialTimeout("tcp", net.JoinHostPort(c.UpstreamHost, c.UpstreamPort), 12*time.Second)
    if err != nil {
        return nil, err
    }
    ok := false
    defer func() {
        if !ok {
            _ = conn.Close()
        }
    }()
    _ = conn.SetDeadline(time.Now().Add(20 * time.Second))

    if err := upstreamHandshake(conn, c.Username, c.Password); err != nil {
        return nil, err
    }

    hb := []byte(host)
    if len(hb) > 255 {
        return nil, errors.New("hostname too long")
    }
    req := []byte{5, 1, 0, 3, byte(len(hb))}
    req = append(req, hb...)
    p := make([]byte, 2)
    binary.BigEndian.PutUint16(p, port)
    req = append(req, p...)
    if _, err := conn.Write(req); err != nil {
        return nil, err
    }
    rep, err := readUpstreamReply(conn)
    if err != nil {
        return nil, err
    }
    if rep != 0 {
        return nil, fmt.Errorf("upstream CONNECT failed with code %d", rep)
    }
    _ = conn.SetDeadline(time.Time{})
    ok = true
    return conn, nil
}

func probeGoogle(c cfg) error {
    hosts := []string{
        "oauth2.googleapis.com",
        "cloudcode-pa.googleapis.com",
        "daily-cloudcode-pa.googleapis.com",
    }
    var failed []string
    for _, host := range hosts {
        started := time.Now()
        raw, err := dialViaUpstream(c, host, 443)
        if err == nil {
            tlsConn := tls.Client(raw, &tls.Config{
                ServerName: host,
                MinVersion: tls.VersionTLS12,
            })
            _ = tlsConn.SetDeadline(time.Now().Add(15 * time.Second))
            err = tlsConn.Handshake()
            _ = tlsConn.Close()
        }
        if err != nil {
            fmt.Printf("%s FAIL %v\n", host, err)
            failed = append(failed, host)
            continue
        }
        fmt.Printf("%s OK %dms\n", host, time.Since(started).Milliseconds())
    }
    if len(failed) > 0 {
        return fmt.Errorf("Google TLS probe failed for: %s", strings.Join(failed, ", "))
    }
    return nil
}

func checkIP(c cfg) (string, error) {
    raw, err := dialViaUpstream(c, "api.ipify.org", 443)
    if err != nil {
        return "", err
    }
    defer raw.Close()

    tlsConn := tls.Client(raw, &tls.Config{ServerName: "api.ipify.org", MinVersion: tls.VersionTLS12})
    if err := tlsConn.Handshake(); err != nil {
        return "", err
    }
    if _, err := io.WriteString(tlsConn, "GET / HTTP/1.1\r\nHost: api.ipify.org\r\nConnection: close\r\nUser-Agent: AGRouteGuard/0.4\r\n\r\n"); err != nil {
        return "", err
    }
    b, err := io.ReadAll(tlsConn)
    if err != nil {
        return "", err
    }
    parts := strings.SplitN(string(b), "\r\n\r\n", 2)
    if len(parts) != 2 {
        return "", errors.New("unexpected ipify response")
    }
    return strings.TrimSpace(parts[1]), nil
}

// ---- Minimal authoritative DNS for the two gate names ----

func serveDNSUDP(addr string) error {
    pc, err := net.ListenPacket("udp", addr)
    if err != nil {
        return err
    }
    log.Printf("gate DNS/UDP listening on %s", addr)
    defer pc.Close()

    buf := make([]byte, 4096)
    for {
        n, peer, err := pc.ReadFrom(buf)
        if err != nil {
            return err
        }
        req := append([]byte(nil), buf[:n]...)
        go func() {
            resp, err := buildDNSResponse(req)
            if err == nil {
                _, _ = pc.WriteTo(resp, peer)
            }
        }()
    }
}

func serveDNSTCP(addr string) error {
    ln, err := net.Listen("tcp", addr)
    if err != nil {
        return err
    }
    log.Printf("gate DNS/TCP listening on %s", addr)
    defer ln.Close()

    for {
        c, err := ln.Accept()
        if err != nil {
            return err
        }
        go func() {
            defer c.Close()
            _ = c.SetDeadline(time.Now().Add(5 * time.Second))
            for {
                lenBuf := make([]byte, 2)
                if _, err := io.ReadFull(c, lenBuf); err != nil {
                    return
                }
                n := int(binary.BigEndian.Uint16(lenBuf))
                if n < 12 || n > 4096 {
                    return
                }
                req := make([]byte, n)
                if _, err := io.ReadFull(c, req); err != nil {
                    return
                }
                resp, err := buildDNSResponse(req)
                if err != nil {
                    return
                }
                out := make([]byte, 2+len(resp))
                binary.BigEndian.PutUint16(out[:2], uint16(len(resp)))
                copy(out[2:], resp)
                if _, err := c.Write(out); err != nil {
                    return
                }
            }
        }()
    }
}

func buildDNSResponse(req []byte) ([]byte, error) {
    if len(req) < 12 {
        return nil, errors.New("short DNS packet")
    }
    qd := binary.BigEndian.Uint16(req[4:6])
    if qd != 1 {
        return nil, errors.New("only one DNS question supported")
    }

    host, qtype, qend, err := parseDNSQuestion(req)
    if err != nil {
        return nil, err
    }
    ip, known := gateHosts[strings.ToLower(strings.TrimSuffix(host, "."))]

    flags := uint16(0x8180) // response, recursion desired/available, no error
    answers := uint16(0)
    if !known {
        flags = 0x8183 // NXDOMAIN for anything NRPT should never have sent us
    } else if qtype == 1 {
        answers = 1
    }

    resp := make([]byte, 12)
    copy(resp[0:2], req[0:2])
    binary.BigEndian.PutUint16(resp[2:4], flags)
    binary.BigEndian.PutUint16(resp[4:6], 1)
    binary.BigEndian.PutUint16(resp[6:8], answers)
    binary.BigEndian.PutUint16(resp[8:10], 0)
    binary.BigEndian.PutUint16(resp[10:12], 0)
    resp = append(resp, req[12:qend]...)

    if answers == 1 {
        // name pointer -> question at offset 12
        resp = append(resp, 0xc0, 0x0c)
        resp = append(resp, 0x00, 0x01) // A
        resp = append(resp, 0x00, 0x01) // IN
        resp = append(resp, 0x00, 0x00, 0x00, 0x3c) // TTL 60
        resp = append(resp, 0x00, 0x04)
        resp = append(resp, ip.To4()...)
    }
    // AAAA and other types intentionally return NOERROR/NODATA for known gate
    // names, preventing a native IPv6 escape path.
    return resp, nil
}

func parseDNSQuestion(msg []byte) (host string, qtype uint16, end int, err error) {
    off := 12
    var labels []string
    for {
        if off >= len(msg) {
            return "", 0, 0, errors.New("bad DNS qname")
        }
        n := int(msg[off])
        off++
        if n == 0 {
            break
        }
        if n&0xc0 != 0 || n > 63 || off+n > len(msg) {
            return "", 0, 0, errors.New("unsupported DNS qname")
        }
        labels = append(labels, string(msg[off:off+n]))
        off += n
    }
    if off+4 > len(msg) {
        return "", 0, 0, errors.New("short DNS question")
    }
    qtype = binary.BigEndian.Uint16(msg[off : off+2])
    end = off + 4
    return strings.Join(labels, "."), qtype, end, nil
}
