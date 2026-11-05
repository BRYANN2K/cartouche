// The Neural Engine side of frame generation: an arm64 helper process computes the flow between
// two frames with a small network, on IOSurfaces shared with this library
#import <Metal/Metal.h>

NS_ASSUME_NONNULL_BEGIN

@interface FGNeural : NSObject

// Starts the helper and hands it the surfaces; the model loads in the background, see ready
+ (nullable instancetype)startWithDevice:(id<MTLDevice>)device helper:(NSString *)helper model:(NSString *)model
                                   error:(NSString *_Nullable *_Nullable)error;
@property (nonatomic, readonly) BOOL ready;
// One frame per slot, planar RGB at the network's size: written by the GPU, read by the helper
- (id<MTLTexture>)inputForSlot:(int)slot;
// The flows from the middle frame to the earlier and the later one, four planes, network pixels
@property (nonatomic, readonly) id<MTLTexture> flow;
// The earlier frame's share in the blend at the middle, 0 to 1, one plane: 0.5 where both see it
@property (nonatomic, readonly) id<MTLTexture> mask;
// Asks for the flow between the frame in slot earlier and the one in the other slot
- (void)requestEarlier:(int)earlier;
// Waits for the answer to the last request, at most seconds
- (BOOL)waitFor:(double)seconds;
@property (nonatomic, readonly) double lastMillis;
- (void)stop;

@end

NS_ASSUME_NONNULL_END
