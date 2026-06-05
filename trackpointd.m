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
#import <mach/mach_time.h>

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
#define PREF_PTS          @"tpPtsEnabled"

/* Press-to-select thresholds */
#define PTS_MAX_DURATION  0.25  /* max tap duration (seconds) */
#define PTS_MAX_DIST      20.0  /* max accumulated displacement (pixels) */
#define PTS_STOP_DELAY    0.06  /* idle time after last move = stick stopped */

#define LOG(fmt, ...) fprintf(stderr, "[tp] " fmt "\n", ##__VA_ARGS__)

static CFMachPortRef     s_tap        = NULL;   /* unified event tap */
static int               s_tpCount    = 0;
static bool              s_middleDown = false;
static bool              s_hasMoved   = false;
static CGPoint           s_lastPos    = {0, 0};
static CFMutableArrayRef s_tp_devices = NULL;  /* retained ThinkPad device refs for queue retry */

static bool    s_f18Enabled  = false;
static bool    s_swapEnabled = false;
static int     s_sensitivity = TP_SENSITIVITY_DEFAULT;  /* 1-9 */
static double  s_scrollSpeed = SCROLL_SPEED;
static bool    s_naturalScroll = false;
static double  s_scrollAccumX = 0.0;
static double  s_scrollAccumY = 0.0;
static CGRect  s_displayBounds;

/* Per-device filtering via IOHIDQueue polling */
static IOHIDQueueRef s_tp_queue = NULL;     /* X/Y element queue for ThinkPad pointing device */
static bool          s_tp_queue_ok = false; /* queue confirmed working (got at least one value) */
static uint64_t      s_last_tp_time = 0;   /* mach_absolute_time of last fresh ThinkPad HID value */
static NSTimer      *s_imTimer = nil;       /* Input Monitoring permission poll timer */

/* If a fresh ThinkPad HID value was seen within this window, treat event as ThinkPad.
 * Bridges the gap when queue is drained on event N and event N+1 arrives before next HID report. */
#define TP_RECENCY_NS  50000000ULL   /* 50ms */

/* Press-to-select state */
static bool              s_ptsEnabled    = false;
static bool              s_pts_tracking  = false;  /* active tap session */
static bool              s_pts_inhibit   = false;  /* gesture too large — wait for stick stop */
static double            s_pts_totalDist = 0;
static CFAbsoluteTime    s_pts_startTime = 0;
static CGPoint           s_pts_pos       = {0, 0};
static CFRunLoopTimerRef s_pts_timer     = NULL;

/* sensitivity 1-9 -> scale factor via exponential curve
   1 -> ~0.37x, 5 -> 1.0x, 9 -> ~2.72x */
static double sensitivity_factor(void) {
    return exp((s_sensitivity - 5) * 0.25);
}

static void try_create_event_tap(void);
static void try_build_queue_for_devices(void);
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
@property (strong) NSButton    *ptsCheck;
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
        initWithContentRect:NSMakeRect(0, 0, 360, 470)
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
    CGFloat y = 430;

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
    y -= 16;

    /* ── Separator ── */
    NSBox *sep4 = [[NSBox alloc] initWithFrame:NSMakeRect(pad, y, W - pad*2, 1)];
    sep4.boxType = NSBoxSeparator;
    [cv addSubview:sep4];
    y -= 18;

    /* ── TrackPoint ── */
    NSTextField *tph = [NSTextField labelWithString:@"TrackPoint"];
    tph.font = [NSFont boldSystemFontOfSize:12];
    tph.frame = NSMakeRect(pad, y, W - pad*2, 18);
    [cv addSubview:tph];
    y -= 26;

    self.ptsCheck = [NSButton checkboxWithTitle:@"Press-to-Select (tap stick → left click)"
                     target:self action:@selector(togglePts:)];
    self.ptsCheck.frame = NSMakeRect(pad + 8, y, W - pad*2 - 8, 20);
    [cv addSubview:self.ptsCheck];

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
    self.ptsCheck.state  = s_ptsEnabled  ? NSControlStateValueOn : NSControlStateValueOff;

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

