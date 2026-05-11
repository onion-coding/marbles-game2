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

# In-memory clipboard — holds the dict from the most recent Ctrl+C.
var _clipboard: Dictionary = {}

# Drag state. _drag_active is set on LMB-press over the selected object.
# Mouse motion while active raycasts to a horizontal plane at the
# object's Y, snaps to GRID_STEP, updates obj.position. LMB release ends.
const GRID_STEP := 0.1
var _drag_active: bool = false
var _drag_grab_offset: Vector3 = Vector3.ZERO   # local offset from cursor hit to obj.position

# In-progress tube placement. Each click during this mode appends a
# waypoint to the active EditorTube and rebuilds its visual. Enter
# finalises; ESC cancels (and frees the partial tube).
var _tube_in_progress: EditorTube = null

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
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				_handle_left_click(mb.position)
			else:
				_drag_active = false
	elif event is InputEventMouseMotion:
		if _drag_active and _selected != null:
			_handle_drag(event.position)
	elif event is InputEventKey:
		var k := event as InputEventKey
		if k.pressed and not k.echo:
			match k.keycode:
				KEY_ESCAPE:
					if _tube_in_progress != null:
						_cancel_tube_placement()
					else:
						_pending_add_type = ""
						_select(null)
						_ui.set_status("Cancelled.")
				KEY_ENTER, KEY_KP_ENTER:
					if _tube_in_progress != null:
						_finish_tube_placement()
				KEY_DELETE, KEY_BACKSPACE:
					_delete_selected()
				KEY_S:
					if k.ctrl_pressed:
						_on_save_requested()
				KEY_L:
					if k.ctrl_pressed:
						_on_load_requested()
				KEY_C:
					if k.ctrl_pressed:
						_copy_selected()
				KEY_V:
					if k.ctrl_pressed:
						_paste_clipboard()
				KEY_D:
					if k.ctrl_pressed:
						# Duplicate-in-place: copy + paste in one keystroke.
						_copy_selected()
						_paste_clipboard()

func _handle_left_click(screen_pos: Vector2) -> void:
	var from := _camera.project_ray_origin(screen_pos)
	var dir := _camera.project_ray_normal(screen_pos)
	var to := from + dir * 1000.0
	var space := get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(from, to)
	var hit := space.intersect_ray(query)

	# Tube multi-click placement: each click appends a waypoint to the
	# tube currently being drawn. ENTER finalises, ESC cancels.
	if _pending_add_type == "tube":
		_handle_tube_click(screen_pos, from, dir, hit)
		return

	if _pending_add_type != "":
		var pos: Vector3
		if hit.has("position"):
			pos = hit["position"]
			pos.y += 1.0
		else:
			pos = from + dir * 12.0
		_add_object(_pending_add_type, pos)
		_pending_add_type = ""
		return

	# Hit detection: walk up the parent chain so a click on a child mesh
	# (the inner shell of a tube, e.g.) still finds the EditorObject.
	var hit_obj: EditorObject = null
	if hit.has("collider"):
		var node: Node = hit["collider"]
		while node != null:
			if node is EditorObject:
				hit_obj = node as EditorObject
				break
			node = node.get_parent()

	if hit_obj == null:
		_select(null)
		return

	# Click on an object: select it. If it was already selected, start
	# a drag in the XZ plane so the user can move it. Grab offset =
	# distance from cursor's plane-hit to the object's centre, so the
	# object stays anchored to where the cursor first grabbed it.
	if hit_obj == _selected:
		var grab_world: Vector3 = _ray_to_xz_plane(from, dir, _selected.position.y)
		_drag_grab_offset = _selected.position - grab_world
		_drag_active = true
	else:
		_select(hit_obj)

func _handle_drag(screen_pos: Vector2) -> void:
	if _selected == null:
		return
	var from := _camera.project_ray_origin(screen_pos)
	var dir := _camera.project_ray_normal(screen_pos)
	var target := _ray_to_xz_plane(from, dir, _selected.position.y) + _drag_grab_offset
	# Snap to GRID_STEP on X and Z only — Y stays put so the user uses
	# the +/- buttons (or spinbox) for vertical changes.
	target.x = snappedf(target.x, GRID_STEP)
	target.z = snappedf(target.z, GRID_STEP)
	_selected.position = Vector3(target.x, _selected.position.y, target.z)

func _ray_to_xz_plane(origin: Vector3, dir: Vector3, plane_y: float) -> Vector3:
	# Ray-plane intersection with the horizontal plane y=plane_y. If the
	# ray is parallel (dir.y ≈ 0), fall back to a point in front of the
	# camera at the original Y so the drag doesn't snap to infinity.
	if absf(dir.y) < 0.0001:
		return origin + dir * 10.0
	var t: float = (plane_y - origin.y) / dir.y
	if t < 0.0:
		# Plane is behind the camera — return origin so position doesn't jump.
		return Vector3(origin.x, plane_y, origin.z)
	return origin + dir * t

