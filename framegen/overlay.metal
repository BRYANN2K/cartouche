// The HUD's glass panel and its shadow, the text layers drawn by Core Text, and the frame-time
// graph: one instanced quad each, in pixels from the target's top left. Colours are sRGB with
// straight alpha.
#include <metal_stdlib>
using namespace metal;

enum { quad_panel, quad_graph, quad_shadow };

struct OverlayQuad {
	float4 rect;  // x, y, width, height
	float4 uv;    // panel: rim colour; shadow: the shape casting it
	float4 color;
	float4 shape; // kind, corner radius, then panel: rim width, highlight height; shadow: blur
	float4 clip;  // the panel's rect: the graph is cut to it, the shadow stays outside it; panel: x is its layer mask
};

// Text layers drawn by Core Text, premultiplied sRGB, composited by the panel that holds them
struct Layers {
	float4 rect[4];
	float alpha[4];
};

struct GraphData {
	float y[120];  // pixels from the graph's top
	float grid[3];
	float count;
	float unit;    // pixels per point
	float width;   // line width in pixels
	float pad[2];
};

struct OverlayVertex {
	float4 position [[position]];
	float2 uv;
	float4 extra [[flat]];
	float4 color [[flat]];
	float4 rect [[flat]];
	float4 shape [[flat]];
	float4 clip [[flat]];
};

vertex OverlayVertex overlay_vertex(uint corner [[vertex_id]], uint index [[instance_id]],
                                    const device OverlayQuad *quads [[buffer(0)]], constant float2 &size [[buffer(1)]])
{
	OverlayQuad q = quads[index];
	float2 at = float2(corner & 1, corner >> 1);
	float2 pixel = q.rect.xy + at * q.rect.zw;
	OverlayVertex out;
	out.position = float4(pixel / size * float2(2, -2) + float2(-1, 1), 0, 1);
	out.uv = mix(q.uv.xy, q.uv.zw, at);
	out.extra = q.uv;
	out.color = q.color;
	out.rect = q.rect;
	out.shape = q.shape;
	out.clip = q.clip;
	return out;
}

static float3 linear_from_srgb(float3 c)
{
	return select(pow((c + 0.055) / 1.055, 2.4), c / 12.92, c <= 0.04045);
}

// Signed distance to a rounded box, negative inside
static float box(float2 p, float4 rect, float radius)
{
	float2 half_size = rect.zw * 0.5;
	float r = min(radius, min(half_size.x, half_size.y));
	float2 d = abs(p - rect.xy - half_size) - (half_size - r);
	return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0) - r;
}

static float4 over(float4 top, float4 under)
{
	float a = top.a + under.a * (1 - top.a);
	if (a <= 0)
		return float4(0);
	return float4((top.rgb * top.a + under.rgb * under.a * (1 - top.a)) / a, a);
}

static float segment(float2 p, float2 a, float2 b)
{
	float2 ab = b - a;
	float t = saturate(dot(p - a, ab) / max(dot(ab, ab), 1e-6));
	return length(p - a - ab * t);
}

// One text layer over c where p falls in its rect
static float4 layer(float4 c, texture2d<float> t, float4 r, float alpha, float2 p)
{
	constexpr sampler smooth(filter::linear, address::clamp_to_edge);
	float2 uv = (p - r.xy) / r.zw;
	if (any(uv < 0) || any(uv >= 1))
		return c;
	float4 x = t.sample(smooth, uv);
	return x.a > 0 ? over(float4(x.rgb / x.a, x.a * alpha), c) : c;
}

fragment float4 overlay_fragment(OverlayVertex in [[stage_in]], texture2d<float> t0 [[texture(0)]],
                                 texture2d<float> t1 [[texture(1)]], texture2d<float> t2 [[texture(2)]],
                                 texture2d<float> t3 [[texture(3)]], constant uint &linear [[buffer(0)]],
                                 constant GraphData &graph [[buffer(1)]], constant Layers &layers [[buffer(2)]])
{
	int kind = int(in.shape.x);
	float2 p = in.position.xy;
	float4 color = in.color;
	if (kind == quad_panel) {
		float d = box(p, in.rect, in.shape.y);
		float4 c = color;
		// The rim and the top highlight live near the edge; the middle is the plain fill
		if (d > -(in.shape.z + 1))
			c = over(float4(in.extra.rgb, in.extra.a * saturate(0.5 + d + in.shape.z)), c);
		if (p.y - in.rect.y < in.shape.w + in.shape.y)
			c = over(float4(1, 1, 1, 0.12 * saturate(0.5 + box(p - float2(0, in.shape.w), in.rect, in.shape.y))), c);
		uint mask = uint(in.clip.x);
		if (mask & 1)
			c = layer(c, t0, layers.rect[0], layers.alpha[0], p);
		if (mask & 2)
			c = layer(c, t1, layers.rect[1], layers.alpha[1], p);
		if (mask & 4)
			c = layer(c, t2, layers.rect[2], layers.alpha[2], p);
		if (mask & 8)
			c = layer(c, t3, layers.rect[3], layers.alpha[3], p);
		color = float4(c.rgb, c.a * saturate(0.5 - d));
	} else if (kind == quad_shadow) {
		float d = box(p, in.extra, in.shape.y);
		float fall = d <= 0 ? 1 : pow(1 - saturate(d / in.shape.z), 2);
		color.a *= fall * saturate(0.5 + box(p, in.clip, in.shape.y));
	} else if (kind == quad_graph) {
		float2 q = p - in.rect.xy;
		int n = int(graph.count);
		float w = in.rect.z, step = w / float(n - 1);
		float fx = q.x / step;
		int i = clamp(int(floor(fx)), 0, n - 2);
		float y = mix(graph.y[i], graph.y[i + 1], saturate(fx - float(i)));
		float4 c = float4(0);
		for (int g = 0; g < 3; g++)
			if (abs(q.y - graph.grid[g]) <= graph.unit * 0.5 && fmod(q.x, graph.unit * 5) < graph.unit * 2)
				c = float4(235.0 / 255, 235.0 / 255, 245.0 / 255, 0.22);
		if (q.y >= y)
			c = over(float4(color.rgb, 0.14), c);
		float d = 1e9;
		for (int k = max(i - 1, 0); k <= min(i + 1, n - 2); k++)
			d = min(d, segment(q, float2(k * step, graph.y[k]), float2((k + 1) * step, graph.y[k + 1])));
		c = over(float4(color.rgb, saturate(graph.width * 0.5 + 0.5 - d)), c);
		color = float4(c.rgb, c.a * color.a * saturate(0.5 - box(p, in.clip, in.shape.y)));
	}
	float3 rgb = linear != 0 ? linear_from_srgb(color.rgb) : color.rgb;
	return float4(rgb, color.a);
}
