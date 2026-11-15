/* Pure protocol/state checks: fail if any path tries to post input. */
#import <Cocoa/Cocoa.h>
#import <ApplicationServices/ApplicationServices.h>
static void unexpected_post(CGEventTapLocation tap, CGEventRef event) {
    (void)tap; (void)event;
    assert(!"core tests must not post input");
}
#define CGEventPost unexpected_post
#define main daemon_main
#import "../trackpointd.m"
#undef main
#undef CGEventPost

int main(void) {
    @autoreleasepool {
        TPReportSpec spec;
        uint8_t bytes[8];
        CFIndex length;
        const uint8_t commands[] = {0x02, 0x05, 0x09};
        for (NSNumber *pid in @[@(TP_USB_PID), @(TP_BLE_PID)]) {
            for (size_t c = 0; c < sizeof(commands); c++) {
                for (int value = 0; value <= 9; value++) {
                    assert(build_config_report(pid.intValue, commands[c], value,
                                               &spec, bytes, &length));
                    assert(length == (pid.intValue == TP_USB_PID ? 8 : 3));
                    assert(spec.reportID == (pid.intValue == TP_USB_PID ? 0x13 : 0x18));
                    assert(spec.type == (pid.intValue == TP_USB_PID ?
                        kIOHIDReportTypeFeature : kIOHIDReportTypeOutput));
                    assert(bytes[0] == spec.reportID && bytes[1] == commands[c] && bytes[2] == value);
                    for (int i = 3; i < 8; i++) assert(bytes[i] == 0);
                }
            }
        }
        uint8_t report[] = {0x16, 0x80, 0x7f};
        int8_t x, y;
        assert(decode_wheel_report(0x16, report, 3, &x, &y) && x == -128 && y == 127);
        for (int len = 0; len <= 8; len++)
            if (len != 3) assert(!decode_wheel_report(0x16, report, len, &x, &y));
        assert(!decode_wheel_report(0x16, NULL, 3, &x, &y));
        assert(input_payload_offset(256, report, 3, 3) == -1);
        report[0] = 0x15;
        assert(!decode_wheel_report(0x16, report, 3, &x, &y));
        uint8_t middle[] = {0x15,0,4,0,0,0,0,0,0};
        bool down;
        assert(!decode_middle_report(0x16, middle, 9, &down));
        assert(!decode_middle_report(0x15, NULL, 9, &down));
        uint16_t usage;
        assert(!decode_hotkey_report(TP_USB_PID, 0x06, middle, 2, &usage));
        assert(!decode_hotkey_report(TP_BLE_PID, 0x05, NULL, 3, &usage));

        assert(validated_http_url(@"https://example.com/path?q=1"));
        assert(validated_http_url(@"http://example.com"));
        for (NSString *url in @[@"", @"example.com", @"https:///", @"file:///tmp/a", @"javascript:alert(1)"])
            assert(!validated_http_url(url));
        assert(!validated_http_url(nil));
        s_sensitivity = 5; assert(sensitivity_factor() == 1.0);
        s_sensitivity = 1; double slow = sensitivity_factor();
        s_sensitivity = 9; double fast = sensitivity_factor();
        assert(slow > 0 && slow < 1 && fast > 1);
        assert(fabs(slow * fast - 1) < 1e-9);
        assert(scaled_scroll_delta(0, 8) == 0);
        assert(scaled_scroll_delta(5, 2) == 10);
        assert(scaled_scroll_delta(-5, 2) == -10);
        assert(elapsed_ns(1, 0) == UINT64_MAX);
        assert(elapsed_ns(1, 2) == UINT64_MAX);

        TPHIDDevice *ctx = [TPHIDDevice new];
        s_tpDevices = [NSMutableArray arrayWithObject:ctx];
        ctx->inputConfirmed = true;
        ctx->lastPointerTime = mach_absolute_time();
        ctx->lastMiddleButtonTime = ctx->lastNativeScrollTime = ctx->lastNativeMiddleTime = ctx->lastPointerTime;
        ctx->rawMiddleDown = ctx->nativeMiddleDown = ctx->nativeScrolled = true;
        ctx->bleVerticalPending = true;
        ctx->lastHotkey = 0xB8;
        s_middleDown = s_hasMoved = true;
        s_scrollAccumX = 10; s_scrollAccumY = -20;
        reset_gesture_state();
        assert(!s_middleDown && !s_hasMoved && s_scrollAccumX == 0 && s_scrollAccumY == 0);
        assert(!ctx->rawMiddleDown && !ctx->nativeMiddleDown && !ctx->nativeScrolled);
        [ctx resetAfterWake];
        assert(!ctx->inputConfirmed && !ctx->lastPointerTime && !ctx->lastMiddleButtonTime);
        assert(!ctx->lastNativeScrollTime && !ctx->lastNativeMiddleTime && !ctx->lastHotkey);
        assert(!ctx->bleVerticalPending);
        TPOrigin origin = poll_trackpoint_origin();
        assert(!origin.fromTrackPoint && !origin.middleButtonDownRecent && !origin.nativeMiddleManaged);
        puts("core protocol/state tests: ok");
    }
}
