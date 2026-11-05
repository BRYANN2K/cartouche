// Where test windows go: the Mac's own screen, as the user works on the others.
// CARTOUCHE_FRAMEGEN_SCREEN=external picks another screen, main the one with the menu bar; with
// no screen of the kind asked for, the main one.

#import <AppKit/AppKit.h>

static NSScreen *test_screen(void)
{
	const char *pick = getenv("CARTOUCHE_FRAMEGEN_SCREEN");
	NSArray<NSScreen *> *screens = NSScreen.screens;
	if (pick == NULL || strcmp(pick, "main") != 0) {
		BOOL builtin = pick == NULL || strcmp(pick, "external") != 0;
		for (NSScreen *screen in screens)
			if ((CGDisplayIsBuiltin([screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue]) != 0) == builtin)
				return screen;
	}
	return screens.firstObject;
}

// A window out of the user's way: at the bottom of the test screen, margin points from its right
// edge, floating (a covered window gets no frames shown), shown without taking the focus or clicks
static void place_test_window(NSWindow *window, CGFloat margin)
{
	NSRect visible = test_screen().visibleFrame;
	window.level = NSFloatingWindowLevel;
	window.ignoresMouseEvents = YES;
	[window setFrameOrigin:NSMakePoint(NSMaxX(visible) - margin - NSWidth(window.frame), NSMinY(visible))];
	[window orderFrontRegardless];
}
