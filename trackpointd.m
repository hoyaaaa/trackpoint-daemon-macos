/*
 * trackpointd.m — ThinkPad TrackPoint macOS menu bar app
 *
 * Key remap: hidutil (kernel level) — Left Opt <-> Left Cmd swap
 * Unified CGEventTap at kCGHIDEventTap:
 *   - Right Option → F18
 *   - Middle button → scroll (with accumulator + threshold)
 *   - Pointer sensitivity delta scaling (BLE-compatible)
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
#define PREF_SCROLL_SPEED @"tpScrollSpeed"

#define LOG(fmt, ...) fprintf(stderr, "[tp] " fmt "\n", ##__VA_ARGS__)

static CFMachPortRef     s_tap        = NULL;   /* unified event tap */
static int               s_tpCount    = 0;
static bool              s_middleDown = false;
static bool              s_hasMoved   = false;
static CGPoint           s_lastPos    = {0, 0};

static bool    s_f18Enabled  = false;
static bool    s_swapEnabled = false;
static int     s_sensitivity = TP_SENSITIVITY_DEFAULT;  /* 1-9 */
static double  s_scrollSpeed = SCROLL_SPEED;
static bool    s_naturalScroll = false;
static double  s_scrollAccumX = 0.0;
static double  s_scrollAccumY = 0.0;
static CGRect  s_displayBounds;

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
@property (strong) NSSlider    *scrollSlider;
@property (strong) NSTextField *scrollValueLabel;
@property (strong) NSButton    *grantBtn;
- (void)syncState;
@end

static SettingsWindowController *g_settings = nil;

@implementation SettingsWindowController

- (instancetype)init {
    NSWindow *win = [[NSWindow alloc]
        initWithContentRect:NSMakeRect(0, 0, 360, 390)
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
    CGFloat y = 350;

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
    y -= 16;

    /* ── Separator ── */
    NSBox *sep3 = [[NSBox alloc] initWithFrame:NSMakeRect(pad, y, W - pad*2, 1)];
    sep3.boxType = NSBoxSeparator;
    [cv addSubview:sep3];
    y -= 18;

    /* ── Scroll Speed ── */
    NSTextField *scrollH = [NSTextField labelWithString:@"Scroll Speed"];
    scrollH.font = [NSFont boldSystemFontOfSize:12];
    scrollH.frame = NSMakeRect(pad, y, W - pad*2, 18);
    [cv addSubview:scrollH];
    y -= 28;

    NSTextField *sMinLbl = [NSTextField labelWithString:@"Slow"];
    sMinLbl.font = [NSFont systemFontOfSize:10];
    sMinLbl.textColor = [NSColor secondaryLabelColor];
    sMinLbl.frame = NSMakeRect(pad, y + 3, 30, 16);
    [cv addSubview:sMinLbl];

    NSTextField *sMaxLbl = [NSTextField labelWithString:@"Fast"];
    sMaxLbl.font = [NSFont systemFontOfSize:10];
    sMaxLbl.textColor = [NSColor secondaryLabelColor];
    sMaxLbl.alignment = NSTextAlignmentRight;
    sMaxLbl.frame = NSMakeRect(W - pad - 30, y + 3, 30, 16);
    [cv addSubview:sMaxLbl];

    self.scrollSlider = [[NSSlider alloc] initWithFrame:NSMakeRect(pad + 34, y, W - pad*2 - 68, 22)];
    self.scrollSlider.minValue = 1.0;
    self.scrollSlider.maxValue = 8.0;
    self.scrollSlider.doubleValue = s_scrollSpeed;
    self.scrollSlider.continuous = YES;
    self.scrollSlider.target = self;
    self.scrollSlider.action = @selector(scrollSliderChanged:);
    [cv addSubview:self.scrollSlider];
    y -= 22;

    self.scrollValueLabel = [NSTextField labelWithString:
        [NSString stringWithFormat:@"%.1f", s_scrollSpeed]];
    self.scrollValueLabel.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular];
    self.scrollValueLabel.textColor = [NSColor secondaryLabelColor];
    self.scrollValueLabel.alignment = NSTextAlignmentCenter;
    self.scrollValueLabel.frame = NSMakeRect(0, y, W, 16);
    [cv addSubview:self.scrollValueLabel];

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

    self.scrollSlider.doubleValue = s_scrollSpeed;
    self.scrollValueLabel.stringValue = [NSString stringWithFormat:@"%.1f", s_scrollSpeed];
}

- (void)sliderChanged:(NSSlider *)slider {
    int val = (int)slider.integerValue;
    s_sensitivity = val;
    self.valueLabel.stringValue = [NSString stringWithFormat:@"%d / 9", val];
    [[NSUserDefaults standardUserDefaults] setInteger:val forKey:PREF_SENSITIVITY];
    LOG("sensitivity -> %d (factor %.2fx)", val, sensitivity_factor());
}

