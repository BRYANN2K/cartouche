// Motion for the frame interpolator, estimated from the presented frames alone. Two estimators:
// block matching on luma at a reduced size, or a coarse-to-fine search on a luma pyramid, checked
// both ways. Then one vector per output pixel, optionally refined per pixel, with still pixels
// held at zero. BLOCK and RADIUS come from the compile options, so the search can be tuned live.

#include <metal_stdlib>
using namespace metal;

#ifndef BLOCK
#define BLOCK 8
#endif
#ifndef RADIUS
#define RADIUS 16
#endif

constant int block = BLOCK;
constant int radius = RADIUS;
constant int window = block + 2 * radius;
// Colour change below which a pixel counts as the same (still pixels, UI over a composited frame)
constant float same_step = 1.5 / 255;

struct Motion {
	float bias;      // cost per pixel of distance, keeps flat areas still
	float scale;     // analysis pixels to output pixels
	uint expand;     // 0 bilinear, 1 nearest, 2 refined per pixel
	uint zero;       // 1: no motion at all
	uint still;      // 1: pixels that did not change keep no motion
};

static float luma(float3 c) { return dot(c, float3(0.299, 0.587, 0.114)); }

kernel void luma_reduce(texture2d<float, access::read> color [[texture(0)]],
                        texture2d<half, access::write> out [[texture(1)]],
                        constant uint &factor [[buffer(0)]],
                        uint2 gid [[thread_position_in_grid]])
{
	if (gid.x >= out.get_width() || gid.y >= out.get_height())
		return;
	uint2 size = uint2(color.get_width(), color.get_height());
	float sum = 0;
	for (uint y = 0; y < factor; y++)
		for (uint x = 0; x < factor; x++)
			sum += luma(color.read(min(gid * factor + uint2(x, y), size - 1)).rgb);
	out.write(half4(sum / float(factor * factor)), gid);
}

// One threadgroup of block x block threads per block. The vector points from a pixel of the
// current frame to where it was in the previous one, in analysis pixels.
kernel void block_match(texture2d<half, access::read> prev [[texture(0)]],
                        texture2d<half, access::read> cur [[texture(1)]],
                        texture2d<half, access::write> vectors [[texture(2)]],
                        constant Motion &m [[buffer(0)]],
                        uint2 group [[threadgroup_position_in_grid]],
                        uint2 local [[thread_position_in_threadgroup]],
                        uint index [[thread_index_in_threadgroup]])
{
	threadgroup half here[block][block];
	threadgroup half area[window][window];
	threadgroup uint best[block * block];

	int2 size = int2(cur.get_width(), cur.get_height());
	int2 origin = int2(group) * block;
	here[local.y][local.x] = cur.read(uint2(clamp(origin + int2(local), int2(0), size - 1))).r;
	for (int i = int(index); i < window * window; i += block * block) {
		int2 at = origin - radius + int2(i % window, i / window);
		area[i / window][i % window] = prev.read(uint2(clamp(at, int2(0), size - 1))).r;
	}
	threadgroup_barrier(mem_flags::mem_threadgroup);

	const int side = 2 * radius + 1;
	uint chosen = 0xffffffffu;
	for (int c = int(index); c < side * side; c += block * block) {
		int2 offset = int2(c % side, c / side);
		float cost = 0;
		for (int y = 0; y < block; y++)
			for (int x = 0; x < block; x++)
				cost += abs(float(here[y][x]) - float(area[offset.y + y][offset.x + x]));
		int2 shift = offset - radius;
		cost += m.bias * float(abs(shift.x) + abs(shift.y));
		// Cost in the high 20 bits, candidate in the low 12, so one min picks both
		uint key = (min(uint(cost * 64.0), 0xfffffu) << 12) | uint(c);
		chosen = min(chosen, key);
	}
	best[index] = chosen;
	threadgroup_barrier(mem_flags::mem_threadgroup);
	for (uint step = block * block / 2; step > 0; step /= 2) {
		if (index < step)
			best[index] = min(best[index], best[index + step]);
		threadgroup_barrier(mem_flags::mem_threadgroup);
	}
	if (index == 0) {
		int c = int(best[0] & 0xfffu);
		int2 shift = int2(c % side, c / side) - radius;
		vectors.write(half4(half(shift.x), half(shift.y), 0, 0), group);
	}
}

kernel void median_blocks(texture2d<half, access::read> vectors [[texture(0)]],
                          texture2d<half, access::write> smooth [[texture(1)]],
                          constant uint &enabled [[buffer(0)]],
                          uint2 gid [[thread_position_in_grid]])
{
	int2 size = int2(vectors.get_width(), vectors.get_height());
	if (int(gid.x) >= size.x || int(gid.y) >= size.y)
		return;
	if (enabled == 0) {
		smooth.write(vectors.read(gid), gid);
		return;
	}
	half xs[9], ys[9];
	int n = 0;
	for (int y = -1; y <= 1; y++)
		for (int x = -1; x <= 1; x++) {
			half2 v = vectors.read(uint2(clamp(int2(gid) + int2(x, y), int2(0), size - 1))).rg;
			xs[n] = v.x;
			ys[n] = v.y;
			n++;
		}
	for (int i = 1; i < 9; i++)
		for (int j = i; j > 0 && xs[j] < xs[j - 1]; j--) {
			half t = xs[j]; xs[j] = xs[j - 1]; xs[j - 1] = t;
		}
	for (int i = 1; i < 9; i++)
		for (int j = i; j > 0 && ys[j] < ys[j - 1]; j--) {
			half t = ys[j]; ys[j] = ys[j - 1]; ys[j - 1] = t;
		}
	smooth.write(half4(xs[4], ys[4], 0, 0), gid);
}

