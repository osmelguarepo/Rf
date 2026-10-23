package steam

import (
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
)

// The only places this code talks to for OpenID (SPEC_ONLINE 16.3). They are constants on purpose: nothing in a
// request can change where the verification is posted.
const (
	OpenIDEndpoint = "https://steamcommunity.com/openid/login"
	openIDNS       = "http://specs.openid.net/auth/2.0"
	identSelect    = "http://specs.openid.net/auth/2.0/identifier_select"
	claimedPrefix  = "https://steamcommunity.com/openid/id/"

	// StateCookie is the cookie that binds the login to the browser that started it. The __Host- prefix makes browsers
	// require Secure, Path=/ and no Domain.
	StateCookie = "__Host-fr_oid"

	stateTTL     = 10 * time.Minute
	nonceMaxAge  = 5 * time.Minute
	nonceMaxSkew = 1 * time.Minute
)

// OpenID error codes, one per check, so tests (and logs) can tell which one refused a response.
const (
	ErrCodeMode          = "mode"
	ErrCodeNS            = "ns"
	ErrCodeDuplicate     = "duplicate_param"
	ErrCodeOPEndpoint    = "op_endpoint"
	ErrCodeReturnTo      = "return_to"
	ErrCodeState         = "state"
	ErrCodeCookie        = "cookie"
	ErrCodeIdentity      = "claimed_id_identity"
	ErrCodeClaimedFormat = "claimed_id_format"
	ErrCodeSigned        = "signed_fields"
	ErrCodeNonceFormat   = "nonce_format"
	ErrCodeNonceStale    = "nonce_stale"
	ErrCodeNonceReplay   = "nonce_replay"
	ErrCodeAssertion     = "assertion_rejected"
	ErrCodeUpstream      = "upstream"
)

// OpenIDError is a refused login. Code is one of the ErrCode constants.
type OpenIDError struct {
	Code   string
	Detail string
}

func (e *OpenIDError) Error() string { return "openid: " + e.Code + ": " + e.Detail }

func fail(code, format string, a ...any) error {
	return &OpenIDError{Code: code, Detail: fmt.Sprintf(format, a...)}
}

// NonceStore remembers response nonces so each is used once. Fresh returns false if the nonce was already seen.
type NonceStore interface {
	Fresh(ctx context.Context, nonce string, seenAt time.Time) (bool, error)
}

// OpenID is the Steam OpenID 2.0 relying party.
type OpenID struct {
	// ReturnURL is the public URL of the return handler without query, e.g. https://play.example.com/api/auth/openid/return.
	ReturnURL string
	// Realm is the origin the user is asked to trust, e.g. https://play.example.com.
	Realm string
	// StateSecret signs the state values (at least 32 bytes).
	StateSecret []byte
	HTTP        Doer
	Nonces      NonceStore
	Now         func() time.Time
}

func (o *OpenID) now() time.Time {
	if o.Now != nil {
		return o.Now()
	}
	return time.Now()
}

func (o *OpenID) sign(body string) string {
	m := hmac.New(sha256.New, o.StateSecret)
	m.Write([]byte("fuel-rivals/openid-state/v1\x00" + body))
	return base64.RawURLEncoding.EncodeToString(m.Sum(nil))
}

// NewState returns a fresh state value: random, expiring and signed. It is both put in return_to and in the cookie.
func (o *OpenID) NewState() (string, error) {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		return "", err
	}
	body := base64.RawURLEncoding.EncodeToString(b[:]) + "." + strconv.FormatInt(o.now().Add(stateTTL).Unix(), 10)
	return body + "." + o.sign(body), nil
}

func (o *OpenID) checkState(state string) error {
	i := strings.LastIndexByte(state, '.')
	if i < 0 {
		return fail(ErrCodeState, "malformed")
	}
	body, tag := state[:i], state[i+1:]
	if subtle.ConstantTimeCompare([]byte(tag), []byte(o.sign(body))) != 1 {
		return fail(ErrCodeState, "bad signature")
	}
	parts := strings.Split(body, ".")
	if len(parts) != 2 {
		return fail(ErrCodeState, "malformed")
	}
	exp, err := strconv.ParseInt(parts[1], 10, 64)
	if err != nil || o.now().Unix() > exp {
		return fail(ErrCodeState, "expired")
	}
	return nil
}

// ReturnTo is the exact return_to value for a state.
func (o *OpenID) ReturnTo(state string) string {
	return o.ReturnURL + "?state=" + url.QueryEscape(state)
}

// StartURL is where the browser is sent to log in at Steam, for a state from NewState.
func (o *OpenID) StartURL(state string) string {
	q := url.Values{
		"openid.ns":         {openIDNS},
		"openid.mode":       {"checkid_setup"},
		"openid.return_to":  {o.ReturnTo(state)},
		"openid.realm":      {o.Realm},
		"openid.identity":   {identSelect},
		"openid.claimed_id": {identSelect},
	}
	return OpenIDEndpoint + "?" + q.Encode()
}

// Required fields of openid.signed.
var requiredSigned = []string{"op_endpoint", "claimed_id", "identity", "return_to", "response_nonce", "assoc_handle"}

