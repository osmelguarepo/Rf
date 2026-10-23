// Package ticket signs and verifies match tickets: what a player shows a game server (in the HELLO message) to prove
// the API assigned it a seat. The byte format is specified in backend/docs/TICKET.md; keep both in step.
package ticket

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"errors"
	"fmt"
	"regexp"
	"time"
)

const (
	// Version is the first byte of the payload.
	Version = 1
	// TTL is how long a ticket is valid after it is issued (SPEC_ONLINE 4 and 10).
	TTL = 60 * time.Second
	// MACSize is the length of the HMAC-SHA256 tag at the end.
	MACSize = sha256.Size
	// MaxSeats is the number of cars of a race.
	MaxSeats = 6

	flagGuest = 1 << 0
	maxField  = 64
)

// Errors a verifier can tell apart.
var (
	ErrFormat  = errors.New("ticket: malformed")
	ErrVersion = errors.New("ticket: unknown version")
	ErrMAC     = errors.New("ticket: bad signature")
	ErrExpired = errors.New("ticket: expired")
)

// Ticket is what a ticket says.
type Ticket struct {
	ServerID string // the game server it is for
	MatchID  string // the match, decimal text
	Seat     int    // 0 to 5
	PlayerID string // the internal player id, decimal text
	SteamID  string // 17 digits, empty for a guest
	Name     string // the display name for the seat, 3 to 8 of A-Z 0-9 (or empty)
	Seed     int64  // the match seed, 0 or more
	Expires  int64  // unix seconds; valid while now <= Expires
}

// Guest reports whether the ticket belongs to a guest (no SteamID).
func (t Ticket) Guest() bool { return t.SteamID == "" }

var (
	asciiRe = regexp.MustCompile(`^[\x21-\x7e]*$`)
	steamRe = regexp.MustCompile(`^\d{17}$`)
	idRe    = regexp.MustCompile(`^[0-9]{1,19}$`)
	nameRe  = regexp.MustCompile(`^[A-Z0-9]{0,8}$`)
)

func (t Ticket) validate() error {
	switch {
	case t.Seat < 0 || t.Seat >= MaxSeats:
		return fmt.Errorf("%w: seat %d", ErrFormat, t.Seat)
	case t.Seed < 0:
		return fmt.Errorf("%w: seed", ErrFormat)
	case t.Expires < 0:
		return fmt.Errorf("%w: expiry", ErrFormat)
	case t.ServerID == "" || len(t.ServerID) > maxField || !asciiRe.MatchString(t.ServerID):
		return fmt.Errorf("%w: server id", ErrFormat)
	case !idRe.MatchString(t.MatchID):
		return fmt.Errorf("%w: match id", ErrFormat)
	case !idRe.MatchString(t.PlayerID):
		return fmt.Errorf("%w: player id", ErrFormat)
	case t.SteamID != "" && !steamRe.MatchString(t.SteamID):
		return fmt.Errorf("%w: steam id", ErrFormat)
	case !nameRe.MatchString(t.Name):
		return fmt.Errorf("%w: name", ErrFormat)
	}
	return nil
}

// Payload is the signed part, byte for byte as docs/TICKET.md describes.
func (t Ticket) Payload() ([]byte, error) {
	if err := t.validate(); err != nil {
		return nil, err
	}
	var flags byte
	if t.Guest() {
		flags |= flagGuest
	}
	out := []byte{Version, flags, byte(t.Seat)}
	out = binary.BigEndian.AppendUint64(out, uint64(t.Seed))
	out = binary.BigEndian.AppendUint64(out, uint64(t.Expires))
	for _, s := range []string{t.ServerID, t.MatchID, t.PlayerID, t.SteamID, t.Name} {
		out = append(out, byte(len(s)))
		out = append(out, s...)
	}
	return out, nil
}

func mac(key, payload []byte) []byte {
	h := hmac.New(sha256.New, key)
	h.Write(payload)
	return h.Sum(nil)
}

var encoding = base64.RawURLEncoding.Strict()

// Sign returns the ticket string: base64url without padding of payload || HMAC-SHA256(key, payload).
func Sign(key []byte, t Ticket) (string, error) {
	p, err := t.Payload()
	if err != nil {
		return "", err
	}
	return encoding.EncodeToString(append(p, mac(key, p)...)), nil
}

// Issue signs a ticket that expires TTL after now.
func Issue(key []byte, t Ticket, now time.Time) (string, error) {
	t.Expires = now.Add(TTL).Unix()
	return Sign(key, t)
}

// Parse reads a ticket string without checking the signature or the expiry. A game server must use Verify.
func Parse(s string) (Ticket, []byte, []byte, error) {
	raw, err := encoding.DecodeString(s)
	if err != nil || len(raw) < 19+5+MACSize {
		return Ticket{}, nil, nil, ErrFormat
	}
	payload, tag := raw[:len(raw)-MACSize], raw[len(raw)-MACSize:]
	if payload[0] != Version {
		return Ticket{}, nil, nil, ErrVersion
	}
	flags := payload[1]
	t := Ticket{
		Seat:    int(payload[2]),
		Seed:    int64(binary.BigEndian.Uint64(payload[3:11])),
		Expires: int64(binary.BigEndian.Uint64(payload[11:19])),
	}
	rest := payload[19:]
	fields := make([]string, 5)
	for i := range fields {
		if len(rest) < 1 || len(rest) < 1+int(rest[0]) {
			return Ticket{}, nil, nil, ErrFormat
		}
		n := int(rest[0])
		fields[i] = string(rest[1 : 1+n])
		rest = rest[1+n:]
	}
	if len(rest) != 0 || flags&^flagGuest != 0 {
		return Ticket{}, nil, nil, ErrFormat
	}
	t.ServerID, t.MatchID, t.PlayerID, t.SteamID, t.Name = fields[0], fields[1], fields[2], fields[3], fields[4]
	if err := t.validate(); err != nil {
		return Ticket{}, nil, nil, err
	}
	if t.Guest() != (flags&flagGuest != 0) {
		return Ticket{}, nil, nil, fmt.Errorf("%w: guest flag", ErrFormat)
	}
	return t, payload, tag, nil
}

// Verify checks the signature with the server's key and the expiry against now, and returns the ticket.
// One use per seat is the game server's job: it binds the seat to the first valid HELLO.
func Verify(key []byte, s string, now time.Time) (Ticket, error) {
	t, payload, tag, err := Parse(s)
	if err != nil {
		return Ticket{}, err
	}
	if !hmac.Equal(tag, mac(key, payload)) {
		return Ticket{}, ErrMAC
	}
	if now.Unix() > t.Expires {
		return Ticket{}, ErrExpired
	}
	return t, nil
}
