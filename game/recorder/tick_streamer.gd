class_name TickStreamer
extends RefCounted

# Streams live race state over TCP to the Go server (see server/stream).
# Wire format matches the live-stream spec:
#
#   [u64 round_id]              initial handshake, LE
#   [u8 type][u32 len][payload] repeated messages until DONE
#
# Types: 0x01 HEADER, 0x02 TICK, 0x03 DONE. HEADER payload is the replay
# header (encode_header in ReplayWriter); TICK payload is one frame
# (encode_frame); DONE payload is empty.
#
# Failures are non-fatal: the race keeps going and the full replay still
# writes to disk. Live streaming is a convenience, not a correctness path.

const MSG_HEADER := 0x01
const MSG_TICK := 0x02
const MSG_DONE := 0x03

var _peer: StreamPeerTCP = null
var _ok: bool = false

# Blocks up to connect_timeout_ms polling for a successful TCP connection.
# Returns true on success, false otherwise (caller should degrade gracefully).
func connect_to(addr: String, port: int, round_id: int, connect_timeout_ms: int = 2000) -> bool:
	_peer = StreamPeerTCP.new()
	var err := _peer.connect_to_host(addr, port)
	if err != OK:
		push_error("TickStreamer: connect_to_host err=%d" % err)
		_peer = null
		return false
	var deadline := Time.get_ticks_msec() + connect_timeout_ms
	while Time.get_ticks_msec() < deadline:
		_peer.poll()
		var s := _peer.get_status()
		if s == StreamPeerTCP.STATUS_CONNECTED:
			break
		if s == StreamPeerTCP.STATUS_ERROR:
			push_error("TickStreamer: status=ERROR while connecting")
			_peer = null
			return false
		OS.delay_msec(10)
	if _peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		push_error("TickStreamer: connect timeout (%d ms)" % connect_timeout_ms)
		_peer = null
		return false

	# Disable buffering: ticks are small and latency matters.
	_peer.set_no_delay(true)

	# Initial handshake: send round_id as u64 LE.
	var id_buf := StreamPeerBuffer.new()
	id_buf.big_endian = false
	id_buf.put_u64(round_id)
	if _peer.put_data(id_buf.data_array) != OK:
		push_error("TickStreamer: failed to send round_id")
		_peer = null
		return false
	_ok = true
	return true

func send_header(payload: PackedByteArray) -> void:
	_send_msg(MSG_HEADER, payload)

func send_tick(payload: PackedByteArray) -> void:
	_send_msg(MSG_TICK, payload)

func send_done() -> void:
	_send_msg(MSG_DONE, PackedByteArray())
	# Do NOT disconnect_from_host() here. The DONE bytes just went into the OS
	# send buffer; Godot's disconnect calls close() on the socket, which can
	# race the kernel's TCP flush and drop the tail under load — the server
	# then misses either DONE *or the final TICK* and the live client terminates
	# via the close-after-HEADER fallback, one frame short of the recorded
	# replay. The server's ingest loop already drives a clean shutdown: MsgDone
	# → return → defer round.Done() → conn.Close() (FIN back to us). The sim's
	# socket naturally tears down when the sim process exits in spec mode.
	_ok = false

func is_streaming() -> bool:
	return _ok and _peer != null and _peer.get_status() == StreamPeerTCP.STATUS_CONNECTED

func _send_msg(msg_type: int, payload: PackedByteArray) -> void:
	if not _ok or _peer == null:
		return
	var hdr := StreamPeerBuffer.new()
	hdr.big_endian = false
	hdr.put_u8(msg_type)
	hdr.put_u32(payload.size())
	var err := _peer.put_data(hdr.data_array)
	if err == OK and payload.size() > 0:
		err = _peer.put_data(payload)
	if err != OK:
		push_error("TickStreamer: send failed err=%d (type=0x%02x)" % [err, msg_type])
		_ok = false
