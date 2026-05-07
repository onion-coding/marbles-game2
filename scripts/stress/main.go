package main

import (
	"bytes"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"math"
	"math/rand"
	"net/http"
	"sort"
	"sync"
	"sync/atomic"
	"time"
)

type Config struct {
	URL            string
	HMACSecret     string
	Concurrency    int
	Duration       time.Duration
	BetsPerRound   int
	ThinkTime      time.Duration
	Deterministic  bool
	ErrorsByStatus map[int]int64
}

type Metrics struct {
	mu                sync.RWMutex
	BetsPlacedTotal   int64
	BetsFailedTotal   int64
	LatenciesStartRnd []time.Duration
	LatenciesPlaceBet []time.Duration
	LatenciesRunRound []time.Duration
	ErrorsByStatus    map[int]int64
	RoundsThroughput  int64
	StartTime         time.Time
	EndTime           time.Time
}

type RoundResponse struct {
	ID    string `json:"id"`
	State string `json:"state"`
}

type BetRequest struct {
	MarbleIdx int    `json:"marble_idx"`
	BetType   string `json:"bet_type"`
	Amount    int    `json:"amount"`
}

type RunRoundResponse struct {
	ID     string `json:"id"`
	Winner int    `json:"winner"`
}

func (m *Metrics) recordStartRound(latency time.Duration) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.LatenciesStartRnd = append(m.LatenciesStartRnd, latency)
}

func (m *Metrics) recordPlaceBet(latency time.Duration) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.LatenciesPlaceBet = append(m.LatenciesPlaceBet, latency)
	atomic.AddInt64(&m.BetsPlacedTotal, 1)
}

func (m *Metrics) recordRunRound(latency time.Duration) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.LatenciesRunRound = append(m.LatenciesRunRound, latency)
	atomic.AddInt64(&m.RoundsThroughput, 1)
}

func (m *Metrics) recordError(statusCode int) {
	m.mu.Lock()
	defer m.mu.Unlock()
	atomic.AddInt64(&m.BetsFailedTotal, 1)
	m.ErrorsByStatus[statusCode]++
}

func makeHMACHeader(secret string, body []byte) string {
	h := hmac.New(sha256.New, []byte(secret))
	h.Write(body)
	return hex.EncodeToString(h.Sum(nil))
}

func startRound(client *http.Client, url, hmacSecret string, metrics *Metrics) (string, error) {
	start := time.Now()

	payload := []byte(`{"type":"normal","house_margin":1000}`)
	req, _ := http.NewRequest("POST", url+"/v1/rounds/start", bytes.NewReader(payload))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-HMAC-SHA256", makeHMACHeader(hmacSecret, payload))

	resp, err := client.Do(req)
	if err != nil {
		metrics.recordError(0)
		return "", err
	}
	defer resp.Body.Close()

	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode >= 400 {
		metrics.recordError(resp.StatusCode)
		return "", fmt.Errorf("start round failed: %d", resp.StatusCode)
	}

	metrics.recordStartRound(time.Since(start))

	var result RoundResponse
	json.Unmarshal(body, &result)
	return result.ID, nil
}

func placeBet(client *http.Client, url, hmacSecret, roundID string, marbleIdx int, metrics *Metrics) error {
	start := time.Now()

	bet := BetRequest{
		MarbleIdx: marbleIdx,
		BetType:   "win",
		Amount:    100,
	}
	payload, _ := json.Marshal(bet)

	req, _ := http.NewRequest("POST", url+"/v1/rounds/"+roundID+"/bets", bytes.NewReader(payload))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-HMAC-SHA256", makeHMACHeader(hmacSecret, payload))

	resp, err := client.Do(req)
	if err != nil {
		metrics.recordError(0)
		return err
	}
	defer resp.Body.Close()

	if resp.StatusCode >= 400 {
		metrics.recordError(resp.StatusCode)
		return fmt.Errorf("place bet failed: %d", resp.StatusCode)
	}

	metrics.recordPlaceBet(time.Since(start))
	return nil
}

