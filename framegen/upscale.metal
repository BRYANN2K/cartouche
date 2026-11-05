// The spatial upscaling chain: CMAA2 anti-aliasing at the game's size, then MetalFX's spatial
// scaler (driven from fg_upscale.m), then RCAS sharpening at the output size. A bilinear pass
// stands in for MetalFX when it is off.
//
// CMAA2 below is a port to Metal of Intel's CMAA2.hlsl, version 2.3:
//   Copyright (c) 2018, Intel Corporation
//   Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file
//   except in compliance with the License. You may obtain a copy of the License at
//   http://www.apache.org/licenses/LICENSE-2.0
//   Unless required by applicable law or agreed to in writing, software distributed under the
//   License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND,
//   either express or implied. See the License for the specific language governing permissions
//   and limitations under the License.
//   Original: https://github.com/GameTechDev/CMAA2
// Changes for Cartouche (2026): Metal syntax; single sample, luma edges computed in place
// (CMAA2_EDGE_DETECTION_LUMA_PATH 1), high preset; one byte of edges per pixel instead of two
// pixels per byte; list heads in a buffer instead of a texture; reads clamped to the image and
// writes past its end or past a list's capacity dropped, where D3D bounds-checks for free;
// colours converted from and to sRGB around the work, as an sRGB resource would be.
//
// RCAS below is a port of FsrRcasF from AMD's ffx_fsr1.h (FidelityFX Super Resolution 1.0):
//   Copyright (c) 2021 Advanced Micro Devices, Inc. All rights reserved.
//   Permission is hereby granted, free of charge, to any person obtaining a copy of this
//   software and associated documentation files (the "Software"), to deal in the Software
//   without restriction, including without limitation the rights to use, copy, modify, merge,
//   publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons
//   to whom the Software is furnished to do so, subject to the following conditions:
//   The above copyright notice and this permission notice shall be included in all copies or
//   substantial portions of the Software.
//   THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
//   INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR
//   PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE
//   FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
//   OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
//   DEALINGS IN THE SOFTWARE.
//   Original: https://github.com/GPUOpen-Effects/FidelityFX-FSR

#include <metal_stdlib>
using namespace metal;

#define IN_X 16
#define IN_Y 16
#define OUT_X (IN_X - 2)
#define OUT_Y (IN_Y - 2)
#define CANDIDATE_THREADS 128
#define APPLY_THREADS 32
#define BLEND_SLOTS 768

constant float edge_threshold = 0.07;
constant float local_contrast_amount = 0.10;
constant float simple_shape_blur = 0.10;
constant float max_line_length = 86;
constant float symmetry_offset = 0.22;
constant float dampening = 0.15;

// Counters in control: [3] items for the next indirect pass, [4] shape candidates, [8] blend
// locations, [12] blend items
struct CMAAInfo {
	uint2 size;
	uint heads_width;
	uint gamma; // the texture holds sRGB-encoded values
	uint hdr;   // values above 1: wider packing of blend colours
	uint candidates_max, locations_max, items_max;
};

static float3 to_linear(float3 c)
{
	return select(pow((c + 0.055) / 1.055, 2.4), c / 12.92, c < 0.04045);
}

static float3 to_gamma(float3 c)
{
	c = max(c, 0.0);
	return select(1.055 * pow(c, 1.0 / 2.4) - 0.055, c * 12.92, c < 0.0031308);
}

static float3 load_color(texture2d<float, access::read> t, int2 p, constant CMAAInfo &info)
{
	p = clamp(p, int2(0), int2(info.size) - 1);
	float3 c = t.read(uint2(p)).rgb;
	return info.gamma ? to_linear(saturate(c)) : c;
}

static uint load_edge(texture2d<uint, access::read> edges, int2 p, constant CMAAInfo &info)
{
	if (any(p < 0) || any(p >= int2(info.size)))
		return 0;
	return edges.read(uint2(p)).r;
}

static float4 unpack_edges(uint value)
{
	return float4((value & 1) != 0, (value & 2) != 0, (value & 4) != 0, (value & 8) != 0);
}

