class_name MapEditor
extends Node3D

# Top-level editor controller. Spawned by main.gd when the --editor CLI
# flag is present. Owns:
#   - EditorCamera (current Camera3D in the viewport)
#   - DirectionalLight3D + WorldEnvironment (a sane editor sky/lighting)
#   - Editor ground plane (so placed objects have something to sit on
#     visually and the cursor has something to raycast against when
#     nothing else is in the scene yet)
#   - EditorUI (CanvasLayer overlay)
#   - List of placed EditorObjects
#
# Input flow:
#   - Mouse over UI: Godot eats the event, editor doesn't see clicks.
#   - LMB in viewport while a palette type is pending: spawn that
#     object at the ray-hit position (or 10 m forward if no hit).
#   - LMB in viewport with no pending type: raycast → if hit is an
#     EditorObject (or a child of one), select it.
#   - ESC: clear selection + cancel pending placement.
#   - DEL / BACKSPACE: remove the selected object.
#   - Ctrl+S / Ctrl+L: save / load.

const MAP_DIR := "user://maps/"
const DEFAULT_MAP_NAME := "current"

var _camera: EditorCamera = null
var _ui: EditorUI = null
var _objects: Array = []          # of EditorObject
var _selected: EditorObject = null
var _pending_add_type: String = ""

func _ready() -> void:
	_build_environment()
	_build_ground()

	_camera = EditorCamera.new()
	_camera.name = "EditorCamera"
	add_child(_camera)

	_ui = EditorUI.new()
	_ui.name = "EditorUI"
	_ui.add_object_requested.connect(_on_add_requested)
	_ui.save_requested.connect(_on_save_requested)
	_ui.load_requested.connect(_on_load_requested)
	add_child(_ui)
	_ui.set_status("Ready.")
	print("[MapEditor] ready — RMB: orbit/fly · MMB: pan · Scroll: zoom")

func _build_environment() -> void:
	var sun := DirectionalLight3D.new()
	sun.name = "EditorSun"
	sun.rotation_degrees = Vector3(-50.0, -30.0, 0.0)
	sun.light_color = Color(1.0, 0.96, 0.88)
	sun.light_energy = 1.2
	sun.shadow_enabled = true
	add_child(sun)

	var we := WorldEnvironment.new()
	we.name = "EditorEnv"
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.16, 0.19, 0.24)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.55, 0.62, 0.72)
	env.ambient_light_energy = 0.7
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.tonemap_exposure = 1.0
	env.adjustment_enabled = true
	env.adjustment_saturation = 1.05
	we.environment = env
	add_child(we)

func _build_ground() -> void:
	var body := StaticBody3D.new()
	body.name = "EditorGround"
	body.position = Vector3(0.0, -0.05, 0.0)
	var coll := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(80.0, 0.1, 80.0)
	coll.shape = shape
	body.add_child(coll)
	var mesh_inst := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(80.0, 0.1, 80.0)
	mesh_inst.mesh = bm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.27, 0.30, 0.34)
	mat.roughness = 0.85
	mesh_inst.material_override = mat
	body.add_child(mesh_inst)
	add_child(body)

	# Subtle grid overlay (10 dark lines + 1 brighter centre line) so the
	# user has a depth reference.
	var grid := _build_grid_lines()
	grid.name = "EditorGrid"
	grid.position = Vector3(0.0, 0.01, 0.0)
	add_child(grid)

func _build_grid_lines() -> MeshInstance3D:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_LINES)
	var half := 40.0
	var step := 2.0
	var i := -half
	while i <= half + 0.01:
		var c := Color(0.45, 0.50, 0.56, 0.5)
		if absf(i) < 0.01:
			c = Color(0.9, 0.7, 0.3, 0.9)
		st.set_color(c)
		st.add_vertex(Vector3(i, 0.0, -half))
		st.add_vertex(Vector3(i, 0.0,  half))
		st.set_color(c)
		st.add_vertex(Vector3(-half, 0.0, i))
		st.add_vertex(Vector3( half, 0.0, i))
		i += step
	var mesh: ArrayMesh = st.commit()
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mi.material_override = mat
	return mi

