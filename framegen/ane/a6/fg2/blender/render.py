# Renders a short clip of a .blend with EEVEE at a high frame rate: the file's own animation is
# slowed down by time remapping (so every frame is a true in-between), and the camera moves on a rig
# of ours. No motion blur.
# Usage: blender -b <file.blend> --python-exit-code 1 -P render.py -- <out dir> <fps> <frames> <seed> [WxH]
import math, os, random, sys
import bpy
from mathutils import Vector

out, fps, frames, seed = sys.argv[sys.argv.index("--") + 1:][:4]
size = sys.argv[sys.argv.index("--") + 5] if len(sys.argv) > sys.argv.index("--") + 5 else "960x540"
fps, frames = int(fps), int(frames)
rng = random.Random(int(seed))
scene = bpy.context.scene
r = scene.render

engines = [e.identifier for e in r.bl_rna.properties["engine"].enum_items]
r.engine = "BLENDER_EEVEE" if "BLENDER_EEVEE" in engines else "BLENDER_EEVEE_NEXT"
eevee = scene.eevee
for name, value in (("taa_render_samples", 16), ("use_motion_blur", False), ("use_raytracing", False)):
	if hasattr(eevee, name):
		setattr(eevee, name, value)
if hasattr(r, "use_motion_blur"):
	r.use_motion_blur = False
r.resolution_x, r.resolution_y = (int(v) for v in size.split("x"))
r.resolution_percentage = 100
r.image_settings.file_format = "PNG"
r.image_settings.color_mode = "RGB"
r.image_settings.color_depth = "8"
r.use_compositing = False
r.use_sequencer = False

# Slow the file's animation down so that its own fps becomes ours
old = max(1, round(r.fps / r.fps_base))
r.frame_map_old, r.frame_map_new = 100, max(100, round(100 * fps / old))
r.fps, r.fps_base = fps, 1
stretch = r.frame_map_new / r.frame_map_old
first = int(scene.frame_start * stretch)
last = max(first + frames, int(scene.frame_end * stretch))
start = rng.randint(first, max(first, last - frames))
scene.frame_start, scene.frame_end = start, start + frames - 1

cam = scene.camera
if cam is None:
	data = bpy.data.cameras.new("fg2")
	cam = bpy.data.objects.new("fg2", data)
	scene.collection.objects.link(cam)
	scene.camera = cam
scene.frame_set(start)
rig = bpy.data.objects.new("fg2_rig", None)
scene.collection.objects.link(rig)
rig.location = cam.matrix_world.translation.copy()
world = cam.matrix_world.copy()
cam.parent = rig
bpy.context.view_layer.update()
cam.matrix_parent_inverse = rig.matrix_world.inverted()
cam.matrix_world = world

# Camera move over the clip: a pan, a dolly and a little shake, in scene units scaled to the view
seconds = frames / fps
dist = sorted((o.matrix_world.translation - rig.location).length for o in scene.objects if o.type == "MESH")
near = dist[len(dist) // 4] if dist else 5.0
reach = near * rng.uniform(0.3, 1.5) * seconds
forward = cam.matrix_world.to_quaternion() @ Vector((0, 0, -1))
side = cam.matrix_world.to_quaternion() @ Vector((1, 0, 0))
move = forward * rng.uniform(-1, 1) * reach + side * rng.uniform(-1, 1) * reach
pan = math.radians(rng.uniform(-90, 90)) * seconds
tilt = math.radians(rng.uniform(-8, 8))
steps = 8
base = rig.location.copy()
for i in range(steps + 1):
	f = i / steps
	ease = f * f * (3 - 2 * f) if rng.random() < 0.5 else f
	rig.location = base + move * ease
	rig.rotation_euler = (tilt * math.sin(math.pi * f), 0.02 * math.sin(7 * f), pan * ease)
	rig.keyframe_insert("location", frame=start + round(f * (frames - 1)))
	rig.keyframe_insert("rotation_euler", frame=start + round(f * (frames - 1)))

os.makedirs(out, exist_ok=True)
r.filepath = os.path.join(out, "f")
bpy.ops.render.render(animation=True)
print(f"fg2: rendered {frames} frames at {fps} fps from frame {start} (stretch {stretch:.2f})")
