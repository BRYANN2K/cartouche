// The scenes of the frame generation test window, shared with the settings search: the logo
// crossing a dark track, and a flight between spinning cubes with a still logo as a HUD.

#import <Metal/Metal.h>

typedef struct {
	float time, dist, aspect, prevTime, prevDist;
} Scene3D;

typedef struct {
	float size[2];
	float x;
	float logo;
	float scale;
} Uniforms;

typedef struct {
	__unsafe_unretained id<MTLRenderPipelineState> cube, ground, hud, cubeMotion, groundMotion;
	__unsafe_unretained id<MTLDepthStencilState> depth;
} Scene3DPipes;

static NSString *shaders = @
	"#include <metal_stdlib>\n"
	"using namespace metal;\n"
	"struct U { float2 size; float x; float logo; float scale; };\n"
	"struct V { float4 p [[position]]; float2 uv; };\n"
	"vertex V track(uint i [[vertex_id]]) { float2 c = float2((i << 1) & 2, i & 2); V o; o.p = float4(c * 2 - 1, 0, 1); o.uv = c; return o; }\n"
	"fragment float4 track_f(V in [[stage_in]], constant U &u [[buffer(0)]]) {\n"
	"  float x = in.p.x / u.scale, y = in.p.y / u.scale;\n"
	"  float line = step(fmod(x, 80.0), 1.5) * 0.06;\n"
	"  float band = step(fmod(floor(y / 40.0), 2.0), 0.5) * 0.015;\n"
	"  return float4(float3(0.11, 0.115, 0.14) + line + band, 1);\n"
	"}\n"
	"vertex V logo(uint i [[vertex_id]], constant U &u [[buffer(0)]]) {\n"
	"  float2 c = float2(i & 1, i >> 1);\n"
	"  float2 at = float2(u.x, (u.size.y - u.logo) / 2) + c * u.logo;\n"
	"  V o; o.p = float4(at / u.size * float2(2, -2) + float2(-1, 1), 0, 1); o.uv = c; return o;\n"
	"}\n"
	"fragment float4 logo_f(V in [[stage_in]], texture2d<float> t [[texture(0)]]) {\n"
	"  constexpr sampler s(filter::linear);\n"
	"  return t.sample(s, in.uv);\n"
	"}\n"
	"struct S { float time; float dist; float aspect; float prevTime; float prevDist; };\n"
	"struct V3 { float4 p [[position]]; float3 local; float3 normal; float depth; float3 tint; float4 prev; float4 cur; };\n"
	"static float hash(float n) { return fract(sin(n * 12.9898) * 43758.5453); }\n"
	"static float4x4 view_proj(float time, float aspect) {\n"
	"  float yaw = sin(time * 0.6) * 0.35, f = 1.0 / tan(0.5236), n = 0.1, r = 200.0;\n"
	"  float4x4 p = float4x4(float4(f / aspect, 0, 0, 0), float4(0, f, 0, 0), float4(0, 0, r / (n - r), -1), float4(0, 0, n * r / (n - r), 0));\n"
	"  float c = cos(yaw), si = sin(yaw);\n"
	"  float4x4 v = float4x4(float4(c, 0, -si, 0), float4(0, 1, 0, 0), float4(si, 0, c, 0), float4(-sin(time * 0.9) * 1.5, -0.4, 0, 1));\n"
	"  return p * v;\n"
	"}\n"
	"constant float3 normals[6] = { float3(1,0,0), float3(-1,0,0), float3(0,1,0), float3(0,-1,0), float3(0,0,1), float3(0,0,-1) };\n"
	"constant float3 axisA[6] = { float3(0,1,0), float3(0,0,1), float3(0,0,1), float3(1,0,0), float3(1,0,0), float3(0,1,0) };\n"
	"constant float3 axisB[6] = { float3(0,0,1), float3(0,1,0), float3(1,0,0), float3(0,0,1), float3(0,1,0), float3(1,0,0) };\n"
	"constant float2 corners[6] = { float2(0,0), float2(1,0), float2(0,1), float2(0,1), float2(1,0), float2(1,1) };\n"
	"static float3 cube_world(uint v, uint inst, float time, float dist, thread float3 &normal) {\n"
	"  uint face = v / 6; float2 c = corners[v % 6] * 2 - 1;\n"
	"  float3 local = normals[face] + c.x * axisA[face] + c.y * axisB[face];\n"
	"  float h = hash(float(inst) + 1.0), a = time * (0.4 + h * 1.6) + h * 6.28;\n"
	"  float3x3 ry = float3x3(float3(cos(a), 0, -sin(a)), float3(0, 1, 0), float3(sin(a), 0, cos(a)));\n"
	"  float3x3 rx = float3x3(float3(1, 0, 0), float3(0, cos(a * 0.7), sin(a * 0.7)), float3(0, -sin(a * 0.7), cos(a * 0.7)));\n"
	"  float gx = float(inst % 8) - 3.5, gz = float(inst / 8);\n"
	"  float z = -fmod(gz * 5.0 - fmod(dist, 160.0) + 160.0, 160.0) - 3.0;\n"
	"  normal = rx * ry * normals[face];\n"
	"  return rx * ry * local * (0.6 + h * 0.5) + float3(gx * 4.5, (hash(float(inst) * 3.1) - 0.3) * 3.0, z);\n"
	"}\n"
	"vertex V3 cube(uint v [[vertex_id]], uint inst [[instance_id]], constant S &s [[buffer(0)]]) {\n"
	"  float3 normal, before;\n"
	"  float3 world = cube_world(v, inst, s.time, s.dist, normal);\n"
	"  float3 then = cube_world(v, inst, s.prevTime, s.prevDist, before);\n"
	"  uint face = v / 6; float2 c = corners[v % 6] * 2 - 1;\n"
	"  float h = hash(float(inst) + 1.0);\n"
	"  V3 o; o.p = view_proj(s.time, s.aspect) * float4(world, 1); o.local = normals[face] + c.x * axisA[face] + c.y * axisB[face];\n"
	"  o.normal = normal; o.depth = -world.z; o.tint = 0.45 + 0.45 * cos(6.28 * (h + float3(0, 0.33, 0.67)));\n"
	"  o.cur = o.p; o.prev = view_proj(s.prevTime, s.aspect) * float4(then, 1); return o;\n"
	"}\n"
	"vertex V3 ground(uint v [[vertex_id]], constant S &s [[buffer(0)]]) {\n"
	"  float2 c = float2(v & 1, v >> 1);\n"
	"  float3 world = float3((c.x * 2 - 1) * 80.0, -2.5, -c.y * 170.0);\n"
	"  V3 o; o.p = view_proj(s.time, s.aspect) * float4(world, 1); o.local = float3(world.x, 0, world.z - s.dist);\n"
	"  o.normal = float3(0, 1, 0); o.depth = -world.z; o.tint = float3(0.55, 0.57, 0.62);\n"
	"  o.cur = o.p; o.prev = view_proj(s.prevTime, s.aspect) * float4(world + float3(0, 0, s.prevDist - s.dist), 1); return o;\n"
	"}\n"
	"fragment float2 motion_f(V3 in [[stage_in]], constant float2 &size [[buffer(0)]]) {\n"
	"  float2 a = in.prev.xy / in.prev.w, b = in.cur.xy / in.cur.w;\n"
	"  return (a - b) * float2(0.5, -0.5) * size;\n"
	"}\n"
	"fragment float4 lit_f(V3 in [[stage_in]], bool front [[front_facing]]) {\n"
	"  float3 q = floor(in.local * 2.0);\n"
	"  float check = fmod(abs(q.x + q.y + q.z), 2.0) < 0.5 ? 1.0 : 0.55;\n"
	"  float light = 0.35 + 0.65 * saturate(dot(normalize(in.normal), normalize(float3(0.4, 0.8, 0.45))));\n"
	"  float fog = saturate(exp(-in.depth * 0.018));\n"
	"  return float4(mix(float3(0.11, 0.115, 0.14), in.tint * check * light, fog), 1);\n"
	"}\n"
	"vertex V hud(uint i [[vertex_id]], constant U &u [[buffer(0)]]) {\n"
	"  float2 c = float2(i & 1, i >> 1);\n"
	"  float2 at = float2(20, u.size.y - u.logo - 20) + c * u.logo;\n"
	"  V o; o.p = float4(at / u.size * float2(2, -2) + float2(-1, 1), 0, 1); o.uv = c; return o;\n"
	"}\n";