func runRound(client *http.Client, url, hmacSecret, roundID string, metrics *Metrics) error {
	start := time.Now()

	payload := []byte(`{"wait":true}`)
	req, _ := http.NewRequest("POST", url+"/v1/rounds/"+roundID+"/run", bytes.NewReader(payload))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-HMAC-SHA256", makeHMACHeader(hmacSecret, payload))

	resp, err := client.Do(req)
	if err != nil {
		metrics.recordError(0)
		return err
	}
	defer resp.Body.Close()

	if resp.StatusCode >= 400 {
		metrics.recordError(resp.StatusCode)
		return fmt.Errorf("run round failed: %d", resp.StatusCode)
	}

	metrics.recordRunRound(time.Since(start))
	return nil
}

func playerLoop(id int, cfg Config, metrics *Metrics, done <-chan struct{}) {
	client := &http.Client{Timeout: 30 * time.Second}

	for {
		select {
		case <-done:
			return
		default:
		}

		// Start round
		roundID, err := startRound(client, cfg.URL, cfg.HMACSecret, metrics)
		if err != nil {
			continue
		}

		// Place bets
		for i := 0; i < cfg.BetsPerRound; i++ {
			marbleIdx := rand.Intn(20)
			if err := placeBet(client, cfg.URL, cfg.HMACSecret, roundID, marbleIdx, metrics); err != nil {
				// Continue with other bets even if one fails
			}
		}

		// Run round
		if err := runRound(client, cfg.URL, cfg.HMACSecret, roundID, metrics); err != nil {
			// Continue to next round
		}

		// Think time
		thinkDuration := cfg.ThinkTime
		if !cfg.Deterministic {
			jitter := time.Duration(rand.Intn(int(cfg.ThinkTime) / 2))
			thinkDuration = cfg.ThinkTime + jitter
		}
		time.Sleep(thinkDuration)
	}
}

func percentile(data []time.Duration, p float64) time.Duration {
	if len(data) == 0 {
		return 0
	}
	sort.Slice(data, func(i, j int) bool { return data[i] < data[j] })
	idx := int(math.Ceil(float64(len(data))*p/100)) - 1
	if idx < 0 {
		idx = 0
	}
	if idx >= len(data) {
		idx = len(data) - 1
	}
	return data[idx]
}

func repeatString(s string, count int) string {
	result := ""
	for i := 0; i < count; i++ {
		result += s
	}
	return result
}

