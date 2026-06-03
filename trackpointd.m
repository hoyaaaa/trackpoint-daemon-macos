/*
 * trackpointd.m — ThinkPad TrackPoint macOS menu bar app
 *
 * Key remap: hidutil (kernel level) — Left Opt <-> Left Cmd swap
 *            CGEventTap (HID level) — Right Option -> F18
 * Scroll:    CGEventTap (mouse tap only)
 * Sensitivity: CGEventTap delta scaling (HID level, BLE-compatible)
 * Detection: IOHIDManager (ThinkPad BLE connect/disconnect)
 *
 * Compile:
 *   clang -O2 -fobjc-arc -o trackpointd trackpointd.m \
 *     -framework Cocoa -framework ApplicationServices -framework IOKit -lm
 */

#import <Cocoa/Cocoa.h>
#import <ApplicationServices/ApplicationServices.h>
#import <IOKit/hid/IOHIDManager.h>
#import <IOKit/hidsystem/IOHIDLib.h>
#import <IOKit/hidsystem/IOHIDParameter.h>
#import <math.h>

/* ── Config ───────────────────────────────────────────────────── */
#define TP_SENSITIVITY_DEFAULT  5   /* 1-9 scale, 5 = neutral */
#define SCROLL_SPEED            3.5
#define SCROLL_THRESHOLD        0.8
#define LENOVO_VID              0x17EF
/* ─────────────────────────────────────────────────────────────── */

#define HID_LEFT_OPTION   "0x7000000E2"
#define HID_LEFT_CMD      "0x7000000E3"

#define PREF_SENSITIVITY  @"tpSensitivity"
#define PREF_F18          @"tpF18Enabled"
#define PREF_SWAP         @"tpSwapEnabled"

#define LOG(fmt, ...) fprintf(stderr, "[tp] " fmt "\n", ##__VA_ARGS__)

static CFMachPortRef     s_tap        = NULL;   /* middle-btn scroll */
static CFMachPortRef     s_kbd_tap    = NULL;   /* Right Opt -> F18  */
static CFMachPortRef     s_scale_tap  = NULL;   /* delta scaling     */
static CFRunLoopTimerRef s_retryTimer = NULL;
static int               s_tpCount    = 0;
static bool              s_middleDown = false;
static bool              s_hasMoved   = false;
static CGPoint           s_lastPos    = {0, 0};

static bool    s_f18Enabled  = false;
static bool    s_swapEnabled = false;
static int     s_sensitivity = TP_SENSITIVITY_DEFAULT;  /* 1-9 */

/* sensitivity 1-9 -> scale factor via exponential curve
   1 -> ~0.37x, 5 -> 1.0x, 9 -> ~2.72x */
static double sensitivity_factor(void) {
    return exp((s_sensitivity - 5) * 0.25);
}

static void try_create_event_tap(void);
static void disable_acceleration(void);
static void setup_hid(void);
static void apply_key_remap(void);

/* ══════════════════════════════════════════════════════════════
   Settings Window
   ══════════════════════════════════════════════════════════════ */
@interface SettingsWindowController : NSWindowController
@property (strong) NSTextField *keyboardStatus;
@property (strong) NSTextField *accessStatus;
@property (strong) NSButton    *f18Check;
@property (strong) NSButton    *swapCheck;
@property (strong) NSSlider    *slider;
@property (strong) NSTextField *valueLabel;
@property (strong) NSButton    *grantBtn;
- (void)syncState;
@end

static SettingsWindowController *g_settings = nil;

@implementation SettingsWindowController

- (instancetype)init {
    NSWindow *win = [[NSWindow alloc]
        initWithContentRect:NSMakeRect(0, 0, 360, 300)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
        backing:NSBackingStoreBuffered
        defer:NO];
    win.title = @"TrackPoint Settings";
    win.releasedWhenClosed = NO;
    self = [super initWithWindow:win];
    if (!self) return nil;
    [self buildUI];
    return self;
}

