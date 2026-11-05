// Load time and latency per frame pair of a Core ML flow model on each compute unit.
// Usage: anelat <model.mlmodelc>
#import <CoreML/CoreML.h>
#import <mach/mach_time.h>

static double ms(uint64_t t)
{
	static mach_timebase_info_data_t tb;
	if (!tb.denom)
		mach_timebase_info(&tb);
	return t * tb.numer / tb.denom / 1e6;
}

int main(int argc, char **argv)
{
	@autoreleasepool {
		if (argc < 2)
			return 2;
		NSURL *url = [NSURL fileURLWithPath:@(argv[1])];
		const char *names[] = { "CPU", "CPU+GPU", "CPU+ANE", "all" };
		MLComputeUnits units[] = { MLComputeUnitsCPUOnly, MLComputeUnitsCPUAndGPU, MLComputeUnitsCPUAndNeuralEngine,
			                       MLComputeUnitsAll };
		for (int u = 0; u < 4; u++) {
			MLModelConfiguration *c = [MLModelConfiguration new];
			c.computeUnits = units[u];
			NSError *e = nil;
			uint64_t t0 = mach_absolute_time();
			MLModel *m = [MLModel modelWithContentsOfURL:url configuration:c error:&e];
			if (!m) {
				printf("%s: load failed %s\n", names[u], e.description.UTF8String);
				continue;
			}
			double load = ms(mach_absolute_time() - t0);
			MLFeatureDescription *fa = m.modelDescription.inputDescriptionsByName[@"a"];
			NSArray *shape = fa.multiArrayConstraint.shape;
			MLMultiArray *a = [[MLMultiArray alloc] initWithShape:shape dataType:MLMultiArrayDataTypeFloat16 error:&e];
			MLMultiArray *b = [[MLMultiArray alloc] initWithShape:shape dataType:MLMultiArrayDataTypeFloat16 error:&e];
			MLDictionaryFeatureProvider *in = [[MLDictionaryFeatureProvider alloc] initWithDictionary:@{ @"a": a, @"b": b }
			                                                                                     error:&e];
			double total = 0, worst = 0;
			int n = 40;
			for (int i = 0; i < n + 5; i++) {
				uint64_t s = mach_absolute_time();
				id out = [m predictionFromFeatures:in error:&e];
				double t = ms(mach_absolute_time() - s);
				if (!out) {
					printf("%s: predict failed\n", names[u]);
					break;
				}
				if (i >= 5) {
					total += t;
					worst = fmax(worst, t);
				}
			}
			printf("%-8s load %6.0f ms  per pair %6.2f ms (worst %.2f)\n", names[u], load, total / n, worst);
		}
	}
}
