// The frame generation library's Neural Engine helper. Core ML runs on the ANE only in arm64
// processes, and games run as x86_64 under Rosetta, so the flow network runs here: the library
// starts this helper, hands over four IOSurfaces, and asks for the flow between two frames.
// Usage: framegen-ane <service name> <model.mlmodelc> <parent pid>
#import <CoreML/CoreML.h>
#import <CoreVideo/CoreVideo.h>
#import <IOSurface/IOSurface.h>
#include <os/os_sync_wait_on_address.h>
#include <fcntl.h>
#include <pthread/qos.h>
#include <servers/bootstrap.h>
#include <signal.h>
#include <stdio.h>
#include <sys/mman.h>
#include <unistd.h>

#include "fg_ane_protocol.h"

typedef struct {
	FGANEHello hello;
	mach_msg_trailer_t trailer;
} Received;

static MLMultiArray *array(IOSurfaceRef surface, int planes)
{
	CVPixelBufferRef buffer = NULL;
	if (CVPixelBufferCreateWithIOSurface(NULL, surface, NULL, &buffer) != kCVReturnSuccess)
		return nil;
	MLMultiArray *array = [[MLMultiArray alloc] initWithPixelBuffer:buffer shape:@[ @1, @(planes), @(fg_ane_height), @(fg_ane_width) ]];
	CVPixelBufferRelease(buffer);
	return array;
}

int main(int argc, char **argv)
{
	@autoreleasepool {
		if (argc < 4)
			return 2;
		pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
		pid_t parent = (pid_t)atoi(argv[3]);
		mach_port_t service;
		if (bootstrap_check_in(bootstrap_port, argv[1], &service) != KERN_SUCCESS) {
			fprintf(stderr, "framegen-ane: cannot check in %s\n", argv[1]);
			return 1;
		}
		Received received = { 0 };
		if (mach_msg(&received.hello.header, MACH_RCV_MSG | MACH_RCV_TIMEOUT, 0, sizeof(received), service, 10000,
		             MACH_PORT_NULL) != KERN_SUCCESS)
			return 1;
		received.hello.control[sizeof(received.hello.control) - 1] = 0;
		int fd = shm_open(received.hello.control, O_RDWR, 0600);
		FGANEControl *control = fd >= 0 ? mmap(NULL, 16384, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0) : MAP_FAILED;
		if (control == MAP_FAILED)
			return 1;
		IOSurfaceRef surfaces[4];
		for (int i = 0; i < 4; i++)
			surfaces[i] = IOSurfaceLookupFromMachPort(received.hello.surfaces[i].name);
		MLMultiArray *frame0 = array(surfaces[0], 3), *frame1 = array(surfaces[1], 3);
		MLMultiArray *flow = array(surfaces[2], 4), *mask = array(surfaces[3], 1);

		MLModelConfiguration *configuration = [MLModelConfiguration new];
		configuration.computeUnits = MLComputeUnitsCPUAndNeuralEngine;
		NSError *error = nil;
		MLModel *model = [MLModel modelWithContentsOfURL:[NSURL fileURLWithPath:@(argv[2])] configuration:configuration
		                                           error:&error];
		if (model == nil || frame0 == nil || frame1 == nil || flow == nil || mask == nil) {
			fprintf(stderr, "framegen-ane: %s\n", model == nil ? error.localizedDescription.UTF8String : "surfaces unusable");
			return 1;
		}
		// Both orders, so the library only writes each new frame once
		MLDictionaryFeatureProvider *forward = [[MLDictionaryFeatureProvider alloc]
			initWithDictionary:@{ @"a": frame0, @"b": frame1 } error:NULL];
		MLDictionaryFeatureProvider *backward = [[MLDictionaryFeatureProvider alloc]
			initWithDictionary:@{ @"a": frame1, @"b": frame0 } error:NULL];
		MLPredictionOptions *options = [MLPredictionOptions new];
		options.outputBackings = @{ @"flow": flow, @"mask": mask };
		// The first runs are slow while the model settles on the ANE
		for (int i = 0; i < 3; i++)
			[model predictionFromFeatures:forward options:options error:NULL];
		atomic_store(&control->ready, 1);

		uint32_t seen = 0;
		while (!atomic_load(&control->quit)) {
			uint32_t now = atomic_load(&control->request);
			if (now == seen) {
				os_sync_wait_on_address_with_timeout(&control->request, seen, 4, OS_SYNC_WAIT_ON_ADDRESS_SHARED,
				                                     OS_CLOCK_MACH_ABSOLUTE_TIME, 200000000);
				if (kill(parent, 0) != 0)
					break;
				continue;
			}
			seen = now;
			uint64_t start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
			@autoreleasepool {
				[model predictionFromFeatures:atomic_load(&control->parity) ? backward : forward options:options error:NULL];
			}
			atomic_store(&control->micros, (uint32_t)((clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start) / 1000));
			atomic_store(&control->done, now);
			os_sync_wake_by_address_any(&control->done, 4, OS_SYNC_WAKE_BY_ADDRESS_SHARED);
		}
		return 0;
	}
}