static uint pack_edges(float4 edges)
{
	return uint(dot(edges, float4(1, 2, 4, 8)));
}

static uint f16_bits(float x)
{
	return uint(as_type<ushort>(half(x)));
}

static float f16_value(uint bits)
{
	return float(as_type<half>(ushort(bits)));
}

// R11G11B10 with one exponent bit moved to the mantissa for LDR, plain R11G11B10 for HDR
static uint pack_color(float3 rgb, constant CMAAInfo &info)
{
	if (info.hdr) {
		rgb = min(rgb, as_type<float>(0x477C0000u));
		return (((f16_bits(rgb.x) + 8) >> 4) & 0x000007FF) | (((f16_bits(rgb.y) + 8) << 7) & 0x003FF800) |
		       (((f16_bits(rgb.z) + 16) << 17) & 0xFFC00000);
	}
	rgb = clamp(rgb, 0.0, 1.0);
	return (((f16_bits(rgb.r) + 4) >> 3) & 0x000007FF) | (((f16_bits(rgb.g) + 4) << 8) & 0x003FF800) |
	       (((f16_bits(rgb.b) + 8) << 18) & 0xFFC00000);
}

static float3 unpack_color(uint rgb, constant CMAAInfo &info)
{
	if (info.hdr)
		return float3(f16_value((rgb << 4) & 0x7FF0), f16_value((rgb >> 7) & 0x7FF0), f16_value((rgb >> 17) & 0x7FE0));
	return float3(f16_value((rgb << 3) & 0x3FF8), f16_value((rgb >> 8) & 0x3FF8), f16_value((rgb >> 18) & 0x3FF0));
}

static float luma_for_edges(float3 linear_rgb)
{
	return dot(sqrt(linear_rgb), float3(0.299, 0.587, 0.114));
}

static float2 edge_luma(int x, int y, thread const float *lumas)
{
	return float2(abs(lumas[x + y * 3] - lumas[x + 1 + y * 3]), abs(lumas[x + y * 3] - lumas[x + (y + 1) * 3]));
}

static float contrast_v(int x, int y, thread float2 (&n)[4][4])
{
	return max(max(n[x + 1][y + 0].y, n[x + 1][y + 1].y), max(n[x + 2][y + 0].y, n[x + 2][y + 1].y)) * local_contrast_amount;
}

static float contrast_h(int x, int y, thread float2 (&n)[4][4])
{
	return max(max(n[x + 0][y + 1].x, n[x + 1][y + 1].x), max(n[x + 0][y + 2].x, n[x + 1][y + 2].x)) * local_contrast_amount;
}

static void load_quad(threadgroup float4 *h, threadgroup float4 *v, uint at, thread float2 &e00, thread float2 &e10,
                      thread float2 &e01, thread float2 &e11)
{
	float4 vh = h[at], vv = v[at];
	e00 = float2(vv.x, vh.x);
	e10 = float2(vv.y, vh.y);
	e01 = float2(vv.z, vh.z);
	e11 = float2(vv.w, vh.w);
}