- (void)buildUI {
    NSView *cv = self.window.contentView;
    CGFloat W = 360, pad = 20;
    CGFloat y = 260;

    /* ── Status ── */
    NSTextField *sh = [NSTextField labelWithString:@"Status"];
    sh.font = [NSFont boldSystemFontOfSize:12];
    sh.frame = NSMakeRect(pad, y, W - pad*2, 18);
    [cv addSubview:sh];
    y -= 22;

    self.keyboardStatus = [NSTextField labelWithString:@""];
    self.keyboardStatus.font = [NSFont systemFontOfSize:12];
    self.keyboardStatus.frame = NSMakeRect(pad + 8, y, W - pad*2 - 8, 18);
    [cv addSubview:self.keyboardStatus];
    y -= 20;

    self.accessStatus = [NSTextField labelWithString:@""];
    self.accessStatus.font = [NSFont systemFontOfSize:12];
    self.accessStatus.frame = NSMakeRect(pad + 8, y, W - pad*2 - 8, 18);
    [cv addSubview:self.accessStatus];
    y -= 26;

    self.grantBtn = [NSButton buttonWithTitle:@"Grant Accessibility Permission..."
                     target:self action:@selector(openAccessibility:)];
    self.grantBtn.bezelStyle = NSBezelStyleInline;
    self.grantBtn.frame = NSMakeRect(pad + 8, y, 240, 22);
    [cv addSubview:self.grantBtn];
    y -= 20;

    /* ── Separator ── */
    NSBox *sep1 = [[NSBox alloc] initWithFrame:NSMakeRect(pad, y, W - pad*2, 1)];
    sep1.boxType = NSBoxSeparator;
    [cv addSubview:sep1];
    y -= 18;

    /* ── Key Remapping ── */
    NSTextField *rh = [NSTextField labelWithString:@"Key Remapping"];
    rh.font = [NSFont boldSystemFontOfSize:12];
    rh.frame = NSMakeRect(pad, y, W - pad*2, 18);
    [cv addSubview:rh];
    y -= 26;

    self.f18Check = [NSButton checkboxWithTitle:@"Right Option → F18"
                     target:self action:@selector(toggleF18:)];
    self.f18Check.frame = NSMakeRect(pad + 8, y, W - pad*2 - 8, 20);
    [cv addSubview:self.f18Check];
    y -= 24;

    self.swapCheck = [NSButton checkboxWithTitle:@"Left Opt ↔ Left Cmd Swap"
                      target:self action:@selector(toggleSwap:)];
    self.swapCheck.frame = NSMakeRect(pad + 8, y, W - pad*2 - 8, 20);
    [cv addSubview:self.swapCheck];
    y -= 16;

    /* ── Separator ── */
    NSBox *sep2 = [[NSBox alloc] initWithFrame:NSMakeRect(pad, y, W - pad*2, 1)];
    sep2.boxType = NSBoxSeparator;
    [cv addSubview:sep2];
    y -= 18;

    /* ── Sensitivity ── */
    NSTextField *sensh = [NSTextField labelWithString:@"Pointer Sensitivity"];
    sensh.font = [NSFont boldSystemFontOfSize:12];
    sensh.frame = NSMakeRect(pad, y, W - pad*2, 18);
    [cv addSubview:sensh];
    y -= 28;

    NSTextField *minLbl = [NSTextField labelWithString:@"Slow"];
    minLbl.font = [NSFont systemFontOfSize:10];
    minLbl.textColor = [NSColor secondaryLabelColor];
    minLbl.frame = NSMakeRect(pad, y + 3, 30, 16);
    [cv addSubview:minLbl];

    NSTextField *maxLbl = [NSTextField labelWithString:@"Fast"];
    maxLbl.font = [NSFont systemFontOfSize:10];
    maxLbl.textColor = [NSColor secondaryLabelColor];
    maxLbl.alignment = NSTextAlignmentRight;
    maxLbl.frame = NSMakeRect(W - pad - 30, y + 3, 30, 16);
    [cv addSubview:maxLbl];

    self.slider = [[NSSlider alloc] initWithFrame:NSMakeRect(pad + 34, y, W - pad*2 - 68, 22)];
    self.slider.minValue = 1;
    self.slider.maxValue = 9;
    self.slider.numberOfTickMarks = 9;
    self.slider.allowsTickMarkValuesOnly = YES;
    self.slider.integerValue = s_sensitivity;
    self.slider.continuous = YES;
    self.slider.target = self;
    self.slider.action = @selector(sliderChanged:);
    [cv addSubview:self.slider];
    y -= 22;

    self.valueLabel = [NSTextField labelWithString:
        [NSString stringWithFormat:@"%d / 9", s_sensitivity]];
    self.valueLabel.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular];
    self.valueLabel.textColor = [NSColor secondaryLabelColor];
    self.valueLabel.alignment = NSTextAlignmentCenter;
    self.valueLabel.frame = NSMakeRect(0, y, W, 16);
    [cv addSubview:self.valueLabel];

    [self syncState];
}

