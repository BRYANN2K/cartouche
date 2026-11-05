// Pixel format helpers shared by the library's passes
#import <Metal/Metal.h>

static inline BOOL is_float(MTLPixelFormat format)
{
	return format == MTLPixelFormatRGBA16Float || format == MTLPixelFormatRGBA32Float ||
	       format == MTLPixelFormatRG11B10Float || format == MTLPixelFormatRGB9E5Float;
}
