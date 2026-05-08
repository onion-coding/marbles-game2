class_name CasinoMetaStreamer
extends RefCounted

# Pushes line-delimited JSON metadata to rgsd's casino/meta_listener.go
# alongside the video stream. rgsd broadcasts each line verbatim onto
# every WebRTC subscriber's data channel, so browsers see what the
# director is currently rendering with the same PTS as the video frame.
#
# Three message types:
#   {"type":"hud","tick":N,"marbles":[{"id":I,"x":X,"y":Y,"vis":B},...]}
#   {"type":"minimap","tick":N,"marbles":[{"id":I,"wx":WX,"wz":WZ},...]}
#   {"type":"names","names":{"0":"alice","1":"bob",...}}
#
# Browser code (casino.js) pattern-matches on `type` and updates the
# right overlay (DOM labels for hud, canvas dots for minimap, text for
# names). Names is sent once per round; hud is sent every captured frame;
# minimap is sent at 10 Hz.

var _peer: StreamPeerTCP = null
var _ok: bool = false

# Connects to host:port. Returns true on success.
func connect_to(host: String, port: int, connect_timeout_ms: int = 2000) -> bool:
	_peer = StreamPeerTCP.new()
	var err := _peer.connect_to_host(host, port)
	if err != OK:
		push_error("CasinoMetaStreamer: connect_to_host err=%d" % err)
		_peer = null
		return false
	var deadline := Time.get_ticks_msec() + connect_timeout_ms
	while Time.get_ticks_msec() < deadline:
		_peer.poll()
		var s := _peer.get_status()
		if s == StreamPeerTCP.STATUS_CONNECTED:
			break
		if s == StreamPeerTCP.STATUS_ERROR:
			push_error("CasinoMetaStreamer: status=ERROR while connecting")
			_peer = null
			return false
		OS.delay_msec(10)
	if _peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		push_error("CasinoMetaStreamer: connect timeout")
		_peer = null
		return false
	_peer.set_no_delay(true)
	_ok = true
	print("CasinoMetaStreamer: connected to %s:%d" % [host, port])
	return true

# send_line writes one JSON object followed by '\n'. rgsd's MetaListener
# scans by newline; an embedded '\n' in a string field would break framing
# but JSON.stringify never emits raw newlines.
func send_line(payload: Dictionary) -> void:
	if not _ok or _peer == null:
		return
	_peer.poll()
	if _peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		_ok = false
		return
	var json := JSON.stringify(payload) + "\n"
	var bytes := json.to_utf8_buffer()
	var err := _peer.put_data(bytes)
	if err != OK:
		push_error("CasinoMetaStreamer: put_data err=%d" % err)
		_ok = false

# send_hud projects each marble's world position to screen-space using
# the active camera, then ships HUD payload. Visibility check folds in
# both the camera frustum and a forward-of-camera test (so a marble
# behind the lens doesn't get a label sliding through center-screen).
func send_hud(tick: int, marbles: Array, camera: Camera3D) -> void:
	if camera == null:
		return
	var arr: Array = []
	for i in range(marbles.size()):
		var m: Node3D = marbles[i]
		if m == null:
			continue
		var pos: Vector3 = m.global_position
		var behind := camera.is_position_behind(pos)
		var screen := camera.unproject_position(pos)
		arr.append({
			"id": i,
			"x": int(round(screen.x)),
			"y": int(round(screen.y)),
			"vis": not behind,
		})
	send_line({"type": "hud", "tick": tick, "marbles": arr})

# send_minimap pushes raw world-space (X, Z) so the browser draws a
# top-down minimap independent of where the broadcast camera is. Called
# at 10 Hz from the host scene.
func send_minimap(tick: int, marbles: Array) -> void:
	var arr: Array = []
	for i in range(marbles.size()):
		var m: Node3D = marbles[i]
		if m == null:
			continue
		var pos: Vector3 = m.global_position
		arr.append({
			"id": i,
			"wx": pos.x,
			"wz": pos.z,
		})
	send_line({"type": "minimap", "tick": tick, "marbles": arr})

# send_names pushes a {marble_id: name} map once per round. Name lookup
# is the bettor's player_id (real bets) or "filler_NN" (synthetic seats).
func send_names(names: Dictionary) -> void:
	send_line({"type": "names", "names": names})

func is_streaming() -> bool:
	return _ok and _peer != null and _peer.get_status() == StreamPeerTCP.STATUS_CONNECTED

func close() -> void:
	if _peer != null:
		_peer.disconnect_from_host()
		_peer = null
	_ok = false