- (void)syncState {
    BOOL accessible = AXIsProcessTrusted();
    BOOL connected  = s_tpCount > 0;

    self.keyboardStatus.stringValue = connected  ? @"Keyboard: Connected"       : @"Keyboard: Disconnected";
    self.keyboardStatus.textColor   = connected  ? [NSColor systemGreenColor]   : [NSColor secondaryLabelColor];

    self.accessStatus.stringValue   = accessible ? @"Accessibility: Granted"    : @"Accessibility: Not Granted";
    self.accessStatus.textColor     = accessible ? [NSColor systemGreenColor]   : [NSColor systemOrangeColor];

    self.grantBtn.hidden   = accessible;
    self.swapCheck.enabled = connected;

    self.f18Check.state  = s_f18Enabled  ? NSControlStateValueOn : NSControlStateValueOff;
    self.swapCheck.state = s_swapEnabled ? NSControlStateValueOn : NSControlStateValueOff;

    self.slider.integerValue = s_sensitivity;
    self.valueLabel.stringValue = [NSString stringWithFormat:@"%d / 9", s_sensitivity];
}

- (void)sliderChanged:(NSSlider *)slider {
    int val = (int)slider.integerValue;
    s_sensitivity = val;
    self.valueLabel.stringValue = [NSString stringWithFormat:@"%d / 9", val];
    [[NSUserDefaults standardUserDefaults] setInteger:val forKey:PREF_SENSITIVITY];
    LOG("sensitivity -> %d (factor %.2fx)", val, sensitivity_factor());
}

- (void)toggleF18:(NSButton *)btn {
    s_f18Enabled = (btn.state == NSControlStateValueOn);
    [[NSUserDefaults standardUserDefaults] setBool:s_f18Enabled forKey:PREF_F18];
    LOG("F18 remap: %s", s_f18Enabled ? "ON" : "OFF");
}

- (void)toggleSwap:(NSButton *)btn {
    s_swapEnabled = (btn.state == NSControlStateValueOn);
    [[NSUserDefaults standardUserDefaults] setBool:s_swapEnabled forKey:PREF_SWAP];
    apply_key_remap();
    LOG("Left Opt<->Cmd swap: %s", s_swapEnabled ? "ON" : "OFF");
}

- (void)openAccessibility:(id)sender {
    [[NSWorkspace sharedWorkspace] openURL:
        [NSURL URLWithString:
            @"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"]];
}

@end

/* ══════════════════════════════════════════════════════════════
   Menu bar UI
   ══════════════════════════════════════════════════════════════ */
@interface AppDelegate : NSObject <NSApplicationDelegate>
@property (strong) NSStatusItem *statusItem;
@property (strong) NSTimer      *accessTimer;
- (void)refresh;
@end

