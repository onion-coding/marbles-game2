package rtp

import (
	"errors"
	"math"
	"testing"
)

func TestSettleStandardRTP(t *testing.T) {
	// 5 players × 20 each → pot 100. RTP 95% → prize 95, house 5.
	buyIns := []uint64{20, 20, 20, 20, 20}
	prize, house, err := Settle(Config{RTPBasisPoints: 9500}, buyIns, 2)
	if err != nil {
		t.Fatalf("Settle: %v", err)
	}
	if prize != 95 || house != 5 {
		t.Errorf("prize=%d house=%d want prize=95 house=5", prize, house)
	}
	if prize+house != 100 {
		t.Errorf("pot invariant broken: prize+house=%d want 100", prize+house)
	}
}

func TestSettle100RTPMeansNoHouseCut(t *testing.T) {
	prize, house, err := Settle(Config{RTPBasisPoints: BasisPoints}, []uint64{100}, 0)
	if err != nil {
		t.Fatalf("Settle: %v", err)
	}
	if prize != 100 || house != 0 {
		t.Errorf("100%% RTP: prize=%d house=%d want 100/0", prize, house)
	}
}

func TestSettle0RTPMeansAllHouse(t *testing.T) {
	prize, house, err := Settle(Config{RTPBasisPoints: 0}, []uint64{100}, 0)
	if err != nil {
		t.Fatalf("Settle: %v", err)
	}
	if prize != 0 || house != 100 {
		t.Errorf("0%% RTP: prize=%d house=%d want 0/100", prize, house)
	}
}

func TestSettleRoundingGoesToHouse(t *testing.T) {
	// 97.50% RTP on a pot of 3 → prize floor(3 * 9750 / 10000) = floor(2.925) = 2, house = 1.
	prize, house, err := Settle(Config{RTPBasisPoints: 9750}, []uint64{1, 1, 1}, 0)
	if err != nil {
		t.Fatalf("Settle: %v", err)
	}
	if prize != 2 || house != 1 {
		t.Errorf("rounding: prize=%d house=%d want 2/1", prize, house)
	}
	// No pennies get lost.
	if prize+house != 3 {
		t.Errorf("pot invariant broken: %d+%d != 3", prize, house)
	}
}

func TestSettleFreeRollParticipant(t *testing.T) {
	// Zero-buy-in player is allowed — they're a legitimate participant.
	// Pot stays at 200; winnerIndex points to the freeroll but still gets the prize.
	buyIns := []uint64{0, 100, 100}
	prize, house, err := Settle(Config{RTPBasisPoints: 9500}, buyIns, 0)
	if err != nil {
		t.Fatalf("Settle: %v", err)
	}
	if prize != 190 || house != 10 {
		t.Errorf("freeroll: prize=%d house=%d want 190/10", prize, house)
	}
}

func TestSettleRejectsBadInputs(t *testing.T) {
	if _, _, err := Settle(Config{RTPBasisPoints: 9500}, nil, 0); !errors.Is(err, ErrNoBuyIns) {
		t.Errorf("empty buyIns: got %v want ErrNoBuyIns", err)
	}
	if _, _, err := Settle(Config{RTPBasisPoints: 9500}, []uint64{1}, -1); !errors.Is(err, ErrWinnerIndex) {
		t.Errorf("negative winner: got %v want ErrWinnerIndex", err)
	}
	if _, _, err := Settle(Config{RTPBasisPoints: 9500}, []uint64{1}, 5); !errors.Is(err, ErrWinnerIndex) {
		t.Errorf("winner out of range: got %v want ErrWinnerIndex", err)
	}
	if _, _, err := Settle(Config{RTPBasisPoints: 10_001}, []uint64{1}, 0); !errors.Is(err, ErrRTPOutOfRange) {
		t.Errorf("RTP > 100%%: got %v want ErrRTPOutOfRange", err)
	}
}

func TestSettleOverflowGuards(t *testing.T) {
	// Two huge buy-ins that would overflow when summed.
	if _, _, err := Settle(Config{RTPBasisPoints: 9500}, []uint64{math.MaxUint64, 1}, 0); !errors.Is(err, ErrPotOverflow) {
		t.Errorf("pot overflow: got %v want ErrPotOverflow", err)
	}

	// Pot that would overflow when multiplied by RTP bps.
	big := uint64(math.MaxUint64/9500) + 1
	if _, _, err := Settle(Config{RTPBasisPoints: 9500}, []uint64{big}, 0); !errors.Is(err, ErrPrizeOverflow) {
		t.Errorf("prize overflow: got %v want ErrPrizeOverflow", err)
	}
}

// Fuzz: for any valid combination, invariant prize + house == total must hold.
func TestSettleInvariantHolds(t *testing.T) {
	cases := []struct {
		rtp    uint32
		buyIns []uint64
		winner int
	}{
		{9500, []uint64{10, 20, 30, 40}, 0},
		{9800, []uint64{1, 2, 3}, 2},
		{10000, []uint64{7, 11, 13, 17, 19}, 3},
		{5000, []uint64{100, 100}, 1},
		{9999, []uint64{1_000_000}, 0},
	}
	for _, c := range cases {
		prize, house, err := Settle(Config{RTPBasisPoints: c.rtp}, c.buyIns, c.winner)
		if err != nil {
			t.Fatalf("Settle(%v): %v", c, err)
		}
		var total uint64
		for _, b := range c.buyIns {
			total += b
		}
		if prize+house != total {
			t.Errorf("invariant broken for %v: prize=%d house=%d total=%d", c, prize, house, total)
		}
	}
}
