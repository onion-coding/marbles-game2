class_name EditorUI
extends CanvasLayer

# Right-side editor overlay: title, save/load buttons, object palette,
# and a properties panel that re-renders whenever the selected object
# changes. Signals (caught by MapEditor):
#   add_object_requested(type)  — palette button pressed
#   save_requested()
#   load_requested()
#   property_changed()          — emitted as the user drags a SpinBox;
#                                 MapEditor pushes the new dict back
#                                 into the selected object.

signal add_object_requested(type: String)
signal save_requested
signal load_requested

const PANEL_WIDTH := 320

var _palette: Panel
var _props_box: VBoxContainer
var _status: Label

# Tracked palette buttons (type -> Button). Toggled on while that type
# is the pending placement so the user sees which mode they're in.
var _palette_buttons: Dictionary = {}
var _hand_button: Button = null
var _undo_button: Button = null

# Position SpinBox refs so MapEditor can push real-time updates after a
# drag or arrow nudge without rebuilding the whole property panel.
var _pos_spinboxes: Array = []   # [SpinBox, SpinBox, SpinBox] for X/Y/Z

signal hand_mode_toggled(active: bool)
signal undo_requested

func _ready() -> void:
	layer = 50

	_palette = Panel.new()
	_palette.name = "EditorPalette"
	_palette.anchor_left = 1.0
	_palette.anchor_right = 1.0
	_palette.anchor_top = 0.0
	_palette.anchor_bottom = 1.0
	_palette.offset_left = -PANEL_WIDTH
	_palette.offset_right = -8                   # right margin so the panel
												  # doesn't bleed into the
												  # window edge
	_palette.offset_top = 8
	_palette.offset_bottom = -8
	add_child(_palette)

	var vbox := VBoxContainer.new()
	vbox.anchor_left = 0.0
	vbox.anchor_right = 1.0
	vbox.anchor_top = 0.0
	vbox.anchor_bottom = 1.0
	vbox.offset_left = 10
	vbox.offset_right = -10
	vbox.offset_top = 10
	vbox.offset_bottom = -10
	_palette.add_child(vbox)

	var title := Label.new()
	title.text = "MAP EDITOR"
	title.add_theme_font_size_override("font_size", 22)
	vbox.add_child(title)

	var hint := Label.new()
	hint.text = "RMB: orbit/fly · MMB: pan · Scroll: zoom\nLMB on selected: drag (0.1m snap, XZ only)\nArrows: nudge · Shift+Arrows: Y-axis\nTube draw: R/F raise/lower next point\nESC: cancel · DEL: remove\nCtrl+C/V/D: copy/paste/duplicate\nCtrl+S/L: save/load"
	hint.add_theme_font_size_override("font_size", 11)
	hint.modulate = Color(1, 1, 1, 0.7)
	vbox.add_child(hint)

	vbox.add_child(HSeparator.new())

	# Top toolbar: Hand-tool toggle + Undo + Save + Load on one row.
	var top_row := HBoxContainer.new()
	_hand_button = Button.new()
	_hand_button.text = "✋"
	_hand_button.toggle_mode = true
	_hand_button.tooltip_text = "Hand tool — select only, never drag"
	_hand_button.custom_minimum_size = Vector2(36, 0)
	_hand_button.toggled.connect(func(pressed: bool): hand_mode_toggled.emit(pressed))
	top_row.add_child(_hand_button)
	_undo_button = Button.new()
	_undo_button.text = "↶"
	_undo_button.tooltip_text = "Undo (Ctrl+Z)"
	_undo_button.custom_minimum_size = Vector2(36, 0)
	_undo_button.pressed.connect(func(): undo_requested.emit())
	top_row.add_child(_undo_button)
	var save_btn := Button.new()
	save_btn.text = "Save"
	save_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	save_btn.pressed.connect(func(): save_requested.emit())
	top_row.add_child(save_btn)
	var load_btn := Button.new()
	load_btn.text = "Load"
	load_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	load_btn.pressed.connect(func(): load_requested.emit())
	top_row.add_child(load_btn)
	vbox.add_child(top_row)

	vbox.add_child(HSeparator.new())

	var palette_label := Label.new()
	palette_label.text = "PLACE"
	palette_label.add_theme_font_size_override("font_size", 13)
	vbox.add_child(palette_label)

	# Object palette. Tube uses a multi-click placement flow: each LMB
	# adds a waypoint, ENTER finishes, ESC cancels.
	var palette_types: Array = [
		["funnel",     "+ Funnel"],
		["tube",       "+ Tube  (multi-click, ENTER to finish)"],
		["peg",        "+ Peg"],
		["slab",       "+ Slab"],
		["multiplier", "+ Multiplier slot"],
	]
	for entry in palette_types:
		var t: String = entry[0]
		var label: String = entry[1]
		var b := Button.new()
		b.text = label
		# toggle_mode = true so the user sees which placement is active
		# (button stays visibly pressed). MapEditor calls
		# set_active_palette(type) when placement starts/ends to keep
		# the toggle state honest.
		b.toggle_mode = true
		b.pressed.connect(func(): add_object_requested.emit(t))
		_palette_buttons[t] = b
		vbox.add_child(b)

	vbox.add_child(HSeparator.new())

	var props_label := Label.new()
	props_label.text = "PROPERTIES"
	props_label.add_theme_font_size_override("font_size", 13)
	vbox.add_child(props_label)

	_props_box = VBoxContainer.new()
	vbox.add_child(_props_box)

	_status = Label.new()
	_status.text = ""
	_status.add_theme_font_size_override("font_size", 11)
	_status.modulate = Color(1, 1, 1, 0.6)
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_child(_status)

	show_properties(null)