- (void)scrollSliderChanged:(NSSlider *)slider {
    double val = slider.doubleValue;
    s_scrollSpeed = val;
    self.scrollValueLabel.stringValue = [NSString stringWithFormat:@"%.1f", val];
    [[NSUserDefaults standardUserDefaults] setDouble:val forKey:PREF_SCROLL_SPEED];
    LOG("scroll speed -> %.1f", val);
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
    s_displayBounds = CGDisplayBounds(CGMainDisplayID());
    /* key absent = macOS default = natural scroll ON */
    NSNumber *scrollPref = [[NSUserDefaults standardUserDefaults]
        objectForKey:@"com.apple.swipescrolldirection"];
    s_naturalScroll = (scrollPref == nil) ? true : [scrollPref boolValue];
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
        try_create_event_tap();  /* tap 직접 생성 — refresh 경유 시 timer=nil로 조건 미충족 */
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
   Unified CGEventTap at kCGHIDEventTap
   Handles: Right Option→F18, middle-button scroll, sensitivity scaling
   ══════════════════════════════════════════════════════════════ */
static CGEventRef unified_callback(CGEventTapProxy proxy, CGEventType type,
                                    CGEventRef event, void *refcon) {
    (void)proxy; (void)refcon;

    /* Re-enable if disabled by system */
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        LOG("tap re-enabled (disabled by %s)",
            type == kCGEventTapDisabledByTimeout ? "timeout" : "user");
        if (s_tap) CGEventTapEnable(s_tap, true);
        return event;
    }

    /* ── Right Option → F18 ────────────────────────────────── */
    if (type == kCGEventFlagsChanged && s_f18Enabled) {
        int64_t kc = CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
        if (kc == 0x3D) {  /* Right Option */
            CGEventFlags flags = CGEventGetFlags(event);
            bool down = (flags & kCGEventFlagMaskAlternate) != 0;
            CGEventSetFlags(event, flags & ~kCGEventFlagMaskAlternate);
            CGEventRef f18 = CGEventCreateKeyboardEvent(NULL, 0x4F, down);
            CGEventPost(kCGHIDEventTap, f18);
            CFRelease(f18);
            return NULL;
        }
    }

    /* ── Middle button: down ───────────────────────────────── */
    if (type == kCGEventOtherMouseDown) {
        int btn = (int)CGEventGetIntegerValueField(event, kCGMouseEventButtonNumber);
        if (btn == 2 && s_tpCount > 0) {
            LOG("middle DOWN");
            s_middleDown = true;
            s_hasMoved = false;
            s_lastPos = CGEventGetLocation(event);
            s_scrollAccumX = 0.0; s_scrollAccumY = 0.0;
            return NULL;
        }
    }

    /* ── Middle button: up ─────────────────────────────────── */
    if (type == kCGEventOtherMouseUp) {
        int btn = (int)CGEventGetIntegerValueField(event, kCGMouseEventButtonNumber);
        if (btn == 2) {
            LOG("middle UP (moved=%s)", s_hasMoved ? "yes" : "no");
            s_middleDown = false;
            s_scrollAccumX = 0.0; s_scrollAccumY = 0.0;
            if (!s_hasMoved) {
                /* Tap = click: re-inject middle click */
                CGPoint p = CGEventGetLocation(event);
                CGEventRef dn = CGEventCreateMouseEvent(NULL, kCGEventOtherMouseDown, p, kCGMouseButtonCenter);
                CGEventRef up = CGEventCreateMouseEvent(NULL, kCGEventOtherMouseUp,   p, kCGMouseButtonCenter);
                CGEventPost(kCGHIDEventTap, dn);
                CGEventPost(kCGHIDEventTap, up);
                CFRelease(dn); CFRelease(up);
            }
            return NULL;
        }
    }

    /* ── Mouse move / drag ─────────────────────────────────── */
    if (type == kCGEventMouseMoved || type == kCGEventOtherMouseDragged) {
        if (s_middleDown) {
            /* Scroll mode */
            CGPoint p = CGEventGetLocation(event);
            double dx = p.x - s_lastPos.x, dy = p.y - s_lastPos.y;
            LOG("scroll move dx=%.1f dy=%.1f accum=(%.1f,%.1f)", dx, dy, s_scrollAccumX+dx, s_scrollAccumY+dy);
            s_lastPos = p;
            s_scrollAccumX += dx;
            s_scrollAccumY += dy;
            double adx = fabs(s_scrollAccumX), ady = fabs(s_scrollAccumY);
            if (adx > SCROLL_THRESHOLD || ady > SCROLL_THRESHOLD) {
                s_hasMoved = true;
                double vx = copysign(pow(adx, 1.4) * s_scrollSpeed, s_scrollAccumX);
                double vy = copysign(pow(ady, 1.4) * s_scrollSpeed, s_scrollAccumY);
                int sign = s_naturalScroll ? -1 : 1;
                CGEventRef sc = CGEventCreateScrollWheelEvent(NULL, kCGScrollEventUnitPixel, 2,
                    (int32_t)round(vy * sign),
                    (int32_t)round(vx * sign));
                LOG("scroll fired dy=%d dx=%d", (int32_t)round(vy*sign), (int32_t)round(vx*sign));
                CGEventPost(kCGHIDEventTap, sc);
                CFRelease(sc);
                s_scrollAccumX = 0.0; s_scrollAccumY = 0.0;
            }
            return NULL;  /* consume move event during scroll */
        } else {
            /* Sensitivity + acceleration scaling */
            if (!s_tpCount) return event;
            double dx = CGEventGetDoubleValueField(event, kCGMouseEventDeltaX);
            double dy = CGEventGetDoubleValueField(event, kCGMouseEventDeltaY);
            if (dx == 0.0 && dy == 0.0) return event;
            /* Windows-like sigmoid acceleration: 1.0x at rest, ~2.5x at high speed */
            double speed = sqrt(dx * dx + dy * dy);
            double accel = 1.0 + 1.5 * (1.0 - exp(-speed / 3.0));
            double factor = sensitivity_factor() * accel;
            double newDx = dx * factor;
            double newDy = dy * factor;
            CGPoint pos = CGEventGetLocation(event);
            CGPoint newPos = { pos.x + (newDx - dx), pos.y + (newDy - dy) };
            CGRect bounds = s_displayBounds;
            newPos.x = MAX(bounds.origin.x, MIN(bounds.origin.x + bounds.size.width  - 1, newPos.x));
            newPos.y = MAX(bounds.origin.y, MIN(bounds.origin.y + bounds.size.height - 1, newPos.y));
            CGEventSetLocation(event, newPos);
            CGEventSetDoubleValueField(event, kCGMouseEventDeltaX, newDx);
            CGEventSetDoubleValueField(event, kCGMouseEventDeltaY, newDy);
            return event;
        }
    }

    return event;
}