// Edges of every pixel, and the pixels where two edges meet as shape candidates. Each thread
// takes a 2x2 quad; the group's border quads only feed their neighbours' local contrast.
kernel void cmaa_edges(texture2d<float, access::read> color [[texture(0)]],
                       texture2d<uint, access::write> edges [[texture(1)]],
                       device atomic_uint *control [[buffer(0)]],
                       device uint *candidates [[buffer(1)]],
                       device uint *heads [[buffer(2)]],
                       constant CMAAInfo &info [[buffer(3)]],
                       uint2 group [[threadgroup_position_in_grid]],
                       uint2 local [[thread_position_in_threadgroup]])
{
	threadgroup float4 fracH[IN_X * IN_Y], fracV[IN_X * IN_Y];
	int2 pixel = (int2(group) * int2(OUT_X, OUT_Y) + int2(local) - 1) * 2;
	const int2 offsets[4] = { int2(0, 0), int2(1, 0), int2(0, 1), int2(1, 1) };
	uint center = local.x + local.y * IN_X;
	bool inside = !(local.x == IN_X - 1 || local.x == 0 || local.y == IN_Y - 1 || local.y == 0);

	float lumas[8];
	for (int i = 0; i < 8; i++)
		lumas[i] = luma_for_edges(load_color(color, pixel + int2(i % 3, i / 3), info));
	float2 qe0 = edge_luma(0, 0, lumas), qe1 = edge_luma(1, 0, lumas), qe2 = edge_luma(0, 1, lumas), qe3 = edge_luma(1, 1, lumas);
	fracV[center] = float4(qe0.x, qe1.x, qe2.x, qe3.x);
	fracH[center] = float4(qe0.y, qe1.y, qe2.y, qe3.y);
	threadgroup_barrier(mem_flags::mem_threadgroup);
	if (!inside)
		return;

	uint out[4] = { 0, 0, 0, 0 };
	float2 top = fracH[center - IN_X].zw, left = fracV[center - 1].yw;
	if (any(float4(qe0, qe1) + float4(qe2, qe3) + float4(top, left) != 0)) {
		uint2 quad = uint2(pixel) / 2;
		if (pixel.x < int(info.size.x) && pixel.y < int(info.size.y))
			heads[quad.y * info.heads_width + quad.x] = 0xFFFFFFFF;

		float2 d0, d1, d2;
		float2 n[4][4];
		load_quad(fracH, fracV, center - IN_X - 1, d0, d1, d2, n[0][0]);
		load_quad(fracH, fracV, center - IN_X, d0, d1, n[1][0], n[2][0]);
		load_quad(fracH, fracV, center - IN_X + 1, d0, d1, n[3][0], d2);
		load_quad(fracH, fracV, center - 1, d0, n[0][1], d1, n[0][2]);
		load_quad(fracH, fracV, center + 1, n[3][1], d0, n[3][2], d1);
		load_quad(fracH, fracV, center - 1 + IN_X, d0, n[0][3], d1, d2);
		load_quad(fracH, fracV, center + IN_X, n[1][3], n[2][3], d0, d1);
		n[1][0].y = top[0];
		n[2][0].y = top[1];
		n[0][1].x = left[0];
		n[0][2].x = left[1];
		n[1][1] = qe0;
		n[2][1] = qe1;
		n[1][2] = qe2;
		n[2][2] = qe3;

		top[0] = (top[0] - contrast_h(0, -1, n)) > edge_threshold;
		top[1] = (top[1] - contrast_h(1, -1, n)) > edge_threshold;
		left[0] = (left[0] - contrast_v(-1, 0, n)) > edge_threshold;
		left[1] = (left[1] - contrast_v(-1, 1, n)) > edge_threshold;

		float4 ce[4];
		ce[0].x = (qe0.x - contrast_v(0, 0, n)) > edge_threshold;
		ce[0].y = (qe0.y - contrast_h(0, 0, n)) > edge_threshold;
		ce[1].x = (qe1.x - contrast_v(1, 0, n)) > edge_threshold;
		ce[1].y = (qe1.y - contrast_h(1, 0, n)) > edge_threshold;
		ce[2].x = (qe2.x - contrast_v(0, 1, n)) > edge_threshold;
		ce[2].y = (qe2.y - contrast_h(0, 1, n)) > edge_threshold;
		ce[3].x = (qe3.x - contrast_v(1, 1, n)) > edge_threshold;
		ce[3].y = (qe3.y - contrast_h(1, 1, n)) > edge_threshold;
		ce[0].z = left[0];
		ce[1].z = ce[0].x;
		ce[2].z = left[1];
		ce[3].z = ce[2].x;
		ce[0].w = top[0];
		ce[1].w = top[1];
		ce[2].w = ce[0].y;
		ce[3].w = ce[1].y;

		for (int i = 0; i < 4; i++) {
			int2 at = pixel + offsets[i];
			float4 e = ce[i];
			bool candidate = (e.x * e.y + e.y * e.z + e.z * e.w + e.w * e.x) != 0;
			if (candidate && all(at < int2(info.size))) {
				uint index = atomic_fetch_add_explicit(&control[4], 1, memory_order_relaxed);
				if (index < info.candidates_max)
					candidates[index] = (uint(at.x) << 18) | uint(at.y);
			}
			out[i] = pack_edges(e);
		}
	}
	// Every pixel's edges are written, empty ones too, so tracing never follows a past frame's
	for (int i = 0; i < 4; i++) {
		int2 at = pixel + offsets[i];
		if (all(at < int2(info.size)))
			edges.write(uint4(out[i]), uint2(at));
	}
}