// Full-size vectors in output pixels. Refined: each pixel takes, among the vectors of its block
// and the eight around it, the one whose 3x3 neighbourhood matches the previous frame best, so
// a moving edge does not drag the background along.
kernel void expand_motion(texture2d<half, access::sample> smooth [[texture(0)]],
                          texture2d<half, access::write> motion [[texture(1)]],
                          texture2d<float, access::read> cur [[texture(2)]],
                          texture2d<float, access::read> prev [[texture(3)]],
                          texture2d<uint, access::read> count [[texture(4)]],
                          constant Motion &m [[buffer(0)]],
                          constant uint &cell [[buffer(1)]],
                          uint2 gid [[thread_position_in_grid]])
{
	uint2 size = uint2(motion.get_width(), motion.get_height());
	if (gid.x >= size.x || gid.y >= size.y)
		return;
	if (m.zero != 0) {
		motion.write(half4(0), gid);
		return;
	}
	// A HUD or any other still part: the same pixels as the frame before, so no motion at all.
	// When the HUD pass already tracks unchanged pixels its count answers the same question
	if (m.still == 2) {
		uint2 at = uint2(float2(gid) * float2(uint2(count.get_width(), count.get_height())) /
		                 float2(size));
		if (count.read(at).r > 0) {
			motion.write(half4(0), gid);
			return;
		}
	} else if (m.still != 0) {
		float same = 0;
		for (int y = -1; y <= 1; y++)
			for (int x = -1; x <= 1; x++) {
				uint2 p = uint2(clamp(int2(gid) + int2(x, y), int2(0), int2(size) - 1));
				same += abs(luma(cur.read(p).rgb) - luma(prev.read(p).rgb));
			}
		if (same < 0.02) {
			motion.write(half4(0), gid);
			return;
		}
	}
	float2 v;
	if (m.expand == 0) {
		constexpr sampler linear(filter::linear, address::clamp_to_edge);
		v = float2(smooth.sample(linear, (float2(gid) + 0.5) / float2(size)).rg);
	} else {
		int2 grid = int2(smooth.get_width(), smooth.get_height());
		int2 home = clamp(int2(gid / cell), int2(0), grid - 1);
		v = float2(smooth.read(uint2(home)).rg);
		if (m.expand == 2) {
			float best = INFINITY;
			for (int by = -1; by <= 1; by++)
				for (int bx = -1; bx <= 1; bx++) {
					float2 c = float2(smooth.read(uint2(clamp(home + int2(bx, by), int2(0), grid - 1))).rg) * m.scale;
					float cost = 0;
					for (int y = -1; y <= 1; y++)
						for (int x = -1; x <= 1; x++) {
							int2 p = clamp(int2(gid) + int2(x, y), int2(0), int2(size) - 1);
							int2 q = clamp(int2(float2(p) + c + 0.5), int2(0), int2(size) - 1);
							cost += abs(luma(cur.read(uint2(p)).rgb) - luma(prev.read(uint2(q)).rgb));
						}
					cost += 0.001 * (abs(c.x) + abs(c.y));
					if (cost < best) {
						best = cost;
						v = c / m.scale;
					}
				}
		}
	}
	motion.write(half4(half2(v * m.scale), 0, 0), gid);
}

// Diagnostic outputs in place of the interpolator
kernel void blend_frames(texture2d<float, access::read> prev [[texture(0)]],
                         texture2d<float, access::read> cur [[texture(1)]],
                         texture2d<float, access::write> out [[texture(2)]],
                         uint2 gid [[thread_position_in_grid]])
{
	if (gid.x >= out.get_width() || gid.y >= out.get_height())
		return;
	out.write(mix(prev.read(gid), cur.read(gid), 0.5), gid);
}

kernel void show_motion(texture2d<half, access::read> motion [[texture(0)]],
                        texture2d<float, access::read> cur [[texture(1)]],
                        texture2d<float, access::write> out [[texture(2)]],
                        uint2 gid [[thread_position_in_grid]])
{
	if (gid.x >= out.get_width() || gid.y >= out.get_height())
		return;
	uint2 at = gid * uint2(motion.get_width(), motion.get_height()) / uint2(out.get_width(), out.get_height());
	float2 v = float2(motion.read(at).rg);
	float strength = saturate(length(v) / 32.0);
	float angle = atan2(v.y, v.x);
	float3 hue = 0.5 + 0.5 * cos(angle + float3(0, 2.094, 4.189));
	float3 base = cur.read(gid).rgb * 0.35;
	out.write(float4(mix(base, hue, strength), 1), gid);
}

// Pyramid estimator. Each level halves the one below; the search starts on the smallest one and
// each finer level only refines what the coarser one found, so large motion costs little.

kernel void luma_down(texture2d<half, access::read> fine [[texture(0)]],
                      texture2d<half, access::write> coarse [[texture(1)]],
                      uint2 gid [[thread_position_in_grid]])
{
	if (gid.x >= coarse.get_width() || gid.y >= coarse.get_height())
		return;
	uint2 last = uint2(fine.get_width(), fine.get_height()) - 1;
	uint2 at = gid * 2;
	half sum = fine.read(min(at, last)).r + fine.read(min(at + uint2(1, 0), last)).r +
	           fine.read(min(at + uint2(0, 1), last)).r + fine.read(min(at + uint2(1, 1), last)).r;
	coarse.write(half4(sum * 0.25h), gid);
}