func set_status(text: String) -> void:
	if _status != null:
		_status.text = text

# Re-render the properties panel for the given object (or "nothing
# selected" when obj is null).
func show_properties(obj) -> void:
	for c in _props_box.get_children():
		c.queue_free()

	if obj == null:
		var l := Label.new()
		l.text = "(nothing selected)"
		l.modulate = Color(1, 1, 1, 0.5)
		_props_box.add_child(l)
		return

	var type_label := Label.new()
	type_label.text = obj.get_object_type().capitalize()
	type_label.add_theme_font_size_override("font_size", 14)
	_props_box.add_child(type_label)

	# Position editors. Step 0.1 m — matches the in-viewport drag snap
	# so the +/- buttons and the mouse drag agree on the same grid.
	# Spinboxes are captured into _pos_spinboxes so MapEditor can push
	# real-time updates after drag/arrow without rebuilding the panel.
	_pos_spinboxes = _add_vec3_row(obj, "Position", -100.0, 100.0, 0.1,
		func(): return obj.position,
		func(v: Vector3): obj.position = v)

	# Scale editors. Drives Node3D.scale, which propagates to every
	# child mesh + collider. Step 0.1 so resize matches the move grid.
	_add_vec3_row(obj, "Scale", 0.1, 20.0, 0.1,
		func(): return obj.scale,
		func(v: Vector3): obj.scale = v)

	# Subclass-specific params.
	var params: Dictionary = obj.get_params()
	for key in params.keys():
		var val = params[key]
		var key_s := String(key)
		if val is float or val is int:
			var bounds := _bounds_for(key_s)
			_add_scalar_row(obj, key_s, float(val), bounds[0], bounds[1], bounds[2])
		elif val is String:
			_add_string_row(obj, key_s, String(val))
		elif val is Array and key_s == "waypoints":
			_add_waypoints_editor(obj, val as Array)

# Heuristic slider ranges keyed on param name. Avoids handing the user a
# slab capped at 10m when plinko's frame is 26m wide.
func _bounds_for(key: String) -> Array:
	if key.contains("multiplier"):
		return [0.0, 30.0, 0.1]
	if key.contains("tilt") or key.contains("deg") or key.contains("angle"):
		return [-180.0, 180.0, 1.0]
	if key.contains("size"):
		return [0.05, 40.0, 0.1]
	if key.contains("height"):
		return [0.05, 30.0, 0.1]
	if key.contains("radius"):
		return [0.05, 12.0, 0.05]
	return [0.0, 20.0, 0.1]

# Render the tube's waypoint list as a stack of X/Y/Z spinboxes with a
# delete button per waypoint, plus an "Add Waypoint" button. Editing
# any cell re-calls obj.apply_params() so the swept mesh rebuilds.
func _add_waypoints_editor(obj, waypoints: Array) -> void:
	var head := Label.new()
	head.text = "Waypoints (%d)" % waypoints.size()
	head.add_theme_font_size_override("font_size", 12)
	_props_box.add_child(head)
	for i in range(waypoints.size()):
		var w = waypoints[i]
		if not (w is Array) or (w as Array).size() < 3:
			continue
		_add_waypoint_row(obj, i, float(w[0]), float(w[1]), float(w[2]))
	var add_btn := Button.new()
	add_btn.text = "+ Add Waypoint"
	add_btn.pressed.connect(func():
		var p: Dictionary = obj.get_params()
		var wps: Array = p.get("waypoints", []) as Array
		# New waypoint: extend along +Z from the last one (or origin).
		var last_x := 0.0
		var last_y := 0.0
		var last_z := 0.0
		if wps.size() > 0:
			var last = wps.back()
			last_x = float(last[0])
			last_y = float(last[1])
			last_z = float(last[2]) + 2.0
		wps.append([last_x, last_y, last_z])
		p["waypoints"] = wps
		obj.apply_params(p)
		show_properties(obj)
	)
	_props_box.add_child(add_btn)