func printReport(cfg Config, metrics *Metrics) {
	fmt.Println("\n" + repeatString("=", 70))
	fmt.Println("STRESS TEST REPORT")
	fmt.Println(repeatString("=", 70))
	fmt.Printf("\nTest Configuration:\n")
	fmt.Printf("  Target URL:        %s\n", cfg.URL)
	fmt.Printf("  Concurrency:       %d virtual players\n", cfg.Concurrency)
	fmt.Printf("  Duration:          %v\n", cfg.Duration)
	fmt.Printf("  Bets per round:    %d\n", cfg.BetsPerRound)
	fmt.Printf("  Think time:        %v\n", cfg.ThinkTime)
	fmt.Printf("  Deterministic:     %v\n", cfg.Deterministic)

	duration := metrics.EndTime.Sub(metrics.StartTime).Seconds()
	errorRate := float64(0)
	if metrics.BetsPlacedTotal+metrics.BetsFailedTotal > 0 {
		errorRate = float64(metrics.BetsFailedTotal) / float64(metrics.BetsPlacedTotal+metrics.BetsFailedTotal) * 100
	}
	throughput := float64(metrics.RoundsThroughput) / duration

	fmt.Printf("\nResults:\n")
	fmt.Printf("  Elapsed time:      %.2f seconds\n", duration)
	fmt.Printf("  Bets placed:       %d\n", metrics.BetsPlacedTotal)
	fmt.Printf("  Bets failed:       %d\n", metrics.BetsFailedTotal)
	fmt.Printf("  Error rate:        %.2f%%\n", errorRate)
	fmt.Printf("  Rounds completed:  %d\n", metrics.RoundsThroughput)
	fmt.Printf("  Throughput:        %.2f rounds/sec\n", throughput)

	fmt.Printf("\nLatency (ms) - startRound:\n")
	fmt.Printf("  p50:  %.2f\n", percentile(metrics.LatenciesStartRnd, 50).Seconds()*1000)
	fmt.Printf("  p95:  %.2f\n", percentile(metrics.LatenciesStartRnd, 95).Seconds()*1000)
	fmt.Printf("  p99:  %.2f\n", percentile(metrics.LatenciesStartRnd, 99).Seconds()*1000)

	fmt.Printf("\nLatency (ms) - placeBet:\n")
	fmt.Printf("  p50:  %.2f\n", percentile(metrics.LatenciesPlaceBet, 50).Seconds()*1000)
	fmt.Printf("  p95:  %.2f\n", percentile(metrics.LatenciesPlaceBet, 95).Seconds()*1000)
	fmt.Printf("  p99:  %.2f\n", percentile(metrics.LatenciesPlaceBet, 99).Seconds()*1000)

	fmt.Printf("\nLatency (ms) - runRound:\n")
	fmt.Printf("  p50:  %.2f\n", percentile(metrics.LatenciesRunRound, 50).Seconds()*1000)
	fmt.Printf("  p95:  %.2f\n", percentile(metrics.LatenciesRunRound, 95).Seconds()*1000)
	fmt.Printf("  p99:  %.2f\n", percentile(metrics.LatenciesRunRound, 99).Seconds()*1000)

	if len(metrics.ErrorsByStatus) > 0 {
		fmt.Printf("\nErrors by HTTP status:\n")
		for status := 400; status <= 599; status++ {
			if count, ok := metrics.ErrorsByStatus[status]; ok && count > 0 {
				fmt.Printf("  %d: %d\n", status, count)
			}
		}
	}

	fmt.Printf("\nAcceptance gates:\n")
	p99PlaceBet := percentile(metrics.LatenciesPlaceBet, 99).Seconds() * 1000
	p99PlaceBetOk := p99PlaceBet < 100
	fmt.Printf("  p99 placeBet < 100ms:        %v (actual: %.2fms)\n", p99PlaceBetOk, p99PlaceBet)
	fmt.Printf("  error rate < 1%%:             %v (actual: %.2f%%)\n", errorRate < 1.0, errorRate)
	fmt.Printf("  throughput >= 50 rounds/min: %v (actual: %.2f rounds/min)\n", throughput*60 >= 50, throughput*60)

	if p99PlaceBetOk && errorRate < 1.0 && throughput*60 >= 50 {
		fmt.Printf("\nResult: PASS\n")
	} else {
		fmt.Printf("\nResult: FAIL\n")
	}
	fmt.Println(repeatString("=", 70))
}

func main() {
	cfg := Config{
		ErrorsByStatus: make(map[int]int64),
	}

	flag.StringVar(&cfg.URL, "url", "http://localhost:8080", "rgsd target URL")
	flag.StringVar(&cfg.HMACSecret, "hmac-secret", "dev-secret", "HMAC secret for endpoints")
	flag.IntVar(&cfg.Concurrency, "concurrency", 10, "number of concurrent players")
	flag.DurationVar(&cfg.Duration, "duration", 30*time.Second, "test duration")
	flag.IntVar(&cfg.BetsPerRound, "bets-per-round", 5, "bets each player places per round")
	flag.DurationVar(&cfg.ThinkTime, "think-time", 2*time.Second, "delay between rounds")
	flag.BoolVar(&cfg.Deterministic, "deterministic", false, "disable random jitter in timing")
	flag.Parse()

	metrics := &Metrics{
		ErrorsByStatus: make(map[int]int64),
		StartTime:      time.Now(),
	}

	done := make(chan struct{})
	var wg sync.WaitGroup

	fmt.Printf("Starting stress test: %d concurrent players for %v...\n", cfg.Concurrency, cfg.Duration)

	for i := 0; i < cfg.Concurrency; i++ {
		wg.Add(1)
		go func(id int) {
			defer wg.Done()
			playerLoop(id, cfg, metrics, done)
		}(i)
	}

	time.Sleep(cfg.Duration)
	close(done)
	wg.Wait()

	metrics.EndTime = time.Now()
	printReport(cfg, metrics)
}