// The whole pyramid under one 16x16 luma tile: level 2 sits inside it, then 3, 4 and 5, so one
// dispatch of 16x16 threads per tile replaces one dispatch per level
kernel void luma_pyramid(texture2d<half, access::read> l0 [[texture(0)]],
                         texture2d<half, access::write> l1 [[texture(1)]],
                         texture2d<half, access::write> l2 [[texture(2)]],
                         texture2d<half, access::write> l3 [[texture(3)]],
                         texture2d<half, access::write> l4 [[texture(4)]],
                         texture2d<half, access::write> l5 [[texture(5)]],
                         constant uint &depth [[buffer(0)]],
                         uint2 gid [[thread_position_in_grid]],
                         uint2 lid [[thread_position_in_threadgroup]],
                         uint2 tgid [[threadgroup_position_in_grid]])
{
	threadgroup half t0[256], t1[64], t2[16], t3[4];
	uint2 last = uint2(l0.get_width(), l0.get_height()) - 1;
	uint2 at = gid * 2;
	half v = (l0.read(min(at, last)).r + l0.read(min(at + uint2(1, 0), last)).r +
	          l0.read(min(at + uint2(0, 1), last)).r + l0.read(min(at + uint2(1, 1), last)).r) * 0.25h;
	t0[lid.y * 16 + lid.x] = v;
	uint2 s1 = uint2(l1.get_width(), l1.get_height());
	if (gid.x < s1.x && gid.y < s1.y)
		l1.write(half4(v), gid);
	threadgroup_barrier(mem_flags::mem_threadgroup);
	if (depth < 2)
		return;
	if (lid.x < 8 && lid.y < 8) {
		uint2 g = tgid * 8 + lid;
		int2 base = int2(tgid) * 16;
		half sum = 0;
		for (int y = 0; y < 2; y++)
			for (int x = 0; x < 2; x++) {
				int2 p = min(int2(2 * g) + int2(x, y), int2(s1) - 1) - base;
				sum += t0[p.y * 16 + p.x];
			}
		v = sum * 0.25h;
		t1[lid.y * 8 + lid.x] = v;
		uint2 s2 = uint2(l2.get_width(), l2.get_height());
		if (g.x < s2.x && g.y < s2.y)
			l2.write(half4(v), g);
	}
	threadgroup_barrier(mem_flags::mem_threadgroup);
	if (depth < 3)
		return;
	if (lid.x < 4 && lid.y < 4) {
		uint2 g = tgid * 4 + lid;
		int2 base = int2(tgid) * 8;
		uint2 s2 = uint2(l2.get_width(), l2.get_height());
		half sum = 0;
		for (int y = 0; y < 2; y++)
			for (int x = 0; x < 2; x++) {
				int2 p = min(int2(2 * g) + int2(x, y), int2(s2) - 1) - base;
				sum += t1[p.y * 8 + p.x];
			}
		v = sum * 0.25h;
		t2[lid.y * 4 + lid.x] = v;
		uint2 s3 = uint2(l3.get_width(), l3.get_height());
		if (g.x < s3.x && g.y < s3.y)
			l3.write(half4(v), g);
	}
	threadgroup_barrier(mem_flags::mem_threadgroup);
	if (depth < 4)
		return;
	if (lid.x < 2 && lid.y < 2) {
		uint2 g = tgid * 2 + lid;
		int2 base = int2(tgid) * 4;
		uint2 s3 = uint2(l3.get_width(), l3.get_height());
		half sum = 0;
		for (int y = 0; y < 2; y++)
			for (int x = 0; x < 2; x++) {
				int2 p = min(int2(2 * g) + int2(x, y), int2(s3) - 1) - base;
				sum += t2[p.y * 4 + p.x];
			}
		v = sum * 0.25h;
		t3[lid.y * 2 + lid.x] = v;
		uint2 s4 = uint2(l4.get_width(), l4.get_height());
		if (g.x < s4.x && g.y < s4.y)
			l4.write(half4(v), g);
	}
	threadgroup_barrier(mem_flags::mem_threadgroup);
	if (depth < 5 || any(lid != uint2(0)))
		return;
	uint2 s4 = uint2(l4.get_width(), l4.get_height()), s5 = uint2(l5.get_width(), l5.get_height());
	int2 base = int2(tgid) * 2;
	half sum = 0;
	for (int y = 0; y < 2; y++)
		for (int x = 0; x < 2; x++) {
			int2 p = min(int2(2 * tgid) + int2(x, y), int2(s4) - 1) - base;
			sum += t3[p.y * 2 + p.x];
		}
	if (tgid.x < s5.x && tgid.y < s5.y)
		l5.write(half4(sum * 0.25h), tgid);
}

struct Level {
	int radius;   // refinement search around the best candidate, in pixels of this level
	int top;      // 1 on the smallest level: no coarser estimate; 2: coarser is the other way's field, same size
	float bias;   // cost per pixel away from the candidate, keeps the field smooth
};

// Cells of 4x4 pixels, each matched with the 8x8 window around it, so neighbouring windows
// overlap. The vector points from the cell in "from" to where it is in "to", in pixels of this level.
static float window_cost(thread const half *here, texture2d<half, access::read> to, int2 origin, int2 v, int2 size)
{
	float cost = 0;
	for (int y = 0; y < 8; y++)
		for (int x = 0; x < 8; x++) {
			int2 p = clamp(origin + int2(x, y) + v, int2(0), size - 1);
			cost += abs(float(here[y * 8 + x]) - float(to.read(uint2(p)).r));
		}
	return cost;
}

