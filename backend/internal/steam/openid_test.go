package steam

import (
	"context"
	"errors"
	"io"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"testing"
	"time"
)

type memNonces struct {
	mu   sync.Mutex
	seen map[string]bool
}

func (m *memNonces) Fresh(_ context.Context, n string, _ time.Time) (bool, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.seen == nil {
		m.seen = map[string]bool{}
	}
	if m.seen[n] {
		return false, nil
	}
	m.seen[n] = true
	return true, nil
}

// steamDouble plays steamcommunity.com: it records every request and answers check_authentication.
type steamDouble struct {
	requests []*http.Request
	forms    []url.Values
	answer   string
	status   int
	err      error
}

func (s *steamDouble) Do(r *http.Request) (*http.Response, error) {
	s.requests = append(s.requests, r)
	b, _ := io.ReadAll(r.Body)
	f, _ := url.ParseQuery(string(b))
	s.forms = append(s.forms, f)
	if s.err != nil {
		return nil, s.err
	}
	st := s.status
	if st == 0 {
		st = 200
	}
	return &http.Response{StatusCode: st, Body: io.NopCloser(strings.NewReader(s.answer))}, nil
}

var fixedNow = time.Date(2026, 10, 23, 12, 0, 0, 0, time.UTC)

const testSteamID = "76561198000000001"

type fixture struct {
	o     *OpenID
	steam *steamDouble
	state string
	query url.Values
}

func newFixture(t *testing.T) *fixture {
	t.Helper()
	steam := &steamDouble{answer: "ns:http://specs.openid.net/auth/2.0\nis_valid:true\n"}
	o := &OpenID{
		ReturnURL:   "https://play.example.com/api/auth/openid/return",
		Realm:       "https://play.example.com",
		StateSecret: []byte("0123456789abcdef0123456789abcdef"),
		HTTP:        steam,
		Nonces:      &memNonces{},
		Now:         func() time.Time { return fixedNow },
	}
	state, err := o.NewState()
	if err != nil {
		t.Fatal(err)
	}
	q := url.Values{
		"state":                 {state},
		"openid.ns":             {openIDNS},
		"openid.mode":           {"id_res"},
		"openid.op_endpoint":    {OpenIDEndpoint},
		"openid.claimed_id":     {claimedPrefix + testSteamID},
		"openid.identity":       {claimedPrefix + testSteamID},
		"openid.return_to":      {o.ReturnTo(state)},
		"openid.response_nonce": {"2026-10-23T11:59:30Zabcdefg"},
		"openid.assoc_handle":   {"1234567890"},
		"openid.signed":         {"signed,op_endpoint,claimed_id,identity,return_to,response_nonce,assoc_handle"},
		"openid.sig":            {"c2lnbmF0dXJl"},
	}
	return &fixture{o: o, steam: steam, state: state, query: q}
}

func (f *fixture) verify(cookie string) (string, error) {
	return f.o.Verify(context.Background(), f.query, cookie)
}

func wantCode(t *testing.T, err error, code string) {
	t.Helper()
	var oe *OpenIDError
	if !errors.As(err, &oe) || oe.Code != code {
		t.Fatalf("want error code %q, got %v", code, err)
	}
}

func TestValidLoginReturnsTheSteamID(t *testing.T) {
	f := newFixture(t)
	id, err := f.verify(f.state)
	if err != nil || id != testSteamID {
		t.Fatalf("%q %v", id, err)
	}
	// Exactly one request, a POST to the hard-coded URL, with the assertion and check_authentication.
	if len(f.steam.requests) != 1 {
		t.Fatalf("%d requests", len(f.steam.requests))
	}
	r := f.steam.requests[0]
	if r.Method != http.MethodPost || r.URL.String() != "https://steamcommunity.com/openid/login" {
		t.Errorf("request went to %s %s", r.Method, r.URL)
	}
	form := f.steam.forms[0]
	if form.Get("openid.mode") != "check_authentication" || form.Get("openid.sig") != "c2lnbmF0dXJl" ||
		form.Get("openid.claimed_id") != claimedPrefix+testSteamID || form.Get("state") != "" {
		t.Errorf("form %v", form)
	}
}