static void set_tap_enabled(bool enabled) {
    if (s_tap) CGEventTapEnable(s_tap, enabled);
    LOG("ThinkPad %s — tap %s", enabled ? "connected" : "disconnected", enabled ? "ON" : "OFF");
    apply_key_remap();
    dispatch_async(dispatch_get_main_queue(), ^{ [g_app refresh]; });
}

static void try_create_event_tap(void) {
    if (s_tap) return;

    CGEventMask mask =
        CGEventMaskBit(kCGEventFlagsChanged)      |
        CGEventMaskBit(kCGEventOtherMouseDown)    |
        CGEventMaskBit(kCGEventOtherMouseUp)      |
        CGEventMaskBit(kCGEventMouseMoved)        |
        CGEventMaskBit(kCGEventOtherMouseDragged);

    s_tap = CGEventTapCreate(kCGHIDEventTap, kCGHeadInsertEventTap,
                              kCGEventTapOptionDefault, mask,
                              unified_callback, NULL);
    if (!s_tap) {
        LOG("unified tap failed — accessibility permission required");
        return;
    }
    CFRunLoopSourceRef src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, s_tap, 0);
    CFRunLoopAddSource(CFRunLoopGetMain(), src, kCFRunLoopCommonModes);
    CGEventTapEnable(s_tap, true);
    LOG("unified tap ON (kCGHIDEventTap)");
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
    if (--s_tpCount <= 0) {
        s_tpCount = 0; s_middleDown = false;
        set_tap_enabled(false);
        /* restore default mouse acceleration */
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        io_service_t svc = IOServiceGetMatchingService(
            kIOMasterPortDefault, IOServiceMatching(kIOHIDSystemClass));
        if (svc) {
            io_connect_t conn;
            if (IOServiceOpen(svc, mach_task_self(), kIOHIDParamConnectType, &conn) == KERN_SUCCESS) {
                IOHIDSetMouseAcceleration(conn, 0.6875);  /* macOS default */
                IOServiceClose(conn);
            }
            IOObjectRelease(svc);
        }
#pragma clang diagnostic pop
        LOG("acceleration restored to default");
    }
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
        if ([ud objectForKey:PREF_SCROLL_SPEED])
            s_scrollSpeed = MAX(1.0, MIN(8.0, [ud doubleForKey:PREF_SCROLL_SPEED]));

        LOG("prefs: sensitivity=%d (%.2fx) scrollSpeed=%.1f f18=%s swap=%s",
            s_sensitivity, sensitivity_factor(), s_scrollSpeed,
            s_f18Enabled ? "on" : "off", s_swapEnabled ? "on" : "off");

        NSApplication *app = [NSApplication sharedApplication];
        app.activationPolicy = NSApplicationActivationPolicyAccessory;
        AppDelegate *delegate = [AppDelegate new];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