static AppDelegate *g_app = nil;

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)n {
    g_app = self;
    g_settings = [SettingsWindowController new];
    [self buildMenu];
    [self refresh];
    disable_acceleration();
    setup_hid();
    try_create_event_tap();
}

- (void)buildMenu {
    self.statusItem = [[NSStatusBar systemStatusBar]
                       statusItemWithLength:NSVariableStatusItemLength];
    self.statusItem.button.font = [NSFont monospacedSystemFontOfSize:12
                                   weight:NSFontWeightMedium];
    NSMenu *menu = [NSMenu new];

    NSMenuItem *settingsItem = [[NSMenuItem alloc]
        initWithTitle:@"Settings..."
        action:@selector(openSettings:) keyEquivalent:@","];
    settingsItem.target = self;
    [menu addItem:settingsItem];

    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *quit = [[NSMenuItem alloc] initWithTitle:@"Quit"
                        action:@selector(terminate:) keyEquivalent:@"q"];
    quit.target = NSApp;
    [menu addItem:quit];

    self.statusItem.menu = menu;
}

- (void)refresh {
    BOOL accessible = AXIsProcessTrusted();
    BOOL connected  = s_tpCount > 0;

    self.statusItem.button.title = !accessible ? @"TP!" :
                                    connected   ? @"TP+" : @"TP-";
    [g_settings syncState];

    if (!accessible && !self.accessTimer) {
        self.accessTimer = [NSTimer scheduledTimerWithTimeInterval:3.0 target:self
            selector:@selector(pollAccess:) userInfo:nil repeats:YES];
    } else if (accessible && self.accessTimer) {
        [self.accessTimer invalidate]; self.accessTimer = nil;
        try_create_event_tap();
    }
}

- (void)pollAccess:(NSTimer *)t {
    if (AXIsProcessTrusted()) {
        [t invalidate]; self.accessTimer = nil;
        [self refresh];
    }
}

- (void)openSettings:(id)sender {
    [g_settings syncState];
    [NSApp activateIgnoringOtherApps:YES];
    [g_settings showWindow:nil];
    [g_settings.window center];
    [g_settings.window makeKeyAndOrderFront:nil];
}

@end

/* ══════════════════════════════════════════════════════════════
   hidutil — kernel-level key remap
   ══════════════════════════════════════════════════════════════ */
static void apply_key_remap(void) {
    BOOL enable = (s_tpCount > 0) && s_swapEnabled;

    NSString *mapping = enable
        ? @"{\"UserKeyMapping\":["
           "{\"HIDKeyboardModifierMappingSrc\":" HID_LEFT_OPTION ",\"HIDKeyboardModifierMappingDst\":" HID_LEFT_CMD "},"
           "{\"HIDKeyboardModifierMappingSrc\":" HID_LEFT_CMD    ",\"HIDKeyboardModifierMappingDst\":" HID_LEFT_OPTION "}"
           "]}"
        : @"{\"UserKeyMapping\":[]}";

    NSTask *task = [NSTask new];
    task.launchPath = @"/usr/bin/hidutil";
    task.arguments  = @[@"property", @"--set", mapping];
    [task launch];
    [task waitUntilExit];
    LOG("hidutil Left Opt<->Left Cmd: %s", enable ? "applied" : "cleared");
}

/* ══════════════════════════════════════════════════════════════
   Disable mouse acceleration
   ══════════════════════════════════════════════════════════════ */
static void disable_acceleration(void) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    io_service_t svc = IOServiceGetMatchingService(
        kIOMasterPortDefault, IOServiceMatching(kIOHIDSystemClass));
    if (!svc) return;
    io_connect_t conn;
    if (IOServiceOpen(svc, mach_task_self(), kIOHIDParamConnectType, &conn) == KERN_SUCCESS) {
        IOHIDSetMouseAcceleration(conn, -1.0);
        IOHIDSetScrollAcceleration(conn, -1.0);
        IOServiceClose(conn);
        LOG("acceleration disabled");
    }
    IOObjectRelease(svc);
#pragma clang diagnostic pop
}

