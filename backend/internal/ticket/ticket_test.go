package ticket

import (
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"testing"
	"time"
)

var testKey, _ = hex.DecodeString("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")

func sample() Ticket {
	return Ticket{ServerID: "srv1", MatchID: "42", Seat: 3, PlayerID: "7", SteamID: "76561198000000001",
		Name: "RACER", Seed: 1234567890123, Expires: 1800000060}
}

type vector struct {
	Name        string `json:"name"`
	ServerID    string `json:"server_id"`
	MatchID     string `json:"match_id"`
	Seat        int    `json:"seat"`
	PlayerID    string `json:"player_id"`
	SteamID     string `json:"steam_id"`
	DisplayName string `json:"display_name"`
	Seed        string `json:"seed"`
	Expires     int64  `json:"expires"`
	PayloadHex  string `json:"payload_hex"`
	MACHex      string `json:"mac_hex"`
	Ticket64    string `json:"ticket"`
	Valid       bool   `json:"valid"`
	Error       string `json:"error,omitempty"`
	Now         int64  `json:"now"`
}

type vectorFile struct {
	KeyHex  string   `json:"key_hex"`
	Vectors []vector `json:"vectors"`
}

func build(name string, t Ticket, now int64) vector {
	p, _ := t.Payload()
	s, _ := Sign(testKey, t)
	return vector{Name: name, ServerID: t.ServerID, MatchID: t.MatchID, Seat: t.Seat, PlayerID: t.PlayerID, SteamID: t.SteamID,
		DisplayName: t.Name, Seed: itoa(t.Seed), Expires: t.Expires, PayloadHex: hex.EncodeToString(p),
		MACHex: hex.EncodeToString(mac(testKey, p)), Ticket64: s, Valid: true, Now: now}
}

func itoa(n int64) string { b, _ := json.Marshal(n); return string(b) }

func TestRoundTrip(t *testing.T) {
	tk := sample()
	s, err := Sign(testKey, tk)
	if err != nil {
		t.Fatal(err)
	}
	got, err := Verify(testKey, s, time.Unix(1800000000, 0))
	if err != nil || got != tk {
		t.Fatalf("got %+v, %v", got, err)
	}
}

func TestGuestTicket(t *testing.T) {
	tk := sample()
	tk.SteamID = ""
	tk.Name = ""
	s, _ := Sign(testKey, tk)
	got, err := Verify(testKey, s, time.Unix(1800000000, 0))
	if err != nil || !got.Guest() {
		t.Fatalf("%+v %v", got, err)
	}
}

func TestRejections(t *testing.T) {
	s, _ := Sign(testKey, sample())
	now := time.Unix(1800000000, 0)
	otherKey := append([]byte{}, testKey...)
	otherKey[0] ^= 1
	if _, err := Verify(otherKey, s, now); !errors.Is(err, ErrMAC) {
		t.Errorf("wrong key: %v", err)
	}
	if _, err := Verify(testKey, s, time.Unix(1800000061, 0)); !errors.Is(err, ErrExpired) {
		t.Errorf("expired: %v", err)
	}
	if _, err := Verify(testKey, s, time.Unix(1800000060, 0)); err != nil {
		t.Errorf("the last second is valid: %v", err)
	}
	// Flip every character of the ticket: nothing may verify.
	for i := range s {
		b := []byte(s)
		if b[i] == 'A' {
			b[i] = 'B'
		} else {
			b[i] = 'A'
		}
		if _, err := Verify(testKey, string(b), now); err == nil {
			t.Fatalf("flipping character %d still verifies", i)
		}
	}
	for _, bad := range []string{"", "!!!", s[:10], s + "AA", s[:len(s)-1]} {
		if _, err := Verify(testKey, bad, now); err == nil {
			t.Errorf("%q verifies", bad)
		}
	}
	// A different version byte is reported as such (with a valid MAC it would still be refused).
	raw := []byte{9}
	if _, err := Verify(testKey, encoding.EncodeToString(append(raw, make([]byte, 60)...)), now); !errors.Is(err, ErrVersion) {
		t.Errorf("version: %v", err)
	}
}

