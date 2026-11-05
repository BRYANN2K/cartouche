// Training triplets from the test window's 3D flight, without its HUD: for each stdin line
// "name middle step speed spin", the frames at middle - step, middle and middle + step, where the
// camera travels speed units a second and the cubes spin spin times as fast as in tune.
// Usage: gen3d <out dir> <width> <height> < jobs
// Writes <name>.raw, three BGRA frames one after the other.
#import <Metal/Metal.h>

#import "../../tests/scene.h"

int main(int argc, char **argv)
{
	@autoreleasepool {
		if (argc < 4)
			return 2;
		int width = atoi(argv[2]), height = atoi(argv[3]);
		id<MTLDevice> device = MTLCreateSystemDefaultDevice();
		NSError *failure = nil;
		id<MTLLibrary> library = [device newLibraryWithSource:shaders options:nil error:&failure];
		Scene3DPipes pipes;
		if (library == nil || !scene3d_build(device, library, &pipes, &failure)) {
			fprintf(stderr, "gen3d: %s\n", failure.localizedDescription.UTF8String);
			return 1;
		}
		MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
		                                                                             width:width height:height mipmapped:NO];
		d.usage = MTLTextureUsageRenderTarget;
		d.storageMode = MTLStorageModeShared;
		id<MTLTexture> color = [device newTextureWithDescriptor:d];
		d.pixelFormat = MTLPixelFormatDepth32Float;
		d.storageMode = MTLStorageModePrivate;
		id<MTLTexture> depth = [device newTextureWithDescriptor:d];
		MTLTextureDescriptor *one = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
		                                                                               width:1 height:1 mipmapped:NO];
		id<MTLTexture> blank = [device newTextureWithDescriptor:one];
		const uint8_t clear[4] = { 0 };
		[blank replaceRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0 withBytes:clear bytesPerRow:4];
		id<MTLCommandQueue> queue = [device newCommandQueue];
		size_t bytes = (size_t)width * height * 4;
		uint8_t *pixels = malloc(bytes * 3);
		char name[256];
		double middle, step, speed, spin;
		while (scanf("%255s %lf %lf %lf %lf", name, &middle, &step, &speed, &spin) == 5) {
			for (int k = 0; k < 3; k++) {
				double t = middle + (k - 1) * step;
				Scene3D s = { (float)(t * spin), (float)(speed * t), (float)width / height, 0, 0 };
				Uniforms u = { { width, height }, 0, 0, 1 };
				MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
				pass.colorAttachments[0].texture = color;
				pass.colorAttachments[0].loadAction = MTLLoadActionClear;
				pass.colorAttachments[0].clearColor = MTLClearColorMake(0.11, 0.115, 0.14, 1);
				pass.colorAttachments[0].storeAction = MTLStoreActionStore;
				pass.depthAttachment.texture = depth;
				pass.depthAttachment.loadAction = MTLLoadActionClear;
				pass.depthAttachment.clearDepth = 1;
				id<MTLCommandBuffer> buffer = [queue commandBuffer];
				id<MTLRenderCommandEncoder> encoder = [buffer renderCommandEncoderWithDescriptor:pass];
				scene3d_draw(encoder, &pipes, s, u, blank);
				[encoder endEncoding];
				[buffer commit];
				[buffer waitUntilCompleted];
				[color getBytes:pixels + bytes * k bytesPerRow:width * 4 fromRegion:MTLRegionMake2D(0, 0, width, height)
				    mipmapLevel:0];
			}
			char path[1024];
			snprintf(path, sizeof(path), "%s/%s.raw", argv[1], name);
			FILE *file = fopen(path, "wb");
			if (file == NULL || fwrite(pixels, 1, bytes * 3, file) != bytes * 3)
				return 1;
			fclose(file);
		}
		return 0;
	}
}