- (void)togglePts:(NSButton *)btn {
    s_ptsEnabled = (btn.state == NSControlStateValueOn);
    [[NSUserDefaults standardUserDefaults] setBool:s_ptsEnabled forKey:PREF_PTS];
    if (!s_ptsEnabled) {
        if (s_pts_timer) { CFRunLoopTimerInvalidate(s_pts_timer); s_pts_timer = NULL; }
        s_pts_tracking = false; s_pts_inhibit = false;
    }
    LOG("press-to-select: %s", s_ptsEnabled ? "ON" : "OFF");
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
@property (strong) NSTimer      *imTimer;
- (void)refresh;
@end

static AppDelegate *g_app = nil;

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)n {
    g_app = self;
    g_settings = [SettingsWindowController new];
    [self buildMenu];
    /* Request Input Monitoring permission (needed for IOHIDQueue per-device filtering) */
    if (!CGPreflightListenEventAccess()) {
        CGRequestListenEventAccess();
        LOG("Input Monitoring: not granted — requesting. Per-device filter will activate once granted.");
        s_imTimer = [NSTimer scheduledTimerWithTimeInterval:3.0 target:self
            selector:@selector(pollIM:) userInfo:nil repeats:YES];
    } else {
        LOG("Input Monitoring: already granted");
    }
    [self refresh];
    /* Compute union of all active display bounds for multi-monitor clamping */
    CGDirectDisplayID displays[8];
    uint32_t dispCount = 0;
    CGGetActiveDisplayList(8, displays, &dispCount);
    s_displayBounds = CGRectZero;
    for (uint32_t i = 0; i < dispCount; i++)
        s_displayBounds = CGRectUnion(s_displayBounds, CGDisplayBounds(displays[i]));
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

- (void)pollIM:(NSTimer *)t {
    if (CGPreflightListenEventAccess()) {
        LOG("Input Monitoring: granted — building per-device queue");
        [t invalidate]; s_imTimer = nil;
        /* Retry device open + queue build for all already-connected ThinkPad devices */
        try_build_queue_for_devices();
        if (!s_tp_queue && s_tp_devices && CFArrayGetCount(s_tp_devices) > 0) {
            /* Elements not ready yet (BLE) — retry after 2s */
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2000 * NSEC_PER_MSEC),
                           dispatch_get_main_queue(), ^{ try_build_queue_for_devices(); });
        }
    }
}

- (void)openSettings:(id)sender {
    [g_settings syncState];
    /* Switch to regular policy so window comes to front over other apps */
    NSApp.activationPolicy = NSApplicationActivationPolicyRegular;
    NSImage *icon = [[NSBundle mainBundle] imageForResource:@"TrackPointD"];
    if (icon) NSApp.applicationIconImage = icon;
    [NSApp activateIgnoringOtherApps:YES];
    [g_settings showWindow:nil];
    [g_settings.window center];
    [g_settings.window makeKeyAndOrderFront:nil];
    /* Watch for window close to revert to accessory (no Dock icon) */
    [[NSNotificationCenter defaultCenter]
        addObserver:self selector:@selector(settingsWindowClosed:)
        name:NSWindowWillCloseNotification object:g_settings.window];
}