kernel void flow_level(texture2d<half, access::read> from [[texture(0)]],
                       texture2d<half, access::read> to [[texture(1)]],
                       texture2d<half, access::read> coarser [[texture(2)]],
                       texture2d<half, access::write> out [[texture(3)]],
                       constant Level &l [[buffer(0)]],
                       uint2 gid [[thread_position_in_grid]])
{
	if (gid.x >= out.get_width() || gid.y >= out.get_height())
		return;
	int2 size = int2(from.get_width(), from.get_height());
	int2 origin = int2(gid) * 4 - 2;
	half here[64];
	for (int y = 0; y < 8; y++)
		for (int x = 0; x < 8; x++)
			here[y * 8 + x] = from.read(uint2(clamp(origin + int2(x, y), int2(0), size - 1))).r;

	// Candidates: no motion, and the coarser level's vector here and around, scaled up
	int2 best = int2(0);
	float bestCost = window_cost(here, to, origin, best, size);
	if (l.top == 2) {
		// The way back starts from the way there, reversed, here and around
		int2 grid = int2(coarser.get_width(), coarser.get_height());
		for (int y = -1; y <= 1; y++)
			for (int x = -1; x <= 1; x++) {
				int2 v = int2(round(-float2(coarser.read(uint2(clamp(int2(gid) + int2(x, y), int2(0), grid - 1))).rg)));
				float cost = window_cost(here, to, origin, v, size);
				if (cost < bestCost) {
					bestCost = cost;
					best = v;
				}
			}
	} else if (l.top == 0) {
		int2 grid = int2(coarser.get_width(), coarser.get_height());
		int2 home = int2(gid) / 2;
		const int2 around[5] = { int2(0, 0), int2(-1, 0), int2(1, 0), int2(0, -1), int2(0, 1) };
		for (int i = 0; i < 5; i++) {
			int2 v = int2(round(float2(coarser.read(uint2(clamp(home + around[i], int2(0), grid - 1))).rg) * 2.0));
			float cost = window_cost(here, to, origin, v, size);
			if (cost < bestCost) {
				bestCost = cost;
				best = v;
			}
		}
	}
	int2 center = best;
	for (int dy = -l.radius; dy <= l.radius; dy++)
		for (int dx = -l.radius; dx <= l.radius; dx++) {
			if (dx == 0 && dy == 0)
				continue;
			int2 v = center + int2(dx, dy);
			float cost = window_cost(here, to, origin, v, size) + l.bias * float(abs(dx) + abs(dy));
			if (cost < bestCost) {
				bestCost = cost;
				best = v;
			}
		}

	// Sub-pixel: a parabola through the costs on each side of the best vector
	float2 v = float2(best);
	float cx0 = window_cost(here, to, origin, best - int2(1, 0), size);
	float cx1 = window_cost(here, to, origin, best + int2(1, 0), size);
	float cy0 = window_cost(here, to, origin, best - int2(0, 1), size);
	float cy1 = window_cost(here, to, origin, best + int2(0, 1), size);
	float c = window_cost(here, to, origin, best, size);
	float dxs = cx0 + cx1 - 2 * c, dys = cy0 + cy1 - 2 * c;
	if (dxs > 1e-4)
		v.x += clamp(0.5 * (cx0 - cx1) / dxs, -0.5, 0.5);
	if (dys > 1e-4)
		v.y += clamp(0.5 * (cy0 - cy1) / dys, -0.5, 0.5);
	out.write(half4(half2(v), half(c / 64.0), 1), gid);
}

// Each cell tries the vectors its eight neighbours found and keeps the best match, a little in
// favour of its own: repeated textures match in several places, and the neighbours settle which.
kernel void flow_propagate(texture2d<half, access::read> from [[texture(0)]],
                           texture2d<half, access::read> to [[texture(1)]],
                           texture2d<half, access::read> field [[texture(2)]],
                           texture2d<half, access::write> out [[texture(3)]],
                           constant Level &l [[buffer(0)]],
                           uint2 gid [[thread_position_in_grid]])
{
	int2 grid = int2(field.get_width(), field.get_height());
	if (int(gid.x) >= grid.x || int(gid.y) >= grid.y)
		return;
	int2 size = int2(from.get_width(), from.get_height());
	int2 origin = int2(gid) * 4 - 2;
	half here[64];
	for (int y = 0; y < 8; y++)
		for (int x = 0; x < 8; x++)
			here[y * 8 + x] = from.read(uint2(clamp(origin + int2(x, y), int2(0), size - 1))).r;
	half4 own = field.read(gid);
	float2 best = float2(own.rg);
	float bestCost = window_cost(here, to, origin, int2(round(best)), size);
	for (int y = -1; y <= 1; y++)
		for (int x = -1; x <= 1; x++) {
			float2 v = float2(field.read(uint2(clamp(int2(gid) + int2(x, y), int2(0), grid - 1))).rg);
			if (x == 0 && y == 0)
				continue;
			float cost = window_cost(here, to, origin, int2(round(v)), size) + l.bias * 4;
			if (cost < bestCost) {
				bestCost = cost;
				best = v;
			}
		}
	out.write(half4(half2(best), half(bestCost / 64.0), 1), gid);
}

