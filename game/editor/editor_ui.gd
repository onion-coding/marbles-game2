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

const PANEL_WIDTH := 280

var _palette: Panel
var _props_box: VBoxContainer
var _status: Label

func _ready() -> void:
	layer = 50

	_palette = Panel.new()
	_palette.name = "EditorPalette"
	_palette.anchor_left = 1.0
	_palette.anchor_right = 1.0
	_palette.anchor_top = 0.0
	_palette.anchor_bottom = 1.0
	_palette.offset_left = -PANEL_WIDTH
	_palette.offset_right = 0
	_palette.offset_top = 0
	_palette.offset_bottom = 0
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

	var save_btn := Button.new()
	save_btn.text = "Save Map"
	save_btn.pressed.connect(func(): save_requested.emit())
	vbox.add_child(save_btn)

	var load_btn := Button.new()
	load_btn.text = "Load Map"
	load_btn.pressed.connect(func(): load_requested.emit())
	vbox.add_child(load_btn)

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
		b.pressed.connect(func(): add_object_requested.emit(t))
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
	_add_vec3_row(obj, "Position", -100.0, 100.0, 0.1,
		func(): return obj.position,
		func(v: Vector3): obj.position = v)

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
		getter: Callable, setter: Callable) -> void:
	var head := Label.new()
	head.text = label
	head.add_theme_font_size_override("font_size", 12)
	_props_box.add_child(head)
	var axes := ["x", "y", "z"]
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
		sb.custom_minimum_size = Vector2(140, 0)
		row.add_child(sb)
		_props_box.add_child(row)
