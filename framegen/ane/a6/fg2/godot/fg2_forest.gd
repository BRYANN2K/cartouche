# A forest built at run time from Poly Haven's CC0 assets (fetch_polyhaven.py): rolling ground with a
# collision shape for the camera, a few hundred trees, rocks, ferns and grass, the sky as light, and
# volumetric fog.
extends Node3D

const SIZE := 160.0
const CELLS := 128


func build(dir: String, rng: RandomNumberGenerator) -> void:
	var noise := FastNoiseLite.new()
	noise.seed = rng.randi()
	noise.frequency = 0.012
	var height := func(x: float, z: float) -> float: return noise.get_noise_2d(x, z) * 9.0
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var step := SIZE / CELLS
	for i in CELLS:
		for j in CELLS:
			var quad := []
			for c in [Vector2(i, j), Vector2(i + 1, j), Vector2(i + 1, j + 1), Vector2(i, j + 1)]:
				var x: float = c.x * step - SIZE / 2
				var z: float = c.y * step - SIZE / 2
				quad.append([Vector3(x, height.call(x, z), z), c / 8.0])
			for k in [0, 1, 2, 0, 2, 3]:
				st.set_uv(quad[k][1])
				st.add_vertex(quad[k][0])
	st.generate_normals()
	st.generate_tangents()
	var ground := MeshInstance3D.new()
	ground.mesh = st.commit()
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = _tex(dir + "/ground/diff.jpg")
	mat.normal_enabled = true
	mat.normal_texture = _tex(dir + "/ground/nor.jpg")
	mat.roughness_texture = _tex(dir + "/ground/rough.jpg")
	ground.material_override = mat
	ground.create_trimesh_collision()
	add_child(ground)

	var models := {}
	for name in DirAccess.get_directories_at(dir + "/models"):
		var doc := GLTFDocument.new()
		var state := GLTFState.new()
		if doc.append_from_file("%s/models/%s/%s.gltf" % [dir, name, name], state) == OK:
			models[name] = doc.generate_scene(state)
	var counts := {"tree": 220, "sapling": 200, "rock": 60, "fern": 220, "grass": 500, "stump": 30, "trunk": 25}
	for name: String in models:
		var n := 40
		for key: String in counts:
			if key in name:
				n = counts[key]
		for k in n:
			var copy: Node3D = models[name].duplicate()
			var x := rng.randf_range(-SIZE / 2 + 4, SIZE / 2 - 4)
			var z := rng.randf_range(-SIZE / 2 + 4, SIZE / 2 - 4)
			copy.position = Vector3(x, height.call(x, z) - 0.1, z)
			copy.rotation.y = rng.randf_range(0, TAU)
			copy.scale = Vector3.ONE * rng.randf_range(0.7, 1.4)
			add_child(copy)
			if "tree" in name or "rock" in name or "stump" in name or "trunk" in name:
				var body := StaticBody3D.new()
				var shape := CollisionShape3D.new()
				var cyl := CylinderShape3D.new()
				cyl.radius = 0.6 if "tree" in name else 1.0
				cyl.height = 8.0
				shape.shape = cyl
				body.add_child(shape)
				body.position = copy.position
				add_child(body)

	var env := Environment.new()
	var sky := Sky.new()
	var sky_mat := PanoramaSkyMaterial.new()
	var img := Image.load_from_file(dir + "/sky.hdr")
	if img != null:
		sky_mat.panorama = ImageTexture.create_from_image(img)
	sky.sky_material = sky_mat
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_AGX
	env.volumetric_fog_enabled = true
	env.volumetric_fog_density = rng.randf_range(0.005, 0.03)
	env.ssao_enabled = true
	var world := WorldEnvironment.new()
	world.environment = env
	add_child(world)
	var sun := DirectionalLight3D.new()
	sun.rotation = Vector3(rng.randf_range(-1.2, -0.35), rng.randf_range(0, TAU), 0)
	sun.shadow_enabled = true
	sun.light_volumetric_fog_energy = 1.5
	add_child(sun)


func _tex(path: String) -> Texture2D:
	var img := Image.load_from_file(path)
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)
