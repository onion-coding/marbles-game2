package rgs

// HTTPWallet is a Wallet implementation that speaks a generic REST protocol
// to an operator wallet service. It is the production replacement for
// MockWallet — wire it up in cmd/rgsd via --wallet-mode=http.
//
// Protocol (all calls are POST to avoid GET-body portability issues):
//
//	POST /wallet/balance  {player_id}              → {balance:uint64}
//	POST /wallet/debit    {player_id, amount, tx_id} → {balance:uint64}
//	POST /wallet/credit   {player_id, amount, tx_id} → {balance:uint64}
//
// Error contract:
//
//   - HTTP 402 → ErrInsufficientFunds
//   - HTTP 404 → ErrUnknownPlayer
//   - HTTP 409 → idempotent repeat (treated as success, balance returned)
//   - HTTP 5xx / network error → transient; retried with exponential backoff
//
// HMAC signing (when HMACSecret is non-nil):
//
//	X-Timestamp: <unix seconds, decimal>
//	X-Signature: hex(HMAC-SHA256(method+"\n"+path+"\n"+timestamp+"\n"+body))
//
// Idempotency header (when IdempotencyKeys is true):
//
//	Idempotency-Key: <tx_id>

import (
	"bytes"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
	"time"
)

// HTTPWalletConfig holds all knobs for the generic wallet HTTP client.
type HTTPWalletConfig struct {
	// BaseURL is the scheme+host (no trailing slash) of the operator wallet
	// service, e.g. "https://wallet.example.com".
	BaseURL string

	// HMACSecret, if non-nil, is used to sign every outbound request with
	// HMAC-SHA256. The signing scheme is identical to the server-side
	// middleware in server/middleware so operators can reuse the same
	// verification logic on their end.
	HMACSecret []byte

	// Timeout is the per-request HTTP timeout. Defaults to 10 s.
	Timeout time.Duration

	// MaxRetries is the number of additional attempts after the first on
	// 5xx / network errors. 0 means try once; 3 is a reasonable default.
	MaxRetries int

	// IdempotencyKeys, when true, adds an "Idempotency-Key: <tx_id>"
	// header to debit and credit requests so the operator's wallet can
	// deduplicate retries at the HTTP layer rather than relying purely on
	// the tx_id in the JSON body.
	IdempotencyKeys bool
}

// HTTPWallet implements the Wallet interface by calling the generic REST
// wallet protocol. All methods are safe for concurrent calls — there is no
// shared mutable state beyond the immutable config and the stdlib http.Client
// which is safe for concurrent use by design.
type HTTPWallet struct {
	cfg    HTTPWalletConfig
	client *http.Client
}

// NewHTTPWallet constructs an HTTPWallet from the given config. If
// cfg.Timeout is 0, a 10-second default is applied. The caller is
// responsible for validating that cfg.BaseURL is non-empty before
// passing it here.
func NewHTTPWallet(cfg HTTPWalletConfig) *HTTPWallet {
	if cfg.Timeout == 0 {
		cfg.Timeout = 10 * time.Second
	}
	return &HTTPWallet{
		cfg:    cfg,
		client: &http.Client{Timeout: cfg.Timeout},
	}
}

// walletRequest is the generic request body for all three wallet endpoints.
// Fields are omitempty so Balance requests (which don't carry amount/tx_id)
// produce a minimal payload.
type walletRequest struct {
	PlayerID string `json:"player_id"`
	Amount   uint64 `json:"amount,omitempty"`
	Currency string `json:"currency,omitempty"`
	TxID     string `json:"tx_id,omitempty"`
}

// walletResponse is the generic success body. Only Balance is guaranteed;
// debit/credit also return it but we only use Balance for callers of
// Debit/Credit (they don't need post-op balance).
type walletResponse struct {
	Balance uint64 `json:"balance"`
}

// walletErrorResponse is the body returned on 4xx.
type walletErrorResponse struct {
	Error string `json:"error"`
}

// Balance implements Wallet.
func (w *HTTPWallet) Balance(playerID, currency string) (uint64, error) {
	if playerID == "" {
		return 0, ErrUnknownPlayer
	}
	cur := NormalizeCurrency(currency)
	resp, err := w.call("POST", "/wallet/balance", "", walletRequest{PlayerID: playerID, Currency: cur})
	if err != nil {
		return 0, err
	}
	return resp.Balance, nil
}

// Debit implements Wallet.
func (w *HTTPWallet) Debit(playerID string, amount uint64, currency, txID string) error {
	if playerID == "" {
		return ErrUnknownPlayer
	}
	if amount == 0 {
		return fmt.Errorf("rgs: HTTPWallet.Debit: amount must be > 0")
	}
	if txID == "" {
		return fmt.Errorf("rgs: HTTPWallet.Debit: txID must be non-empty")
	}
	_, err := w.call("POST", "/wallet/debit", txID, walletRequest{
		PlayerID: playerID,
		Amount:   amount,
		Currency: NormalizeCurrency(currency),
		TxID:     txID,
	})
	return err
}

// Credit implements Wallet.
func (w *HTTPWallet) Credit(playerID string, amount uint64, currency, txID string) error {
	if playerID == "" {
		return ErrUnknownPlayer
	}
	if amount == 0 {
		return fmt.Errorf("rgs: HTTPWallet.Credit: amount must be > 0")
	}
	if txID == "" {
		return fmt.Errorf("rgs: HTTPWallet.Credit: txID must be non-empty")
	}
	_, err := w.call("POST", "/wallet/credit", txID, walletRequest{
		PlayerID: playerID,
		Amount:   amount,
		Currency: NormalizeCurrency(currency),
		TxID:     txID,
	})
	return err
}