// Indirect arguments for the next pass, from the counters: which 0 for the candidates, 1 for
// the deferred apply, which also clears the counters for the next frame
kernel void cmaa_args(device uint *control [[buffer(0)]],
                      device uint *indirect [[buffer(1)]],
                      constant uint &which [[buffer(2)]],
                      constant CMAAInfo &info [[buffer(3)]])
{
	if (which == 0) {
		uint count = min(control[4], info.candidates_max);
		indirect[0] = (count + CANDIDATE_THREADS - 1) / CANDIDATE_THREADS;
		indirect[1] = 1;
		indirect[2] = 1;
		control[3] = count;
	} else {
		uint count = min(control[8], info.locations_max);
		indirect[4] = 1;
		indirect[5] = (count + APPLY_THREADS - 1) / APPLY_THREADS;
		indirect[6] = 1;
		control[3] = count;
		control[4] = 0;
		control[8] = 0;
		control[12] = 0;
	}
}

struct Lists {
	device atomic_uint *control;
	device atomic_uint *heads;
	device uint2 *items;
	device uint *locations;
};

static void store_sample(int2 p, float3 color, bool complex, Lists lists, constant CMAAInfo &info)
{
	if (any(p < 0) || any(p >= int2(info.size)))
		return;
	uint index = atomic_fetch_add_explicit(&lists.control[12], 1, memory_order_relaxed);
	if (index >= info.items_max)
		return;
	uint2 quad = uint2(p) / 2;
	uint offset = (uint(p.y) % 2) * 2 + (uint(p.x) % 2);
	uint header = (offset << 30) | (uint(complex) << 26);
	uint original = atomic_exchange_explicit(&lists.heads[quad.y * info.heads_width + quad.x], index | header,
	                                         memory_order_relaxed);
	lists.items[index] = uint2(original, pack_color(color, info));
	if (original == 0xFFFFFFFF) {
		uint at = atomic_fetch_add_explicit(&lists.control[8], 1, memory_order_relaxed);
		if (at < info.locations_max)
			lists.locations[at] = (quad.x << 16) | quad.y;
	}
}

static float4 simple_shape_blend(float4 edges, float4 left, float4 right, float4 top, float4 bottom)
{
	float fromRight = edges.r, fromBelow = edges.g, fromLeft = edges.b, fromAbove = edges.a;
	float blur = simple_shape_blur;
	float count = dot(edges, float4(1));
	float around = dot(left.bga + right.rga + top.rba + bottom.rgb, float3(1));
	if (count == 2) {
		blur *= 0.75;
		float k = 0.9;
		fromRight += k * (edges.g * top.r * (1.0 - left.g) + edges.a * bottom.r * (1.0 - left.a));
		fromBelow += k * (edges.b * right.g * (1.0 - top.b) + edges.r * left.g * (1.0 - top.r));
		fromLeft += k * (edges.a * bottom.b * (1.0 - right.a) + edges.g * top.b * (1.0 - right.g));
		fromAbove += k * (edges.r * left.a * (1.0 - bottom.r) + edges.b * right.a * (1.0 - bottom.b));
	}
	blur *= saturate(1.30 - around / 10.0);
	return float4(fromLeft, fromAbove, fromRight, fromBelow) * blur;
}