func TestStartURL(t *testing.T) {
	f := newFixture(t)
	u, err := url.Parse(f.o.StartURL(f.state))
	if err != nil || u.Scheme+"://"+u.Host+u.Path != OpenIDEndpoint {
		t.Fatalf("%v %v", u, err)
	}
	q := u.Query()
	if q.Get("openid.mode") != "checkid_setup" || q.Get("openid.return_to") != f.o.ReturnTo(f.state) ||
		q.Get("openid.realm") != "https://play.example.com" || q.Get("openid.identity") != identSelect {
		t.Errorf("%v", q)
	}
}

func TestEveryCheckRefuses(t *testing.T) {
	type tweak func(f *fixture) string // returns the cookie to use
	same := func(f *fixture) string { return f.state }
	set := func(k, v string) tweak {
		return func(f *fixture) string { f.query.Set(k, v); return f.state }
	}
	cases := []struct {
		name string
		code string
		fn   tweak
	}{
		{"mode is not id_res", ErrCodeMode, set("openid.mode", "cancel")},
		{"missing mode", ErrCodeMode, func(f *fixture) string { f.query.Del("openid.mode"); return f.state }},
		{"wrong ns", ErrCodeNS, set("openid.ns", "http://specs.openid.net/auth/1.1")},
		{"op_endpoint of another site", ErrCodeOPEndpoint, set("openid.op_endpoint", "https://evil.example/openid/login")},
		{"op_endpoint over http", ErrCodeOPEndpoint, set("openid.op_endpoint", "http://steamcommunity.com/openid/login")},
		{"op_endpoint with a suffix", ErrCodeOPEndpoint, set("openid.op_endpoint", OpenIDEndpoint+"/")},
		{"no cookie", ErrCodeCookie, func(f *fixture) string { return "" }},
		{"cookie of another login", ErrCodeCookie, func(f *fixture) string {
			other, _ := f.o.NewState()
			return other
		}},
		{"no state in the query", ErrCodeCookie, func(f *fixture) string { f.query.Del("state"); return f.state }},
		{"state not signed by us", ErrCodeState, func(f *fixture) string {
			f.query.Set("state", "AAAA.9999999999.AAAA")
			return "AAAA.9999999999.AAAA"
		}},
		{"state expired", ErrCodeState, func(f *fixture) string {
			f.o.Now = func() time.Time { return fixedNow.Add(11 * time.Minute) }
			return f.state
		}},
		{"return_to of another path", ErrCodeReturnTo, func(f *fixture) string {
			f.query.Set("openid.return_to", "https://play.example.com/api/other?state="+url.QueryEscape(f.state))
			return f.state
		}},
		{"return_to without state", ErrCodeReturnTo, set("openid.return_to", "https://play.example.com/api/auth/openid/return")},
		{"return_to of another host", ErrCodeReturnTo, func(f *fixture) string {
			f.query.Set("openid.return_to", "https://evil.example/api/auth/openid/return?state="+url.QueryEscape(f.state))
			return f.state
		}},
		{"claimed_id differs from identity", ErrCodeIdentity, set("openid.identity", claimedPrefix+"76561198000000002")},
		{"claimed_id missing", ErrCodeIdentity, func(f *fixture) string {
			f.query.Del("openid.claimed_id")
			f.query.Del("openid.identity")
			return f.state
		}},
		{"claimed_id on another host", ErrCodeClaimedFormat, func(f *fixture) string {
			f.query.Set("openid.claimed_id", "https://evil.example/openid/id/"+testSteamID)
			f.query.Set("openid.identity", "https://evil.example/openid/id/"+testSteamID)
			return f.state
		}},
		{"claimed_id with 16 digits", ErrCodeClaimedFormat, func(f *fixture) string {
			f.query.Set("openid.claimed_id", claimedPrefix+"7656119800000000")
			f.query.Set("openid.identity", claimedPrefix+"7656119800000000")
			return f.state
		}},
		{"claimed_id with trailing text", ErrCodeClaimedFormat, func(f *fixture) string {
			f.query.Set("openid.claimed_id", claimedPrefix+testSteamID+"/x")
			f.query.Set("openid.identity", claimedPrefix+testSteamID+"/x")
			return f.state
		}},
		{"claimed_id not signed", ErrCodeSigned, set("openid.signed", "signed,op_endpoint,identity,return_to,response_nonce,assoc_handle")},
		{"identity not signed", ErrCodeSigned, set("openid.signed", "signed,op_endpoint,claimed_id,return_to,response_nonce,assoc_handle")},
		{"return_to not signed", ErrCodeSigned, set("openid.signed", "signed,op_endpoint,claimed_id,identity,response_nonce,assoc_handle")},
		{"response_nonce not signed", ErrCodeSigned, set("openid.signed", "signed,op_endpoint,claimed_id,identity,return_to,assoc_handle")},
		{"op_endpoint not signed", ErrCodeSigned, set("openid.signed", "signed,claimed_id,identity,return_to,response_nonce,assoc_handle")},
		{"no signature", ErrCodeSigned, func(f *fixture) string { f.query.Del("openid.sig"); return f.state }},
		{"nonce too short", ErrCodeNonceFormat, set("openid.response_nonce", "2026")},
		{"nonce without timestamp", ErrCodeNonceFormat, set("openid.response_nonce", "not-a-timestamp-at-all-xyz")},
		{"nonce 5 minutes old", ErrCodeNonceStale, set("openid.response_nonce", "2026-10-23T11:55:00Zabc")},
		{"nonce from the future", ErrCodeNonceStale, set("openid.response_nonce", "2026-10-23T12:05:00Zabc")},
		{"steam says not valid", ErrCodeAssertion, func(f *fixture) string { f.steam.answer = "is_valid:false\n"; return f.state }},
		{"steam answers garbage", ErrCodeAssertion, func(f *fixture) string { f.steam.answer = "<html>"; return f.state }},
		{"steam answers 500", ErrCodeUpstream, func(f *fixture) string { f.steam.status = 500; return f.state }},
		{"steam unreachable", ErrCodeUpstream, func(f *fixture) string { f.steam.err = errors.New("boom"); return f.state }},
		{"duplicate claimed_id", ErrCodeDuplicate, func(f *fixture) string {
			f.query.Add("openid.claimed_id", claimedPrefix+"76561198000000002")
			return f.state
		}},
		{"duplicate signed", ErrCodeDuplicate, func(f *fixture) string {
			f.query.Add("openid.signed", "signed")
			return f.state
		}},
	}
	_ = same
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			f := newFixture(t)
			cookie := tc.fn(f)
			id, err := f.verify(cookie)
			wantCode(t, err, tc.code)
			if id != "" {
				t.Errorf("returned %q with an error", id)
			}
		})
	}
}

func TestNoNetworkBeforeTheLocalChecksPass(t *testing.T) {
	f := newFixture(t)
	f.query.Set("openid.op_endpoint", "https://evil.example/")
	_, _ = f.verify(f.state)
	if len(f.steam.requests) != 0 {
		t.Fatal("a refused response must not cause a request to Steam")
	}
}

func TestNonceIsOneTime(t *testing.T) {
	f := newFixture(t)
	if _, err := f.verify(f.state); err != nil {
		t.Fatal(err)
	}
	_, err := f.verify(f.state)
	wantCode(t, err, ErrCodeNonceReplay)
	if len(f.steam.requests) != 1 {
		t.Errorf("the replay must be stopped before asking Steam: %d requests", len(f.steam.requests))
	}
}

func TestNonceJustUnderFiveMinutesIsAccepted(t *testing.T) {
	f := newFixture(t)
	f.query.Set("openid.response_nonce", "2026-10-23T11:55:01Zabc")
	if _, err := f.verify(f.state); err != nil {
		t.Fatal(err)
	}
}