/* ══════════════════════════════════════════════════════════════
   CGEventTap 1: sensitivity delta scaling (kCGHIDEventTap)
   Only active when ThinkPad connected. Scales pointer movement
   by exp((sensitivity-5)*0.25): 1->0.37x, 5->1.0x, 9->2.72x
   ══════════════════════════════════════════════════════════════ */
static CGEventRef scale_callback(CGEventTapProxy proxy, CGEventType type,
                                  CGEventRef event, void *refcon) {
    (void)proxy; (void)refcon;
    if (!s_tpCount) return event;
    if (s_middleDown) return event;

    double factor = sensitivity_factor();
    if (fabs(factor - 1.0) < 0.01) return event;

    double dx = CGEventGetDoubleValueField(event, kCGMouseEventDeltaX);
    double dy = CGEventGetDoubleValueField(event, kCGMouseEventDeltaY);
    if (dx == 0.0 && dy == 0.0) return event;

    /* Scale the deltas */
    double newDx = dx * factor;
    double newDy = dy * factor;

    /* Shift the event's cursor position by the extra delta.
       CGEventSetLocation is what actually moves the cursor. */
    CGPoint pos = CGEventGetLocation(event);
    CGPoint newPos = { pos.x + (newDx - dx), pos.y + (newDy - dy) };

    /* Clamp to main display bounds */
    CGRect bounds = CGDisplayBounds(CGMainDisplayID());
    newPos.x = MAX(bounds.origin.x, MIN(bounds.origin.x + bounds.size.width  - 1, newPos.x));
    newPos.y = MAX(bounds.origin.y, MIN(bounds.origin.y + bounds.size.height - 1, newPos.y));

    CGEventSetLocation(event, newPos);
    CGEventSetDoubleValueField(event, kCGMouseEventDeltaX, newDx);
    CGEventSetDoubleValueField(event, kCGMouseEventDeltaY, newDy);
    return event;
}

/* ══════════════════════════════════════════════════════════════
   CGEventTap 2: Right Option -> F18 (kCGHIDEventTap)
   ══════════════════════════════════════════════════════════════ */
static CGEventRef kbd_callback(CGEventTapProxy proxy, CGEventType type,
                                CGEventRef event, void *refcon) {
    (void)proxy; (void)refcon;
    if (type != kCGEventFlagsChanged) return event;
    if (!s_f18Enabled) return event;

    int64_t kc = CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
    if (kc != 0x3D) return event;

    CGEventFlags flags = CGEventGetFlags(event);
    bool down = (flags & kCGEventFlagMaskAlternate) != 0;
    CGEventSetFlags(event, flags & ~kCGEventFlagMaskAlternate);

    CGEventRef f18 = CGEventCreateKeyboardEvent(NULL, 0x4F, down);
    CGEventPost(kCGHIDEventTap, f18);
    CFRelease(f18);
    return event;
}

/* ══════════════════════════════════════════════════════════════
   CGEventTap 3: Middle button -> scroll (kCGAnnotatedSessionEventTap)
   ══════════════════════════════════════════════════════════════ */
