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
	hint.text = "RMB: orbit/fly  ·  MMB: pan  ·  Scroll: zoom\nESC: deselect  ·  DEL: remove"
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

	var funnel_btn := Button.new()
	funnel_btn.text = "+  Funnel"
	funnel_btn.pressed.connect(func(): add_object_requested.emit("funnel"))
	vbox.add_child(funnel_btn)

	# Placeholder buttons for future Phase 2 types — disabled, surfaces
	# what's coming so the user knows the editor's planned scope.
	for type_name in ["Tube  (soon)", "Peg  (soon)", "Slab  (soon)", "Multiplier  (soon)"]:
		var b := Button.new()
		b.text = "+  " + type_name
		b.disabled = true
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

	# Position editors (X / Y / Z).
	_add_vec3_row(obj, "Position", -50.0, 50.0, 0.1,
		func(): return obj.position,
		func(v: Vector3): obj.position = v)

	# Subclass-specific params.
	var params: Dictionary = obj.get_params()
	for key in params.keys():
		var val = params[key]
		if val is float or val is int:
			_add_scalar_row(obj, String(key), float(val), 0.0, 10.0, 0.05)

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
