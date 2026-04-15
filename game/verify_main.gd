extends Node

# Headless verifier: loads a replay, confirms the commit matches the reveal,
# re-derives spawn slots, and checks the recorded first-frame positions match
# the rail slot positions. See docs/fairness.md §Verification.

func _ready() -> void:
	var path := _latest_replay_path()
	if path.is_empty():
		push_error("no replays found in user://replays/")
		get_tree().quit(1)
		return
	var replay := ReplayReader.read(path)
	if replay.is_empty():
		push_error("failed to read replay: %s" % path)
		get_tree().quit(1)
		return

	var ok := _verify(replay)
	print("VERIFY: %s (%s)" % ["PASS" if ok else "FAIL", path])
	get_tree().quit(0 if ok else 1)

func _verify(replay: Dictionary) -> bool:
	var server_seed: PackedByteArray = replay["server_seed"]
	var claimed_hash: PackedByteArray = replay["server_seed_hash"]
	var round_id: int = replay["round_id"]
	var slot_count: int = replay["slot_count"]
	var header: Array = replay["header"]

	# 1. Commit/reveal consistency.
	var actual_hash := FairSeed.hash_server_seed(server_seed)
	if actual_hash != claimed_hash:
		push_error("hash mismatch: tamper or corruption")
		return false
	print("  commit OK: hash=%s" % FairSeed.to_hex(claimed_hash))

	# 2. Re-derive spawn slots and compare.
	var client_seeds: Array = []
	for m in header:
		client_seeds.append(String(m["client_seed"]))
	var derived := FairSeed.derive_spawn_slots(server_seed, round_id, client_seeds, slot_count)
	for i in range(header.size()):
		if int(derived[i]) != int(header[i]["slot"]):
			push_error("slot mismatch at marble %d: recorded=%d derived=%d" % [i, header[i]["slot"], derived[i]])
			return false
	print("  slots OK: %d marbles across %d slots" % [header.size(), slot_count])

	# 3. Check recorded first-frame positions match what SpawnRail would produce.
	# Physics hasn't ticked on frame 0 yet, so the state equals the spawn state.
	var frames: Array = replay["frames"]
	if frames.is_empty():
		push_error("replay has no frames")
		return false
	var first_states: Array = frames[0]["states"]
	for i in range(header.size()):
		var expected := SpawnRail.slot_position(int(header[i]["slot"]), i)
		var actual: Vector3 = first_states[i]["pos"]
		if not expected.is_equal_approx(actual):
			push_error("spawn-position mismatch at marble %d: expected=%s got=%s" % [i, expected, actual])
			return false
	print("  positions OK: first frame matches SpawnRail for all %d marbles" % header.size())
	return true

func _latest_replay_path() -> String:
	var dir := DirAccess.open("user://replays/")
	if dir == null:
		return ""
	var best := ""
	var best_mod := 0
	for name in dir.get_files():
		if not name.ends_with(".bin"):
			continue
		var full := "user://replays/%s" % name
		var mod := FileAccess.get_modified_time(full)
		if mod >= best_mod:
			best_mod = mod
			best = full
	return best
