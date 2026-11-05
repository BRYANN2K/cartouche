// DLSS through MetalFX taken over, classic (DXMT) or Metal 4 (MTL4FX, as D3DMetal may): the game's
// temporal scaler tuned as it is made, its inputs fixed at each encode, its output sharpened. On
// by default on the classic path, opt-in on Metal 4 through CARTOUCHE_FRAMEGEN_TEMPORAL4=1, never
// tried on a real game yet; CARTOUCHE_FRAMEGEN_TEMPORAL="off" leaves the runner's chain as it is.
// Settings: docs/FRAME-GENERATION.md.

#import <Metal/Metal.h>

NS_ASSUME_NONNULL_BEGIN

typedef struct {
	BOOL enabled;
	float sharpness;
	float jitter;
	int exposure;
	BOOL mvJittered;
	float reactive;
	int bounds;
	int fx;
} FGTemporalSettings;

FOUNDATION_EXPORT FGTemporalSettings FGTemporalDefaults(void);
// "off" or "name=value,..." over the defaults; NO for a name it does not know
FOUNDATION_EXPORT BOOL FGTemporalParse(const char *_Nullable text, FGTemporalSettings *settings);

// Reads CARTOUCHE_FRAMEGEN_TEMPORAL; log takes one line without its prefix
FOUNDATION_EXPORT void FGTemporalStart(void (*log)(const char *format, ...));
// YES once CARTOUCHE_FRAMEGEN_TEMPORAL4=1 opted the Metal 4 chain in at FGTemporalStart
FOUNDATION_EXPORT BOOL FGTemporalMetal4(void);
// The descriptor the game's scaler is made from, tuned in place
FOUNDATION_EXPORT void FGTemporalTune(id descriptor);
// A scaler just made from that descriptor on device
FOUNDATION_EXPORT void FGTemporalAdopt(id _Nullable scaler, id<MTLDevice> device);
// Stands for the scaler's own encodeToCommandBuffer:, next, on an MTLCommandBuffer or MTL4CommandBuffer
FOUNDATION_EXPORT void FGTemporalEncode(id scaler, SEL selector, id buffer, IMP next);

// Scalers the library makes itself (fg_metal.m), between FGTemporalOwn(YES) and (NO) on one thread:
// the hooks leave them as made. FGTemporalClaim marks one just made, YES if it is ours.
FOUNDATION_EXPORT void FGTemporalOwn(BOOL on);
FOUNDATION_EXPORT BOOL FGTemporalClaim(id _Nullable scaler);
FOUNDATION_EXPORT BOOL FGTemporalIsOwn(id scaler);

FOUNDATION_EXPORT id _Nullable FGTemporalScaler(void);
// The game's scaler encodes since the last call; the HUD shows Temporal only while there are some
FOUNDATION_EXPORT unsigned long FGTemporalTakeEncodes(void);
// GPU time of the command buffers the scaler was encoded into, median of the last 120, ms
FOUNDATION_EXPORT double FGTemporalBufferMillis(void);

NS_ASSUME_NONNULL_END