func TestInvalidFieldsAreNotSigned(t *testing.T) {
	bad := []func(*Ticket){
		func(t *Ticket) { t.Seat = 6 },
		func(t *Ticket) { t.Seat = -1 },
		func(t *Ticket) { t.Seed = -1 },
		func(t *Ticket) { t.SteamID = "123" },
		func(t *Ticket) { t.PlayerID = "abc" },
		func(t *Ticket) { t.MatchID = "" },
		func(t *Ticket) { t.ServerID = "" },
		func(t *Ticket) { t.ServerID = "has space" },
		func(t *Ticket) { t.Name = "lower" },
		func(t *Ticket) { t.Name = "TOOLONGNAME" },
	}
	for i, f := range bad {
		tk := sample()
		f(&tk)
		if _, err := Sign(testKey, tk); err == nil {
			t.Errorf("case %d signs", i)
		}
	}
}

// The vectors in testdata/ticket_vectors.json are what the Godot side must reproduce. Run with
// TICKET_UPDATE_VECTORS=1 to regenerate them.
func TestVectors(t *testing.T) {
	guest := sample()
	guest.SteamID, guest.Name, guest.Seat, guest.Seed, guest.PlayerID = "", "", 0, 0, "9223372036854775807"
	max := sample()
	max.Seat, max.Seed, max.Name, max.MatchID = 5, 9223372036854775807, "A1B2C3D4", "9223372036854775807"
	vs := []vector{
		build("steam player, seat 3", sample(), 1800000000),
		build("guest, seat 0, seed 0", guest, 1800000000),
		build("largest seed, seat 5", max, 1800000000),
	}
	expired := build("same as the first, one second late", sample(), 1800000061)
	expired.Valid, expired.Error = false, "expired"
	badMac := build("first with one character of the signature changed", sample(), 1800000000)
	at := len(badMac.Ticket64) - 10
	swap := "A"
	if badMac.Ticket64[at] == 'A' {
		swap = "B"
	}
	badMac.Ticket64 = badMac.Ticket64[:at] + swap + badMac.Ticket64[at+1:]
	badMac.Valid, badMac.Error = false, "bad signature"
	vs = append(vs, expired, badMac)

	path := "../../testdata/ticket_vectors.json"
	if os.Getenv("TICKET_UPDATE_VECTORS") == "1" {
		b, _ := json.MarshalIndent(vectorFile{KeyHex: hex.EncodeToString(testKey), Vectors: vs}, "", "  ")
		if err := os.WriteFile(path, append(b, '\n'), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("%v (run with TICKET_UPDATE_VECTORS=1)", err)
	}
	var file vectorFile
	if err := json.Unmarshal(raw, &file); err != nil {
		t.Fatal(err)
	}
	if file.KeyHex != hex.EncodeToString(testKey) || len(file.Vectors) != len(vs) {
		t.Fatalf("vector file out of date: regenerate with TICKET_UPDATE_VECTORS=1")
	}
	for i, v := range file.Vectors {
		if v.Ticket64 != vs[i].Ticket64 || v.PayloadHex != vs[i].PayloadHex || v.MACHex != vs[i].MACHex {
			t.Errorf("vector %q differs from the code: regenerate and update the Godot side", v.Name)
		}
		_, err := Verify(testKey, v.Ticket64, time.Unix(v.Now, 0))
		if (err == nil) != v.Valid {
			t.Errorf("vector %q: valid=%v but Verify says %v", v.Name, v.Valid, err)
		}
	}
}

func TestPayloadLayoutIsStable(t *testing.T) {
	p, _ := sample().Payload()
	// version, flags, seat, then the 8-byte seed and expiry, big endian.
	if p[0] != 1 || p[1] != 0 || p[2] != 3 {
		t.Fatalf("header % x", p[:3])
	}
	if hex.EncodeToString(p[3:11]) != "0000011f71fb04cb" {
		t.Errorf("seed bytes %x", p[3:11])
	}
	if hex.EncodeToString(p[11:19]) != "000000006b49d23c" {
		t.Errorf("expiry bytes %x", p[11:19])
	}
	if string(p[20:24]) != "srv1" || p[19] != 4 {
		t.Errorf("server id: % x", p[19:24])
	}
}
