class_name RgsClient
extends Node

# HTTP client for the RGS betting endpoints.
#
# Responsibilities:
#   - Persist a UUID v4 player_id in user://player_id.txt across runs.
#   - POST /v1/rounds/{round_id}/bets  → emits bet_placed or bet_failed.
#   - GET  /v1/rounds/{round_id}/bets?player_id=<id>  → emits bets_loaded.
#   - GET  /v1/wallets/{player_id}/balance  → emits balance_loaded.
#     (Open item: endpoint not yet implemented server-side; local estimate
#     via bet_placed.balance_after is used as the primary balance source.)
#
# All HTTP calls use a fresh HTTPRequest child node so they can run
# concurrently without queuing. Each node is removed+freed after completion.

signal bet_placed(bet: Dictionary)       # {bet_id, marble_idx, amount, balance_after, expected_payout_if_win}
signal bet_failed(error: String)
signal bets_loaded(bets: Array)          # array of bet dicts from GET /bets
signal balance_loaded(balance: float)    # from GET /wallets/<id>/balance

# Set by whoever owns this node (main.gd in RGS mode).
var base_url: String = ""
var player_id: String = ""

# ─── Lifecycle ───────────────────────────────────────────────────────────────

func _ready() -> void:
	player_id = _load_or_create_player_id()

# ─── Public API ──────────────────────────────────────────────────────────────

func place_bet(round_id: int, marble_idx: int, amount: float) -> void:
	var url := "%s/v1/rounds/%d/bets" % [base_url, round_id]
	var body := JSON.stringify({
		"player_id": player_id,
		"marble_idx": marble_idx,
		"amount": amount,
	})
	var http := _new_http()
	http.request_completed.connect(_on_place_bet_response.bind(http, marble_idx, amount))
	var err := http.request(url, ["Content-Type: application/json"], HTTPClient.METHOD_POST, body)
	if err != OK:
		remove_child(http)
		http.queue_free()
		bet_failed.emit("HTTPRequest.request() failed (err=%d)" % err)

func fetch_bets(round_id: int) -> void:
	var url := "%s/v1/rounds/%d/bets?player_id=%s" % [base_url, round_id, player_id]
	var http := _new_http()
	http.request_completed.connect(_on_fetch_bets_response.bind(http))
	var err := http.request(url)
	if err != OK:
		remove_child(http)
		http.queue_free()

# Open item: no server endpoint yet. Call this once it lands.
func fetch_balance() -> void:
	var url := "%s/v1/wallets/%s/balance" % [base_url, player_id]
	var http := _new_http()
	http.request_completed.connect(_on_balance_response.bind(http))
	var err := http.request(url)
	if err != OK:
		remove_child(http)
		http.queue_free()

# ─── Callbacks ───────────────────────────────────────────────────────────────

func _on_place_bet_response(result: int, code: int, _headers: PackedStringArray,
		body: PackedByteArray, http: HTTPRequest, marble_idx: int, amount: float) -> void:
	remove_child(http)
	http.queue_free()
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		var msg := "bet POST failed (result=%d http=%d)" % [result, code]
		if body.size() > 0:
			msg += ": " + body.get_string_from_utf8()
		bet_failed.emit(msg)
		return
	var parsed = JSON.parse_string(body.get_string_from_utf8())
	if typeof(parsed) != TYPE_DICTIONARY:
		bet_failed.emit("bet response is not a JSON object")
		return
	var bet := {
		"bet_id": parsed.get("bet_id", 0),
		"marble_idx": marble_idx,
		"amount": amount,
		"balance_after": float(parsed.get("balance_after", 0.0)),
		"expected_payout_if_win": float(parsed.get("expected_payout_if_win", 0.0)),
	}
	bet_placed.emit(bet)

func _on_fetch_bets_response(result: int, code: int, _headers: PackedStringArray,
		body: PackedByteArray, http: HTTPRequest) -> void:
	remove_child(http)
	http.queue_free()
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		return
	var parsed = JSON.parse_string(body.get_string_from_utf8())
	if typeof(parsed) == TYPE_ARRAY:
		bets_loaded.emit(parsed as Array)

func _on_balance_response(result: int, code: int, _headers: PackedStringArray,
		body: PackedByteArray, http: HTTPRequest) -> void:
	remove_child(http)
	http.queue_free()
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		balance_loaded.emit(-1.0)
		return
	var parsed = JSON.parse_string(body.get_string_from_utf8())
	if typeof(parsed) == TYPE_DICTIONARY and parsed.has("balance"):
		balance_loaded.emit(float(parsed["balance"]))
	else:
		balance_loaded.emit(-1.0)

# ─── Helpers ─────────────────────────────────────────────────────────────────

func _new_http() -> HTTPRequest:
	var http := HTTPRequest.new()
	add_child(http)
	return http

# Load the persistent player UUID from user://player_id.txt, or generate and
# save a new one if the file doesn't exist or is empty.
func _load_or_create_player_id() -> String:
	var path := "user://player_id.txt"
	var f := FileAccess.open(path, FileAccess.READ)
	if f != null:
		var stored := f.get_as_text().strip_edges()
		f.close()
		if stored.length() == 36:   # "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"
			return stored
	var uuid := _generate_uuid_v4()
	var fw := FileAccess.open(path, FileAccess.WRITE)
	if fw != null:
		fw.store_string(uuid)
		fw.close()
	return uuid

# Generate a UUID v4 using Godot's built-in random number generator.
# Format: xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx
static func _generate_uuid_v4() -> String:
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	# Build 16 random bytes then apply version/variant bits.
	var b: PackedByteArray = PackedByteArray()
	b.resize(16)
	for i in range(16):
		b[i] = rng.randi() % 256
	b[6] = (b[6] & 0x0F) | 0x40   # version 4
	b[8] = (b[8] & 0x3F) | 0x80   # variant 10xx
	return "%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x" % [
		b[0], b[1], b[2], b[3],
		b[4], b[5],
		b[6], b[7],
		b[8], b[9],
		b[10], b[11], b[12], b[13], b[14], b[15],
	]
