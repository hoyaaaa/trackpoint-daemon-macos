/* Run the command in README.md; intercept posting so tests never send input. */
#import <Cocoa/Cocoa.h>
#import <ApplicationServices/ApplicationServices.h>
static int clicks, scrolls;
static void capture_post(CGEventTapLocation tap, CGEventRef event) {
    assert(tap == kCGSessionEventTap);
    CGEventType type = CGEventGetType(event);
    if (type == kCGEventScrollWheel) scrolls++;
    else if (type == kCGEventOtherMouseDown || type == kCGEventOtherMouseUp) clicks++;
    else assert(false);
}
#define CGEventPost capture_post
#define main daemon_main
#import "../trackpointd.m"
#undef main
#undef CGEventPost

static TPHIDDevice *device;
static void prepare(bool blocked) {
    s_tpDevices = [NSMutableArray array];
    device = [TPHIDDevice new];
    device->inputConfirmed = true;
    [s_tpDevices addObject:device];
    s_enabled = s_preferredScroll = true;
    s_blockMiddle = blocked;
    s_lastMiddleClickTime = 0;
    reset_gesture_state();
    clicks = scrolls = 0;
}
static bool send_event(CGEventType type, bool attributed, int button, CGPoint point) {
    CGEventRef event = CGEventCreateMouseEvent(NULL, type, point, button);
    assert(event);
    device->rawMiddleDown = attributed && type != kCGEventOtherMouseUp;
    device->lastMiddleButtonTime = attributed ? mach_absolute_time() : 0;
    device->lastPointerTime = attributed ? mach_absolute_time() : 0;
    bool consumed = unified_callback(NULL, type, event, NULL) == NULL;
    CFRelease(event);
    return consumed;
}
int main(void) {
    @autoreleasepool {
        CGPoint start = CGPointMake(100,100), moved = CGPointMake(120,130);
        for (int blocked = 0; blocked <= 1; blocked++) {
            prepare(blocked);
            assert(send_event(kCGEventOtherMouseDown, true, 2, start));
            assert(s_middleDown);
            assert(send_event(kCGEventOtherMouseDragged, true, 2, moved));
            assert(s_hasMoved && scrolls == 1 && clicks == 0);
            assert(send_event(kCGEventOtherMouseUp, true, 2, moved));
            assert(!s_middleDown && clicks == 0);

            prepare(blocked);
            assert(send_event(kCGEventOtherMouseDown, true, 2, start));
            assert(send_event(kCGEventOtherMouseUp, true, 2, start));
            assert(clicks == (blocked ? 0 : 2) && scrolls == 0);

            prepare(blocked);
            native_middle_changed(device, true);
            native_middle_changed(device, false);
            assert(clicks == (blocked ? 0 : 2));
            prepare(blocked);
            native_middle_changed(device, true);
            device->nativeScrolled = true;
            native_middle_changed(device, false);
            assert(clicks == 0);

            prepare(blocked);
            assert(send_event(kCGEventOtherMouseDown, false, 2, start) == blocked);
            assert(send_event(kCGEventOtherMouseDragged, false, 2, moved) == blocked);
            assert(send_event(kCGEventOtherMouseUp, false, 2, moved) == blocked);
            assert(!s_middleDown);
            assert(!send_event(kCGEventOtherMouseDown, false, 3, start));

            prepare(blocked);
            s_preferredScroll = false;
            assert(send_event(kCGEventOtherMouseDown, true, 2, start) == blocked);
            assert(!s_middleDown);
            prepare(blocked);
            s_enabled = false;
            assert(!send_event(kCGEventOtherMouseDown, true, 2, start));
            prepare(blocked);
            [s_tpDevices removeAllObjects];
            assert(!send_event(kCGEventOtherMouseDown, true, 2, start));
        }
        puts("block-middle regression tests: ok");
    }
}