- (void)settingsWindowClosed:(NSNotification *)n {
    [[NSNotificationCenter defaultCenter] removeObserver:self
        name:NSWindowWillCloseNotification object:g_settings.window];
    NSApp.activationPolicy = NSApplicationActivationPolicyAccessory;
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
   Press-to-select: fires left click after brief stick tap
   ══════════════════════════════════════════════════════════════ */
static void pts_fire(CFRunLoopTimerRef timer, void *info) {
    (void)info;
    CFRunLoopTimerInvalidate(timer);
    s_pts_timer = NULL;
    if (s_pts_inhibit) {
        /* gesture was too large — stick stopped, clear inhibit, no click */
        s_pts_inhibit = false;
        return;
    }
    if (!s_pts_tracking) return;
    s_pts_tracking = false;
    CGEventRef dn = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseDown, s_pts_pos, kCGMouseButtonLeft);
    CGEventRef up = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseUp,   s_pts_pos, kCGMouseButtonLeft);
    CGEventPost(kCGSessionEventTap, dn);
    CGEventPost(kCGSessionEventTap, up);
    CFRelease(dn); CFRelease(up);
    LOG("press-to-select: click at (%.0f, %.0f)", s_pts_pos.x, s_pts_pos.y);
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

    /* ── Right Option → F18 (ThinkPad keyboard only) ──────── */
    if (type == kCGEventFlagsChanged && s_f18Enabled && s_tpCount > 0) {
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
            /* cancel any pending PTS on middle-down */
            if (s_pts_timer) { CFRunLoopTimerInvalidate(s_pts_timer); s_pts_timer = NULL; }
            s_pts_tracking = false; s_pts_inhibit = false;
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
            /* Sensitivity + acceleration scaling — ThinkPad origin only */
            if (!s_tpCount) return event;

            /* Poll IOHIDQueue: event is from ThinkPad if queue has FRESH values (< 15ms old).
             * CGEventTap fires before IOHIDManager for the same event, so queue holds values
             * from the PREVIOUS HID report (~8ms ago at 125Hz). Stale values (> 15ms) are
             * from an idle TrackPoint and must be drained without counting as ThinkPad origin.
             * Fallback: if queue never produces values, trust s_tpCount > 0. */
            bool has_fresh = false;  /* true = definite ThinkPad HID value seen this callback */
            if (s_tp_queue) {
                static mach_timebase_info_data_t s_tb;
                if (s_tb.denom == 0) mach_timebase_info(&s_tb);
                uint64_t now = mach_absolute_time();

                /* Drain queue; if any value is fresh (<15ms), update s_last_tp_time */
                IOHIDValueRef val;
                while ((val = IOHIDQueueCopyNextValueWithTimeout(s_tp_queue, 0)) != NULL) {
                    uint64_t ts = IOHIDValueGetTimeStamp(val);
                    uint64_t age_ns = (now - ts) * s_tb.numer / s_tb.denom;
                    if (age_ns < 15000000ULL) {   /* 15ms — fresh HID report */
                        has_fresh = true;
                        s_last_tp_time = now;
                        if (!s_tp_queue_ok) {
                            s_tp_queue_ok = true;
                            LOG("HID queue confirmed — per-device filtering active");
                        }
                    }
                    CFRelease(val);
                }

                if (s_tp_queue_ok) {
                    /* ThinkPad if fresh now OR seen within 50ms recency window */
                    uint64_t since_ns = (now - s_last_tp_time) * s_tb.numer / s_tb.denom;
                    bool from_tp = has_fresh || (since_ns < TP_RECENCY_NS);

                    static CFAbsoluteTime s_last_filter_log = 0;
                    CFAbsoluteTime now2 = CFAbsoluteTimeGetCurrent();
                    if (now2 - s_last_filter_log > 1.0) {
                        LOG("%s (since_tp=%.0fms%s)", from_tp ? "ThinkPad move" : "other device — filtered",
                            since_ns / 1e6, has_fresh ? ",fresh" : "");
                        s_last_filter_log = now2;
                    }

                    if (!from_tp) {
                        /* Definite non-ThinkPad — cancel any pending PTS */
                        if (s_pts_tracking || s_pts_inhibit) {
                            if (s_pts_timer) { CFRunLoopTimerInvalidate(s_pts_timer); s_pts_timer = NULL; }
                            s_pts_tracking = false; s_pts_inhibit = false;
                        }
                        return event;
                    }
                }
            }

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

            /* Press-to-select: track brief stick bursts */
            if (s_ptsEnabled) {
                double rawSpeed = sqrt(dx * dx + dy * dy);
                /* always cancel pending stop timer on new movement */
                if (s_pts_timer) { CFRunLoopTimerInvalidate(s_pts_timer); s_pts_timer = NULL; }

                bool need_timer = false;
                if (s_pts_inhibit) {
                    /* gesture already failed — reschedule "stick stopped" clear */
                    need_timer = true;
                } else if (!s_pts_tracking) {
                    /* Only start new PTS session on confirmed ThinkPad (fresh HID value).
                     * Recency-only passes (ambiguous device) must not start new sessions. */
                    if (has_fresh) {
                        s_pts_tracking = true;
                        s_pts_startTime = CFAbsoluteTimeGetCurrent();
                        s_pts_totalDist = rawSpeed;
                        s_pts_pos = newPos;
                        need_timer = true;
                    }
                } else {
                    s_pts_totalDist += rawSpeed;
                    s_pts_pos = newPos;
                    bool valid = (CFAbsoluteTimeGetCurrent() - s_pts_startTime) < PTS_MAX_DURATION
                              && s_pts_totalDist < PTS_MAX_DIST;
                    if (!valid) {
                        /* too long/far — inhibit until stick stops */
                        s_pts_tracking = false;
                        s_pts_inhibit  = true;
                    }
                    need_timer = true;
                }

                if (need_timer) {
                    CFRunLoopTimerContext ctx = {0, NULL, NULL, NULL, NULL};
                    s_pts_timer = CFRunLoopTimerCreate(kCFAllocatorDefault,
                        CFAbsoluteTimeGetCurrent() + PTS_STOP_DELAY,
                        0, 0, 0, pts_fire, &ctx);
                    CFRunLoopAddTimer(CFRunLoopGetMain(), s_pts_timer, kCFRunLoopDefaultMode);
                }
            }

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
    CGEventTapEnable(s_tap, s_tpCount > 0);
    LOG("unified tap created (kCGHIDEventTap) — %s", s_tpCount > 0 ? "ON" : "waiting for ThinkPad");
    dispatch_async(dispatch_get_main_queue(), ^{ [g_app refresh]; });
}

