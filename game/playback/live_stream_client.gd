class_name LiveStreamClient
extends Node

# WebSocket subscriber for the server's /live/{id} endpoint. Decodes the binary
# protocol (u8 type + u32 le_len + payload; types HEADER/TICK/DONE — see
# server/stream/stream.go) and re-emits decoded dicts as Godot signals so
# callers don't have to know the wire format.
#
# Each WS frame carries exactly one protocol message (ws.go encodeInline),
# so packet boundaries line up with message boundaries — no reassembly needed.

const MSG_HEADER := 0x01
const MSG_TICK := 0x02
const MSG_DONE := 0x03

signal header_received(header: Dictionary)
signal tick_received(frame: Dictionary)
signal done_received()
signal connection_failed(reason: String)
signal closed()

var _ws: WebSocketPeer = null
var _marble_count: int = 0
var _header_seen: bool = false
var _closed_emitted: bool = false

func connect_to_url(url: String) -> int:
	_ws = WebSocketPeer.new()
	# Defaults (64 KiB / 2048 packets) are too small for a whole round's worth
	# of TICKs delivered as back-to-back WS frames at ~570 B each. A 15 s race
	# at 60 Hz × 570 B ≈ 500 KiB and ~900 packets; give a generous headroom so
	# a slow _process frame can't cause the peer to drop the tail (including
	# the DONE frame) when the server closes the socket.
	_ws.set_inbound_buffer_size(4 * 1024 * 1024)
	_ws.set_max_queued_packets(16384)
	var err := _ws.connect_to_url(url)
	if err != OK:
		push_error("LiveStreamClient: connect_to_url err=%d url=%s" % [err, url])
	return err

func _process(_delta: float) -> void:
	if _ws == null:
		return
	_ws.poll()
	# Always drain buffered packets, regardless of current state. When a round
	# ends, the server closes the socket right after DONE — the final TICKs and
	# the DONE frame are still in the peer's inbound queue, and we'd drop them
	# if we only drained while STATE_OPEN.
	while _ws.get_available_packet_count() > 0:
		var pkt := _ws.get_packet()
		_dispatch_packet(pkt)
	var state := _ws.get_ready_state()
	if state == WebSocketPeer.STATE_CLOSED:
		var code := _ws.get_close_code()
		var reason := _ws.get_close_reason()
		_ws = null
		if not _header_seen and code <= 0:
			connection_failed.emit("ws closed before handshake (code=%d reason=%s)" % [code, reason])
		if not _closed_emitted:
			_closed_emitted = true
			closed.emit()

func close() -> void:
	if _ws != null:
		_ws.close()

func _dispatch_packet(pkt: PackedByteArray) -> void:
	if pkt.size() < 5:
		push_error("LiveStreamClient: short packet (%d bytes)" % pkt.size())
		return
	var b := StreamPeerBuffer.new()
	b.big_endian = false
	b.data_array = pkt
	var msg_type := b.get_u8()
	var length := b.get_u32()
	# pkt is header(5) + payload(length); slice out the payload for the decoders.
	var payload: PackedByteArray = pkt.slice(5, 5 + length)
	if payload.size() != int(length):
		push_error("LiveStreamClient: payload len mismatch got=%d want=%d" % [payload.size(), length])
		return
	match msg_type:
		MSG_HEADER:
			var hdr := ReplayReader.decode_header_bytes(payload)
			if hdr.is_empty():
				push_error("LiveStreamClient: header decode failed")
				return
			_marble_count = (hdr["header"] as Array).size()
			_header_seen = true
			header_received.emit(hdr)
		MSG_TICK:
			if not _header_seen:
				push_error("LiveStreamClient: TICK before HEADER")
				return
			var frame := ReplayReader.decode_frame_bytes(payload, _marble_count)
			tick_received.emit(frame)
		MSG_DONE:
			done_received.emit()
		_:
			push_error("LiveStreamClient: unknown msg_type=0x%02x" % msg_type)
