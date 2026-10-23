// Package steam talks to Steam: it verifies game auth tickets (desktop client), runs the OpenID 2.0 web login and fetches
// persona names. Every network dependency sits behind an interface so tests run without Steam.
package steam

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"time"
)

// Doer is the part of *http.Client the package needs.
type Doer interface {
	Do(*http.Request) (*http.Response, error)
}

// NewHTTPClient is the client used against Steam: short timeout and no redirects (a redirect from an API we call is
// never expected, and following one could send a secret key somewhere else).
func NewHTTPClient() *http.Client {
	return &http.Client{
		Timeout:       10 * time.Second,
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}
}

// SteamIDRe is the form of a 64-bit individual SteamID.
var SteamIDRe = regexp.MustCompile(`^\d{17}$`)

// Verified is what Steam says about a game auth ticket.
type Verified struct {
	SteamID         string // the player (text, never a number)
	OwnerSteamID    string // the account that owns the game (differs under Family Sharing)
	VACBanned       bool
	PublisherBanned bool
}

// ErrInvalidTicket means Steam rejected the ticket (or it is not well formed).
var ErrInvalidTicket = errors.New("steam: invalid ticket")

// ErrUnavailable means Steam could not be asked or answered with garbage; retrying later may work.
var ErrUnavailable = errors.New("steam: service unavailable")

// Verifier checks a game auth ticket (GodotSteam getAuthTicketForWebApi, identity "fuelrivals").
type Verifier interface {
	VerifyTicket(ctx context.Context, ticketHex string) (Verified, error)
}

// Persona fetches the public profile name of a SteamID.
type Persona interface {
	PersonaName(ctx context.Context, steamID string) (string, error)
}

var ticketHexRe = regexp.MustCompile(`^[0-9a-fA-F]+$`)

const maxTicketHex = 4096

// TicketVerifier is the real Verifier: ISteamUserAuth/AuthenticateUserTicket on partner.steam-api.com with the
// publisher key.
type TicketVerifier struct {
	Key      string // STEAM_PARTNER_API_KEY
	AppID    string
	Identity string // "fuelrivals"
	BaseURL  string // default https://partner.steam-api.com
	HTTP     Doer
}

// VerifyTicket implements Verifier.
func (v *TicketVerifier) VerifyTicket(ctx context.Context, ticketHex string) (Verified, error) {
	if len(ticketHex) < 2 || len(ticketHex) > maxTicketHex || !ticketHexRe.MatchString(ticketHex) {
		return Verified{}, ErrInvalidTicket
	}
	base := v.BaseURL
	if base == "" {
		base = "https://partner.steam-api.com"
	}
	q := url.Values{"key": {v.Key}, "appid": {v.AppID}, "ticket": {ticketHex}, "identity": {v.Identity}}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, base+"/ISteamUserAuth/AuthenticateUserTicket/v1/?"+q.Encode(), nil)
	if err != nil {
		return Verified{}, ErrUnavailable
	}
	client := v.HTTP
	if client == nil {
		client = NewHTTPClient()
	}
	resp, err := client.Do(req)
	if err != nil {
		// err can carry the URL with the key in it: report a bare error.
		return Verified{}, ErrUnavailable
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, 64<<10))
	if err != nil || resp.StatusCode >= 500 {
		return Verified{}, ErrUnavailable
	}
	return parseTicketResponse(resp.StatusCode, body)
}

func parseTicketResponse(status int, body []byte) (Verified, error) {
	var doc struct {
		Response struct {
			Params *struct {
				Result          string `json:"result"`
				SteamID         string `json:"steamid"`
				OwnerSteamID    string `json:"ownersteamid"`
				VACBanned       bool   `json:"vacbanned"`
				PublisherBanned bool   `json:"publisherbanned"`
			} `json:"params"`
			Error *struct {
				Code int    `json:"errorcode"`
				Desc string `json:"errordesc"`
			} `json:"error"`
		} `json:"response"`
	}
	if err := json.Unmarshal(body, &doc); err != nil {
		return Verified{}, ErrUnavailable
	}
	if doc.Response.Error != nil || status == http.StatusForbidden || status == http.StatusUnauthorized {
		if status == http.StatusForbidden || status == http.StatusUnauthorized {
			return Verified{}, fmt.Errorf("%w: key rejected by Steam (HTTP %d)", ErrUnavailable, status)
		}
		return Verified{}, ErrInvalidTicket
	}
	p := doc.Response.Params
	if p == nil || p.Result != "OK" || !SteamIDRe.MatchString(p.SteamID) {
		return Verified{}, ErrInvalidTicket
	}
	return Verified{SteamID: p.SteamID, OwnerSteamID: p.OwnerSteamID, VACBanned: p.VACBanned, PublisherBanned: p.PublisherBanned}, nil
}

// PersonaFetcher is the real Persona: ISteamUser/GetPlayerSummaries with the Web API key.
type PersonaFetcher struct {
	Key     string // STEAM_WEB_API_KEY
	BaseURL string // default https://api.steampowered.com
	HTTP    Doer
}

// PersonaName implements Persona.
func (p *PersonaFetcher) PersonaName(ctx context.Context, steamID string) (string, error) {
	if !SteamIDRe.MatchString(steamID) {
		return "", ErrInvalidTicket
	}
	base := p.BaseURL
	if base == "" {
		base = "https://api.steampowered.com"
	}
	q := url.Values{"key": {p.Key}, "steamids": {steamID}}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, base+"/ISteamUser/GetPlayerSummaries/v2/?"+q.Encode(), nil)
	if err != nil {
		return "", ErrUnavailable
	}
	client := p.HTTP
	if client == nil {
		client = NewHTTPClient()
	}
	resp, err := client.Do(req)
	if err != nil {
		return "", ErrUnavailable
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, 64<<10))
	if err != nil || resp.StatusCode != http.StatusOK {
		return "", ErrUnavailable
	}
	var doc struct {
		Response struct {
			Players []struct {
				SteamID string `json:"steamid"`
				Name    string `json:"personaname"`
			} `json:"players"`
		} `json:"response"`
	}
	if json.Unmarshal(body, &doc) != nil {
		return "", ErrUnavailable
	}
	for _, pl := range doc.Response.Players {
		if pl.SteamID == steamID {
			return pl.Name, nil
		}
	}
	return "", ErrUnavailable
}
