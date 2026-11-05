// Tests only, inserted next to the library: a game we cannot change (AMD's FSR sample) runs
// without ever taking the focus. Its windows go to the Mac's own screen, bottom-right, floating
// and ignoring clicks; the app never activates and stays out of App Nap. As tests/screen.h,
// CARTOUCHE_FRAMEGEN_SCREEN=external or main picks another screen.
#import <AppKit/AppKit.h>
#import <objc/runtime.h>

static id activity;
static IMP next_order;

static NSScreen *test_screen(void)
{
	const char *pick = getenv("CARTOUCHE_FRAMEGEN_SCREEN");
	if (pick == NULL || strcmp(pick, "main") != 0) {
		BOOL builtin = pick == NULL || strcmp(pick, "external") != 0;
		for (NSScreen *screen in NSScreen.screens)
			if ((CGDisplayIsBuiltin([screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue]) != 0) == builtin)
				return screen;
	}
	return NSScreen.screens.firstObject;
}

static void place(NSWindow *window)
{
	NSRect visible = test_screen().visibleFrame;
	window.level = NSFloatingWindowLevel;
	window.ignoresMouseEvents = YES;
	[window setFrameOrigin:NSMakePoint(NSMaxX(visible) - NSWidth(window.frame), NSMinY(visible))];
}

static void hook_order(NSWindow *window, SEL selector, NSWindowOrderingMode mode, NSInteger other)
{
	if (mode != NSWindowOut)
		place(window);
	((void (*)(id, SEL, NSWindowOrderingMode, NSInteger))next_order)(window, selector, mode, other);
}

static void hook_make_key(NSWindow *window, SEL selector, id sender)
{
	(void)selector;
	(void)sender;
	place(window);
	[window orderFrontRegardless];
}

static void stay(id app, SEL selector, ...)
{
	(void)app;
	(void)selector;
}

static BOOL stay_running(id app, SEL selector, NSApplicationActivationOptions options)
{
	(void)app;
	(void)selector;
	(void)options;
	return NO;
}

static IMP next_policy;
static BOOL hook_policy(id app, SEL selector, NSApplicationActivationPolicy policy)
{
	(void)policy;
	return ((BOOL (*)(id, SEL, NSApplicationActivationPolicy))next_policy)(app, selector,
	                                                                        NSApplicationActivationPolicyAccessory);
}

__attribute__((constructor)) static void quiet(void)
{
	activity = [NSProcessInfo.processInfo beginActivityWithOptions:NSActivityUserInitiated | NSActivityLatencyCritical
	                                                        reason:@"framegen test"];
	Class app = [NSApplication class], window = [NSWindow class];
	method_setImplementation(class_getInstanceMethod(app, @selector(activateIgnoringOtherApps:)), (IMP)stay);
	Method activate = class_getInstanceMethod(app, sel_registerName("activate"));
	if (activate != NULL)
		method_setImplementation(activate, (IMP)stay);
	method_setImplementation(class_getInstanceMethod([NSRunningApplication class], @selector(activateWithOptions:)),
	                         (IMP)stay_running);
	next_policy = method_setImplementation(class_getInstanceMethod(app, @selector(setActivationPolicy:)), (IMP)hook_policy);
	next_order = method_setImplementation(class_getInstanceMethod(window, @selector(orderWindow:relativeTo:)),
	                                      (IMP)hook_order);
	method_setImplementation(class_getInstanceMethod(window, @selector(makeKeyAndOrderFront:)), (IMP)hook_make_key);
}
