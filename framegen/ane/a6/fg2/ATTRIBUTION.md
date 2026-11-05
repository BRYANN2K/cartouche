# Cartouche FG 2 training data: sources and credits

The FG 2 network is trained on frames rendered or captured from the works below. No frame, asset or
file of theirs ships with Cartouche: only the trained weights do. Licences checked on 2026-10-28.
Training uses only permissive or attribution-only content (CC0, CC BY, MIT, BSD), so the weights carry
no share-alike term. GPL programs (Woof!, Godot's and Blender's own code) only render the frames; their
licence does not reach what they draw.

## Kept

| Source | Used for | Licence | Credit |
|---|---|---|---|
| Freedoom 0.13.0 (freedoom1.wad, freedoom2.wad, built-in demos DEMO1 to DEMO4) | Woof! demo playback | BSD 3-Clause | Contributors to the Freedoom project, https://freedoom.github.io |
| Woof! 16.0.0 | Doom engine that plays the demos (no art of its own) | GPL-2.0+ (program only) | Fabian Greffrath and contributors |
| Godot demo projects (3d/platformer, 3d/truck_town, 3d/volumetric_fog) | Movie maker with our camera | MIT | Godot Engine contributors |
| Godot TPS demo | Movie maker with our camera | Code MIT; assets and music CC BY 3.0 | Juan Linietsky, Fernando Miguel Calabró; music Christian Fernando Perucchi |
| Bistro-Demo-Tweaked | Movie maker with our camera | Code MIT; assets CC BY 4.0 (visuals). Some sounds are CC BY-NC 4.0: not used, audio is off | John James Gutib; Lumberyard Bistro Reference Scene by Logan Preshaw; Amazon Lumberyard Bistro by Amazon Lumberyard (CC BY 4.0) |
| Poly Haven: fir_sapling_medium, tree_small_02, dead_tree_trunk_02, tree_stump_01, rock_moss_set_01, rock_moss_set_02, fern_02, grass_medium_01, grass_medium_02, forest_ground_04, kloofendal_48d_partly_cloudy_puresky | Our forest scene (fg2/godot/fg2_forest.gd) | CC0 | Poly Haven, https://polyhaven.com |
| Blender demo: Classroom | EEVEE clips with our camera | CC0 | Christophe Seux, Blender Foundation |
| Blender demo: Italian Flat (flat-archiviz) | EEVEE clips | CC BY | Flavio Della Tommasa, https://download.blender.org/demo/cycles/flat-archiviz.blend |
| Blender benchmark: Agent 327 Barbershop | EEVEE clips | CC BY | Blender Animation Studio, https://svn.blender.org/svnroot/bf-blender/trunk/lib/benchmarks/cycles/barbershop_interior/ (skipped if the download fails) |
| Blender benchmark: Cosmos Laundromat (victor) | EEVEE clips | CC BY | Blender Institute, Cosmos Laundromat, https://download.blender.org/demo/test/benchmark.zip |
| Netflix Nocturne (120 fps EXR frames) | Real footage at 120 fps | CC BY 4.0 | © Netflix, Inc., Nocturne, https://opencontent.netflix.com |
| Big Buck Bunny 60 fps (FG 1 data, reused) | Film triplets | CC BY 3.0 | © Blender Foundation, www.bigbuckbunny.org |
| Aileron (Pillow's default font) | HUD text drawn over 30 % of the samples | CC0 | Sora Sagano |

## Test only (never trained on)

| Source | Licence | Credit |
|---|---|---|
| Sintel trailer | CC BY 3.0 | © Blender Foundation, www.sintel.org |
| OpenTTD 15.3 title game with OpenGFX 8.0 | GPL-2.0 (scores only, no weight learns from it) | OpenTTD team; OpenGFX team |

## Left out tonight

| Source | Why |
|---|---|
| SuperTuxKart 1.5, 0 A.D. 0.28.0, The Battle for Wesnoth 1.18.8 | Art under CC BY-SA (and GPL for some SuperTuxKart assets): weights trained on it could inherit share-alike terms. Capture code kept behind `FG2_SHAREALIKE=1`, off until an ADR accepts it |
| Intel Sponza, Jungle Ruins, Animated Knight | 3.7, 4.0 and 1.1 GB packages: no room above the 15 GB disk floor with the rest |
| Beeple Zero-Day | No direct download found |
| JangaFX VDB | MediaFire pages only, no plain download |
| Spring (Blender Studio) | Not freely downloadable; Italian Flat replaces it |
| Poly Haven fir_tree_01, pine_tree_01, pine_sapling_medium | 0.25 to 0.9 GB each at 1k |
