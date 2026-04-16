// Package rtp computes the winner's prize and the house cut for one round.
//
// One marble per player. The total pot is the sum of buy-ins across all
// marbles. The winning marble's owner takes Pot × RTP; the house keeps
// the remainder. "RTP" = return-to-player, a regulatory/industry term
// expressed here in basis points (bps) so the math is integer-safe and
// certification-friendly — 9500 bps = 95.00%.
//
// This package is deliberately trivial: no currency type, no wallet, no
// rounding-mode knobs. That lets a real RGS later call Settle with whatever
// unit it uses (cents, satoshis, USDC-6) without this package caring.
// The only invariant is prize + houseCut == total (no silent loss of funds).
package rtp

import (
	"errors"
	"fmt"
	"math"
)

// BasisPoints is the denominator for RTP percentages. 100% = 10_000 bps.
const BasisPoints uint32 = 10_000

type Config struct {
	// RTPBasisPoints: return-to-player as basis points out of 10_000.
	// 9500 = 95.00% RTP; 10_000 = no house edge; 0 = all house.
	RTPBasisPoints uint32
}

var (
	ErrNoBuyIns       = errors.New("rtp: buy-in list is empty")
	ErrWinnerIndex    = errors.New("rtp: winner_index out of range")
	ErrRTPOutOfRange  = errors.New("rtp: RTPBasisPoints must be in [0, 10000]")
	ErrPotOverflow    = errors.New("rtp: pot total overflows uint64")
	ErrPrizeOverflow  = errors.New("rtp: prize computation overflows uint64")
)

// Settle returns prize (to winner) and houseCut (to operator). The caller
// supplies buy-ins indexed by marble_index; winnerIndex must be a valid index.
// Buy-ins of zero are allowed (e.g. a freeroll marble); they contribute nothing
// to the pot but count as a legitimate participant.
//
// Invariant: prize + houseCut == sum(buyIns). prize rounds DOWN to the nearest
// unit; the rounding remainder goes to the house. This matches standard casino
// accounting (player never paid more than displayed; house absorbs the dust).
func Settle(cfg Config, buyIns []uint64, winnerIndex int) (prize, houseCut uint64, err error) {
	if cfg.RTPBasisPoints > BasisPoints {
		return 0, 0, fmt.Errorf("%w: got %d", ErrRTPOutOfRange, cfg.RTPBasisPoints)
	}
	if len(buyIns) == 0 {
		return 0, 0, ErrNoBuyIns
	}
	if winnerIndex < 0 || winnerIndex >= len(buyIns) {
		return 0, 0, fmt.Errorf("%w: got %d, have %d buy-ins", ErrWinnerIndex, winnerIndex, len(buyIns))
	}

	var total uint64
	for _, b := range buyIns {
		if total > math.MaxUint64-b {
			return 0, 0, ErrPotOverflow
		}
		total += b
	}

	// prize = total * rtp_bps / 10_000; check the multiplication for overflow.
	if cfg.RTPBasisPoints > 0 && total > math.MaxUint64/uint64(cfg.RTPBasisPoints) {
		return 0, 0, ErrPrizeOverflow
	}
	prize = total * uint64(cfg.RTPBasisPoints) / uint64(BasisPoints)
	houseCut = total - prize
	return prize, houseCut, nil
}
