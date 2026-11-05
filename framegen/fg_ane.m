#import "fg_ane.h"

#import <CoreVideo/CoreVideo.h>
#import <IOSurface/IOSurface.h>
#include <os/os_sync_wait_on_address.h>
#include <crt_externs.h>
#include <fcntl.h>
#include <servers/bootstrap.h>
#include <spawn.h>
#include <sys/mman.h>
#include <unistd.h>

#include "ane/fg_ane_protocol.h"

@implementation FGNeural {
	IOSurfaceRef _surfaces[4];
	id<MTLTexture> _inputs[2], _flow, _mask;
	FGANEControl *_control;
	char _controlName[64];
	pid_t _helper;
	uint32_t _request;
}

static IOSurfaceRef make_surface(int rows)
{
	CVPixelBufferRef buffer = NULL;
	NSDictionary *attributes = @{ (id)kCVPixelBufferIOSurfacePropertiesKey: @{}, (id)kCVPixelBufferMetalCompatibilityKey: @YES };
	if (CVPixelBufferCreate(NULL, fg_ane_width, rows, kCVPixelFormatType_OneComponent16Half,
	                        (__bridge CFDictionaryRef)attributes, &buffer) != kCVReturnSuccess)
		return NULL;
	IOSurfaceRef surface = CVPixelBufferGetIOSurface(buffer);
	if (surface != NULL)
		CFRetain(surface);
	CVPixelBufferRelease(buffer);
	return surface;
}

static id<MTLTexture> texture_on(id<MTLDevice> device, IOSurfaceRef surface)
{
	MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR16Float
	                                                                             width:IOSurfaceGetWidth(surface)
	                                                                            height:IOSurfaceGetHeight(surface)
	                                                                         mipmapped:NO];
	d.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
	d.storageMode = MTLStorageModeShared;
	return [device newTextureWithDescriptor:d iosurface:surface plane:0];
}

+ (instancetype)startWithDevice:(id<MTLDevice>)device helper:(NSString *)helper model:(NSString *)model error:(NSString **)error
{
	FGNeural *neural = [FGNeural new];
	return [neural startWithDevice:device helper:helper model:model error:error] ? neural : nil;
}

- (BOOL)startWithDevice:(id<MTLDevice>)device helper:(NSString *)helper model:(NSString *)model error:(NSString **)error
{
	const int rows[4] = { 3 * fg_ane_height, 3 * fg_ane_height, 4 * fg_ane_height, fg_ane_height };
	for (int i = 0; i < 4; i++)
		if ((_surfaces[i] = make_surface(rows[i])) == NULL) {
			*error = @"no IOSurface";
			return NO;
		}
	_inputs[0] = texture_on(device, _surfaces[0]);
	_inputs[1] = texture_on(device, _surfaces[1]);
	_flow = texture_on(device, _surfaces[2]);
	_mask = texture_on(device, _surfaces[3]);
	snprintf(_controlName, sizeof(_controlName), "/cartouche-fg-%d", getpid());
	int fd = shm_open(_controlName, O_RDWR | O_CREAT, 0600);
	if (fd < 0 || ftruncate(fd, 16384) != 0) {
		*error = @"no control page";
		return NO;
	}
	_control = mmap(NULL, 16384, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
	close(fd);
	if (_control == MAP_FAILED) {
		_control = NULL;
		*error = @"no control page";
		return NO;
	}
	memset(_control, 0, sizeof(*_control));

	// The helper gets a clean environment: the game's would insert this x86_64 library into it
	char service[96], parent[16];
	snprintf(service, sizeof(service), "dev.cartouche.framegen.ane.%d", getpid());
	snprintf(parent, sizeof(parent), "%d", getpid());
	char *argv[] = { (char *)helper.fileSystemRepresentation, service, (char *)model.fileSystemRepresentation, parent, NULL };
	char home[PATH_MAX + 8], tmp[PATH_MAX + 8];
	snprintf(home, sizeof(home), "HOME=%s", getenv("HOME") ?: "/tmp");
	snprintf(tmp, sizeof(tmp), "TMPDIR=%s", getenv("TMPDIR") ?: "/tmp");
	char *envp[] = { home, tmp, "PATH=/usr/bin:/bin", NULL };
	if (posix_spawn(&_helper, argv[0], NULL, NULL, argv, envp) != 0) {
		*error = [NSString stringWithFormat:@"cannot start %@", helper];
		return NO;
	}
	mach_port_t port = MACH_PORT_NULL;
	for (int i = 0; i < 200 && bootstrap_look_up(bootstrap_port, service, &port) != KERN_SUCCESS; i++)
		usleep(10000);
	if (port == MACH_PORT_NULL) {
		*error = @"helper did not check in";
		[self stop];
		return NO;
	}
	FGANEHello hello = { 0 };
	hello.header.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0) | MACH_MSGH_BITS_COMPLEX;
	hello.header.msgh_size = sizeof(hello);
	hello.header.msgh_remote_port = port;
	hello.body.msgh_descriptor_count = 4;
	for (int i = 0; i < 4; i++) {
		hello.surfaces[i].name = IOSurfaceCreateMachPort(_surfaces[i]);
		hello.surfaces[i].disposition = MACH_MSG_TYPE_MOVE_SEND;
		hello.surfaces[i].type = MACH_MSG_PORT_DESCRIPTOR;
	}
	strlcpy(hello.control, _controlName, sizeof(hello.control));
	kern_return_t kr = mach_msg(&hello.header, MACH_SEND_MSG | MACH_SEND_TIMEOUT, sizeof(hello), 0, MACH_PORT_NULL, 1000,
	                            MACH_PORT_NULL);
	mach_port_deallocate(mach_task_self(), port);
	if (kr != KERN_SUCCESS) {
		*error = @"helper did not take the surfaces";
		[self stop];
		return NO;
	}
	return YES;
}

- (BOOL)ready { return _control != NULL && atomic_load(&_control->ready) != 0; }
- (id<MTLTexture>)inputForSlot:(int)slot { return _inputs[slot & 1]; }
- (id<MTLTexture>)flow { return _flow; }
- (id<MTLTexture>)mask { return _mask; }
- (double)lastMillis { return _control ? atomic_load(&_control->micros) / 1000.0 : 0; }

- (void)requestEarlier:(int)earlier
{
	atomic_store(&_control->parity, (uint32_t)(earlier & 1));
	atomic_store(&_control->request, ++_request);
	os_sync_wake_by_address_any(&_control->request, 4, OS_SYNC_WAKE_BY_ADDRESS_SHARED);
}

- (BOOL)waitFor:(double)seconds
{
	uint64_t deadline = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) + (uint64_t)(seconds * 1e9);
	for (;;) {
		uint32_t done = atomic_load(&_control->done);
		if (done == _request)
			return YES;
		uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
		if (now >= deadline)
			return NO;
		os_sync_wait_on_address_with_timeout(&_control->done, done, 4, OS_SYNC_WAIT_ON_ADDRESS_SHARED,
		                                     OS_CLOCK_MACH_ABSOLUTE_TIME, deadline - now);
	}
}

- (void)stop
{
	if (_control != NULL) {
		atomic_store(&_control->quit, 1);
		os_sync_wake_by_address_any(&_control->request, 4, OS_SYNC_WAKE_BY_ADDRESS_SHARED);
		munmap(_control, 16384);
		_control = NULL;
		shm_unlink(_controlName);
	}
	for (int i = 0; i < 4; i++)
		if (_surfaces[i] != NULL) {
			CFRelease(_surfaces[i]);
			_surfaces[i] = NULL;
		}
}

- (void)dealloc { [self stop]; }

@end
