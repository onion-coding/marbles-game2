package rgs

import (
	"errors"
	"testing"
)

func TestDecimalsForCurrency(t *testing.T) {
	tests := []struct {
		currency string
		want     int
	}{
		{"EUR", 2},
		{"USD", 2},
		{"GBP", 2},
		{"eur", 2}, // lowercase normalised
		{"BTC", 8},
		{"ETH", 8},
		{"USDT", 8},
		{"btc", 8},
		{"XYZ", 2}, // unknown → fiat default
		{"", 2},
	}
	for _, tc := range tests {
		got := DecimalsForCurrency(tc.currency)
		if got != tc.want {
			t.Errorf("DecimalsForCurrency(%q) = %d, want %d", tc.currency, got, tc.want)
		}
	}
}

func TestUnitsPerWhole(t *testing.T) {
	if got := UnitsPerWhole("EUR"); got != 100 {
		t.Errorf("UnitsPerWhole(EUR) = %d, want 100", got)
	}
	if got := UnitsPerWhole("BTC"); got != 100_000_000 {
		t.Errorf("UnitsPerWhole(BTC) = %d, want 100_000_000", got)
	}
	if got := UnitsPerWhole("ETH"); got != 100_000_000 {
		t.Errorf("UnitsPerWhole(ETH) = %d, want 100_000_000", got)
	}
}

func TestValidateCurrency(t *testing.T) {
	supported := []string{"EUR", "USD", "BTC"}

	if err := ValidateCurrency("EUR", supported); err != nil {
		t.Errorf("EUR should be valid, got %v", err)
	}
	if err := ValidateCurrency("eur", supported); err != nil {
		t.Errorf("eur (lowercase) should be valid, got %v", err)
	}
	if err := ValidateCurrency("GBP", supported); err == nil {
		t.Error("GBP should be invalid when not in list, got nil")
	} else if !errors.Is(err, ErrUnsupportedCurrency) {
		t.Errorf("expected ErrUnsupportedCurrency, got %v", err)
	}
	if err := ValidateCurrency("", supported); !errors.Is(err, ErrUnsupportedCurrency) {
		t.Errorf("empty currency: expected ErrUnsupportedCurrency, got %v", err)
	}
}

func TestNormalizeCurrency(t *testing.T) {
	if got := NormalizeCurrency("eur"); got != "EUR" {
		t.Errorf("NormalizeCurrency(eur) = %q, want EUR", got)
	}
	if got := NormalizeCurrency(""); got != DefaultCurrency {
		t.Errorf("NormalizeCurrency('') = %q, want %q", got, DefaultCurrency)
	}
	if got := NormalizeCurrency("BTC"); got != "BTC" {
		t.Errorf("NormalizeCurrency(BTC) = %q, want BTC", got)
	}
}