# --- Tube multi-click placement -------------------------------------

func _handle_tube_click(_screen_pos: Vector2, from: Vector3, dir: Vector3, hit: Dictionary) -> void:
	# First click: create the tube and place its origin at the hit point.
	# Subsequent clicks: append a waypoint in WORLD space (the tube
	# object converts to its local frame).
	var world_pos: Vector3
	if hit.has("position"):
		world_pos = hit["position"]
		world_pos.y += 0.05
	else:
		# No physical hit — place at the previous waypoint's Y, or
		# 10 m forward of the camera if there's no previous waypoint.
		var plane_y: float = 2.0
		if _tube_in_progress != null and _tube_in_progress.waypoints.size() > 0:
			plane_y = _tube_in_progress.global_position.y + _tube_in_progress.waypoints.back().y
		world_pos = _ray_to_xz_plane(from, dir, plane_y)

	if _tube_in_progress == null:
		_tube_in_progress = EditorTube.new()
		_tube_in_progress.position = world_pos
		add_child(_tube_in_progress)
		# First waypoint at the local origin.
		_tube_in_progress.append_waypoint_local(Vector3.ZERO)
		_ui.set_status("Tube: click to add more waypoints, ENTER to finish, ESC to cancel.")
	else:
		_tube_in_progress.append_waypoint_world(world_pos)
		_ui.set_status("Tube has %d waypoints. ENTER to finish." % _tube_in_progress.waypoints.size())

func _finish_tube_placement() -> void:
	if _tube_in_progress == null:
		return
	if _tube_in_progress.waypoints.size() < 2:
		_ui.set_status("Tube needs ≥2 waypoints. ESC to cancel.")
		return
	_objects.append(_tube_in_progress)
	_select(_tube_in_progress)
	_ui.set_status("Tube placed (%d waypoints)." % _tube_in_progress.waypoints.size())
	_tube_in_progress = null
	_pending_add_type = ""

func _cancel_tube_placement() -> void:
	if _tube_in_progress != null:
		_tube_in_progress.queue_free()
		_tube_in_progress = null
	_pending_add_type = ""
	_ui.set_status("Tube placement cancelled.")

# --- Object management ----------------------------------------------

func _add_object(type: String, pos: Vector3) -> EditorObject:
	var obj := _instantiate_type(type)
	if obj == null:
		push_warning("[MapEditor] unknown object type: %s" % type)
		return null
	obj.position = pos
	add_child(obj)
	obj.build_visual()
	_objects.append(obj)
	_select(obj)
	_ui.set_status("Placed %s." % type)
	return obj

func _instantiate_type(type: String) -> EditorObject:
	# Central factory so save/load, copy/paste, and the palette button
	# all agree on which class corresponds to which JSON tag.
	match type:
		"funnel":
			return EditorFunnel.new()
		"peg":
			return EditorPeg.new()
		"slab":
			return EditorSlab.new()
		"multiplier":
			return EditorMultiplier.new()
		"tube":
			return EditorTube.new()
		_:
			return null

# --- Clipboard -------------------------------------------------------

func _copy_selected() -> void:
	if _selected == null:
		_ui.set_status("Nothing to copy.")
		return
	_clipboard = _selected.to_dict()
	_ui.set_status("Copied %s." % _selected.get_object_type())

func _paste_clipboard() -> void:
	if _clipboard.is_empty():
		_ui.set_status("Clipboard is empty.")
		return
	var type := String(_clipboard.get("type", ""))
	var obj := _instantiate_type(type)
	if obj == null:
		_ui.set_status("Paste failed — unknown type %s." % type)
		return
	obj.from_dict(_clipboard)
	# Offset slightly so the paste doesn't z-fight with the original.
	obj.position += Vector3(0.6, 0.0, 0.6)
	add_child(obj)
	obj.build_visual()
	_objects.append(obj)
	_select(obj)
	_ui.set_status("Pasted %s." % type)

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
	# Cancel any in-progress tube before starting a new placement.
	if _tube_in_progress != null:
		_cancel_tube_placement()
	_pending_add_type = type
	if type == "tube":
		_ui.set_status("Tube: click to place each waypoint, ENTER finishes.")
	else:
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
			var obj := _instantiate_type(t)
			if obj == null:
				push_warning("[MapEditor] load: unknown type %s" % t)
				continue
			obj.from_dict(entry)
			add_child(obj)
			obj.build_visual()
			_objects.append(obj)
	print("[MapEditor] loaded %d objects ← %s" % [_objects.size(), path])
	_ui.set_status("Loaded %d objects." % _objects.size())
