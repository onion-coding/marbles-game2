.PHONY: build clean test quick medium full help

help:
	@echo "Marbles Game Stress Test Harness"
	@echo "=================================="
	@echo ""
	@echo "Targets:"
	@echo "  build         Build the stress test binary"
	@echo "  clean         Remove compiled binaries"
	@echo "  quick         Run quick smoke test (10 players, 30s)"
	@echo "  medium        Run CI-friendly test (100 players, 5min)"
	@echo "  full          Run release gate test (1000 players, 30min)"
	@echo "  test          Build and run quick test"
	@echo ""
	@echo "Environment variables:"
	@echo "  URL           rgsd target (default: http://localhost:8080)"
	@echo "  HMAC_SECRET   HMAC secret (default: dev-secret)"
	@echo ""
	@echo "Examples:"
	@echo "  make build"
	@echo "  make quick"
	@echo "  URL=http://10.0.0.1:8080 make medium"
	@echo ""

build:
	go build -o stress-test main.go

clean:
	rm -f stress-test stress-test.exe

test: build quick

quick: build
	./stress-test \
		-url=${URL:-http://localhost:8080} \
		-hmac-secret=${HMAC_SECRET:-dev-secret} \
		-concurrency=10 \
		-duration=30s \
		-bets-per-round=5 \
		-think-time=1s

medium: build
	./stress-test \
		-url=${URL:-http://localhost:8080} \
		-hmac-secret=${HMAC_SECRET:-dev-secret} \
		-concurrency=100 \
		-duration=5m \
		-bets-per-round=20 \
		-think-time=1s

full: build
	./stress-test \
		-url=${URL:-http://localhost:8080} \
		-hmac-secret=${HMAC_SECRET:-dev-secret} \
		-concurrency=1000 \
		-duration=30m \
		-bets-per-round=20 \
		-think-time=1s