# --- Input -----------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
			_handle_left_click(mb.position)
	elif event is InputEventKey:
		var k := event as InputEventKey
		if k.pressed and not k.echo:
			match k.keycode:
				KEY_ESCAPE:
					_pending_add_type = ""
					_select(null)
					_ui.set_status("Cancelled.")
				KEY_DELETE, KEY_BACKSPACE:
					_delete_selected()
				KEY_S:
					if k.ctrl_pressed:
						_on_save_requested()
				KEY_L:
					if k.ctrl_pressed:
						_on_load_requested()

func _handle_left_click(screen_pos: Vector2) -> void:
	var from := _camera.project_ray_origin(screen_pos)
	var dir := _camera.project_ray_normal(screen_pos)
	var to := from + dir * 1000.0
	var space := get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(from, to)
	var hit := space.intersect_ray(query)

	if _pending_add_type != "":
		var pos: Vector3
		if hit.has("position"):
			pos = hit["position"]
			# Lift the new object so it sits on the surface, not buried.
			pos.y += 1.0
		else:
			pos = from + dir * 12.0
		_add_object(_pending_add_type, pos)
		_pending_add_type = ""
		return

	if hit.has("collider"):
		var node: Node = hit["collider"]
		while node != null:
			if node is EditorObject:
				_select(node as EditorObject)
				return
			node = node.get_parent()

	_select(null)

# --- Object management ----------------------------------------------

func _add_object(type: String, pos: Vector3) -> EditorObject:
	var obj: EditorObject = null
	match type:
		"funnel":
			obj = EditorFunnel.new()
		_:
			push_warning("[MapEditor] unknown object type: %s" % type)
			return null
	obj.position = pos
	add_child(obj)
	obj.build_visual()
	_objects.append(obj)
	_select(obj)
	_ui.set_status("Placed %s." % type)
	return obj

func _select(obj) -> void:
	if _selected == obj:
		return
	if _selected != null and is_instance_valid(_selected):
		_selected.set_selected(false)
	_selected = obj
	if obj != null:
		obj.set_selected(true)
	_ui.show_properties(_selected)

func _delete_selected() -> void:
	if _selected == null:
		return
	_objects.erase(_selected)
	_selected.queue_free()
	_selected = null
	_ui.show_properties(null)
	_ui.set_status("Removed.")

# --- Save / load -----------------------------------------------------

func _on_add_requested(type: String) -> void:
	_pending_add_type = type
	_ui.set_status("Click in the viewport to place a %s." % type)

func _on_save_requested() -> void:
	DirAccess.make_dir_recursive_absolute(MAP_DIR)
	var path := MAP_DIR + DEFAULT_MAP_NAME + ".json"
	var data := {
		"version": 1,
		"name": DEFAULT_MAP_NAME,
		"objects": [],
	}
	for o in _objects:
		if o is EditorObject:
			data["objects"].append((o as EditorObject).to_dict())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_error("[MapEditor] cannot write %s (err=%d)" % [path, FileAccess.get_open_error()])
		_ui.set_status("Save FAILED.")
		return
	f.store_string(JSON.stringify(data, "  "))
	f.close()
	print("[MapEditor] saved %d objects → %s" % [_objects.size(), path])
	_ui.set_status("Saved %d objects." % _objects.size())

func _on_load_requested() -> void:
	var path := MAP_DIR + DEFAULT_MAP_NAME + ".json"
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		_ui.set_status("No saved map at %s yet." % path)
		return
	var text := f.get_as_text()
	f.close()
	var parsed = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		_ui.set_status("Map file is invalid JSON.")
		return

	# Clear scene.
	for o in _objects:
		if is_instance_valid(o):
			o.queue_free()
	_objects.clear()
	_selected = null
	_ui.show_properties(null)

	var arr = parsed.get("objects", [])
	if arr is Array:
		for entry in arr:
			if typeof(entry) != TYPE_DICTIONARY:
				continue
			var t := String(entry.get("type", ""))
			var obj: EditorObject = null
			match t:
				"funnel":
					obj = EditorFunnel.new()
				_:
					push_warning("[MapEditor] load: unknown type %s" % t)
					continue
			obj.from_dict(entry)
			add_child(obj)
			obj.build_visual()
			_objects.append(obj)
	print("[MapEditor] loaded %d objects ← %s" % [_objects.size(), path])
	_ui.set_status("Loaded %d objects." % _objects.size())