// Snapshot implements Wallet. HTTPWallet is a pass-through client — it has
// no local ledger to snapshot. Returns an empty map. Callers that need a
// full ledger snapshot should query the operator wallet service directly.
func (w *HTTPWallet) Snapshot() map[string]map[string]uint64 {
	return map[string]map[string]uint64{}
}

// Restore implements Wallet. HTTPWallet is a pass-through client — it has
// no local ledger to restore. This is a no-op; callers that need to restore
// state should seed the operator wallet service directly.
func (w *HTTPWallet) Restore(_ map[string]map[string]uint64) {}

// call executes a single wallet RPC with retries and HMAC signing. txID is
// the idempotency key (empty for Balance calls). The returned walletResponse
// is only populated on success (nil error).
func (w *HTTPWallet) call(method, path, txID string, payload walletRequest) (*walletResponse, error) {
	bodyBytes, err := json.Marshal(payload)
	if err != nil {
		return nil, fmt.Errorf("rgs: HTTPWallet: marshal request: %w", err)
	}

	url := w.cfg.BaseURL + path

	var lastErr error
	maxAttempts := w.cfg.MaxRetries + 1
	for attempt := 0; attempt < maxAttempts; attempt++ {
		if attempt > 0 {
			// Exponential backoff: 100ms, 200ms, 400ms, …
			sleep := time.Duration(100*(1<<uint(attempt-1))) * time.Millisecond
			time.Sleep(sleep)
		}

		resp, err := w.doRequest(method, url, path, txID, bodyBytes)
		if err != nil {
			// Network-level error — retry.
			lastErr = fmt.Errorf("rgs: HTTPWallet %s %s: %w", method, path, err)
			continue
		}

		switch {
		case resp.statusCode == http.StatusOK:
			return &walletResponse{Balance: resp.balance}, nil

		case resp.statusCode == http.StatusConflict:
			// 409 = idempotent replay acknowledged by the operator — treat
			// as success. Balance in the response body may not be populated
			// for all operators, so we return 0; callers of Debit/Credit
			// don't use the returned balance.
			return &walletResponse{Balance: resp.balance}, nil

		case resp.statusCode == http.StatusPaymentRequired:
			return nil, fmt.Errorf("%w: %s", ErrInsufficientFunds, resp.errMsg)

		case resp.statusCode == http.StatusNotFound:
			return nil, fmt.Errorf("%w: %s", ErrUnknownPlayer, resp.errMsg)

		case resp.statusCode >= 500:
			// Transient server error — eligible for retry.
			lastErr = fmt.Errorf("rgs: HTTPWallet %s %s: server error %d: %s",
				method, path, resp.statusCode, resp.errMsg)
			continue

		default:
			// 400/401/403/… — client-side error, do not retry.
			return nil, fmt.Errorf("rgs: HTTPWallet %s %s: status %d: %s",
				method, path, resp.statusCode, resp.errMsg)
		}
	}

	return nil, lastErr
}

// rawResponse is the minimal decoded HTTP response.
type rawResponse struct {
	statusCode int
	balance    uint64
	errMsg     string
}

func (w *HTTPWallet) doRequest(method, url, path, txID string, body []byte) (rawResponse, error) {
	ts := strconv.FormatInt(time.Now().Unix(), 10)

	req, err := http.NewRequest(method, url, bytes.NewReader(body))
	if err != nil {
		return rawResponse{}, err
	}
	req.Header.Set("Content-Type", "application/json")

	if w.cfg.IdempotencyKeys && txID != "" {
		req.Header.Set("Idempotency-Key", txID)
	}
	if len(w.cfg.HMACSecret) > 0 {
		req.Header.Set("X-Timestamp", ts)
		req.Header.Set("X-Signature", computeWalletSignature(w.cfg.HMACSecret, method, path, ts, body))
	}

	httpResp, err := w.client.Do(req)
	if err != nil {
		return rawResponse{}, err
	}
	defer httpResp.Body.Close()

	respBody, err := io.ReadAll(httpResp.Body)
	if err != nil {
		return rawResponse{}, fmt.Errorf("read response body: %w", err)
	}

	raw := rawResponse{statusCode: httpResp.StatusCode}

	if httpResp.StatusCode == http.StatusOK || httpResp.StatusCode == http.StatusConflict {
		var ok walletResponse
		if jerr := json.Unmarshal(respBody, &ok); jerr == nil {
			raw.balance = ok.Balance
		}
	} else {
		var errBody walletErrorResponse
		if jerr := json.Unmarshal(respBody, &errBody); jerr == nil {
			raw.errMsg = errBody.Error
		} else {
			raw.errMsg = strings.TrimSpace(string(respBody))
		}
	}

	return raw, nil
}

// computeWalletSignature signs outbound wallet requests with the same
// HMAC-SHA256 scheme used by the server-side middleware — operators who
// reuse the middleware verification logic will accept these signatures
// without any adaptor code.
//
// Message = method + "\n" + path + "\n" + timestamp + "\n" + body
func computeWalletSignature(secret []byte, method, path, timestamp string, body []byte) string {
	mac := hmac.New(sha256.New, secret)
	_, _ = io.WriteString(mac, method)
	_, _ = io.WriteString(mac, "\n")
	_, _ = io.WriteString(mac, path)
	_, _ = io.WriteString(mac, "\n")
	_, _ = io.WriteString(mac, timestamp)
	_, _ = io.WriteString(mac, "\n")
	_, _ = mac.Write(body)
	return hex.EncodeToString(mac.Sum(nil))
}
