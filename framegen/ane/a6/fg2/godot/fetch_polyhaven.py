# Downloads the forest's assets from Poly Haven (CC0): glTF models at 1k, a ground texture and a sky.
# Usage: fetch_polyhaven.py <dir>
import json, os, sys, urllib.request

# The big scanned trees (fir_tree_01, pine_tree_01: 0.5 to 0.9 GB each at 1k) are left out
MODELS = ["fir_sapling_medium", "tree_small_02",
          "dead_tree_trunk_02", "tree_stump_01", "rock_moss_set_01", "rock_moss_set_02", "fern_02",
          "grass_medium_01", "grass_medium_02"]
GROUND, SKY = "forest_ground_04", "kloofendal_48d_partly_cloudy_puresky"
root = sys.argv[1]


def get(url, path=None):
	req = urllib.request.Request(url, headers={"User-Agent": "cartouche-fg2-dataset"})
	with urllib.request.urlopen(req, timeout=120) as r:
		data = r.read()
	if path is None:
		return json.loads(data)
	os.makedirs(os.path.dirname(path), exist_ok=True)
	with open(path, "wb") as f:
		f.write(data)


for model in MODELS:
	files = get(f"https://api.polyhaven.com/files/{model}")["gltf"]["1k"]["gltf"]
	if os.path.exists(f"{root}/models/{model}/{model}.gltf"):
		continue
	for rel, item in files.get("include", {}).items():
		get(item["url"], f"{root}/models/{model}/{rel}")
	get(files["url"], f"{root}/models/{model}/{model}.gltf")
	print("model", model, flush=True)
tex = get(f"https://api.polyhaven.com/files/{GROUND}")
for kind, key in (("Diffuse", "diff"), ("nor_gl", "nor"), ("Rough", "rough")):
	get(tex[kind]["2k"]["jpg"]["url"], f"{root}/ground/{key}.jpg")
get(get(f"https://api.polyhaven.com/files/{SKY}")["hdri"]["2k"]["hdr"]["url"], f"{root}/sky.hdr")
print("ground and sky done")
with open(f"{root}/LICENSE.txt", "w") as f:
	f.write("Assets from Poly Haven (https://polyhaven.com), CC0 1.0: " + ", ".join(MODELS + [GROUND, SKY]) + "\n")