static void detect_zs(float4 edges, float4 m1, float4 p1, float4 p2, thread float &inverted, thread float &normal)
{
	inverted = edges.r * edges.g * p1.a;
	inverted *= 2.0 + (m1.g + p2.a) - (edges.a + p1.g) - 0.7 * (p2.g + m1.a + edges.b + p1.r);
	normal = edges.r * edges.a * p1.g;
	normal *= 2.0 + (m1.a + p2.g) - (edges.g + p1.a) - 0.7 * (p2.a + m1.g + edges.b + p1.r);
}

static void z_line_lengths(thread float &lengthLeft, thread float &lengthRight, int2 at, bool horizontal, bool inverted,
                           float2 stepRight, texture2d<uint, access::read> edges, constant CMAAInfo &info)
{
	uint traceLeft = horizontal ? 0x08 : 0x04, traceRight = horizontal ? 0x02 : 0x01;
	if (inverted) {
		uint t = traceLeft;
		traceLeft = traceRight;
		traceRight = t;
	}
	bool goLeft = true, goRight = true;
	lengthLeft = 1;
	lengthRight = 1;
	for (;;) {
		uint l = load_edge(edges, int2(float2(at) - stepRight * lengthLeft), info);
		uint r = load_edge(edges, int2(float2(at) + stepRight * (lengthRight + 1)), info);
		goLeft = goLeft && (l & traceLeft) == traceLeft;
		goRight = goRight && (r & traceRight) == traceRight;
		lengthLeft += goLeft;
		lengthRight += goRight;
		float longest = max(lengthRight, lengthLeft);
		if (!goLeft && !goRight)
			longest = max_line_length;
		if (longest >= min(max_line_length, 1.25 * min(lengthRight, lengthLeft) - 0.25))
			break;
	}
}

static bool collect_zs(int2 at, bool horizontal, bool inverted, float quality, float lengthLeft, float lengthRight,
                       threadgroup atomic_uint &count, threadgroup uint2 *items)
{
	float leftOdd = symmetry_offset * fmod(lengthLeft, 2.0), rightOdd = symmetry_offset * fmod(lengthRight, 2.0);
	float dampen = saturate((lengthLeft + lengthRight - quality) * dampening);
	float from = -floor((lengthLeft + 1) / 2) + 1.0, to = floor((lengthRight + 1) / 2);
	uint n = uint(to - from + 1);
	uint index = atomic_fetch_add_explicit(&count, n, memory_order_relaxed);
	if (index + n > BLEND_SLOTS)
		return false;
	float step = 1.0 / ((to - from) + 1 - leftOdd - rightOdd);
	float base = (0.5 - leftOdd - from) * step;
	uint header = (uint(at.x) << 18) | uint(at.y);
	uint fixed = (uint(horizontal) << 31) | (uint(inverted) << 30);
	for (float i = from; i <= to; i++) {
		float second = i > 0;
		float offset = 1.0 - second * 2.0;
		float k = ((step * i + base) * offset + second) * dampen;
		items[index++] = uint2(header, fixed | (uint(i + 256) << 20) | (uint(offset + 256) << 10) | uint(saturate(k) * 1023 + 0.5));
	}
	return true;
}

static void blend_zs(int2 at, bool horizontal, bool inverted, float quality, float lengthLeft, float lengthRight,
                     float2 stepRight, texture2d<float, access::read> color, Lists lists, constant CMAAInfo &info)
{
	float2 dir = horizontal ? float2(0, -1) : float2(-1, 0);
	if (inverted)
		dir = -dir;
	float leftOdd = symmetry_offset * fmod(lengthLeft, 2.0), rightOdd = symmetry_offset * fmod(lengthRight, 2.0);
	float dampen = saturate((lengthLeft + lengthRight - quality) * dampening);
	float from = -floor((lengthLeft + 1) / 2) + 1.0, to = floor((lengthRight + 1) / 2);
	float step = 1.0 / ((to - from) + 1 - leftOdd - rightOdd);
	float base = (0.5 - leftOdd - from) * step;
	for (float i = from; i <= to; i++) {
		float second = i > 0;
		float offset = 1.0 - second * 2.0;
		float k = ((step * i + base) * offset + second) * dampen;
		float2 p = float2(at) + stepRight * i;
		float3 c = load_color(color, int2(p), info), o = load_color(color, int2(p + dir * offset), info);
		store_sample(int2(p), mix(c, o, k), true, lists, info);
	}
}