// The forward vector of a cell, followed into the other frame, must come back with the backward
// vector found there. Where it does not, the cell is uncovered or covered between the frames, and
// it takes the best matching vector among its neighbours that do pass.
kernel void flow_check(texture2d<half, access::read> forward [[texture(0)]],
                       texture2d<half, access::read> backward [[texture(1)]],
                       texture2d<half, access::write> out [[texture(2)]],
                       constant float &tolerance [[buffer(0)]],
                       uint2 gid [[thread_position_in_grid]])
{
	int2 grid = int2(forward.get_width(), forward.get_height());
	if (int(gid.x) >= grid.x || int(gid.y) >= grid.y)
		return;
	half4 f = forward.read(gid);
	int2 there = clamp(int2(round((float2(gid) * 4 + 2 + float2(f.rg)) / 4 - 0.5)), int2(0), grid - 1);
	float miss = length(float2(f.rg) + float2(backward.read(uint2(there)).rg));
	if (miss <= tolerance) {
		out.write(half4(f.rg, f.b, 1), gid);
		return;
	}
	half4 chosen = half4(f.rg, f.b, 0);
	float bestCost = INFINITY;
	for (int y = -2; y <= 2; y++)
		for (int x = -2; x <= 2; x++) {
			int2 q = clamp(int2(gid) + int2(x, y), int2(0), grid - 1);
			half4 n = forward.read(uint2(q));
			int2 back = clamp(int2(round((float2(q) * 4 + 2 + float2(n.rg)) / 4 - 0.5)), int2(0), grid - 1);
			if (length(float2(n.rg) + float2(backward.read(uint2(back)).rg)) > tolerance)
				continue;
			if (float(n.b) < bestCost) {
				bestCost = float(n.b);
				chosen = half4(n.rg, n.b, 0);
			}
		}
	out.write(chosen, gid);
}

// Scene cuts: a 16-bin luma histogram per frame, compared with the frame before. A pan keeps the
// histogram; a cut changes it.
// Cuts are found over the whole frame and in each of 3x3 regions: a menu or a minimap can change
// alone. Region 0 is the whole frame, 1 to 9 the regions row by row.
static uint region_of(uint2 gid, uint2 size)
{
	return 1 + min(gid.x * 3 / size.x, 2u) + 3 * min(gid.y * 3 / size.y, 2u);
}

kernel void luma_histogram(texture2d<half, access::read> luma [[texture(0)]],
                           device atomic_uint *bins [[buffer(0)]],
                           uint2 gid [[thread_position_in_grid]])
{
	uint2 size = uint2(luma.get_width(), luma.get_height());
	if (gid.x >= size.x || gid.y >= size.y)
		return;
	uint bin = min(uint(saturate(float(luma.read(gid).r)) * 16.0), 15u);
	atomic_fetch_add_explicit(&bins[bin], 1, memory_order_relaxed);
	atomic_fetch_add_explicit(&bins[region_of(gid, size) * 16 + bin], 1, memory_order_relaxed);
}

// threshold: the share of the histogram that moved, for the whole frame and for a region
kernel void scene_cut(device const uint *now [[buffer(0)]],
                      device const uint *before [[buffer(1)]],
                      device uint *cut [[buffer(2)]],
                      constant float2 &threshold [[buffer(3)]],
                      uint gid [[thread_position_in_grid]])
{
	if (gid > 9)
		return;
	float total = 0, moved = 0;
	for (uint i = gid * 16; i < gid * 16 + 16; i++) {
		total += float(now[i]);
		moved += abs(float(now[i]) - float(before[i]));
	}
	cut[gid] = total > 0 && moved / (2 * total) > (gid == 0 ? threshold.x : threshold.y) ? 1 : 0;
}

// After a cut there is nothing to interpolate: the generated frame repeats the last one before
// it, over the whole frame or over the regions that cut
kernel void cut_fallback(texture2d<float, access::read> prev [[texture(0)]],
                         texture2d<float, access::write> out [[texture(1)]],
                         device const uint *cut [[buffer(0)]],
                         uint2 gid [[thread_position_in_grid]])
{
	uint2 size = uint2(out.get_width(), out.get_height());
	if (gid.x >= size.x || gid.y >= size.y || (cut[0] == 0 && cut[region_of(gid, size)] == 0))
		return;
	out.write(prev.read(gid), gid);
}

// Interpolation at half size, for large frames: the frames go in at half size, and the
// generated frame comes back up to full size
kernel void shrink_color(texture2d<float, access::read> full [[texture(0)]],
                         texture2d<float, access::write> half_size [[texture(1)]],
                         uint2 gid [[thread_position_in_grid]])
{
	if (gid.x >= half_size.get_width() || gid.y >= half_size.get_height())
		return;
	uint2 last = uint2(full.get_width(), full.get_height()) - 1;
	uint2 at = gid * 2;
	float4 sum = full.read(min(at, last)) + full.read(min(at + uint2(1, 0), last)) +
	             full.read(min(at + uint2(0, 1), last)) + full.read(min(at + uint2(1, 1), last));
	half_size.write(sum * 0.25, gid);
}

