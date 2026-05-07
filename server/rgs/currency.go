package rgs

import (
	"fmt"
	"strings"
)

// SupportedCurrencies is the default whitelist. Operators can override it
// via --supported-currencies; the CLI flag calls SetSupportedCurrencies.
//
// ISO 4217 fiat codes + common crypto tickers. All stored as uppercase.
var defaultSupportedCurrencies = []string{"EUR", "USD", "GBP", "BTC", "ETH", "USDT"}

// DefaultCurrency is the currency used when a caller omits the currency
// parameter. Configurable via --default-currency.
const DefaultCurrency = "EUR"

// ErrUnsupportedCurrency is returned when a currency code is not in the
// active whitelist.
var ErrUnsupportedCurrency = fmt.Errorf("unsupported currency")

// DecimalsForCurrency returns the number of sub-unit decimal places for a
// given currency code.
//
//   - Fiat (EUR, USD, GBP): 2 decimals — 1.00 = 100 units
//   - Crypto (BTC, ETH, USDT): 8 decimals — 1.00000000 = 100_000_000 units
//
// Unknown currencies default to 2 (standard fiat assumption). This never
// errors so callers can use it in display paths without extra error handling.
func DecimalsForCurrency(c string) int {
	switch strings.ToUpper(c) {
	case "BTC", "ETH", "USDT":
		return 8
	default:
		return 2
	}
}

// UnitsPerWhole returns 10^DecimalsForCurrency(c). Useful when converting
// between the human-readable float representation and the integer storage
// unit:
//
//	amountUnits = uint64(amountFloat * float64(UnitsPerWhole(currency)))
func UnitsPerWhole(c string) uint64 {
	d := DecimalsForCurrency(c)
	v := uint64(1)
	for i := 0; i < d; i++ {
		v *= 10
	}
	return v
}

// ValidateCurrency returns nil if c is in the active whitelist, otherwise
// ErrUnsupportedCurrency. The check is case-insensitive.
func ValidateCurrency(c string, supported []string) error {
	upper := strings.ToUpper(c)
	for _, s := range supported {
		if strings.ToUpper(s) == upper {
			return nil
		}
	}
	return fmt.Errorf("%w: %q (supported: %s)", ErrUnsupportedCurrency, c, strings.Join(supported, ","))
}

// NormalizeCurrency returns the canonical uppercase form of a currency code.
func NormalizeCurrency(c string) string {
	if c == "" {
		return DefaultCurrency
	}
	return strings.ToUpper(c)
}