// Blended colours for each candidate: simple shapes from its 4 neighbours, Z shapes along
// the traced line, gathered in the group then spread over its threads
kernel void cmaa_candidates(texture2d<float, access::read> color [[texture(0)]],
                            texture2d<uint, access::read> edges [[texture(1)]],
                            device atomic_uint *control [[buffer(0)]],
                            device uint *candidates [[buffer(1)]],
                            device atomic_uint *heads [[buffer(2)]],
                            constant CMAAInfo &info [[buffer(3)]],
                            device uint2 *items [[buffer(4)]],
                            device uint *locations [[buffer(5)]],
                            uint id [[thread_position_in_grid]],
                            uint local [[thread_position_in_threadgroup]])
{
	threadgroup atomic_uint count;
	threadgroup uint2 blends[BLEND_SLOTS];
	if (local == 0)
		atomic_store_explicit(&count, 0, memory_order_relaxed);
	threadgroup_barrier(mem_flags::mem_threadgroup);
	Lists lists = { control, heads, items, locations };

	uint total = atomic_load_explicit(&control[3], memory_order_relaxed);
	if (id < total) {
		uint packed = candidates[id];
		int2 at = int2(packed >> 18, packed & 0x3FFF);
		float4 e = unpack_edges(load_edge(edges, at, info));
		float4 left = unpack_edges(load_edge(edges, at + int2(-1, 0), info));
		float4 right = unpack_edges(load_edge(edges, at + int2(1, 0), info));
		float4 bottom = unpack_edges(load_edge(edges, at + int2(0, 1), info));
		float4 top = unpack_edges(load_edge(edges, at + int2(0, -1), info));

		float4 blend = simple_shape_blend(e, left, right, top, bottom);
		float3 c = load_color(color, at, info) * (1.0 - dot(blend, float4(1)));
		if (blend.x > 0)
			c += blend.x * load_color(color, at + int2(-1, 0), info);
		if (blend.y > 0)
			c += blend.y * load_color(color, at + int2(0, -1), info);
		if (blend.z > 0)
			c += blend.z * load_color(color, at + int2(1, 0), info);
		if (blend.w > 0)
			c += blend.w * load_color(color, at + int2(0, 1), info);
		store_sample(at, c, false, lists, info);

		float inverted, normal;
		bool horizontal = true, invertedZ = false;
		detect_zs(e, left, right, unpack_edges(load_edge(edges, at + int2(2, 0), info)), inverted, normal);
		float best = max(inverted, normal);
		if (best > 0)
			invertedZ = inverted > normal;
		// Vertical: the same test on the edges turned a quarter counter-clockwise
		detect_zs(e.argb, bottom.argb, top.argb, unpack_edges(load_edge(edges, at + int2(0, -2), info)).argb, inverted, normal);
		float vertical = max(inverted, normal);
		if (vertical > best) {
			best = vertical;
			horizontal = false;
			invertedZ = inverted > normal;
		}
		if (best > 0) {
			float quality = floor(clamp(4.0 - best, 0.0, 3.0));
			float2 stepRight = horizontal ? float2(1, 0) : float2(0, -1);
			float lengthLeft, lengthRight;
			z_line_lengths(lengthLeft, lengthRight, at, horizontal, invertedZ, stepRight, edges, info);
			lengthLeft -= quality;
			lengthRight -= quality;
			if (lengthLeft + lengthRight >= 5.0 &&
			    !collect_zs(at, horizontal, invertedZ, quality, lengthLeft, lengthRight, count, blends))
				blend_zs(at, horizontal, invertedZ, quality, lengthLeft, lengthRight, stepRight, color, lists, info);
		}
	}

	threadgroup_barrier(mem_flags::mem_threadgroup);
	uint gathered = min(uint(BLEND_SLOTS), atomic_load_explicit(&count, memory_order_relaxed));
	for (uint index = local; index < gathered; index += CANDIDATE_THREADS) {
		uint2 item = blends[index];
		int2 start = int2(item.x >> 18, item.x & 0x3FFF);
		bool horizontal = (item.y >> 31) & 1, invertedZ = (item.y >> 30) & 1;
		float stepIndex = float((item.y >> 20) & 0x3FF) - 256.0, offset = float((item.y >> 10) & 0x3FF) - 256.0;
		float k = float(item.y & 0x3FF) / 1023.0;
		float2 stepRight = horizontal ? float2(1, 0) : float2(0, -1), dir = horizontal ? float2(0, -1) : float2(-1, 0);
		if (invertedZ)
			dir = -dir;
		float2 p = float2(start) + stepRight * stepIndex;
		float3 c = load_color(color, int2(p), info), o = load_color(color, int2(p + dir * offset), info);
		store_sample(int2(p), mix(c, o, k), true, lists, info);
	}
}