// shrink_color and luma_reduce at factor 4 in one pass over the luma grid: each thread's 4x4
// block is four of the small frame's 2x2 boxes, and its luma the mean of their four lumas
kernel void shrink_luma(texture2d<float, access::read> full [[texture(0)]],
                        texture2d<float, access::write> half_size [[texture(1)]],
                        texture2d<half, access::write> luma_out [[texture(2)]],
                        uint2 gid [[thread_position_in_grid]])
{
	if (gid.x >= luma_out.get_width() || gid.y >= luma_out.get_height())
		return;
	uint2 last = uint2(full.get_width(), full.get_height()) - 1;
	uint2 hlast = uint2(half_size.get_width(), half_size.get_height()) - 1;
	float sum = 0;
	for (uint y = 0; y < 2; y++)
		for (uint x = 0; x < 2; x++) {
			uint2 at = gid * 4 + uint2(x * 2, y * 2);
			float4 b = full.read(min(at, last)) + full.read(min(at + uint2(1, 0), last)) +
			           full.read(min(at + uint2(0, 1), last)) + full.read(min(at + uint2(1, 1), last));
			half_size.write(b * 0.25, min(gid * 2 + uint2(x, y), hlast));
			sum += luma(b.rgb);
		}
	luma_out.write(half4(sum / 16), gid);
}

kernel void grow_color(texture2d<float, access::sample> small [[texture(0)]],
                       texture2d<float, access::write> full [[texture(1)]],
                       uint2 gid [[thread_position_in_grid]])
{
	if (gid.x >= full.get_width() || gid.y >= full.get_height())
		return;
	constexpr sampler linear(filter::linear, address::clamp_to_edge);
	full.write(small.sample(linear, (float2(gid) + 0.5) / float2(full.get_width(), full.get_height())), gid);
}

// After MetalFX: where its frame disagrees with a reconstruction we trust, use ours. Each
// candidate vector, the pixel's own, four neighbours at a distance and none at all, says
// where the output pixel sits in both real frames; how well the two 3x3 luma patches agree
// is its cost, measured on the analysis luma. The candidates mix by a softmax of their costs.
// A pixel is replaced when the best cost is low and MetalFX's colour is far from the mix: a
// doubled edge or a HUD dragged along.
struct Repair {
	float sigma;   // softmax width, in mean luma difference per pixel
	float far_lo;  // distance from the mix where replacing starts and is complete
	float far_hi;
	float sure_lo; // best cost where trust starts falling and is gone
	float sure_hi;
	float reach;   // distance of the neighbour candidates, in output pixels
	float scale;   // motion texture pixels to output pixels
	float factor;  // output pixels per analysis pixel
	float phase;   // where the output sits, 0 previous frame to 1 current one
	float occlusion; // Neural Engine only: how much its mask sets each side's share in the mix
	float flows;     // Neural Engine only: 1 adds its two flows from the middle as a candidate
	float own;       // 1: no MetalFX frame, the mix is the output
	float still;     // keep_still folded in: frames unchanged to take from the last real frame, 0 off
	float cuts;      // cut_fallback folded in: 1 replaces the cut regions with the previous frame
};

constant int candidates = 7;

// The network's flows go from the middle frame to the earlier (planes 0, 1) and the later one
// (planes 2, 3), in network pixels
static float2 ane_flows(texture2d<half, access::sample> flow, float2 uv, uint k, float h)
{
	constexpr sampler linear(filter::linear, address::clamp_to_edge);
	float y = clamp(uv.y, 0.5 / h, 1 - 0.5 / h);
	return float2(flow.sample(linear, float2(uv.x, (y + k) / 4)).r, flow.sample(linear, float2(uv.x, (y + k + 1) / 4)).r);
}

// Where output pixel q sits in the previous (p) and current (c) frame for candidate k, in output
// pixels: a vector from the motion texture split by the phase, or the network's two flows
static void candidate(texture2d<half, access::sample> motion, texture2d<half, access::sample> flow, float2 q, int k,
                      constant Repair &r, float2 output, thread float2 &p, thread float2 &c)
{
	constexpr sampler s(filter::linear, address::clamp_to_edge);
	if (k == 6) {
		float h = flow.get_height() / 4;
		float2 uv = q / output, scale = output / float2(flow.get_width(), h);
		p = q + ane_flows(flow, uv, 0, h) * scale * (2 * r.phase);
		c = q + ane_flows(flow, uv, 2, h) * scale * (2 * (1 - r.phase));
		return;
	}
	float2 offsets[5] = { float2(0), float2(r.reach, 0), float2(-r.reach, 0), float2(0, r.reach), float2(0, -r.reach) };
	// v points from a pixel of the current frame to where it was: at 0.5, half of it on each side
	float2 v = k == 5 ? float2(0) : float2(motion.sample(s, (q + offsets[k]) / output).rg) * r.scale;
	p = q + v * r.phase;
	c = q - v * (1 - r.phase);
}

// The network's blend mask is the earlier frame's share at the middle; at phase t each side's
// share also follows its distance. Returns the current frame's share.
static float current_share(texture2d<half, access::sample> mask, float2 uv, constant Repair &r)
{
	if (r.occlusion <= 0)
		return r.phase;
	constexpr sampler s(filter::linear, address::clamp_to_edge);
	float m = clamp(float(mask.sample(s, uv).r), 0.0, 1.0);
	float before = (1 - r.phase) * m, after = r.phase * (1 - m);
	return mix(r.phase, after / max(before + after, 1e-4), r.occlusion);
}

