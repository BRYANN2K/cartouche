# Flies a camera of our own through a project's scene, for Godot's movie maker, with no player.
# godot --path <project> --script res://fg2_shot.gd --write-movie <dir>/f.png --fixed-fps 240
#       --quit-after <frames> -- scene=res://<scene>.tscn seed=<n> [start=x,y,z] [speed=m/s] [height=m]
#       [shot=seconds]; scene=forest assets=<dir> builds fg2_forest.gd's forest instead
# The camera walks or runs forward at eye height, turns smoothly with sudden flicks now and then,
# and steers away from walls it would hit (physics ray casts). Every shot seconds it jumps back to a
# place it went through, with a new heading, speed and lens: one start-up for many shots.
extends SceneTree

var cam: Camera3D
var rng := RandomNumberGenerator.new()
var opts := {}
var yaw := 0.0
var pitch := 0.0
var speed := 4.0
var t := 0.0
var flick := 0.0
var freqs := []
var shot_t := 0.0
var visited: Array[Vector3] = []


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		var kv := a.split("=", true, 1)
		if kv.size() == 2:
			opts[kv[0]] = kv[1]
	rng.seed = int(opts.get("seed", "1"))
	Engine.physics_ticks_per_second = int(opts.get("physics", "240"))


func _setup() -> void:
	var scene: Node
	if opts.get("scene", "") == "forest":
		scene = load("res://fg2_forest.gd").new()
		root.add_child(scene)
		scene.build(opts["assets"], rng)
	else:
		var packed: PackedScene = load(opts.get("scene", ProjectSettings.get_setting("application/run/main_scene")))
		scene = packed.instantiate()
		root.add_child(scene)
	cam = Camera3D.new()
	cam.far = 1500.0
	root.add_child(cam)
	cam.global_position = _start(scene)
	_new_shot()


func _new_shot() -> void:
	if not visited.is_empty():
		cam.global_position = visited[rng.randi() % visited.size()]
	cam.fov = rng.randf_range(60.0, 85.0)
	yaw = rng.randf_range(-PI, PI)
	speed = float(opts.get("speed", "0")) if opts.has("speed") else [1.5, 3.0, 5.0, 8.0, 12.0][rng.randi() % 5]
	freqs.clear()
	for i in 4:
		freqs.append(Vector3(rng.randf_range(0.05, 0.9), rng.randf_range(0.2, 1.4), rng.randf_range(0, TAU)))
	shot_t = 0.0


func _start(scene: Node) -> Vector3:
	if opts.has("start"):
		var p: PackedStringArray = opts["start"].split(",")
		return Vector3(float(p[0]), float(p[1]), float(p[2]))
	var cams := scene.find_children("*", "Camera3D", true, false)
	if not cams.is_empty():
		return (cams[0] as Camera3D).global_position
	var box := AABB()
	for m: VisualInstance3D in scene.find_children("*", "VisualInstance3D", true, false):
		var b := m.global_transform * m.get_aabb()
		box = b if box.size == Vector3.ZERO else box.merge(b)
	return box.get_center() + Vector3(0, float(opts.get("height", "1.7")), 0)


func _ray(from: Vector3, to: Vector3) -> Dictionary:
	var space := cam.get_world_3d().direct_space_state
	return space.intersect_ray(PhysicsRayQueryParameters3D.create(from, to))


func _process(delta: float) -> bool:
	if cam == null:
		_setup()
		return false
	t += delta
	shot_t += delta
	if shot_t > float(opts.get("shot", "4")):
		_new_shot()
	if int(t / delta) % 60 == 0:
		visited.append(cam.global_position)
	cam.make_current()
	var turn: float = 0.0
	for f in freqs:
		turn += f.y * sin(TAU * f.x * t + f.z)
	if flick == 0.0 and rng.randf() < delta * 0.15:
		flick = rng.randf_range(-1, 1) * rng.randf_range(1.5, 4.0)
	turn += flick
	flick = move_toward(flick, 0.0, delta * 3.0)
	# Look around for the most open way and steer to it when the way ahead closes
	var reach: float = max(4.0, speed * 1.5)
	var best_free := 0.0
	var best_angle := 0.0
	var ahead_free := reach
	for angle in [0.0, -0.5, 0.5, -1.0, 1.0, -1.6, 1.6]:
		var dir := Vector3(-sin(yaw + angle), 0, -cos(yaw + angle))
		var hit := _ray(cam.global_position, cam.global_position + dir * reach)
		var free: float = reach if hit.is_empty() else cam.global_position.distance_to(hit.position)
		if angle == 0.0:
			ahead_free = free
		if free > best_free + 0.01:
			best_free = free
			best_angle = angle
	if ahead_free < reach * 0.9:
		turn += clamp(best_angle * 4.0, -3.0, 3.0) * (1.5 - ahead_free / reach)
	var forward := Vector3(-sin(yaw), 0, -cos(yaw))
	var pace: float = speed * (0.6 + 0.4 * sin(TAU * freqs[0].x * 0.5 * t)) * clamp(ahead_free / reach, 0.15, 1.0)
	if ahead_free > 1.0:
		cam.global_position += forward * pace * delta
	yaw += turn * delta * 0.6
	pitch = 0.18 * sin(TAU * freqs[1].x * 0.4 * t + freqs[1].z)
	var floor := _ray(cam.global_position + Vector3.UP * 2.0, cam.global_position + Vector3.DOWN * 30.0)
	if not floor.is_empty():
		var want: float = floor.position.y + float(opts.get("height", "1.7"))
		cam.global_position.y = lerp(cam.global_position.y, want, min(1.0, delta * 4.0))
	cam.global_basis = Basis.from_euler(Vector3(pitch, yaw, 0.04 * sin(TAU * freqs[2].x * t)))
	return false