// Each quad with blended samples: the weighted mean of its pixel's samples over the copy of
// the input in out
kernel void cmaa_apply(texture2d<float, access::read> color [[texture(0)]],
                       texture2d<float, access::write> out [[texture(1)]],
                       device uint *control [[buffer(0)]],
                       device uint *locations [[buffer(1)]],
                       device uint *heads [[buffer(2)]],
                       constant CMAAInfo &info [[buffer(3)]],
                       device uint2 *items [[buffer(4)]],
                       uint2 id [[thread_position_in_grid]],
                       uint2 local [[thread_position_in_threadgroup]])
{
	uint candidate = id.y, offset = local.x;
	if (candidate >= control[3])
		return;
	uint packed = locations[candidate];
	uint2 quad = uint2(packed >> 16, packed & 0xFFFF);
	const uint2 offsets[4] = { uint2(0, 0), uint2(1, 0), uint2(0, 1), uint2(1, 1) };
	uint2 pixel = quad * 2 + offsets[offset];
	uint head = heads[quad.y * info.heads_width + quad.x];
	float4 sum = 0;
	for (uint i = 0; head != 0xFFFFFFFF && i < 32; i++) {
		uint at = (head >> 30) & 3;
		bool complex = (head >> 26) & 1;
		uint2 item = items[head & ((1u << 26) - 1)];
		head = item.x;
		if (at == offset) {
			float weight = 0.8 + float(complex);
			sum += float4(unpack_color(item.y, info) * weight, weight);
		}
	}
	if (sum.a == 0 || any(pixel >= info.size))
		return;
	float3 c = sum.rgb / sum.a;
	out.write(float4(info.gamma ? to_gamma(c) : c, color.read(pixel).a), pixel);
}

// Format conversions into CMAA2's copy when a blit cannot do it
kernel void copy_image(texture2d<float, access::read> src [[texture(0)]],
                       texture2d<float, access::write> dst [[texture(1)]],
                       uint2 id [[thread_position_in_grid]])
{
	if (all(id < uint2(dst.get_width(), dst.get_height())))
		dst.write(src.read(id), id);
}

struct Screen {
	float4 p [[position]];
};

vertex Screen screen_v(uint i [[vertex_id]])
{
	float2 c = float2((i << 1) & 2, i & 2);
	Screen o;
	o.p = float4(c * 2 - 1, 0, 1);
	return o;
}

// Bilinear: also the plain copy when the sizes match
fragment float4 bilinear_f(Screen in [[stage_in]], texture2d<float> src [[texture(0)]], constant float2 &size [[buffer(0)]])
{
	constexpr sampler s(filter::linear, address::clamp_to_edge);
	return src.sample(s, in.p.xy / size);
}

constant float rcas_limit = 0.25 - 1.0 / 16.0;

