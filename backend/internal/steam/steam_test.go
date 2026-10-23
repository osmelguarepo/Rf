package steam

import (
	"context"
	"errors"
	"io"
	"net/http"
	"strings"
	"testing"
)

type stub struct {
	status int
	body   string
	url    string
}

func (s *stub) Do(r *http.Request) (*http.Response, error) {
	s.url = r.URL.String()
	return &http.Response{StatusCode: s.status, Body: io.NopCloser(strings.NewReader(s.body))}, nil
}

func TestTicketVerifierParsesSteamAnswers(t *testing.T) {
	ok := `{"response":{"params":{"result":"OK","steamid":"76561198000000001","ownersteamid":"76561198000000002","vacbanned":false,"publisherbanned":true}}}`
	s := &stub{status: 200, body: ok}
	v := &TicketVerifier{Key: "KEY", AppID: "480", Identity: "fuelrivals", HTTP: s}
	got, err := v.VerifyTicket(context.Background(), "ABCDEF0123")
	if err != nil || got.SteamID != "76561198000000001" || got.OwnerSteamID != "76561198000000002" || !got.PublisherBanned || got.VACBanned {
		t.Fatalf("%+v %v", got, err)
	}
	if !strings.HasPrefix(s.url, "https://partner.steam-api.com/ISteamUserAuth/AuthenticateUserTicket/v1/?") ||
		!strings.Contains(s.url, "identity=fuelrivals") || !strings.Contains(s.url, "appid=480") {
		t.Errorf("url %s", s.url)
	}

	cases := map[string]struct {
		status int
		body   string
		want   error
	}{
		"steam error":  {200, `{"response":{"error":{"errorcode":3,"errordesc":"Invalid ticket"}}}`, ErrInvalidTicket},
		"not ok":       {200, `{"response":{"params":{"result":"Failure","steamid":"76561198000000001"}}}`, ErrInvalidTicket},
		"bad steamid":  {200, `{"response":{"params":{"result":"OK","steamid":"12"}}}`, ErrInvalidTicket},
		"no params":    {200, `{"response":{}}`, ErrInvalidTicket},
		"garbage":      {200, `<html>`, ErrUnavailable},
		"server error": {503, ``, ErrUnavailable},
		"key rejected": {403, `{}`, ErrUnavailable},
	}
	for name, c := range cases {
		v := &TicketVerifier{Key: "KEY", AppID: "480", Identity: "fuelrivals", HTTP: &stub{status: c.status, body: c.body}}
		if _, err := v.VerifyTicket(context.Background(), "ABCDEF0123"); !errors.Is(err, c.want) {
			t.Errorf("%s: got %v, want %v", name, err, c.want)
		}
	}
	for _, bad := range []string{"", "zz", "not hex", strings.Repeat("a", 5000)} {
		if _, err := v.VerifyTicket(context.Background(), bad); !errors.Is(err, ErrInvalidTicket) {
			t.Errorf("ticket %q: %v", bad, err)
		}
	}
}

func TestPersonaFetcher(t *testing.T) {
	body := `{"response":{"players":[{"steamid":"76561198000000001","personaname":"Speedy"}]}}`
	p := &PersonaFetcher{Key: "K", HTTP: &stub{status: 200, body: body}}
	name, err := p.PersonaName(context.Background(), "76561198000000001")
	if err != nil || name != "Speedy" {
		t.Fatalf("%q %v", name, err)
	}
	if _, err := p.PersonaName(context.Background(), "76561198000000009"); !errors.Is(err, ErrUnavailable) {
		t.Errorf("another steam id: %v", err)
	}
	if _, err := p.PersonaName(context.Background(), "abc"); err == nil {
		t.Error("bad id")
	}
	p = &PersonaFetcher{Key: "K", HTTP: &stub{status: 500}}
	if _, err := p.PersonaName(context.Background(), "76561198000000001"); !errors.Is(err, ErrUnavailable) {
		t.Errorf("%v", err)
	}
}

func TestFakeVerifier(t *testing.T) {
	var f FakeVerifier
	if v, err := f.VerifyTicket(context.Background(), "ok-76561198000000001"); err != nil || v.SteamID != "76561198000000001" {
		t.Fatal(v, err)
	}
	if v, _ := f.VerifyTicket(context.Background(), "banned-76561198000000001"); !v.PublisherBanned {
		t.Fatal("banned")
	}
	if _, err := f.VerifyTicket(context.Background(), "nope"); !errors.Is(err, ErrInvalidTicket) {
		t.Fatal(err)
	}
	if _, err := f.VerifyTicket(context.Background(), "down"); !errors.Is(err, ErrUnavailable) {
		t.Fatal(err)
	}
}