// One analysis pixel: the softmax weights of the candidates and the best cost
kernel void repair_weights(texture2d<half, access::sample> prev [[texture(0)]],
                           texture2d<half, access::sample> cur [[texture(1)]],
                      texture2d<half, access::sample> motion [[texture(2)]],
                      texture2d<half, access::write> first [[texture(3)]],
                      texture2d<half, access::write> second [[texture(4)]],
                      texture2d<half, access::sample> flow [[texture(5)]],
                      constant Repair &r [[buffer(0)]],
                      constant float2 &output [[buffer(1)]],
                      device atomic_uint *counts [[buffer(2)]],
                      uint2 gid [[thread_position_in_grid]])
{
	uint2 size = uint2(first.get_width(), first.get_height());
	if (gid.x >= size.x || gid.y >= size.y)
		return;
	if (all(gid == uint2(0))) {
		atomic_store_explicit(&counts[0], 0, memory_order_relaxed);
		atomic_store_explicit(&counts[1], 0, memory_order_relaxed);
	}
	constexpr sampler s(filter::linear, address::clamp_to_edge);
	float2 inv = 1.0 / float2(size), qa = float2(gid) + 0.5;
	int count = r.flows > 0 ? candidates : candidates - 1;
	float cost[candidates], best = INFINITY;
	for (int k = 0; k < count; k++) {
		float2 p, c;
		candidate(motion, flow, qa * r.factor, k, r, output, p, c);
		p /= r.factor;
		c /= r.factor;
		float sum = 0;
		for (int y = -1; y <= 1; y++)
			for (int x = -1; x <= 1; x++) {
				float2 o = float2(x, y);
				sum += abs(float(prev.sample(s, (p + o) * inv).r) - float(cur.sample(s, (c + o) * inv).r));
			}
		cost[k] = sum / 9;
		best = min(best, cost[k]);
	}
	float w[candidates], total = 0;
	for (int k = 0; k < candidates; k++) {
		w[k] = k < count ? exp(-(cost[k] - best) / r.sigma) : 0;
		total += w[k];
	}
	first.write(half4(w[0], w[1], w[2], w[3]) / total, gid);
	second.write(half4(w[4] / total, w[5] / total, best, w[6] / total), gid);
}

// Per frame: the sum of trust (1 sure, 0 none) in 1/256 steps and the count of replaced pixels
static void tally(device atomic_uint *counts, float trust, bool replaced)
{
	uint sure = simd_sum(uint(trust * 256)), swapped = simd_sum(replaced ? 1u : 0u);
	if (simd_is_first()) {
		atomic_fetch_add_explicit(&counts[0], sure, memory_order_relaxed);
		atomic_fetch_add_explicit(&counts[1], swapped, memory_order_relaxed);
	}
}

kernel void repair_frame(texture2d<float, access::sample> raw [[texture(0)]],
                         texture2d<float, access::sample> prev [[texture(1)]],
                         texture2d<float, access::sample> cur [[texture(2)]],
                         texture2d<half, access::sample> motion [[texture(3)]],
                         texture2d<float, access::write> out [[texture(4)]],
                         texture2d<half, access::sample> first [[texture(5)]],
                         texture2d<half, access::sample> second [[texture(6)]],
                         texture2d<half, access::sample> flow [[texture(7)]],
                         texture2d<half, access::sample> mask [[texture(8)]],
                         texture2d<uint, access::read> count [[texture(9)]],
                         constant Repair &r [[buffer(0)]],
                         device atomic_uint *counts [[buffer(1)]],
                         device const uint *cut [[buffer(2)]],
                         uint2 gid [[thread_position_in_grid]])
{
	uint2 size = uint2(out.get_width(), out.get_height());
	if (gid.x >= size.x || gid.y >= size.y)
		return;
	constexpr sampler s(filter::linear, address::clamp_to_edge);
	float2 inv = 1.0 / float2(size), q = float2(gid) + 0.5;
	float4 b = float4(second.sample(s, q * inv));
	float trust = 1 - smoothstep(r.sure_lo, r.sure_hi, b.z), replaced = false;
	float4 result;
	if (b.z >= r.sure_hi && r.own == 0) {
		// No candidate is trusted: MetalFX's pixel stays
		result = raw.sample(s, q * inv);
		trust = 0;
	} else {
		float4 a = float4(first.sample(s, q * inv));
		float w[candidates] = { a.x, a.y, a.z, a.w, b.x, b.y, b.w };
		float share = current_share(mask, q * inv, r);
		float3 mixed = 0;
		float total = 0;
		for (int k = 0; k < candidates; k++) {
			if (w[k] < 0.01)
				continue;
			float2 p, c;
			candidate(motion, flow, q, k, r, float2(size), p, c);
			mixed += w[k] * mix(prev.sample(s, p * inv).rgb, cur.sample(s, c * inv).rgb, share);
			total += w[k];
		}
		mixed /= max(total, 1e-6);
		if (r.own > 0) {
			result = float4(mixed, 1);
			replaced = true;
		} else {
			float4 fx = raw.sample(s, q * inv);
			float3 d = abs(fx.rgb - mixed);
			float far = max(d.r, max(d.g, d.b));
			float alpha = smoothstep(r.far_lo, r.far_hi, far) * trust;
			result = float4(mix(fx.rgb, mixed, alpha), fx.a);
			replaced = alpha > 0.5;
		}
	}
	// The still-count and cut passes of finishOutput folded in, same order: still then cut
	if (r.still > 0 && count.read(gid).r >= uint(r.still))
		result = cur.sample(s, q * inv);
	if (r.cuts > 0 && (cut[0] != 0 || cut[region_of(gid, size)] != 0))
		result = prev.sample(s, q * inv);
	out.write(result, gid);
	if (trust > 0 || replaced)
		tally(counts, trust, replaced);
}