/* ══════════════════════════════════════════════════════════════
   IOHIDManager — ThinkPad connection detection
   ══════════════════════════════════════════════════════════════ */

/* Attempt to open stored ThinkPad devices and build queue.
 * Called at startup and whenever Input Monitoring permission is detected. */
static void try_build_queue_for_devices(void) {
    if (s_tp_queue) return;
    if (!s_tp_devices || CFArrayGetCount(s_tp_devices) == 0) return;

    CFIndex count = CFArrayGetCount(s_tp_devices);
    for (CFIndex i = 0; i < count; i++) {
        IOHIDDeviceRef dev = (IOHIDDeviceRef)CFArrayGetValueAtIndex(s_tp_devices, i);
        IOReturn openRet = IOHIDDeviceOpen(dev, kIOHIDOptionsTypeNone);
        LOG("IM-retry: IOHIDDeviceOpen 0x%08X (%s)", openRet,
            openRet == kIOReturnSuccess     ? "ok" :
            openRet == kIOReturnExclusiveAccess ? "exclusive" : "other");
        if (openRet != kIOReturnSuccess && openRet != kIOReturnExclusiveAccess) continue;

        CFArrayRef elems = IOHIDDeviceCopyMatchingElements(dev, NULL, kIOHIDOptionsTypeNone);
        int total = elems ? (int)CFArrayGetCount(elems) : 0;
        LOG("IM-retry: %d elements found", total);
        int added = 0;
        if (total > 0) {
            IOHIDQueueRef queue = IOHIDQueueCreate(kCFAllocatorDefault, dev, 64, kIOHIDOptionsTypeNone);
            if (queue) {
                for (CFIndex j = 0; j < total; j++) {
                    IOHIDElementRef elem = (IOHIDElementRef)CFArrayGetValueAtIndex(elems, j);
                    uint32_t ePage  = IOHIDElementGetUsagePage(elem);
                    uint32_t eUsage = IOHIDElementGetUsage(elem);
                    if (ePage == 1 && (eUsage == 0x30 || eUsage == 0x31)) {
                        IOHIDQueueAddElement(queue, elem);
                        added++;
                    }
                }
                if (added > 0) {
                    IOHIDQueueStart(queue);
                    s_tp_queue = queue;
                    LOG("IM-retry: queue built with %d X/Y elements — per-device filter active", added);
                } else {
                    CFRelease(queue);
                    LOG("IM-retry: no X/Y elements on this device");
                }
            }
        }
        if (elems) CFRelease(elems);
        if (s_tp_queue) break;
    }
}