static NSMutableArray *scene3d_keep;

static BOOL scene3d_build(id<MTLDevice> device, id<MTLLibrary> library, Scene3DPipes *pipes, NSError **error)
{
	MTLRenderPipelineDescriptor *describe = [MTLRenderPipelineDescriptor new];
	describe.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
	describe.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
	describe.vertexFunction = [library newFunctionWithName:@"hud"];
	describe.fragmentFunction = [library newFunctionWithName:@"logo_f"];
	describe.colorAttachments[0].blendingEnabled = YES;
	describe.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorOne;
	describe.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
	id<MTLRenderPipelineState> hud = [device newRenderPipelineStateWithDescriptor:describe error:error];
	describe.colorAttachments[0].blendingEnabled = NO;
	describe.vertexFunction = [library newFunctionWithName:@"cube"];
	describe.fragmentFunction = [library newFunctionWithName:@"lit_f"];
	id<MTLRenderPipelineState> cube = [device newRenderPipelineStateWithDescriptor:describe error:error];
	describe.vertexFunction = [library newFunctionWithName:@"ground"];
	id<MTLRenderPipelineState> ground = [device newRenderPipelineStateWithDescriptor:describe error:error];
	MTLDepthStencilDescriptor *d = [MTLDepthStencilDescriptor new];
	d.depthCompareFunction = MTLCompareFunctionLess;
	d.depthWriteEnabled = YES;
	id<MTLDepthStencilState> depth = [device newDepthStencilStateWithDescriptor:d];
	describe.colorAttachments[0].pixelFormat = MTLPixelFormatRG16Float;
	describe.fragmentFunction = [library newFunctionWithName:@"motion_f"];
	id<MTLRenderPipelineState> groundMotion = [device newRenderPipelineStateWithDescriptor:describe error:error];
	describe.vertexFunction = [library newFunctionWithName:@"cube"];
	id<MTLRenderPipelineState> cubeMotion = [device newRenderPipelineStateWithDescriptor:describe error:error];
	if (hud == nil || cube == nil || ground == nil || depth == nil || cubeMotion == nil || groundMotion == nil)
		return NO;
	scene3d_keep = [NSMutableArray arrayWithObjects:hud, cube, ground, depth, cubeMotion, groundMotion, nil];
	*pipes = (Scene3DPipes){ cube, ground, hud, cubeMotion, groundMotion, depth };
	return YES;
}