static CGEventRef mouse_callback(CGEventTapProxy proxy, CGEventType type,
                                  CGEventRef event, void *refcon) {
    (void)proxy; (void)refcon;
    int btn = (int)CGEventGetIntegerValueField(event, kCGMouseEventButtonNumber);

    if (type == kCGEventOtherMouseDown && btn == 2) {
        if (!s_tpCount) return event;
        s_middleDown = true; s_hasMoved = false;
        s_lastPos = CGEventGetLocation(event);
        return NULL;
    }
    if (type == kCGEventOtherMouseUp && btn == 2) {
        s_middleDown = false;
        if (!s_hasMoved) {
            CGPoint p = CGEventGetLocation(event);
            CGEventRef dn = CGEventCreateMouseEvent(NULL, kCGEventOtherMouseDown, p, kCGMouseButtonCenter);
            CGEventRef up = CGEventCreateMouseEvent(NULL, kCGEventOtherMouseUp,   p, kCGMouseButtonCenter);
            CGEventPost(kCGSessionEventTap, dn);
            CGEventPost(kCGSessionEventTap, up);
            CFRelease(dn); CFRelease(up);
        }
        return NULL;
    }
    if (s_middleDown && (type == kCGEventMouseMoved || type == kCGEventOtherMouseDragged)) {
        CGPoint p = CGEventGetLocation(event);
        double dx = p.x - s_lastPos.x, dy = p.y - s_lastPos.y;
        s_lastPos = p;
        if (fabs(dx) > SCROLL_THRESHOLD || fabs(dy) > SCROLL_THRESHOLD) {
            s_hasMoved = true;
            CGEventRef sc = CGEventCreateScrollWheelEvent(NULL, kCGScrollEventUnitPixel, 2,
                -(int32_t)round(dy * SCROLL_SPEED), -(int32_t)round(dx * SCROLL_SPEED));
            CGEventPost(kCGSessionEventTap, sc);
            CFRelease(sc);
        }
        return NULL;
    }
    return event;
}

static void set_tap_enabled(bool enabled) {
    if (s_tap) CGEventTapEnable(s_tap, true);
    LOG("ThinkPad %s — scroll %s", enabled ? "connected" : "disconnected", enabled ? "ON" : "OFF");
    apply_key_remap();
    dispatch_async(dispatch_get_main_queue(), ^{ [g_app refresh]; });
}

static void tap_retry(CFRunLoopTimerRef timer, void *info) {
    (void)info;
    if (s_tap) { CFRunLoopTimerInvalidate(timer); s_retryTimer = NULL; return; }
    try_create_event_tap();
}

static void try_create_event_tap(void) {
    /* ── Scale tap: kCGHIDEventTap (mouse delta scaling) ── */
    if (!s_scale_tap) {
        CGEventMask scaleMask = CGEventMaskBit(kCGEventMouseMoved) |
                                CGEventMaskBit(kCGEventOtherMouseDragged);
        s_scale_tap = CGEventTapCreate(kCGHIDEventTap, kCGHeadInsertEventTap,
                                        kCGEventTapOptionDefault,
                                        scaleMask, scale_callback, NULL);
        if (s_scale_tap) {
            CFRunLoopSourceRef src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, s_scale_tap, 0);
            CFRunLoopAddSource(CFRunLoopGetMain(), src, kCFRunLoopCommonModes);
            CGEventTapEnable(s_scale_tap, true);
            LOG("scale tap ON");
        } else {
            LOG("scale tap failed — accessibility permission required");
        }
    }

    /* ── Keyboard tap: kCGHIDEventTap (Right Option -> F18) ── */
    if (!s_kbd_tap) {
        s_kbd_tap = CGEventTapCreate(kCGHIDEventTap, kCGHeadInsertEventTap,
                                      kCGEventTapOptionDefault,
                                      CGEventMaskBit(kCGEventFlagsChanged),
                                      kbd_callback, NULL);
        if (s_kbd_tap) {
            CFRunLoopSourceRef src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, s_kbd_tap, 0);
            CFRunLoopAddSource(CFRunLoopGetMain(), src, kCFRunLoopCommonModes);
            CGEventTapEnable(s_kbd_tap, true);
            LOG("keyboard tap ON");
        } else {
            LOG("keyboard tap failed — accessibility permission required");
        }
    }

    /* ── Mouse tap: kCGAnnotatedSessionEventTap (middle btn scroll) ── */
    if (s_tap) return;
    CGEventMask mask =
        CGEventMaskBit(kCGEventOtherMouseDown)    |
        CGEventMaskBit(kCGEventOtherMouseUp)      |
        CGEventMaskBit(kCGEventMouseMoved)        |
        CGEventMaskBit(kCGEventOtherMouseDragged);

    s_tap = CGEventTapCreate(kCGAnnotatedSessionEventTap, kCGHeadInsertEventTap,
                              kCGEventTapOptionDefault, mask, mouse_callback, NULL);
    if (!s_tap) {
        LOG("mouse tap failed — accessibility permission required");
        if (!s_retryTimer) {
            CFRunLoopTimerContext ctx = {0};
            s_retryTimer = CFRunLoopTimerCreate(kCFAllocatorDefault,
                CFAbsoluteTimeGetCurrent() + 5.0, 5.0, 0, 0, tap_retry, &ctx);
            CFRunLoopAddTimer(CFRunLoopGetMain(), s_retryTimer, kCFRunLoopDefaultMode);
        }
        return;
    }
    if (s_retryTimer) { CFRunLoopTimerInvalidate(s_retryTimer); s_retryTimer = NULL; }
    CFRunLoopSourceRef src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, s_tap, 0);
    CFRunLoopAddSource(CFRunLoopGetMain(), src, kCFRunLoopCommonModes);
    CGEventTapEnable(s_tap, true);
    LOG("mouse tap ON");
    dispatch_async(dispatch_get_main_queue(), ^{ [g_app refresh]; });
}