static void hid_added(void *ctx, IOReturn r, void *sender, IOHIDDeviceRef dev) {
    (void)ctx; (void)r; (void)sender;

    /* Store device for later retry (e.g. when Input Monitoring granted) */
    if (s_tp_devices) CFArrayAppendValue(s_tp_devices, dev);  /* array retains */

    IOReturn openRet = IOHIDDeviceOpen(dev, kIOHIDOptionsTypeNone);
    LOG("IOHIDDeviceOpen: 0x%08X (%s)", openRet,
        openRet == kIOReturnSuccess ? "ok" :
        openRet == kIOReturnExclusiveAccess ? "exclusive" : "other");
    s_tpCount++;

    /* Build X/Y element queue for this device.
     * BLE devices may not have elements ready immediately — retry after 500ms if needed. */
    if (!s_tp_queue) {
        IOHIDDeviceRef devRetained = (IOHIDDeviceRef)CFRetain(dev);
        void (^tryBuildQueue)(void) = ^{
            if (s_tp_queue) { CFRelease(devRetained); return; }
            CFArrayRef elems = IOHIDDeviceCopyMatchingElements(devRetained, NULL, kIOHIDOptionsTypeNone);
            int total = elems ? (int)CFArrayGetCount(elems) : 0;
            LOG("HID device: %d elements (queue build attempt)", total);
            int added = 0;
            if (total > 0) {
                IOHIDQueueRef queue = IOHIDQueueCreate(kCFAllocatorDefault, devRetained, 64, kIOHIDOptionsTypeNone);
                if (queue) {
                    for (CFIndex i = 0; i < total; i++) {
                        IOHIDElementRef elem = (IOHIDElementRef)CFArrayGetValueAtIndex(elems, i);
                        uint32_t ePage  = IOHIDElementGetUsagePage(elem);
                        uint32_t eUsage = IOHIDElementGetUsage(elem);
                        if (ePage == 1 && (eUsage == 0x30 || eUsage == 0x31)) {
                            IOHIDQueueAddElement(queue, elem);
                            added++;
                        }
                    }
                    if (added > 0) {
                        IOHIDQueueStart(queue);
                        s_tp_queue = queue;
                        LOG("HID queue created with %d X/Y elements", added);
                    } else {
                        CFRelease(queue);
                        LOG("HID queue: no X/Y elements on this device");
                    }
                }
            }
            if (elems) CFRelease(elems);
            CFRelease(devRetained);
        };

        CFArrayRef elems = IOHIDDeviceCopyMatchingElements(dev, NULL, kIOHIDOptionsTypeNone);
        int total = elems ? (int)CFArrayGetCount(elems) : 0;
        if (elems) CFRelease(elems);

        if (total > 0) {
            /* Elements ready now — build immediately */
            tryBuildQueue();
        } else {
            /* BLE not yet enumerated — retry in 500ms */
            LOG("HID device: 0 elements at connect — will retry in 2s");
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2000 * NSEC_PER_MSEC),
                           dispatch_get_main_queue(), tryBuildQueue);
        }
    }

    set_tap_enabled(true);
}

static void hid_removed(void *ctx, IOReturn r, void *sender, IOHIDDeviceRef dev) {
    (void)ctx; (void)r; (void)sender;

    /* Remove from stored devices array */
    if (s_tp_devices) {
        CFIndex idx = CFArrayGetFirstIndexOfValue(s_tp_devices,
            CFRangeMake(0, CFArrayGetCount(s_tp_devices)), dev);
        if (idx != kCFNotFound) CFArrayRemoveValueAtIndex(s_tp_devices, idx);  /* array releases */
    }

    if (--s_tpCount <= 0) {
        s_tpCount = 0; s_middleDown = false;
        if (s_tp_queue) {
            IOHIDQueueStop(s_tp_queue);
            CFRelease(s_tp_queue);
            s_tp_queue = NULL;
            s_tp_queue_ok = false;
        }
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
    s_tp_devices = CFArrayCreateMutable(kCFAllocatorDefault, 0, &kCFTypeArrayCallBacks);
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
        if ([ud objectForKey:PREF_PTS])
            s_ptsEnabled  = [ud boolForKey:PREF_PTS];

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