// Float colour goes through a reversible tone map around RCAS, which expects 0 to 1
static float3 tone(float3 c, bool hdr)
{
	return hdr ? c / (1.0 + max(max(c.r, c.g), max(c.b, 0.0))) : c;
}

// RCAS at p: sharpness is 2^-stops, 1 the most
static float4 rcas(texture2d<float, access::read> src, int2 p, float sharpness, bool hdr)
{
	int2 last = int2(src.get_width(), src.get_height()) - 1;
	float3 b = tone(src.read(uint2(clamp(p + int2(0, -1), int2(0), last))).rgb, hdr);
	float3 d = tone(src.read(uint2(clamp(p + int2(-1, 0), int2(0), last))).rgb, hdr);
	float4 ee = src.read(uint2(clamp(p, int2(0), last)));
	float3 e = tone(ee.rgb, hdr);
	float3 f = tone(src.read(uint2(clamp(p + int2(1, 0), int2(0), last))).rgb, hdr);
	float3 h = tone(src.read(uint2(clamp(p + int2(0, 1), int2(0), last))).rgb, hdr);
	float3 mn4 = min(min(b, d), min(f, h)), mx4 = max(max(b, d), max(f, h));
	// Clamped denominators: FSR's reciprocals give infinities there, which its max drops
	float3 hitMin = min(mn4, e) / max(4.0 * mx4, 1e-5);
	float3 hitMax = (1.0 - max(mx4, e)) / min(4.0 * mn4 - 4.0, -1e-5);
	float3 lobe3 = max(-hitMin, hitMax);
	float lobe = max(-rcas_limit, min(max(lobe3.r, max(lobe3.g, lobe3.b)), 0.0)) * sharpness;
	float3 c = (lobe * (b + d + h + f) + e) / (4.0 * lobe + 1.0);
	if (hdr)
		c = c / max(1.0 - max(max(c.r, c.g), c.b), 1.0 / 65504.0);
	return float4(c, ee.a);
}

fragment float4 rcas_f(Screen in [[stage_in]], texture2d<float, access::read> src [[texture(0)]],
                       constant float &sharpness [[buffer(0)]])
{
	return rcas(src, int2(in.p.xy), sharpness, false);
}

struct RcasParams {
	float sharpness;
	uint hdr;
};

// The same into a texture that can only be written, as a temporal scaler's output
kernel void rcas_k(texture2d<float, access::read> src [[texture(0)]], texture2d<float, access::write> dst [[texture(1)]],
                   constant RcasParams &params [[buffer(0)]], uint2 id [[thread_position_in_grid]])
{
	if (all(id < uint2(dst.get_width(), dst.get_height())))
		dst.write(rcas(src, int2(id), params.sharpness, params.hdr != 0), id);
}

// After a game's temporal scaler: where the colour changed more than the game's motion explains
// (animated textures, particles, anything drawn without vectors), MetalFX leans on the current frame
kernel void reactive_temporal(texture2d<float, access::read> color [[texture(0)]],
                              texture2d<float, access::read> previous [[texture(1)]],
                              texture2d<float, access::read> motion [[texture(2)]],
                              texture2d<float, access::write> mask [[texture(3)]],
                              texture2d<float, access::write> keep [[texture(4)]],
                              constant float4 &params [[buffer(0)]], uint2 id [[thread_position_in_grid]])
{
	if (any(id >= uint2(mask.get_width(), mask.get_height())))
		return;
	// params: motion scale x and y, strength, threshold
	float3 c = color.read(id).rgb;
	keep.write(float4(c, 1), id);
	float2 m = motion.read(id).xy * params.xy;
	int2 last = int2(previous.get_width(), previous.get_height()) - 1;
	int2 at = int2(round(float2(id) + m));
	float change = 0;
	if (all(at >= 0) && all(at <= last)) {
		float3 before = previous.read(uint2(at)).rgb;
		change = abs(dot(c - before, float3(0.299, 0.587, 0.114))) / (1.0 + dot(c, float3(0.299, 0.587, 0.114)));
	}
	mask.write(float4(saturate((change - params.w) * params.z)), id);
}
