package main

import (
    "encoding/binary"
    "net"
    "strings"
    "testing"
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
