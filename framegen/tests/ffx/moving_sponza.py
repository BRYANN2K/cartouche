# Writes a copy of the FSR sample's Sponza scene that moves: every root but the cameras goes under
# one node, translated back and forth, so the view pans as if the camera did. The sample's own
# camera stays still and only moves on keyboard input, which a test without focus cannot give.
# The copy lives outside the sample's folders and points back at its buffers and textures.
# A yaw in degrees and a depth amplitude make it hard: the scene turns around its origin, away from
# the camera, so near columns sweep across far walls, and comes closer then goes back.
# Usage: python3 -I moving_sponza.py <MainSponza.gltf> <out dir> [amplitude] [period s] [yaw] [depth]
import json
import math
import os
import struct
import sys

source, out = sys.argv[1], sys.argv[2]
amplitude = float(sys.argv[3]) if len(sys.argv) > 3 else 2.0
period = float(sys.argv[4]) if len(sys.argv) > 4 else 8.0
yaw = float(sys.argv[5]) if len(sys.argv) > 5 else 0.0
depth = float(sys.argv[6]) if len(sys.argv) > 6 else 0.0
os.makedirs(out, exist_ok=True)
with open(source) as f:
    scene = json.load(f)

back = os.path.relpath(os.path.dirname(os.path.abspath(source)), os.path.abspath(out))
for entry in scene.get("buffers", []) + scene.get("images", []):
    if "uri" in entry and not entry["uri"].startswith("data:"):
        entry["uri"] = back + "/" + entry["uri"]


def has_camera(index):
    node = scene["nodes"][index]
    return "camera" in node or node.get("name", "").startswith("PhysCamera") or any(
        has_camera(c) for c in node.get("children", []))


roots = scene["scenes"][0]["nodes"]
moving = [r for r in roots if not has_camera(r)]
mover = len(scene["nodes"])
scene["nodes"].append({"name": "Mover", "children": moving})
scene["scenes"][0]["nodes"] = [r for r in roots if r not in moving] + [mover]

steps = 160
times = [period * i / steps for i in range(steps + 1)]
offsets = [(amplitude * math.sin(2 * math.pi * t / period), 0.0, depth * math.sin(4 * math.pi * t / period)) for t in times]
turns = [math.radians(yaw) * math.sin(2 * math.pi * t / period + 1.0) for t in times]
rotations = [(0.0, math.sin(a / 2), 0.0, math.cos(a / 2)) for a in turns]
data = struct.pack("<%df" % len(times), *times) + b"".join(struct.pack("<3f", *o) for o in offsets)
data += b"".join(struct.pack("<4f", *q) for q in rotations)
with open(os.path.join(out, "mover.bin"), "wb") as f:
    f.write(data)
buffer = len(scene["buffers"])
scene["buffers"].append({"uri": "mover.bin", "byteLength": len(data)})
views = len(scene["bufferViews"])
scene["bufferViews"] += [{"buffer": buffer, "byteOffset": 0, "byteLength": 4 * len(times)},
                         {"buffer": buffer, "byteOffset": 4 * len(times), "byteLength": 12 * len(times)},
                         {"buffer": buffer, "byteOffset": 16 * len(times), "byteLength": 16 * len(times)}]
accessors = len(scene["accessors"])
scene["accessors"] += [{"bufferView": views, "componentType": 5126, "count": len(times), "type": "SCALAR",
                        "min": [times[0]], "max": [times[-1]]},
                       {"bufferView": views + 1, "componentType": 5126, "count": len(times), "type": "VEC3"},
                       {"bufferView": views + 2, "componentType": 5126, "count": len(times), "type": "VEC4"}]
scene["animations"] = [{"name": "pan", "samplers": [{"input": accessors, "output": accessors + 1, "interpolation": "LINEAR"},
                                                     {"input": accessors, "output": accessors + 2, "interpolation": "LINEAR"}],
                        "channels": [{"sampler": 0, "target": {"node": mover, "path": "translation"}},
                                     {"sampler": 1, "target": {"node": mover, "path": "rotation"}}]}]
with open(os.path.join(out, "MovingSponza.gltf"), "w") as f:
    json.dump(scene, f)
print("moving %d of %d roots, amplitude %.1f, period %.1f s, yaw %.0f, depth %.1f" % (len(moving), len(roots), amplitude,
                                                                                    period, yaw, depth))