/* ══════════════════════════════════════════════════════════════
   IOHIDManager — ThinkPad connection detection
   ══════════════════════════════════════════════════════════════ */
static void hid_added(void *ctx, IOReturn r, void *sender, IOHIDDeviceRef dev) {
    (void)ctx; (void)r; (void)sender; (void)dev;
    IOHIDDeviceOpen(dev, kIOHIDOptionsTypeNone);
    s_tpCount++;
    set_tap_enabled(true);
}

static void hid_removed(void *ctx, IOReturn r, void *sender, IOHIDDeviceRef dev) {
    (void)ctx; (void)r; (void)sender; (void)dev;
    if (--s_tpCount <= 0) { s_tpCount = 0; s_middleDown = false; set_tap_enabled(false); }
    dispatch_async(dispatch_get_main_queue(), ^{ [g_app refresh]; });
}

static void setup_hid(void) {
    IOHIDManagerRef mgr = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
    int vid = LENOVO_VID;
    CFNumberRef vidNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &vid);
    CFMutableDictionaryRef match = CFDictionaryCreateMutable(kCFAllocatorDefault, 1,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(match, CFSTR(kIOHIDVendorIDKey), vidNum);
    CFRelease(vidNum);
    IOHIDManagerSetDeviceMatching(mgr, match); CFRelease(match);
    IOHIDManagerRegisterDeviceMatchingCallback(mgr, hid_added, NULL);
    IOHIDManagerRegisterDeviceRemovalCallback(mgr, hid_removed, NULL);
    IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
    IOHIDManagerOpen(mgr, kIOHIDOptionsTypeNone);
    LOG("HID manager active");
}

/* ══════════════════════════════════════════════════════════════
   main
   ══════════════════════════════════════════════════════════════ */
int main(int argc, const char *argv[]) {
    freopen("/tmp/trackpointd.log", "a", stderr);
    setvbuf(stderr, NULL, _IONBF, 0);

    @autoreleasepool {
        NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
        if ([ud objectForKey:PREF_SENSITIVITY])
            s_sensitivity = (int)MAX(1, MIN(9, [ud integerForKey:PREF_SENSITIVITY]));
        if ([ud objectForKey:PREF_F18])
            s_f18Enabled  = [ud boolForKey:PREF_F18];
        if ([ud objectForKey:PREF_SWAP])
            s_swapEnabled = [ud boolForKey:PREF_SWAP];

        LOG("prefs: sensitivity=%d (%.2fx) f18=%s swap=%s",
            s_sensitivity, sensitivity_factor(),
            s_f18Enabled ? "on" : "off", s_swapEnabled ? "on" : "off");

        NSApplication *app = [NSApplication sharedApplication];
        app.activationPolicy = NSApplicationActivationPolicyAccessory;
        AppDelegate *delegate = [AppDelegate new];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
