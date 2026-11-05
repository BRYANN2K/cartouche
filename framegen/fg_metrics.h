// What the overlay shows: the present path's numbers, the process's CPU, memory and heat, kept
// apart from any drawing. Published to other processes in fg_metrics_shm.h's block.

#import <Foundation/Foundation.h>

#import "fg_metrics_shm.h"

NS_ASSUME_NONNULL_BEGIN

// The present thread's numbers for one whole second
typedef struct {
	double presentedFps, realFps, frameMs, framegenGpuMs, latencyMs, latencyMaxMs, refreshMs;
	uint64_t generated, dropped;
	unsigned droppedSecond;
	int framegen, factor, ane, pauseReason;
} FGMetricsSecond;

// Starts the once-a-second sampler; publish also creates the shared block. Once per process.
FOUNDATION_EXPORT void FGMetricsStart(BOOL publish);
FOUNDATION_EXPORT BOOL FGMetricsRunning(void);
// Interval in ms between two shown frames, and between two real frames
FOUNDATION_EXPORT void FGMetricsShown(double ms);
FOUNDATION_EXPORT void FGMetricsReal(double ms);
// GPU time of one present pass
FOUNDATION_EXPORT void FGMetricsPresentGPU(double ms);
FOUNDATION_EXPORT void FGMetricsSecondDone(const FGMetricsSecond *second);
FOUNDATION_EXPORT void FGMetricsUpscale(int mode, unsigned inWidth, unsigned inHeight, unsigned outWidth,
                                        unsigned outHeight);
// A copy of the current block, header and frame ring included
FOUNDATION_EXPORT void FGMetricsRead(FGMetricsBlock *block);
// Tests only: the shared block's name, empty when not published
FOUNDATION_EXPORT const char *FGMetricsName(void);
// The mean of the slowest 1 % of intervals (at least one), as fps; 0 without intervals
FOUNDATION_EXPORT double FGMetricsLow1(const double *ms, int count);

NS_ASSUME_NONNULL_END