static void scene3d_draw(id<MTLRenderCommandEncoder> encoder, const Scene3DPipes *pipes, Scene3D s, Uniforms u,
                         id<MTLTexture> logo)
{
	[encoder setDepthStencilState:pipes->depth];
	[encoder setRenderPipelineState:pipes->ground];
	[encoder setVertexBytes:&s length:sizeof(s) atIndex:0];
	[encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
	[encoder setRenderPipelineState:pipes->cube];
	[encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:36 instanceCount:8 * 32];
	[encoder setRenderPipelineState:pipes->hud];
	[encoder setVertexBytes:&u length:sizeof(u) atIndex:0];
	[encoder setFragmentTexture:logo atIndex:0];
	[encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
}

// The true motion of every pixel, in pixels towards where it was the frame before, as the
// interpolator wants it; the HUD stays still, so it is left out
__attribute__((unused)) static void scene3d_motion(id<MTLRenderCommandEncoder> encoder, const Scene3DPipes *pipes, Scene3D s, float width,
                           float height)
{
	float size[2] = { width, height };
	[encoder setDepthStencilState:pipes->depth];
	[encoder setRenderPipelineState:pipes->groundMotion];
	[encoder setVertexBytes:&s length:sizeof(s) atIndex:0];
	[encoder setFragmentBytes:size length:sizeof(size) atIndex:0];
	[encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
	[encoder setRenderPipelineState:pipes->cubeMotion];
	[encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:36 instanceCount:8 * 32];
}