// HUD and other still parts without a HUD-less frame: how many real frames in a row each
// pixel kept its colour. Pixels still for long enough come from the latest real frame.
kernel void still_count(texture2d<float, access::read> prev [[texture(0)]],
                        texture2d<float, access::read> cur [[texture(1)]],
                        texture2d<uint, access::read> before [[texture(2)]],
                        texture2d<uint, access::write> after [[texture(3)]],
                        constant uint &fresh [[buffer(0)]],
                        uint2 gid [[thread_position_in_grid]])
{
	if (gid.x >= after.get_width() || gid.y >= after.get_height())
		return;
	if (fresh != 0) {
		after.write(uint4(0), gid);
		return;
	}
	float3 d = abs(cur.read(gid).rgb - prev.read(gid).rgb);
	bool same = max(d.r, max(d.g, d.b)) < same_step;
	after.write(uint4(same ? min(before.read(gid).r + 1, 255u) : 0u), gid);
}

kernel void keep_still(texture2d<uint, access::read> count [[texture(0)]],
                       texture2d<float, access::read> cur [[texture(1)]],
                       texture2d<float, access::write> out [[texture(2)]],
                       constant uint &frames [[buffer(0)]],
                       uint2 gid [[thread_position_in_grid]])
{
	if (gid.x >= out.get_width() || gid.y >= out.get_height() || count.read(gid).r < frames)
		return;
	out.write(cur.read(gid), gid);
}

// The UI of the last real frame over a generated one, when the source keeps it apart: premultiplied
// over the generated frame (under), or, composited, the final frame wherever it differs from the
// same frame without UI (under)
kernel void ui_over(texture2d<float, access::read> ui [[texture(0)]],
                    texture2d<float, access::read> under [[texture(1)]],
                    texture2d<float, access::write> out [[texture(2)]],
                    constant uint &composited [[buffer(0)]],
                    uint2 gid [[thread_position_in_grid]])
{
	if (gid.x >= out.get_width() || gid.y >= out.get_height())
		return;
	float4 u = ui.read(gid), f = under.read(gid);
	if (composited != 0) {
		float3 d = abs(u.rgb - f.rgb);
		if (max(d.r, max(d.g, d.b)) >= same_step)
			out.write(u, gid);
	} else if (u.a > 0)
		out.write(float4(u.rgb + (1 - u.a) * f.rgb, f.a), gid);
}

// The game's own motion, from its upscaler's inputs, resampled to the interpolator's size
kernel void engine_motion(texture2d<half, access::sample> engine [[texture(0)]],
                          texture2d<half, access::write> motion [[texture(1)]],
                          constant float &scale [[buffer(0)]],
                          uint2 gid [[thread_position_in_grid]])
{
	if (gid.x >= motion.get_width() || gid.y >= motion.get_height())
		return;
	constexpr sampler nearest(filter::nearest, address::clamp_to_edge);
	float2 uv = (float2(gid) + 0.5) / float2(motion.get_width(), motion.get_height());
	motion.write(half4(half2(float2(engine.sample(nearest, uv).rg) * scale), 0, 0), gid);
}

// Neural Engine path: the frame at the network's size, as three planes of RGB
kernel void ane_input(texture2d<float, access::sample> frame [[texture(0)]],
                      texture2d<half, access::write> planes [[texture(1)]],
                      uint2 gid [[thread_position_in_grid]])
{
	uint w = planes.get_width(), h = planes.get_height() / 3;
	if (gid.x >= w || gid.y >= h)
		return;
	constexpr sampler linear(filter::linear, address::clamp_to_edge);
	half3 c = half3(frame.sample(linear, (float2(gid) + 0.5) / float2(w, h)).rgb);
	planes.write(half4(c.r), uint2(gid.x, gid.y));
	planes.write(half4(c.g), uint2(gid.x, gid.y + h));
	planes.write(half4(c.b), uint2(gid.x, gid.y + 2 * h));
}

// The interpolator wants, at each pixel of the later frame, where it was in the earlier one: the
// middle point that lands on this pixel is about one later-flow step back
kernel void ane_motion(texture2d<half, access::sample> flow [[texture(0)]],
                       texture2d<half, access::write> motion [[texture(1)]],
                       uint2 gid [[thread_position_in_grid]])
{
	float2 size = float2(motion.get_width(), motion.get_height());
	if (gid.x >= size.x || gid.y >= size.y)
		return;
	float h = flow.get_height() / 4;
	float2 scale = size / float2(flow.get_width(), h), q = float2(gid) + 0.5;
	// A few fixed-point steps toward the middle point x with x + later(x) = q; the closest wins
	float2 x = q, best = q;
	float least = INFINITY;
	for (int i = 0; i < 3; i++) {
		x = q - ane_flows(flow, x / size, 2, h) * scale;
		float miss = length(x + ane_flows(flow, x / size, 2, h) * scale - q);
		if (miss < least) {
			least = miss;
			best = x;
		}
	}
	float2 uv = best / size;
	float2 v = ane_flows(flow, uv, 0, h) - ane_flows(flow, uv, 2, h);
	motion.write(half4(half2(v * scale), 0, 0), gid);
}

// The overlay: a generated frame shows a green square in its top-left corner, a real one none
kernel void mark_generated(texture2d<float, access::write> out [[texture(0)]],
                           uint2 gid [[thread_position_in_grid]])
{
	uint2 at = gid + uint2(16, 16);
	if (at.x < out.get_width() && at.y < out.get_height())
		out.write(float4(0, 1, 0, 1), at);
}