func _add_waypoint_row(obj, idx: int, x: float, y: float, z: float) -> void:
	var row := HBoxContainer.new()
	var l := Label.new()
	l.text = "wp %d" % idx
	l.custom_minimum_size = Vector2(48, 0)
	row.add_child(l)

	var sb_x := _waypoint_spinbox(x)
	var sb_y := _waypoint_spinbox(y)
	var sb_z := _waypoint_spinbox(z)
	row.add_child(sb_x)
	row.add_child(sb_y)
	row.add_child(sb_z)

	sb_x.value_changed.connect(func(v): _set_waypoint_component(obj, idx, 0, v))
	sb_y.value_changed.connect(func(v): _set_waypoint_component(obj, idx, 1, v))
	sb_z.value_changed.connect(func(v): _set_waypoint_component(obj, idx, 2, v))

	var del_btn := Button.new()
	del_btn.text = "×"
	del_btn.custom_minimum_size = Vector2(28, 0)
	del_btn.pressed.connect(func():
		var p: Dictionary = obj.get_params()
		var wps: Array = (p.get("waypoints", []) as Array).duplicate()
		if idx < wps.size():
			wps.remove_at(idx)
			p["waypoints"] = wps
			obj.apply_params(p)
			show_properties(obj)
	)
	row.add_child(del_btn)
	_props_box.add_child(row)

func _waypoint_spinbox(initial: float) -> SpinBox:
	var sb := SpinBox.new()
	sb.min_value = -100.0
	sb.max_value =  100.0
	sb.step = 0.1
	sb.value = initial
	sb.custom_minimum_size = Vector2(64, 0)
	return sb

func _set_waypoint_component(obj, idx: int, axis_idx: int, val: float) -> void:
	var p: Dictionary = obj.get_params()
	var wps: Array = (p.get("waypoints", []) as Array).duplicate()
	if idx >= wps.size():
		return
	var w: Array = (wps[idx] as Array).duplicate()
	if w.size() < 3:
		return
	w[axis_idx] = val
	wps[idx] = w
	p["waypoints"] = wps
	obj.apply_params(p)

func _add_string_row(obj, key: String, current: String) -> void:
	var row := HBoxContainer.new()
	var l := Label.new()
	l.text = key
	l.custom_minimum_size = Vector2(96, 0)
	row.add_child(l)
	var le := LineEdit.new()
	le.text = current
	le.custom_minimum_size = Vector2(140, 0)
	le.text_changed.connect(func(v: String):
		var p: Dictionary = obj.get_params()
		p[key] = v
		obj.apply_params(p)
	)
	row.add_child(le)
	_props_box.add_child(row)

func _add_scalar_row(obj, key: String, current: float, min_v: float, max_v: float, step: float) -> void:
	var row := HBoxContainer.new()
	var l := Label.new()
	l.text = key
	l.custom_minimum_size = Vector2(96, 0)
	row.add_child(l)
	var sb := SpinBox.new()
	sb.min_value = min_v
	sb.max_value = max_v
	sb.step = step
	sb.value = current
	sb.value_changed.connect(func(v: float):
		var p: Dictionary = obj.get_params()
		p[key] = v
		obj.apply_params(p)
	)
	sb.custom_minimum_size = Vector2(140, 0)
	row.add_child(sb)
	_props_box.add_child(row)

func _add_vec3_row(obj, label: String, min_v: float, max_v: float, step: float,
		getter: Callable, setter: Callable) -> Array:
	var head := Label.new()
	head.text = label
	head.add_theme_font_size_override("font_size", 12)
	_props_box.add_child(head)
	var axes := ["x", "y", "z"]
	var spinboxes: Array = []
	for i in range(3):
		var row := HBoxContainer.new()
		var axis_label := Label.new()
		axis_label.text = axes[i].to_upper()
		axis_label.custom_minimum_size = Vector2(20, 0)
		row.add_child(axis_label)
		var sb := SpinBox.new()
		sb.min_value = min_v
		sb.max_value = max_v
		sb.step = step
		var v3: Vector3 = getter.call()
		sb.value = v3[i]
		var idx := i
		sb.value_changed.connect(func(val: float):
			var cur: Vector3 = getter.call()
			cur[idx] = val
			setter.call(cur)
		)
		sb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(sb)
		_props_box.add_child(row)
		spinboxes.append(sb)
	return spinboxes

# --- Real-time refresh + palette state -------------------------------

# MapEditor calls this after a drag tick / arrow nudge so the X/Y/Z
# spinboxes reflect the current position immediately. Cheap: just sets
# three float values, no panel rebuild.
func refresh_position(pos: Vector3) -> void:
	if _pos_spinboxes.size() != 3:
		return
	for i in range(3):
		var sb: SpinBox = _pos_spinboxes[i]
		if sb != null and is_instance_valid(sb):
			# set_value_no_signal so this doesn't recursively re-emit
			# back into the position setter callback.
			sb.set_value_no_signal(pos[i])

# Visually highlight the active placement button (or none, if type=="").
func set_active_palette(type: String) -> void:
	for key in _palette_buttons.keys():
		var btn: Button = _palette_buttons[key]
		if btn != null and is_instance_valid(btn):
			btn.set_pressed_no_signal(key == type)

# MapEditor toggles its hand-tool state; sync the button visual.
func set_hand_mode(active: bool) -> void:
	if _hand_button != null and is_instance_valid(_hand_button):
		_hand_button.set_pressed_no_signal(active)

# Enable/disable the undo button so it greys out when the stack is empty.
func set_undo_enabled(enabled: bool) -> void:
	if _undo_button != null and is_instance_valid(_undo_button):
		_undo_button.disabled = not enabled
