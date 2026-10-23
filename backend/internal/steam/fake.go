package steam

import (
	"context"
	"strings"
	"sync"
)

// Unavailable is what the service uses for a Steam dependency whose key is not configured: every call fails with
// ErrUnavailable.
type Unavailable struct{}

// VerifyTicket implements Verifier.
func (Unavailable) VerifyTicket(context.Context, string) (Verified, error) {
	return Verified{}, ErrUnavailable
}

// PersonaName implements Persona.
func (Unavailable) PersonaName(context.Context, string) (string, error) { return "", ErrUnavailable }

// FakeVerifier is a Verifier for tests and local development without Steam. A ticket "ok-<steamid>" verifies as that
// SteamID, "banned-<steamid>" as a publisher-banned one, anything else is rejected, "down" simulates an outage.
type FakeVerifier struct{}

// VerifyTicket implements Verifier.
func (FakeVerifier) VerifyTicket(_ context.Context, ticket string) (Verified, error) {
	switch {
	case ticket == "down":
		return Verified{}, ErrUnavailable
	case strings.HasPrefix(ticket, "ok-") && SteamIDRe.MatchString(ticket[3:]):
		return Verified{SteamID: ticket[3:], OwnerSteamID: ticket[3:]}, nil
	case strings.HasPrefix(ticket, "banned-") && SteamIDRe.MatchString(ticket[7:]):
		return Verified{SteamID: ticket[7:], OwnerSteamID: ticket[7:], PublisherBanned: true}, nil
	}
	return Verified{}, ErrInvalidTicket
}

// FakePersona is a Persona with the names given in Names (SteamID to name); unknown IDs get "Player".
type FakePersona struct {
	mu    sync.Mutex
	Names map[string]string
	Err   error
	Calls int
}

// PersonaName implements Persona.
func (f *FakePersona) PersonaName(_ context.Context, steamID string) (string, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.Calls++
	if f.Err != nil {
		return "", f.Err
	}
	if n, ok := f.Names[steamID]; ok {
		return n, nil
	}
	return "Player", nil
}