// Verify checks the response Steam sent the browser back with (the query of the return URL) and the value of the state
// cookie of that browser. It returns the SteamID only if every check passes:
//
//  1. no openid.* parameter appears twice; mode is id_res and ns is OpenID 2.0;
//  2. op_endpoint is exactly Steam's endpoint;
//  3. return_to is exactly ours with the state, the state is signed by us, unexpired, and equals the cookie;
//  4. claimed_id equals identity and has the form https://steamcommunity.com/openid/id/<17 digits>;
//  5. openid.signed lists op_endpoint, claimed_id, identity, return_to, response_nonce and assoc_handle;
//  6. response_nonce is under 5 minutes old (not from the future) and was not used before;
//  7. a check_authentication POST to the hard-coded Steam URL answers is_valid:true.
func (o *OpenID) Verify(ctx context.Context, q url.Values, cookieState string) (string, error) {
	for k, v := range q {
		if strings.HasPrefix(k, "openid.") && len(v) != 1 {
			return "", fail(ErrCodeDuplicate, "%s appears %d times", k, len(v))
		}
	}
	get := func(k string) string { return q.Get("openid." + k) }

	if get("mode") != "id_res" {
		return "", fail(ErrCodeMode, "mode %q", get("mode"))
	}
	if get("ns") != openIDNS {
		return "", fail(ErrCodeNS, "ns %q", get("ns"))
	}
	if get("op_endpoint") != OpenIDEndpoint {
		return "", fail(ErrCodeOPEndpoint, "op_endpoint %q", get("op_endpoint"))
	}
	state := q.Get("state")
	if cookieState == "" {
		return "", fail(ErrCodeCookie, "missing")
	}
	if state == "" || subtle.ConstantTimeCompare([]byte(state), []byte(cookieState)) != 1 {
		return "", fail(ErrCodeCookie, "state does not match the cookie")
	}
	if err := o.checkState(state); err != nil {
		return "", err
	}
	if get("return_to") != o.ReturnTo(state) {
		return "", fail(ErrCodeReturnTo, "return_to %q", get("return_to"))
	}
	claimed, identity := get("claimed_id"), get("identity")
	if claimed == "" || claimed != identity {
		return "", fail(ErrCodeIdentity, "claimed_id and identity differ")
	}
	if !strings.HasPrefix(claimed, claimedPrefix) || !SteamIDRe.MatchString(claimed[len(claimedPrefix):]) {
		return "", fail(ErrCodeClaimedFormat, "claimed_id %q", claimed)
	}
	steamID := claimed[len(claimedPrefix):]

	signed := map[string]bool{}
	for _, f := range strings.Split(get("signed"), ",") {
		signed[f] = true
	}
	for _, f := range requiredSigned {
		if !signed[f] {
			return "", fail(ErrCodeSigned, "%s is not signed", f)
		}
	}
	if get("sig") == "" {
		return "", fail(ErrCodeSigned, "no signature")
	}

	nonce := get("response_nonce")
	if len(nonce) < 20 || len(nonce) > 255 {
		return "", fail(ErrCodeNonceFormat, "length %d", len(nonce))
	}
	issued, err := time.Parse("2006-01-02T15:04:05Z", nonce[:20])
	if err != nil {
		return "", fail(ErrCodeNonceFormat, "timestamp")
	}
	age := o.now().Sub(issued)
	if age >= nonceMaxAge || age < -nonceMaxSkew {
		return "", fail(ErrCodeNonceStale, "age %s", age)
	}
	fresh, err := o.Nonces.Fresh(ctx, nonce, o.now())
	if err != nil {
		return "", fail(ErrCodeUpstream, "nonce store: %v", err)
	}
	if !fresh {
		return "", fail(ErrCodeNonceReplay, "nonce already used")
	}

	if err := o.checkAuthentication(ctx, q); err != nil {
		return "", err
	}
	return steamID, nil
}

// checkAuthentication asks Steam whether it issued the assertion. The URL is the constant OpenIDEndpoint.
func (o *OpenID) checkAuthentication(ctx context.Context, q url.Values) error {
	form := url.Values{}
	for k, v := range q {
		if strings.HasPrefix(k, "openid.") && k != "openid.mode" {
			form[k] = v
		}
	}
	form.Set("openid.mode", "check_authentication")
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, OpenIDEndpoint, strings.NewReader(form.Encode()))
	if err != nil {
		return fail(ErrCodeUpstream, "request")
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	client := o.HTTP
	if client == nil {
		client = NewHTTPClient()
	}
	resp, err := client.Do(req)
	if err != nil {
		return fail(ErrCodeUpstream, "check_authentication failed")
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, 16<<10))
	if err != nil || resp.StatusCode != http.StatusOK {
		return fail(ErrCodeUpstream, "check_authentication status %d", resp.StatusCode)
	}
	valid := false
	for _, line := range strings.Split(string(body), "\n") {
		if strings.TrimSpace(line) == "is_valid:true" {
			valid = true
		}
	}
	if !valid {
		return fail(ErrCodeAssertion, "Steam says the assertion is not valid")
	}
	return nil
}
