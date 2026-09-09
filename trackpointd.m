/*
 * trackpointd.m — ThinkPad TrackPoint macOS menu bar app
 *
 * Key remap: per-device hidutil — modifier swap and Right Option -> F18
 * Unified CGEventTap at kCGHIDEventTap:
 *   - Middle button → scroll (with accumulator + threshold)
 *   - Software sensitivity fallback
 * Exact-device HID value callback: pointer-origin confirmation
 * Detection/config: IOHIDManager, exact TrackPoint Keyboard II USB/BLE IDs
 *
 * Compile:
 *   clang -O2 -fobjc-arc -o trackpointd trackpointd.m \
 *     -framework Cocoa -framework ApplicationServices -framework CoreAudio \
 *     -framework IOKit -lm
 */

#import <Cocoa/Cocoa.h>
#import <ApplicationServices/ApplicationServices.h>
#import <CoreAudio/CoreAudio.h>
#import <IOKit/hid/IOHIDManager.h>
#import <IOKit/hidsystem/IOHIDLib.h>
#import <math.h>
#import <mach/mach_time.h>
#import <assert.h>
#import <float.h>

/* ── Config ───────────────────────────────────────────────────── */
#define TP_SENSITIVITY_DEFAULT  5   /* 1-9 scale, 5 = neutral */
#define SCROLL_SPEED            3.5
#define SCROLL_THRESHOLD        0.8
#define LENOVO_VID              0x17EF
#define TP_USB_PID              0x60EE
#define TP_BLE_PID              0x60E1
/* ─────────────────────────────────────────────────────────────── */

#define HID_LEFT_OPTION   "0x7000000E2"
#define HID_LEFT_CMD      "0x7000000E3"
#define HID_RIGHT_OPTION  "0x7000000E6"
#define HID_F18           "0x70000006D"

#define PREF_SENSITIVITY  @"tpSensitivity"
#define PREF_F18          @"tpF18Enabled"
#define PREF_SWAP         @"tpSwapEnabled"
#define PREF_SCROLL_SPEED @"tpScrollSpeed"
#define PREF_SCROLL       @"tpPreferredScroll"
#define PREF_FN_LOCK      @"tpFnLock"
#define PREF_F12_MODE     @"tpF12Mode"
#define PREF_F12_URL      @"tpF12URL"
#define PREF_F12_TEXT     @"tpF12Text"
#define PREF_F12_FILES    @"tpF12Files"

#define LOG(fmt, ...) fprintf(stderr, "[tp] " fmt "\n", ##__VA_ARGS__)

static CFMachPortRef     s_tap        = NULL;   /* unified event tap */
static CFRunLoopSourceRef s_tapSource = NULL;
static bool              s_middleDown = false;
static bool              s_hasMoved   = false;
static CGPoint           s_lastPos    = {0, 0};
static uint64_t          s_lastMiddleClickTime = 0;

static bool    s_f18Enabled  = true;
static bool    s_swapEnabled = true;
static int     s_sensitivity = TP_SENSITIVITY_DEFAULT;  /* 1-9 */
static double  s_scrollSpeed = SCROLL_SPEED;
static bool    s_preferredScroll = true;
static bool    s_fnLock = false;
static bool    s_hardwareSensitivity = false;
static bool    s_naturalScroll = false;
static double  s_scrollAccumX = 0.0;
static double  s_scrollAccumY = 0.0;
static NSTimer      *s_imTimer = nil;       /* Input Monitoring permission poll timer */
static IOHIDManagerRef s_hidManager = NULL;

typedef NS_ENUM(NSInteger, TPF12Mode) {
    TPF12Disabled = 0,
    TPF12OpenFiles = 1,
    TPF12OpenURL = 2,
    TPF12TypeText = 3,
};

static TPF12Mode s_f12Mode = TPF12OpenURL;
static NSString *s_f12URL = @"https://support.lenovo.com/accessories/trackpoint_keyboard";
static NSString *s_f12Text = @"";
static NSArray<NSString *> *s_f12Files = @[];
static bool s_accessibilityRequestAttempted = false;

/* If a fresh ThinkPad HID value was seen within this window, treat the
 * corresponding CG event as coming from that exact device. */
#define TP_RECENCY_NS  50000000ULL   /* 50ms */
#define NATIVE_DUP_NS  15000000ULL   /* native report vs. compatibility event */

@interface TPHIDDevice : NSObject {
@public
    IOHIDDeviceRef device;
    bool inputConfirmed;
    uint64_t lastPointerTime;
    uint64_t lastMiddleButtonTime;
    uint64_t lastNativeScrollTime;
    uint64_t lastNativeMiddleTime;
    uint16_t lastHotkey;
    bool nativeMiddleDown;
    bool nativeScrolled;
    bool rawMiddleDown;
}
- (instancetype)initWithDevice:(IOHIDDeviceRef)hidDevice;
- (void)resetAfterWake;
@end

static NSMutableArray<TPHIDDevice *> *s_tpDevices;

static int tp_count(void) {
    return (int)s_tpDevices.count;
}

static TPHIDDevice *tp_context_for_device(IOHIDDeviceRef device) {
    for (TPHIDDevice *ctx in s_tpDevices)
        if (ctx->device == device) return ctx;
    return nil;
}

static bool tp_has_direct_input(void) {
    for (TPHIDDevice *ctx in s_tpDevices)
        if (ctx->inputConfirmed) return true;
    return false;
}

static IOHIDAccessType input_monitoring_access(void) {
    return IOHIDCheckAccess(kIOHIDRequestTypeListenEvent);
}

static bool input_monitoring_granted(void) {
    return input_monitoring_access() == kIOHIDAccessTypeGranted;
}

/* sensitivity 1-9 -> scale factor via exponential curve
   1 -> ~0.37x, 5 -> 1.0x, 9 -> ~2.72x */
static double sensitivity_factor(void) {
    return exp((s_sensitivity - 5) * 0.25);
}

static void try_create_event_tap(void);
static void setup_hid(void);
static void refresh_ui(void);
static void apply_key_remap(void);
static void apply_hardware_settings(void);
static void reset_gesture_state(void);
static void reset_compatibility_middle(void);
static NSURL *validated_http_url(NSString *value);
static void run_f12_action(void);
static bool toggle_default_input_mute(void);
static void show_notification_center(void);
static void open_privacy_settings(NSString *pane);
static void handle_hotkey(uint16_t usage);
static void post_middle_click(CGPoint point);
static uint64_t elapsed_ns(uint64_t now, uint64_t then);
static void native_middle_changed(TPHIDDevice *ctx, bool down);

typedef struct {
    IOHIDReportType type;
    uint8_t reportID;
} TPReportSpec;

static bool report_spec_for_pid(int productID, TPReportSpec *spec) {
    if (productID == TP_USB_PID) {
        spec->type = kIOHIDReportTypeFeature;
        spec->reportID = 0x13;
        return true;
    }
    if (productID == TP_BLE_PID) {
        spec->type = kIOHIDReportTypeOutput;
        spec->reportID = 0x18;
        return true;
    }
    return false;
}

static bool build_config_report(int productID, uint8_t command, uint8_t value,
                                TPReportSpec *spec, uint8_t report[8],
                                CFIndex *reportLength) {
    if (!report_spec_for_pid(productID, spec)) return false;
    *reportLength = productID == TP_USB_PID ? 8 : 3;
    memset(report, 0, 8);
    report[0] = spec->reportID;
    report[1] = command;
    report[2] = value;
    return true;
}

static int device_number(IOHIDDeviceRef dev, CFStringRef key) {
    CFTypeRef value = IOHIDDeviceGetProperty(dev, key);
    int number = 0;
    if (value && CFGetTypeID(value) == CFNumberGetTypeID())
        CFNumberGetValue((CFNumberRef)value, kCFNumberIntType, &number);
    return number;
}

static bool is_trackpoint_keyboard_ii(IOHIDDeviceRef dev) {
    int vid = device_number(dev, CFSTR(kIOHIDVendorIDKey));
    int pid = device_number(dev, CFSTR(kIOHIDProductIDKey));
    return vid == LENOVO_VID && (pid == TP_USB_PID || pid == TP_BLE_PID);
}

static bool send_config_command(IOHIDDeviceRef dev, uint8_t command, uint8_t value) {
    TPReportSpec spec;
    int pid = device_number(dev, CFSTR(kIOHIDProductIDKey));
    uint8_t report[8];
    CFIndex reportLength;
    if (!build_config_report(pid, command, value, &spec, report, &reportLength))
        return false;
    IOReturn ret = IOHIDDeviceSetReport(dev, spec.type, spec.reportID,
                                         report, reportLength);
    LOG("HID config pid=%04X report=%02X cmd=%02X value=%u: 0x%08X",
        (unsigned int)pid, spec.reportID, command, value, (unsigned int)ret);
    return ret == kIOReturnSuccess;
}

static CFIndex input_payload_offset(uint32_t reportID, const uint8_t *report,
                                    CFIndex reportLength,
                                    CFIndex expectedLength) {
    if (!report || reportID > UINT8_MAX || reportLength != expectedLength ||
        report[0] != (uint8_t)reportID)
        return -1;
    return 1;
}

static bool decode_hotkey_report(int pid, uint32_t reportID,
                                 const uint8_t *report, CFIndex reportLength,
                                 uint16_t *usage) {
    if (reportID != 0x05) return false;
    CFIndex expectedLength;
    if (pid == TP_USB_PID) expectedLength = 2;
    else if (pid == TP_BLE_PID) expectedLength = 3;
    else return false;
    CFIndex offset = input_payload_offset(reportID, report, reportLength,
                                          expectedLength);
    if (offset < 0) return false;
    *usage = report[offset];
    return true;
}

static bool decode_wheel_report(uint32_t reportID, const uint8_t *report,
                                CFIndex reportLength, int8_t *horizontal,
                                int8_t *vertical) {
    /* Both transports use wire report ID 0x16 (22 decimal). */
    if (reportID != 0x16) return false;
    CFIndex offset = input_payload_offset(reportID, report, reportLength, 3);
    if (offset < 0 || reportLength - offset < 2) return false;
    *horizontal = (int8_t)report[offset];
    *vertical = (int8_t)report[offset + 1];
    return true;
}

static bool decode_middle_report(uint32_t reportID, const uint8_t *report,
                                 CFIndex reportLength, bool *down) {
    if (reportID != 0x15) return false;
    CFIndex offset = input_payload_offset(reportID, report, reportLength, 9);
    if (offset < 0 || reportLength - offset < 2) return false;
    *down = (report[offset + 1] & 0x04) != 0;
    return true;
}

static void hid_report(void *context, IOReturn result, void *sender,
                       IOHIDReportType type, uint32_t reportID,
                       uint8_t *report, CFIndex reportLength) {
    (void)context;
    if (result != kIOReturnSuccess || type != kIOHIDReportTypeInput) return;
    TPHIDDevice *ctx = tp_context_for_device((IOHIDDeviceRef)sender);
    if (!ctx) return;

    /* Report 5 carries a Lenovo hotkey usage (second byte is padding on BLE). */
    if (reportID == 0x05) {
        uint16_t usage;
        int pid = device_number(ctx->device, CFSTR(kIOHIDProductIDKey));
        if (!decode_hotkey_report(pid, reportID, report, reportLength, &usage))
            return;
        if (usage == 0) {
            ctx->lastHotkey = 0;
        } else if (usage != ctx->lastHotkey) {
            ctx->lastHotkey = usage;
            handle_hotkey(usage);
        }
        return;
    }

    /* Native Preferred Scrolling report: horizontal byte, then vertical byte. */
    int8_t horizontal, vertical;
    if (s_preferredScroll && decode_wheel_report(reportID, report, reportLength,
                                                 &horizontal, &vertical)) {
        if (horizontal == 0 && vertical == 0) return;
        bool isBLE = device_number(ctx->device, CFSTR(kIOHIDProductIDKey)) == TP_BLE_PID;
        int sign = s_naturalScroll ? -1 : 1;
        int32_t verticalPixels = isBLE ? 0 :
            (int32_t)lrint((double)vertical * s_scrollSpeed * sign);
        int32_t horizontalPixels =
            (int32_t)lrint((double)horizontal * s_scrollSpeed * sign);
        /* BLE also emits a standard vertical wheel report. Reusing that avoids
         * double scrolling; the vendor report is still needed for horizontal. */
        if (verticalPixels != 0 || horizontalPixels != 0) {
            CGEventRef scroll = CGEventCreateScrollWheelEvent(NULL,
                kCGScrollEventUnitPixel, 2, verticalPixels, horizontalPixels);
            if (scroll) {
                CGEventPost(kCGSessionEventTap, scroll);
                CFRelease(scroll);
            }
        }
        ctx->lastNativeScrollTime = mach_absolute_time();
        ctx->nativeScrolled = true;
        s_hasMoved = true;
        return;
    }

    /* BLE native middle-button report (usage 4 in report 0x15). */
    bool down;
    if (s_preferredScroll &&
        decode_middle_report(reportID, report, reportLength, &down)) {
        native_middle_changed(ctx, down);
    }
}

static void hid_value(void *context, IOReturn result, void *sender,
                      IOHIDValueRef value) {
    (void)context; (void)sender;
    if (result != kIOReturnSuccess) return;
    IOHIDElementRef element = IOHIDValueGetElement(value);
    TPHIDDevice *ctx = tp_context_for_device(IOHIDElementGetDevice(element));
    if (!ctx) return;
    uint32_t page = IOHIDElementGetUsagePage(element);
    uint32_t usage = IOHIDElementGetUsage(element);
    CFIndex integerValue = IOHIDValueGetIntegerValue(value);

    if (page == kHIDPage_GenericDesktop &&
        (usage == kHIDUsage_GD_X || usage == kHIDUsage_GD_Y) &&
        integerValue != 0) {
        uint64_t now = mach_absolute_time();
        ctx->lastPointerTime = now;
        if (!ctx->inputConfirmed) {
            ctx->inputConfirmed = true;
            LOG("direct HID input confirmed — exact-device filtering active");
            dispatch_async(dispatch_get_main_queue(), ^{ refresh_ui(); });
        }
        return;
    }

    if (page == kHIDPage_Button && usage == 3) {
        ctx->lastMiddleButtonTime = mach_absolute_time();
        ctx->rawMiddleDown = integerValue != 0;
    }

    if (page == 0xFFA0 && usage == 0xFB) {
        if (s_preferredScroll)
            native_middle_changed(ctx, integerValue != 0);
    }
}

static void native_middle_changed(TPHIDDevice *ctx, bool down) {
    if (down && !ctx->nativeMiddleDown) {
        /* A CG compatibility event can arrive before this raw report. */
        reset_compatibility_middle();
        ctx->nativeMiddleDown = true;
        ctx->nativeScrolled = false;
        ctx->lastNativeMiddleTime = mach_absolute_time();
    } else if (!down && ctx->nativeMiddleDown) {
        ctx->nativeMiddleDown = false;
        ctx->lastNativeMiddleTime = mach_absolute_time();
        if (!ctx->nativeScrolled && s_preferredScroll) {
            CGEventRef current = CGEventCreate(NULL);
            CGPoint point = current ? CGEventGetLocation(current) : CGPointZero;
            if (current) CFRelease(current);
            post_middle_click(point);
        }
    }
}

@implementation TPHIDDevice

- (instancetype)initWithDevice:(IOHIDDeviceRef)hidDevice {
    self = [super init];
    if (!self) return nil;
    device = (IOHIDDeviceRef)CFRetain(hidDevice);
    inputConfirmed = false;
    lastPointerTime = 0;
    lastMiddleButtonTime = 0;
    lastNativeScrollTime = 0;
    lastNativeMiddleTime = 0;
    lastHotkey = 0;
    nativeMiddleDown = false;
    nativeScrolled = false;
    rawMiddleDown = false;
    return self;
}

- (void)resetAfterWake {
    inputConfirmed = false;
    lastPointerTime = 0;
    lastMiddleButtonTime = 0;
    lastNativeScrollTime = 0;
    lastNativeMiddleTime = 0;
    lastHotkey = 0;
}

- (void)dealloc {
    if (device) CFRelease(device);
}

@end

/* ══════════════════════════════════════════════════════════════
   Settings Window
   ══════════════════════════════════════════════════════════════ */
@interface SettingsWindowController : NSWindowController <NSTextFieldDelegate,
    NSTableViewDataSource, NSTableViewDelegate>
@property (strong) NSTextField *keyboardStatus;
@property (strong) NSTextField *accessStatus;
@property (strong) NSTextField *inputStatus;
@property (strong) NSButton    *f18Check;
@property (strong) NSButton    *swapCheck;
@property (strong) NSButton    *fnLockCheck;
@property (strong) NSButton    *preferredCheck;
@property (strong) NSSlider    *slider;
@property (strong) NSTextField *valueLabel;
@property (strong) NSSlider    *scrollSlider;
@property (strong) NSTextField *scrollValueLabel;
@property (strong) NSButton    *accessibilityBtn;
@property (strong) NSButton    *inputMonitoringBtn;
@property (strong) NSTextField *f12Summary;
@property (strong) NSTextField *f12DetailLabel;
@property (strong) NSTextField *f12DetailValue;
@property (strong) NSPanel     *f12Panel;
@property (strong) NSPopUpButton *f12Popup;
@property (strong) NSTextField *f12EditorLabel;
@property (strong) NSTextField *f12Value;
@property (strong) NSScrollView *f12FilesScroll;
@property (strong) NSTableView *f12FilesTable;
@property (strong) NSButton    *f12ChooseBtn;
@property (strong) NSButton    *f12RemoveBtn;
@property (strong) NSTextField *f12Warning;
@property (assign) TPF12Mode   f12DraftMode;
@property (copy) NSString      *f12DraftURL;
@property (copy) NSString      *f12DraftText;
@property (copy) NSArray<NSString *> *f12DraftFiles;
- (void)syncState;
@end

static SettingsWindowController *g_settings = nil;

@implementation SettingsWindowController

- (instancetype)init {
    NSWindow *win = [[NSWindow alloc]
        initWithContentRect:NSMakeRect(0, 0, 520, 520)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
        backing:NSBackingStoreBuffered
        defer:NO];
    win.title = @"TrackPoint Keyboard II Properties";
    win.releasedWhenClosed = NO;
    self = [super initWithWindow:win];
    if (!self) return nil;
    [self buildUI];
    return self;
}

- (void)buildUI {
    NSView *cv = self.window.contentView;
    CGFloat W = 520, H = 520;
    NSTabView *tabs = [[NSTabView alloc] initWithFrame:NSMakeRect(12, 12, W - 24, H - 24)];
    [cv addSubview:tabs];

    /* Lenovo's Windows property page keeps its three settings together. */
    NSTabViewItem *windowsItem = [[NSTabViewItem alloc] initWithIdentifier:@"windows"];
    windowsItem.label = @"External TrackPoint Keyboard";
    NSView *windowsView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 488, 460)];
    windowsItem.view = windowsView;
    [tabs addTabViewItem:windowsItem];

    NSImageView *keyboardImage = [[NSImageView alloc] initWithFrame:NSMakeRect(154, 354, 180, 74)];
    keyboardImage.image = [NSImage imageWithSystemSymbolName:@"keyboard"
                                    accessibilityDescription:@"ThinkPad TrackPoint Keyboard II"];
    keyboardImage.imageScaling = NSImageScaleProportionallyUpOrDown;
    [windowsView addSubview:keyboardImage];

    NSTextField *trackPointDot = [NSTextField labelWithString:@"●"];
    trackPointDot.font = [NSFont systemFontOfSize:18 weight:NSFontWeightBold];
    trackPointDot.textColor = [NSColor systemRedColor];
    trackPointDot.alignment = NSTextAlignmentCenter;
    trackPointDot.frame = NSMakeRect(232, 379, 24, 24);
    trackPointDot.accessibilityLabel = @"TrackPoint";
    [windowsView addSubview:trackPointDot];

    NSBox *pointerBox = [[NSBox alloc] initWithFrame:NSMakeRect(20, 264, 448, 76)];
    pointerBox.title = @"Pointer speed";
    [windowsView addSubview:pointerBox];

    NSTextField *minLbl = [NSTextField labelWithString:@"Slow"];
    minLbl.font = [NSFont systemFontOfSize:11];
    minLbl.frame = NSMakeRect(12, 19, 38, 16);
    [pointerBox addSubview:minLbl];

    NSTextField *maxLbl = [NSTextField labelWithString:@"Fast"];
    maxLbl.font = [NSFont systemFontOfSize:11];
    maxLbl.alignment = NSTextAlignmentRight;
    maxLbl.frame = NSMakeRect(398, 19, 38, 16);
    [pointerBox addSubview:maxLbl];

    self.slider = [[NSSlider alloc] initWithFrame:NSMakeRect(54, 16, 340, 24)];
    self.slider.minValue = 1;
    self.slider.maxValue = 9;
    self.slider.numberOfTickMarks = 9;
    self.slider.allowsTickMarkValuesOnly = YES;
    self.slider.integerValue = s_sensitivity;
    self.slider.continuous = NO;
    self.slider.target = self;
    self.slider.action = @selector(sliderChanged:);
    self.slider.accessibilityLabel = @"Pointer speed";
    [pointerBox addSubview:self.slider];

    self.valueLabel = [NSTextField labelWithString:
        [NSString stringWithFormat:@"%d / 9", s_sensitivity]];
    self.valueLabel.hidden = YES;

    self.preferredCheck = [NSButton checkboxWithTitle:@"ThinkPad Preferred Scrolling"
                           target:self action:@selector(togglePreferredScroll:)];
    self.preferredCheck.frame = NSMakeRect(28, 226, 420, 22);
    [windowsView addSubview:self.preferredCheck];

    NSBox *separator = [[NSBox alloc] initWithFrame:NSMakeRect(20, 211, 448, 1)];
    separator.boxType = NSBoxSeparator;
    [windowsView addSubview:separator];

    NSTextField *star = [NSTextField labelWithString:@"★"];
    star.font = [NSFont systemFontOfSize:40 weight:NSFontWeightRegular];
    star.textColor = [NSColor systemRedColor];
    star.alignment = NSTextAlignmentCenter;
    star.frame = NSMakeRect(47, 111, 52, 50);
    star.accessibilityLabel = @"F12 User Defined Key";
    [windowsView addSubview:star];

    NSTextField *f12Help = [NSTextField wrappingLabelWithString:
        @"The key represented by the star icon allows you to set a user-defined function."];
    f12Help.font = [NSFont systemFontOfSize:11];
    f12Help.frame = NSMakeRect(22, 53, 132, 58);
    [windowsView addSubview:f12Help];

    NSTextField *f12ActionLabel = [NSTextField labelWithString:
        @"The action for the User Defined Key:"];
    f12ActionLabel.font = [NSFont systemFontOfSize:11];
    f12ActionLabel.frame = NSMakeRect(176, 166, 280, 18);
    [windowsView addSubview:f12ActionLabel];

    self.f12Summary = [NSTextField labelWithString:@""];
    self.f12Summary.font = [NSFont systemFontOfSize:12 weight:NSFontWeightSemibold];
    self.f12Summary.frame = NSMakeRect(192, 140, 264, 18);
    [windowsView addSubview:self.f12Summary];

    self.f12DetailLabel = [NSTextField labelWithString:@""];
    self.f12DetailLabel.font = [NSFont systemFontOfSize:11];
    self.f12DetailLabel.frame = NSMakeRect(176, 112, 280, 18);
    [windowsView addSubview:self.f12DetailLabel];

    self.f12DetailValue = [NSTextField labelWithString:@""];
    self.f12DetailValue.font = [NSFont systemFontOfSize:11];
    self.f12DetailValue.lineBreakMode = NSLineBreakByTruncatingMiddle;
    self.f12DetailValue.frame = NSMakeRect(192, 86, 264, 18);
    [windowsView addSubview:self.f12DetailValue];

    NSButton *modifyButton = [NSButton buttonWithTitle:@"Modify…" target:self
                                                 action:@selector(showF12Editor:)];
    modifyButton.bezelStyle = NSBezelStyleRounded;
    modifyButton.frame = NSMakeRect(370, 45, 86, 28);
    [windowsView addSubview:modifyButton];

    /* macOS-only requirements and conveniences stay out of Lenovo's page. */
    NSTabViewItem *macItem = [[NSTabViewItem alloc] initWithIdentifier:@"macos"];
    macItem.label = @"macOS Integration";
    NSView *macView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 488, 460)];
    macItem.view = macView;
    [tabs addTabViewItem:macItem];

    NSBox *deviceBox = [[NSBox alloc] initWithFrame:NSMakeRect(18, 382, 452, 58)];
    deviceBox.title = @"Device";
    [macView addSubview:deviceBox];
    self.keyboardStatus = [NSTextField labelWithString:@""];
    self.keyboardStatus.font = [NSFont systemFontOfSize:12];
    self.keyboardStatus.frame = NSMakeRect(14, 15, 424, 18);
    [deviceBox addSubview:self.keyboardStatus];

    NSBox *permissionsBox = [[NSBox alloc] initWithFrame:NSMakeRect(18, 242, 452, 128)];
    permissionsBox.title = @"macOS Permissions";
    [macView addSubview:permissionsBox];

    self.accessStatus = [NSTextField labelWithString:@""];
    self.accessStatus.font = [NSFont systemFontOfSize:12];
    self.accessStatus.frame = NSMakeRect(14, 75, 280, 18);
    [permissionsBox addSubview:self.accessStatus];
    self.accessibilityBtn = [NSButton buttonWithTitle:@"Request Access…" target:self
                                               action:@selector(requestAccessibility:)];
    self.accessibilityBtn.bezelStyle = NSBezelStyleRounded;
    self.accessibilityBtn.frame = NSMakeRect(300, 68, 136, 28);
    [permissionsBox addSubview:self.accessibilityBtn];

    self.inputStatus = [NSTextField labelWithString:@""];
    self.inputStatus.font = [NSFont systemFontOfSize:12];
    self.inputStatus.frame = NSMakeRect(14, 42, 280, 18);
    [permissionsBox addSubview:self.inputStatus];
    self.inputMonitoringBtn = [NSButton buttonWithTitle:@"Request Access…" target:self
                                                 action:@selector(requestInputMonitoring:)];
    self.inputMonitoringBtn.bezelStyle = NSBezelStyleRounded;
    self.inputMonitoringBtn.frame = NSMakeRect(300, 35, 136, 28);
    [permissionsBox addSubview:self.inputMonitoringBtn];

    NSTextField *permissionHelp = [NSTextField labelWithString:
        @"Request Access registers TrackPointD; only you can approve it in macOS."];
    permissionHelp.font = [NSFont systemFontOfSize:10];
    permissionHelp.textColor = [NSColor secondaryLabelColor];
    permissionHelp.frame = NSMakeRect(14, 13, 422, 16);
    [permissionsBox addSubview:permissionHelp];

    NSBox *keysBox = [[NSBox alloc] initWithFrame:NSMakeRect(18, 126, 452, 104)];
    keysBox.title = @"Keyboard Options";
    [macView addSubview:keysBox];

    self.fnLockCheck = [NSButton checkboxWithTitle:@"Fn Lock (F1–F12 standard keys)"
                       target:self action:@selector(toggleFnLock:)];
    self.fnLockCheck.frame = NSMakeRect(14, 58, 410, 20);
    [keysBox addSubview:self.fnLockCheck];
    self.f18Check = [NSButton checkboxWithTitle:@"Right Option → F18"
                     target:self action:@selector(toggleF18:)];
    self.f18Check.frame = NSMakeRect(14, 35, 200, 20);
    [keysBox addSubview:self.f18Check];
    self.swapCheck = [NSButton checkboxWithTitle:@"Left Option ↔ Left Command"
                      target:self action:@selector(toggleSwap:)];
    self.swapCheck.frame = NSMakeRect(224, 35, 214, 20);
    [keysBox addSubview:self.swapCheck];

    NSBox *extrasBox = [[NSBox alloc] initWithFrame:NSMakeRect(18, 56, 452, 58)];
    extrasBox.title = @"macOS TrackPoint Extras";
    [macView addSubview:extrasBox];

    NSTextField *scrollH = [NSTextField labelWithString:@"Scroll speed"];
    scrollH.font = [NSFont systemFontOfSize:11];
    scrollH.frame = NSMakeRect(14, 14, 78, 18);
    [extrasBox addSubview:scrollH];
    self.scrollSlider = [[NSSlider alloc] initWithFrame:NSMakeRect(94, 11, 282, 22)];
    self.scrollSlider.minValue = 1.0;
    self.scrollSlider.maxValue = 8.0;
    self.scrollSlider.doubleValue = s_scrollSpeed;
    self.scrollSlider.continuous = YES;
    self.scrollSlider.target = self;
    self.scrollSlider.action = @selector(scrollSliderChanged:);
    self.scrollSlider.accessibilityLabel = @"Scroll speed";
    [extrasBox addSubview:self.scrollSlider];
    self.scrollValueLabel = [NSTextField labelWithString:
        [NSString stringWithFormat:@"%.1f", s_scrollSpeed]];
    self.scrollValueLabel.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular];
    self.scrollValueLabel.alignment = NSTextAlignmentRight;
    self.scrollValueLabel.frame = NSMakeRect(382, 14, 54, 18);
    [extrasBox addSubview:self.scrollValueLabel];

    [tabs selectTabViewItem:windowsItem];
    [self syncState];
}

- (void)syncState {
    BOOL accessible = AXIsProcessTrusted();
    BOOL connected  = tp_count() > 0;
    BOOL directInput = tp_has_direct_input();
    if (accessible) s_accessibilityRequestAttempted = true;

    if (!connected) {
        self.keyboardStatus.stringValue = @"Keyboard: Disconnected";
        self.keyboardStatus.textColor = [NSColor secondaryLabelColor];
        self.keyboardStatus.toolTip = nil;
    } else if (!directInput) {
        self.keyboardStatus.stringValue = @"Keyboard: Connected — move TrackPoint to verify input";
        self.keyboardStatus.textColor = [NSColor systemOrangeColor];
        self.keyboardStatus.toolTip = @"If this remains after moving the TrackPoint, turn off Modify events for this keyboard in Karabiner-Elements → Devices, then reopen TrackPointD.";
    } else {
        self.keyboardStatus.stringValue = [NSString stringWithFormat:
            @"Keyboard: Connected (%@ sensitivity)",
            s_hardwareSensitivity ? @"hardware" : @"software fallback"];
        self.keyboardStatus.textColor = [NSColor systemGreenColor];
        self.keyboardStatus.toolTip = nil;
    }

    IOHIDAccessType inputAccess = input_monitoring_access();
    BOOL inputAllowed = inputAccess == kIOHIDAccessTypeGranted;
    self.accessStatus.stringValue = accessible ? @"Accessibility: ✓ Allowed" :
        (s_accessibilityRequestAttempted ? @"Accessibility: Not allowed" : @"Accessibility: Not requested");
    self.accessStatus.textColor = accessible
        ? [NSColor systemGreenColor] : [NSColor systemOrangeColor];
    self.inputStatus.stringValue = inputAllowed ? @"Input Monitoring: ✓ Allowed" :
        (inputAccess == kIOHIDAccessTypeDenied
            ? @"Input Monitoring: Not allowed" : @"Input Monitoring: Not requested");
    self.inputStatus.textColor = inputAllowed
        ? [NSColor systemGreenColor] : [NSColor systemOrangeColor];
    self.accessibilityBtn.title = accessible || s_accessibilityRequestAttempted
        ? @"Open Settings…" : @"Request Access…";
    self.inputMonitoringBtn.title = inputAccess == kIOHIDAccessTypeUnknown
        ? @"Request Access…" : @"Open Settings…";

    self.f18Check.state  = s_f18Enabled  ? NSControlStateValueOn : NSControlStateValueOff;
    self.swapCheck.state = s_swapEnabled ? NSControlStateValueOn : NSControlStateValueOff;
    self.fnLockCheck.state = s_fnLock ? NSControlStateValueOn : NSControlStateValueOff;
    self.preferredCheck.state = s_preferredScroll ? NSControlStateValueOn : NSControlStateValueOff;

    self.slider.integerValue = s_sensitivity;
    self.valueLabel.stringValue = [NSString stringWithFormat:@"%d / 9", s_sensitivity];

    self.scrollSlider.doubleValue = s_scrollSpeed;
    self.scrollValueLabel.stringValue = [NSString stringWithFormat:@"%.1f", s_scrollSpeed];

    [self updateF12Summary];
}

- (void)sliderChanged:(NSSlider *)slider {
    int val = (int)slider.integerValue;
    s_sensitivity = val;
    self.valueLabel.stringValue = [NSString stringWithFormat:@"%d / 9", val];
    [[NSUserDefaults standardUserDefaults] setInteger:val forKey:PREF_SENSITIVITY];
    apply_hardware_settings();
    [self syncState];
    LOG("sensitivity -> %d (%s)", val,
        s_hardwareSensitivity ? "hardware" : "software fallback");
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
    apply_key_remap();
    LOG("F18 remap: %s", s_f18Enabled ? "ON" : "OFF");
}

- (void)toggleSwap:(NSButton *)btn {
    s_swapEnabled = (btn.state == NSControlStateValueOn);
    [[NSUserDefaults standardUserDefaults] setBool:s_swapEnabled forKey:PREF_SWAP];
    apply_key_remap();
    LOG("Left Opt<->Cmd swap: %s", s_swapEnabled ? "ON" : "OFF");
}

- (void)toggleFnLock:(NSButton *)btn {
    s_fnLock = (btn.state == NSControlStateValueOn);
    [[NSUserDefaults standardUserDefaults] setBool:s_fnLock forKey:PREF_FN_LOCK];
    apply_hardware_settings();
    LOG("Fn Lock: %s", s_fnLock ? "ON" : "OFF");
}

- (void)togglePreferredScroll:(NSButton *)btn {
    s_preferredScroll = (btn.state == NSControlStateValueOn);
    [[NSUserDefaults standardUserDefaults] setBool:s_preferredScroll forKey:PREF_SCROLL];
    reset_gesture_state();
    apply_hardware_settings();
    LOG("Preferred Scrolling: %s", s_preferredScroll ? "ON" : "OFF");
}

- (void)updateF12Summary {
    NSString *summary = @"Please select";
    NSString *detailLabel = @"";
    NSString *detailValue = @"";
    NSString *toolTip = nil;

    switch (s_f12Mode) {
        case TPF12OpenFiles: {
            summary = @"Open applications or files";
            detailLabel = @"Applications or files to open:";
            NSMutableArray<NSString *> *names = [NSMutableArray array];
            for (NSString *path in s_f12Files)
                [names addObject:path.lastPathComponent.length ? path.lastPathComponent : path];
            detailValue = names.count
                ? [names componentsJoinedByString:@" · "] : @"No application or file selected";
            toolTip = s_f12Files.count ? [s_f12Files componentsJoinedByString:@"\n"] : nil;
            break;
        }
        case TPF12OpenURL:
            summary = @"Open web site";
            detailLabel = @"Web-site URL:";
            detailValue = s_f12URL ?: @"";
            toolTip = detailValue;
            break;
        case TPF12TypeText:
            summary = @"Enter text";
            detailLabel = @"Text to be entered:";
            detailValue = [s_f12Text ?: @"" stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
            toolTip = detailValue;
            break;
        case TPF12Disabled:
            break;
    }

    self.f12Summary.stringValue = summary;
    self.f12DetailLabel.stringValue = detailLabel;
    self.f12DetailValue.stringValue = detailValue;
    self.f12DetailValue.toolTip = toolTip.length ? toolTip : nil;
}

- (void)buildF12Editor {
    self.f12Panel = [[NSPanel alloc]
        initWithContentRect:NSMakeRect(0, 0, 470, 292)
        styleMask:NSWindowStyleMaskTitled
        backing:NSBackingStoreBuffered
        defer:NO];
    self.f12Panel.title = @"User Defined Key Settings";
    self.f12Panel.releasedWhenClosed = NO;
    NSView *view = self.f12Panel.contentView;

    NSTextField *instruction = [NSTextField labelWithString:
        @"Select the action for the User Defined Key (F12):"];
    instruction.font = [NSFont systemFontOfSize:12];
    instruction.frame = NSMakeRect(20, 248, 430, 18);
    [view addSubview:instruction];

    self.f12Popup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(20, 210, 430, 28)];
    [self.f12Popup addItemsWithTitles:@[@"Please select",
        @"Open applications or files", @"Open web site", @"Enter text"]];
    self.f12Popup.target = self;
    self.f12Popup.action = @selector(f12ModeChanged:);
    self.f12Popup.accessibilityLabel = @"F12 action";
    [view addSubview:self.f12Popup];

    NSBox *separator = [[NSBox alloc] initWithFrame:NSMakeRect(20, 195, 430, 1)];
    separator.boxType = NSBoxSeparator;
    [view addSubview:separator];

    self.f12EditorLabel = [NSTextField labelWithString:@""];
    self.f12EditorLabel.font = [NSFont systemFontOfSize:12];
    self.f12EditorLabel.frame = NSMakeRect(20, 164, 430, 18);
    [view addSubview:self.f12EditorLabel];

    self.f12Value = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 130, 330, 24)];
    self.f12Value.selectable = YES;
    self.f12Value.delegate = self;
    self.f12Value.target = self;
    self.f12Value.action = @selector(f12ValueChanged:);
    NSTextFieldCell *valueCell = (NSTextFieldCell *)self.f12Value.cell;
    valueCell.usesSingleLineMode = YES;
    valueCell.scrollable = YES;
    [view addSubview:self.f12Value];

    self.f12FilesTable = [[NSTableView alloc] initWithFrame:NSMakeRect(0, 0, 330, 74)];
    NSTableColumn *fileColumn = [[NSTableColumn alloc] initWithIdentifier:@"file"];
    fileColumn.width = 310;
    [self.f12FilesTable addTableColumn:fileColumn];
    self.f12FilesTable.headerView = nil;
    self.f12FilesTable.dataSource = self;
    self.f12FilesTable.delegate = self;
    self.f12FilesTable.allowsMultipleSelection = YES;
    self.f12FilesTable.accessibilityLabel = @"Applications or files to open";
    self.f12FilesScroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(20, 78, 330, 76)];
    self.f12FilesScroll.borderType = NSBezelBorder;
    self.f12FilesScroll.hasVerticalScroller = YES;
    self.f12FilesScroll.documentView = self.f12FilesTable;
    [view addSubview:self.f12FilesScroll];

    self.f12ChooseBtn = [NSButton buttonWithTitle:@"Add…" target:self
                                            action:@selector(chooseF12Files:)];
    self.f12ChooseBtn.bezelStyle = NSBezelStyleRounded;
    self.f12ChooseBtn.frame = NSMakeRect(360, 128, 90, 28);
    [view addSubview:self.f12ChooseBtn];

    self.f12RemoveBtn = [NSButton buttonWithTitle:@"Remove" target:self
                                            action:@selector(removeF12Files:)];
    self.f12RemoveBtn.bezelStyle = NSBezelStyleRounded;
    self.f12RemoveBtn.frame = NSMakeRect(360, 92, 90, 28);
    [view addSubview:self.f12RemoveBtn];

    self.f12Warning = [NSTextField wrappingLabelWithString:@""];
    self.f12Warning.font = [NSFont systemFontOfSize:11];
    self.f12Warning.frame = NSMakeRect(20, 72, 430, 44);
    [view addSubview:self.f12Warning];

    NSButton *cancel = [NSButton buttonWithTitle:@"Cancel" target:self
                                           action:@selector(cancelF12Editor:)];
    cancel.bezelStyle = NSBezelStyleRounded;
    cancel.keyEquivalent = @"\e";
    cancel.frame = NSMakeRect(270, 20, 86, 30);
    [view addSubview:cancel];

    NSButton *ok = [NSButton buttonWithTitle:@"OK" target:self
                                       action:@selector(saveF12Editor:)];
    ok.bezelStyle = NSBezelStyleRounded;
    ok.keyEquivalent = @"\r";
    ok.frame = NSMakeRect(364, 20, 86, 30);
    [view addSubview:ok];
}

- (void)showF12Editor:(id)sender {
    (void)sender;
    if (!self.f12Panel) [self buildF12Editor];
    if (self.f12Panel.sheetParent) return;

    self.f12DraftMode = s_f12Mode;
    self.f12DraftURL = [s_f12URL copy] ?: @"";
    self.f12DraftText = [s_f12Text copy] ?: @"";
    self.f12DraftFiles = [s_f12Files copy] ?: @[];
    [self.f12Popup selectItemAtIndex:self.f12DraftMode];
    [self configureF12Controls];
    [self.window beginSheet:self.f12Panel completionHandler:nil];
}

- (void)updateF12Validation {
    BOOL invalidURL = self.f12DraftMode == TPF12OpenURL &&
        self.f12Value.stringValue.length &&
        !validated_http_url(self.f12Value.stringValue);
    self.f12Value.textColor = invalidURL ? NSColor.systemRedColor : NSColor.controlTextColor;

    if (invalidURL) {
        self.f12Warning.hidden = NO;
        self.f12Warning.textColor = NSColor.systemRedColor;
        self.f12Warning.stringValue = @"Enter a valid http:// or https:// web-site URL.";
    } else if (self.f12DraftMode == TPF12TypeText) {
        self.f12Warning.hidden = NO;
        self.f12Warning.textColor = NSColor.systemOrangeColor;
        self.f12Warning.stringValue =
            @"Do not store passwords or personal information. Saved text is not encrypted.";
    } else {
        self.f12Warning.hidden = YES;
        self.f12Warning.stringValue = @"";
    }
}

- (void)configureF12Controls {
    BOOL filesMode = self.f12DraftMode == TPF12OpenFiles;
    self.f12ChooseBtn.hidden = !filesMode;
    self.f12RemoveBtn.hidden = !filesMode;
    self.f12FilesScroll.hidden = !filesMode;
    self.f12EditorLabel.hidden = self.f12DraftMode == TPF12Disabled;
    self.f12Value.hidden = self.f12DraftMode == TPF12Disabled || filesMode;
    self.f12Value.editable = YES;
    self.f12Value.toolTip = nil;
    self.f12Value.placeholderString = nil;

    switch (self.f12DraftMode) {
        case TPF12OpenFiles: {
            self.f12EditorLabel.stringValue = @"Applications or files to open:";
            [self.f12FilesTable reloadData];
            self.f12RemoveBtn.enabled = self.f12FilesTable.selectedRowIndexes.count > 0;
            break;
        }
        case TPF12OpenURL:
            self.f12EditorLabel.stringValue = @"Web-site URL:";
            self.f12Value.stringValue = self.f12DraftURL ?: @"";
            self.f12Value.placeholderString = @"https://example.com";
            break;
        case TPF12TypeText:
            self.f12EditorLabel.stringValue = @"Text to be entered:";
            self.f12Value.stringValue = self.f12DraftText ?: @"";
            self.f12Value.placeholderString = @"Text to type";
            break;
        case TPF12Disabled:
            self.f12EditorLabel.stringValue = @"";
            self.f12Value.stringValue = @"";
            break;
    }
    [self updateF12Validation];
}

- (void)f12ModeChanged:(NSPopUpButton *)sender {
    [self persistF12Value];
    self.f12DraftMode = (TPF12Mode)sender.indexOfSelectedItem;
    [self configureF12Controls];
}

- (void)persistF12Value {
    if (self.f12DraftMode == TPF12OpenURL) {
        self.f12DraftURL = self.f12Value.stringValue;
    } else if (self.f12DraftMode == TPF12TypeText) {
        self.f12DraftText = self.f12Value.stringValue;
    }
}

- (void)f12ValueChanged:(NSTextField *)sender {
    (void)sender;
    [self persistF12Value];
}

- (void)controlTextDidEndEditing:(NSNotification *)notification {
    if (notification.object == self.f12Value) [self persistF12Value];
}

- (void)controlTextDidChange:(NSNotification *)notification {
    if (notification.object == self.f12Value) {
        [self persistF12Value];
        [self updateF12Validation];
    }
}

- (void)saveF12Editor:(id)sender {
    (void)sender;
    [self persistF12Value];
    if (self.f12DraftMode == TPF12OpenURL && self.f12DraftURL.length &&
        !validated_http_url(self.f12DraftURL)) {
        NSBeep();
        [self.f12Panel makeFirstResponder:self.f12Value];
        [self updateF12Validation];
        return;
    }

    s_f12Mode = self.f12DraftMode;
    s_f12URL = [self.f12DraftURL copy] ?: @"";
    s_f12Text = [self.f12DraftText copy] ?: @"";
    s_f12Files = [self.f12DraftFiles copy] ?: @[];
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setInteger:s_f12Mode forKey:PREF_F12_MODE];
    [defaults setObject:s_f12URL forKey:PREF_F12_URL];
    [defaults setObject:s_f12Text forKey:PREF_F12_TEXT];
    [defaults setObject:s_f12Files forKey:PREF_F12_FILES];
    [self.window endSheet:self.f12Panel];
    [self updateF12Summary];
}

- (void)cancelF12Editor:(id)sender {
    (void)sender;
    [self.window endSheet:self.f12Panel];
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    (void)tableView;
    return (NSInteger)self.f12DraftFiles.count;
}

- (NSView *)tableView:(NSTableView *)tableView
   viewForTableColumn:(NSTableColumn *)tableColumn
                  row:(NSInteger)row {
    (void)tableColumn;
    NSTextField *field = [tableView makeViewWithIdentifier:@"F12File" owner:self];
    if (!field) {
        field = [NSTextField labelWithString:@""];
        field.identifier = @"F12File";
        field.lineBreakMode = NSLineBreakByTruncatingMiddle;
    }
    NSString *path = self.f12DraftFiles[(NSUInteger)row];
    field.stringValue = path.lastPathComponent.length ? path.lastPathComponent : path;
    field.toolTip = path;
    return field;
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    if (notification.object == self.f12FilesTable)
        self.f12RemoveBtn.enabled = self.f12FilesTable.selectedRowIndexes.count > 0;
}

- (void)removeF12Files:(id)sender {
    (void)sender;
    NSIndexSet *selection = self.f12FilesTable.selectedRowIndexes;
    if (!selection.count) return;
    NSMutableArray<NSString *> *files = [self.f12DraftFiles mutableCopy];
    [files removeObjectsAtIndexes:selection];
    self.f12DraftFiles = [files copy];
    [self.f12FilesTable reloadData];
    self.f12RemoveBtn.enabled = NO;
}

- (void)chooseF12Files:(id)sender {
    (void)sender;
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseFiles = YES;
    panel.canChooseDirectories = NO;
    panel.allowsMultipleSelection = YES;
    panel.message = @"Choose up to four applications or files";
    [panel beginSheetModalForWindow:self.f12Panel completionHandler:^(NSModalResponse result) {
        if (result != NSModalResponseOK) return;
        NSArray<NSURL *> *urls = panel.URLs;
        NSMutableArray<NSString *> *paths = [self.f12DraftFiles mutableCopy];
        BOOL omitted = NO;
        for (NSURL *url in urls) {
            NSString *path = url.path;
            if (!path.length || [paths containsObject:path]) continue;
            if (paths.count >= 4) {
                omitted = YES;
                continue;
            }
            [paths addObject:path];
        }
        self.f12DraftFiles = [paths copy];
        [self configureF12Controls];
        if (omitted) {
            NSAlert *alert = [NSAlert new];
            alert.messageText = @"Only the first four items were selected.";
            alert.informativeText = @"The Lenovo F12 action supports up to four files or applications.";
            [alert beginSheetModalForWindow:self.f12Panel completionHandler:nil];
        }
    }];
}

- (void)requestAccessibility:(id)sender {
    (void)sender;
    if (!AXIsProcessTrusted() && !s_accessibilityRequestAttempted) {
        s_accessibilityRequestAttempted = true;
        NSDictionary *options = @{(__bridge id)kAXTrustedCheckOptionPrompt: @YES};
        (void)AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options);
        [self syncState];
        return;
    }
    open_privacy_settings(@"Privacy_Accessibility");
}

- (void)requestInputMonitoring:(id)sender {
    (void)sender;
    if (input_monitoring_access() == kIOHIDAccessTypeUnknown) {
        (void)IOHIDRequestAccess(kIOHIDRequestTypeListenEvent);
        [self syncState];
        return;
    }
    open_privacy_settings(@"Privacy_ListenEvent");
}

@end

static void open_privacy_settings(NSString *pane) {
    NSString *base;
    if (@available(macOS 13.0, *))
        base = @"x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?";
    else
        base = @"x-apple.systempreferences:com.apple.preference.security?";
    NSString *url = [base stringByAppendingString:pane];
    NSURL *settingsURL = [NSURL URLWithString:url];
    if (settingsURL && [[NSWorkspace sharedWorkspace] openURL:settingsURL]) return;
    [[NSWorkspace sharedWorkspace] openURL:
        [NSURL URLWithString:@"x-apple.systempreferences:"]];
}

/* ══════════════════════════════════════════════════════════════
   Menu bar UI
   ══════════════════════════════════════════════════════════════ */
@interface AppDelegate : NSObject <NSApplicationDelegate>
@property (strong) NSStatusItem *statusItem;
@property (strong) NSTimer      *accessTimer;
- (void)refresh;
- (void)openSettings:(id)sender;
@end

static AppDelegate *g_app = nil;

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)n {
    g_app = self;
    g_settings = [SettingsWindowController new];
    [self buildMenu];
    /* Defer Input Monitoring's first request to the explicit settings button. */
    if (!input_monitoring_granted()) {
        LOG("Input Monitoring: not granted — waiting for user request.");
        s_imTimer = [NSTimer scheduledTimerWithTimeInterval:3.0 target:self
            selector:@selector(pollIM:) userInfo:nil repeats:YES];
    } else {
        LOG("Input Monitoring: already granted");
    }
    [self refresh];
    /* key absent = macOS default = natural scroll ON */
    NSNumber *scrollPref = [[NSUserDefaults standardUserDefaults]
        objectForKey:@"com.apple.swipescrolldirection"];
    s_naturalScroll = (scrollPref == nil) ? true : [scrollPref boolValue];
    [[[NSWorkspace sharedWorkspace] notificationCenter] addObserver:self
        selector:@selector(systemDidWake:) name:NSWorkspaceDidWakeNotification object:nil];
    if (input_monitoring_granted()) setup_hid();
    if (AXIsProcessTrusted()) try_create_event_tap();
}

- (void)systemDidWake:(NSNotification *)notification {
    (void)notification;
    reset_gesture_state();
    for (TPHIDDevice *ctx in s_tpDevices) [ctx resetAfterWake];
    NSNumber *scrollPref = [[NSUserDefaults standardUserDefaults]
        objectForKey:@"com.apple.swipescrolldirection"];
    s_naturalScroll = (scrollPref == nil) ? true : scrollPref.boolValue;
    apply_hardware_settings();
    apply_key_remap();
    [self refresh];
    LOG("settings reapplied after wake");
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    (void)notification;
    [self.accessTimer invalidate];
    [s_imTimer invalidate];
    [[[NSWorkspace sharedWorkspace] notificationCenter] removeObserver:self];
    reset_gesture_state();

    /* Reset the per-device mapping property only on this keyboard model. */
    bool oldF18 = s_f18Enabled, oldSwap = s_swapEnabled;
    s_f18Enabled = false; s_swapEnabled = false;
    apply_key_remap();
    s_f18Enabled = oldF18; s_swapEnabled = oldSwap;

    if (s_tap) CGEventTapEnable(s_tap, false);
    if (s_tapSource) {
        CFRunLoopRemoveSource(CFRunLoopGetMain(), s_tapSource, kCFRunLoopCommonModes);
        CFRelease(s_tapSource); s_tapSource = NULL;
    }
    if (s_tap) { CFRelease(s_tap); s_tap = NULL; }
    if (s_hidManager) {
        IOHIDManagerUnscheduleFromRunLoop(s_hidManager, CFRunLoopGetMain(),
                                           kCFRunLoopCommonModes);
        IOHIDManagerClose(s_hidManager, kIOHIDOptionsTypeNone);
        CFRelease(s_hidManager); s_hidManager = NULL;
    }
    [s_tpDevices removeAllObjects];
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
    BOOL inputAllowed = input_monitoring_granted();
    BOOL connected  = tp_count() > 0;
    BOOL directInput = !connected || tp_has_direct_input();

    self.statusItem.button.title = (!accessible || !inputAllowed || !directInput) ? @"TP!" :
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
    if (input_monitoring_granted()) {
        LOG("Input Monitoring: granted — starting direct device input");
        [t invalidate]; s_imTimer = nil;
        if (!s_hidManager) setup_hid();
        [self refresh];
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

static void refresh_ui(void) {
    [g_app refresh];
}

/* ══════════════════════════════════════════════════════════════
   hidutil — kernel-level key remap
   ══════════════════════════════════════════════════════════════ */
static void apply_key_remap(void) {
    if (tp_count() == 0) return;

    NSMutableArray<NSString *> *items = [NSMutableArray array];
    if (s_swapEnabled) {
        [items addObject:@"{\"HIDKeyboardModifierMappingSrc\":" HID_LEFT_OPTION
                         ",\"HIDKeyboardModifierMappingDst\":" HID_LEFT_CMD "}"];
        [items addObject:@"{\"HIDKeyboardModifierMappingSrc\":" HID_LEFT_CMD
                         ",\"HIDKeyboardModifierMappingDst\":" HID_LEFT_OPTION "}"];
    }
    if (s_f18Enabled) {
        [items addObject:@"{\"HIDKeyboardModifierMappingSrc\":" HID_RIGHT_OPTION
                         ",\"HIDKeyboardModifierMappingDst\":" HID_F18 "}"];
    }
    NSString *mapping = [NSString stringWithFormat:@"{\"UserKeyMapping\":[%@]}",
                         [items componentsJoinedByString:@","]];

    NSMutableSet<NSNumber *> *products = [NSMutableSet set];
    for (TPHIDDevice *ctx in s_tpDevices)
        [products addObject:@(device_number(ctx->device, CFSTR(kIOHIDProductIDKey)))];

    for (NSNumber *product in products) {
        NSString *match = [NSString stringWithFormat:
            @"{\"VendorID\":%d,\"ProductID\":%d}", LENOVO_VID, product.intValue];
        NSTask *task = [NSTask new];
        task.launchPath = @"/usr/bin/hidutil";
        task.arguments = @[@"property", @"--matching", match, @"--set", mapping];
        task.standardOutput = [NSFileHandle fileHandleWithNullDevice];
        task.standardError = [NSFileHandle fileHandleWithNullDevice];
        [task launch];
        [task waitUntilExit];
        LOG("hidutil pid=%04X mappings=%lu: %s", (unsigned int)product.intValue,
            (unsigned long)items.count, task.terminationStatus == 0 ? "ok" : "failed");
    }
}

static void apply_hardware_settings(void) {
    bool sensitivityApplied = false;
    for (TPHIDDevice *ctx in s_tpDevices) {
        sensitivityApplied |= send_config_command(ctx->device, 0x02,
                                                   (uint8_t)s_sensitivity);
        send_config_command(ctx->device, 0x05, s_fnLock ? 1 : 0);
        send_config_command(ctx->device, 0x09, s_preferredScroll ? 1 : 0);
    }
    s_hardwareSensitivity = sensitivityApplied;
    dispatch_async(dispatch_get_main_queue(), ^{ [g_settings syncState]; });
}

static void open_system_settings(NSString *pane) {
    NSString *url = pane.length
        ? [@"x-apple.systempreferences:" stringByAppendingString:pane]
        : @"x-apple.systempreferences:";
    NSURL *settingsURL = [NSURL URLWithString:url];
    if (settingsURL) [[NSWorkspace sharedWorkspace] openURL:settingsURL];
}

static NSURL *validated_http_url(NSString *value) {
    NSURLComponents *components = [NSURLComponents componentsWithString:value ?: @""];
    NSString *scheme = components.scheme.lowercaseString;
    if (!([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"]) ||
        components.host.length == 0)
        return nil;
    return components.URL;
}

static void type_text(NSString *text) {
    NSUInteger length = MIN((NSUInteger)1000, text.length);
    if (length == 0 || !AXIsProcessTrusted()) return;
    UniChar *characters = calloc(length, sizeof(UniChar));
    if (!characters) return;
    [text getCharacters:characters range:NSMakeRange(0, length)];
    CGEventRef down = CGEventCreateKeyboardEvent(NULL, 0, true);
    CGEventRef up = CGEventCreateKeyboardEvent(NULL, 0, false);
    if (down && up) {
        CGEventKeyboardSetUnicodeString(down, length, characters);
        CGEventKeyboardSetUnicodeString(up, length, characters);
        CGEventPost(kCGSessionEventTap, down);
        CGEventPost(kCGSessionEventTap, up);
    }
    if (down) CFRelease(down);
    if (up) CFRelease(up);
    free(characters);
}

static void run_f12_action(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        switch (s_f12Mode) {
            case TPF12OpenFiles:
                for (NSString *path in s_f12Files) {
                    if ([[NSFileManager defaultManager] fileExistsAtPath:path])
                        [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:path]];
                }
                break;
            case TPF12OpenURL: {
                NSURL *targetURL = validated_http_url(s_f12URL);
                if (targetURL) {
                    [[NSWorkspace sharedWorkspace] openURL:targetURL];
                } else {
                    NSBeep();
                    LOG("F12 URL rejected: only http/https is allowed");
                }
                break;
            }
            case TPF12TypeText:
                type_text(s_f12Text ?: @"");
                break;
            case TPF12Disabled:
                break;
        }
    });
}

static bool toggle_default_input_mute(void) {
    AudioObjectPropertyAddress defaultInput = {
        kAudioHardwarePropertyDefaultInputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    AudioDeviceID device = kAudioObjectUnknown;
    UInt32 size = sizeof(device);
    OSStatus status = AudioObjectGetPropertyData(kAudioObjectSystemObject,
        &defaultInput, 0, NULL, &size, &device);
    if (status != noErr || device == kAudioObjectUnknown) {
        LOG("default input lookup failed: %d", (int)status);
        return false;
    }

    AudioObjectPropertyAddress mute = {
        kAudioDevicePropertyMute,
        kAudioDevicePropertyScopeInput,
        kAudioObjectPropertyElementMain
    };
    Boolean settable = false;
    if (!AudioObjectHasProperty(device, &mute) ||
        AudioObjectIsPropertySettable(device, &mute, &settable) != noErr ||
        !settable) {
        LOG("default input device has no writable mute control");
        return false;
    }

    UInt32 muted = 0;
    size = sizeof(muted);
    status = AudioObjectGetPropertyData(device, &mute, 0, NULL, &size, &muted);
    if (status != noErr) {
        LOG("input mute read failed: %d", (int)status);
        return false;
    }
    muted = muted ? 0 : 1;
    status = AudioObjectSetPropertyData(device, &mute, 0, NULL,
                                        sizeof(muted), &muted);
    LOG("default input mute -> %s: %d", muted ? "ON" : "OFF", (int)status);
    return status == noErr;
}

static void show_notification_center(void) {
    if (!AXIsProcessTrusted()) return;
    const CGKeyCode nKey = 45;
    CGEventRef down = CGEventCreateKeyboardEvent(NULL, nKey, true);
    CGEventRef up = CGEventCreateKeyboardEvent(NULL, nKey, false);
    if (down && up) {
        CGEventSetFlags(down, kCGEventFlagMaskSecondaryFn);
        CGEventSetFlags(up, kCGEventFlagMaskSecondaryFn);
        CGEventPost(kCGSessionEventTap, down);
        CGEventPost(kCGSessionEventTap, up);
    }
    if (down) CFRelease(down);
    if (up) CFRelease(up);
}

static void handle_hotkey(uint16_t usage) {
    LOG("hotkey usage=0x%02X", usage);
    switch (usage) {
        case 0xB5: /* Fn-Esc */
            s_fnLock = !s_fnLock;
            [[NSUserDefaults standardUserDefaults] setBool:s_fnLock forKey:PREF_FN_LOCK];
            apply_hardware_settings();
            break;
        case 0xB6: /* Fn-F10 */
            dispatch_async(dispatch_get_main_queue(), ^{ open_system_settings(@"com.apple.BluetoothSettings"); });
            break;
        case 0xB7: /* Fn-F11 */
            dispatch_async(dispatch_get_main_queue(), ^{ [g_app openSettings:nil]; });
            break;
        case 0xB8: /* Fn-F12 */
            run_f12_action();
            break;
        case 0xB9: { /* Fn-PrtSc */
            dispatch_async(dispatch_get_main_queue(), ^{
                NSTask *task = [NSTask new];
                task.launchPath = @"/usr/sbin/screencapture";
                task.arguments = @[@"-i"];
                [task launch];
            });
            break;
        }
        case 0xBB: /* Fn-F4: microphone mute */
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!toggle_default_input_mute()) NSBeep();
            });
            break;
        case 0xBC: /* Fn-F9 */
            dispatch_async(dispatch_get_main_queue(), ^{ open_system_settings(@""); });
            break;
        case 0xC1: /* Fn-F8: Windows Action Center */
            dispatch_async(dispatch_get_main_queue(), ^{ show_notification_center(); });
            break;
        default:
            break; /* macOS already handles standard media/brightness usages. */
    }
}

static void post_middle_click(CGPoint point) {
    uint64_t now = mach_absolute_time();
    if (elapsed_ns(now, s_lastMiddleClickTime) < 100000000ULL) return;
    s_lastMiddleClickTime = now;
    CGEventRef down = CGEventCreateMouseEvent(NULL, kCGEventOtherMouseDown,
                                               point, kCGMouseButtonCenter);
    CGEventRef up = CGEventCreateMouseEvent(NULL, kCGEventOtherMouseUp,
                                             point, kCGMouseButtonCenter);
    if (down && up) {
        /* Session-level injection is downstream of our HID tap: no recursion. */
        CGEventPost(kCGSessionEventTap, down);
        CGEventPost(kCGSessionEventTap, up);
    }
    if (down) CFRelease(down);
    if (up) CFRelease(up);
}

static void reset_gesture_state(void) {
    reset_compatibility_middle();
    for (TPHIDDevice *ctx in s_tpDevices) {
        ctx->nativeMiddleDown = false;
        ctx->nativeScrolled = false;
        ctx->rawMiddleDown = false;
    }
}

static void reset_compatibility_middle(void) {
    s_middleDown = false;
    s_hasMoved = false;
    s_scrollAccumX = 0.0;
    s_scrollAccumY = 0.0;
}

typedef struct {
    bool fromTrackPoint;
    bool middleButtonDownRecent;
    bool nativeScrollRecent;
    bool nativeMiddleActive;
    bool nativeMiddleManaged;
} TPOrigin;

static uint64_t elapsed_ns(uint64_t now, uint64_t then) {
    static mach_timebase_info_data_t timebase;
    if (timebase.denom == 0) mach_timebase_info(&timebase);
    if (then == 0 || now < then) return UINT64_MAX;
    return (now - then) * timebase.numer / timebase.denom;
}

static TPOrigin poll_trackpoint_origin(void) {
    TPOrigin origin = {0};
    uint64_t now = mach_absolute_time();
    for (TPHIDDevice *ctx in s_tpDevices) {
        if (ctx->inputConfirmed &&
            elapsed_ns(now, ctx->lastPointerTime) < TP_RECENCY_NS)
            origin.fromTrackPoint = true;
        if (ctx->rawMiddleDown &&
            elapsed_ns(now, ctx->lastMiddleButtonTime) < TP_RECENCY_NS)
            origin.middleButtonDownRecent = true;
        if (elapsed_ns(now, ctx->lastNativeScrollTime) < NATIVE_DUP_NS)
            origin.nativeScrollRecent = true;
        if (ctx->nativeMiddleDown) origin.nativeMiddleActive = true;
        if (ctx->nativeMiddleDown ||
            elapsed_ns(now, ctx->lastNativeMiddleTime) < TP_RECENCY_NS)
            origin.nativeMiddleManaged = true;
    }
    return origin;
}

static CGPoint clamp_to_active_display(CGPoint point) {
    CGDirectDisplayID displays[16];
    uint32_t count = 0;
    if (CGGetActiveDisplayList(16, displays, &count) != kCGErrorSuccess || count == 0)
        return point;

    CGPoint nearest = point;
    double bestDistance = DBL_MAX;
    for (uint32_t i = 0; i < count; i++) {
        CGRect bounds = CGDisplayBounds(displays[i]);
        if (CGRectContainsPoint(bounds, point)) return point;
        CGPoint candidate = {
            MAX(CGRectGetMinX(bounds), MIN(CGRectGetMaxX(bounds) - 1, point.x)),
            MAX(CGRectGetMinY(bounds), MIN(CGRectGetMaxY(bounds) - 1, point.y)),
        };
        double dx = candidate.x - point.x, dy = candidate.y - point.y;
        double distance = dx * dx + dy * dy;
        if (distance < bestDistance) {
            bestDistance = distance;
            nearest = candidate;
        }
    }
    return nearest;
}

/* ══════════════════════════════════════════════════════════════
   Unified CGEventTap at kCGHIDEventTap
   Handles: Preferred Scrolling fallback and software sensitivity fallback
   ══════════════════════════════════════════════════════════════ */
static CGEventRef unified_callback(CGEventTapProxy proxy, CGEventType type,
                                    CGEventRef event, void *refcon) {
    (void)proxy; (void)refcon;

    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        reset_gesture_state();
        if (s_tap && tp_count() > 0) CGEventTapEnable(s_tap, true);
        LOG("event tap recovered after %s",
            type == kCGEventTapDisabledByTimeout ? "timeout" : "user disable");
        return event;
    }

    bool isMove = type == kCGEventMouseMoved || type == kCGEventLeftMouseDragged ||
                  type == kCGEventRightMouseDragged || type == kCGEventOtherMouseDragged;
    bool isOtherButton = type == kCGEventOtherMouseDown || type == kCGEventOtherMouseUp;
    TPOrigin origin = (isMove || isOtherButton)
        ? poll_trackpoint_origin() : (TPOrigin){0};

    if (isOtherButton) {
        int button = (int)CGEventGetIntegerValueField(event, kCGMouseEventButtonNumber);
        if (button == 2 && s_preferredScroll && tp_count() > 0) {
            /* Native report handling is exact-device and owns this gesture. */
            if (origin.nativeMiddleManaged) {
                reset_compatibility_middle();
                return NULL;
            }

            if (type == kCGEventOtherMouseDown) {
                if (!origin.middleButtonDownRecent) return event; /* fail closed */
                s_middleDown = true;
                s_hasMoved = false;
                s_lastPos = CGEventGetLocation(event);
                s_scrollAccumX = 0.0;
                s_scrollAccumY = 0.0;
                return NULL;
            }

            if (s_middleDown) {
                bool moved = s_hasMoved;
                CGPoint point = CGEventGetLocation(event);
                reset_gesture_state();
                if (!moved) post_middle_click(point);
                return NULL;
            }
        }
    }

    if (!isMove || tp_count() == 0) return event;

    if (s_middleDown) {
        /* Once an exact-device middle-down is consumed, own the gesture until
         * release. Passing an unattributed move would create an orphan drag. */
        if (!origin.fromTrackPoint) return NULL;
        if (origin.nativeScrollRecent) return NULL;

        /* Compatibility-mode fallback when native vendor reports are unavailable. */
        CGPoint point = CGEventGetLocation(event);
        s_scrollAccumX += point.x - s_lastPos.x;
        s_scrollAccumY += point.y - s_lastPos.y;
        s_lastPos = point;
        double absX = fabs(s_scrollAccumX), absY = fabs(s_scrollAccumY);
        if (absX > SCROLL_THRESHOLD || absY > SCROLL_THRESHOLD) {
            s_hasMoved = true;
            double x = copysign(pow(absX, 1.4) * s_scrollSpeed, s_scrollAccumX);
            double y = copysign(pow(absY, 1.4) * s_scrollSpeed, s_scrollAccumY);
            int sign = s_naturalScroll ? -1 : 1;
            CGEventRef scroll = CGEventCreateScrollWheelEvent(NULL,
                kCGScrollEventUnitPixel, 2, (int32_t)lrint(y * sign),
                (int32_t)lrint(x * sign));
            if (scroll) {
                CGEventPost(kCGSessionEventTap, scroll);
                CFRelease(scroll);
            }
            s_scrollAccumX = 0.0;
            s_scrollAccumY = 0.0;
        }
        return NULL;
    }

    if (origin.nativeMiddleActive && origin.fromTrackPoint) return NULL;

    if (!origin.fromTrackPoint) return event;

    double dx = CGEventGetDoubleValueField(event, kCGMouseEventDeltaX);
    double dy = CGEventGetDoubleValueField(event, kCGMouseEventDeltaY);
    if (dx == 0.0 && dy == 0.0) return event;

    CGPoint newPosition = CGEventGetLocation(event);
    if (!s_hardwareSensitivity) {
        double factor = sensitivity_factor();
        double scaledX = dx * factor, scaledY = dy * factor;
        newPosition.x += scaledX - dx;
        newPosition.y += scaledY - dy;
        newPosition = clamp_to_active_display(newPosition);
        CGEventSetLocation(event, newPosition);
        CGEventSetDoubleValueField(event, kCGMouseEventDeltaX, scaledX);
        CGEventSetDoubleValueField(event, kCGMouseEventDeltaY, scaledY);
    }

    return event;
}

static void set_tap_enabled(bool enabled) {
    if (s_tap) CGEventTapEnable(s_tap, enabled);
    if (!enabled) reset_gesture_state();
    LOG("ThinkPad %s — tap %s", enabled ? "connected" : "disconnected", enabled ? "ON" : "OFF");
    if (enabled) apply_key_remap();
    dispatch_async(dispatch_get_main_queue(), ^{ [g_app refresh]; });
}

static void try_create_event_tap(void) {
    if (s_tap) return;

    CGEventMask mask =
        CGEventMaskBit(kCGEventOtherMouseDown)    |
        CGEventMaskBit(kCGEventOtherMouseUp)      |
        CGEventMaskBit(kCGEventMouseMoved)        |
        CGEventMaskBit(kCGEventLeftMouseDragged)  |
        CGEventMaskBit(kCGEventRightMouseDragged) |
        CGEventMaskBit(kCGEventOtherMouseDragged);

    s_tap = CGEventTapCreate(kCGHIDEventTap, kCGHeadInsertEventTap,
                              kCGEventTapOptionDefault, mask,
                              unified_callback, NULL);
    if (!s_tap) {
        LOG("unified tap failed — accessibility permission required");
        return;
    }
    s_tapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, s_tap, 0);
    if (!s_tapSource) {
        CFRelease(s_tap); s_tap = NULL;
        LOG("event tap run-loop source creation failed");
        return;
    }
    CFRunLoopAddSource(CFRunLoopGetMain(), s_tapSource, kCFRunLoopCommonModes);
    CGEventTapEnable(s_tap, tp_count() > 0);
    LOG("unified tap created (kCGHIDEventTap) — %s",
        tp_count() > 0 ? "ON" : "waiting for ThinkPad");
    dispatch_async(dispatch_get_main_queue(), ^{ [g_app refresh]; });
}

/* ══════════════════════════════════════════════════════════════
   IOHIDManager — ThinkPad connection detection
   ══════════════════════════════════════════════════════════════ */

static void hid_added(void *ctx, IOReturn r, void *sender, IOHIDDeviceRef dev) {
    (void)ctx; (void)r; (void)sender;
    if (!is_trackpoint_keyboard_ii(dev)) return;
    for (TPHIDDevice *existing in s_tpDevices)
        if (existing->device == dev) return;

    TPHIDDevice *deviceContext = [[TPHIDDevice alloc] initWithDevice:dev];
    [s_tpDevices addObject:deviceContext];
    apply_hardware_settings();
    LOG("TrackPoint Keyboard II connected pid=%04X",
        (unsigned int)device_number(dev, CFSTR(kIOHIDProductIDKey)));
    set_tap_enabled(true);
}

static void hid_removed(void *ctx, IOReturn r, void *sender, IOHIDDeviceRef dev) {
    (void)ctx; (void)r; (void)sender;
    NSUInteger index = [s_tpDevices indexOfObjectPassingTest:
        ^BOOL(TPHIDDevice *candidate, NSUInteger idx, BOOL *stop) {
            (void)idx; (void)stop;
            return candidate->device == dev;
    }];
    if (index == NSNotFound) return;
    [s_tpDevices removeObjectAtIndex:index];
    reset_gesture_state();
    s_hardwareSensitivity = false;
    if (tp_count() > 0) apply_hardware_settings();
    set_tap_enabled(tp_count() > 0);
    LOG("TrackPoint Keyboard II disconnected");
}

static void setup_hid(void) {
    s_tpDevices = [NSMutableArray array];
    s_hidManager = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
    NSArray *matches = @[
        @{@kIOHIDVendorIDKey: @(LENOVO_VID), @kIOHIDProductIDKey: @(TP_USB_PID)},
        @{@kIOHIDVendorIDKey: @(LENOVO_VID), @kIOHIDProductIDKey: @(TP_BLE_PID)},
    ];
    IOHIDManagerSetDeviceMatchingMultiple(s_hidManager, (__bridge CFArrayRef)matches);
    NSArray *inputMatches = @[
        @{@kIOHIDElementUsagePageKey: @(kHIDPage_GenericDesktop),
          @kIOHIDElementUsageKey: @(kHIDUsage_GD_X)},
        @{@kIOHIDElementUsagePageKey: @(kHIDPage_GenericDesktop),
          @kIOHIDElementUsageKey: @(kHIDUsage_GD_Y)},
        @{@kIOHIDElementUsagePageKey: @(kHIDPage_Button)},
        @{@kIOHIDElementUsagePageKey: @0xFFA0,
          @kIOHIDElementUsageKey: @0xFB},
    ];
    IOHIDManagerSetInputValueMatchingMultiple(s_hidManager,
                                               (__bridge CFArrayRef)inputMatches);
    IOHIDManagerRegisterDeviceMatchingCallback(s_hidManager, hid_added, NULL);
    IOHIDManagerRegisterDeviceRemovalCallback(s_hidManager, hid_removed, NULL);
    IOHIDManagerRegisterInputReportCallback(s_hidManager, hid_report, NULL);
    IOHIDManagerRegisterInputValueCallback(s_hidManager, hid_value, NULL);
    IOHIDManagerScheduleWithRunLoop(s_hidManager, CFRunLoopGetMain(),
                                     kCFRunLoopCommonModes);
    IOReturn result = IOHIDManagerOpen(s_hidManager, kIOHIDOptionsTypeNone);
    LOG("HID manager direct callbacks: 0x%08X", (unsigned int)result);
}

/* ══════════════════════════════════════════════════════════════
   main
   ══════════════════════════════════════════════════════════════ */
static int run_self_test(void) {
    TPReportSpec spec;
    uint8_t report[8];
    CFIndex length = 0;

    assert(build_config_report(TP_USB_PID, 0x02, 5, &spec, report, &length));
    assert(spec.type == kIOHIDReportTypeFeature && spec.reportID == 0x13);
    assert(length == 8 && report[0] == 0x13 && report[1] == 0x02 && report[2] == 5);
    for (CFIndex i = 3; i < length; i++) assert(report[i] == 0);

    assert(build_config_report(TP_BLE_PID, 0x09, 1, &spec, report, &length));
    assert(spec.type == kIOHIDReportTypeOutput && spec.reportID == 0x18);
    assert(length == 3 && report[0] == 0x18 && report[1] == 0x09 && report[2] == 1);
    assert(!build_config_report(0x1234, 0x02, 5, &spec, report, &length));

    int8_t horizontal = 0, vertical = 0;
    uint8_t wheelWithID[] = {0x16, 0xFE, 0x03};
    assert(decode_wheel_report(0x16, wheelWithID, 3, &horizontal, &vertical));
    assert(horizontal == -2 && vertical == 3);
    uint8_t usbWheel[] = {0x16, 0x7F, 0x80};
    assert(decode_wheel_report(0x16, usbWheel, 3, &horizontal, &vertical));
    assert(horizontal == 127 && vertical == -128);
    uint8_t wheelWithoutID[] = {0x16, 0xFF};
    assert(!decode_wheel_report(0x16, wheelWithoutID, 2, &horizontal, &vertical));
    uint8_t wheelWrongID[] = {0x22, 0x01, 0x02};
    assert(!decode_wheel_report(0x22, wheelWrongID, 3, &horizontal, &vertical));
    uint8_t wheelShort[] = {0x16, 0x01};
    assert(!decode_wheel_report(0x16, wheelShort, 2, &horizontal, &vertical));

    uint16_t hotkey = 0;
    uint8_t usbHotkey[] = {0x05, 0xB8};
    assert(decode_hotkey_report(TP_USB_PID, 0x05, usbHotkey, 2, &hotkey));
    assert(hotkey == 0xB8);
    uint8_t bleHotkey[] = {0x05, 0xB8, 0x00};
    assert(decode_hotkey_report(TP_BLE_PID, 0x05, bleHotkey, 3, &hotkey));
    assert(hotkey == 0xB8);
    assert(!decode_hotkey_report(TP_USB_PID, 0x05, bleHotkey, 3, &hotkey));
    assert(!decode_hotkey_report(TP_BLE_PID, 0x05, usbHotkey, 2, &hotkey));
    assert(!decode_hotkey_report(0x1234, 0x05, usbHotkey, 2, &hotkey));

    bool middleDown = false;
    uint8_t middleWithID[] = {0x15, 0x00, 0x04, 0, 0, 0, 0, 0, 0};
    assert(decode_middle_report(0x15, middleWithID, 9, &middleDown) && middleDown);
    uint8_t middleUp[] = {0x15, 0, 0, 0, 0, 0, 0, 0, 0};
    assert(decode_middle_report(0x15, middleUp, 9, &middleDown) && !middleDown);
    uint8_t notMiddle[] = {0x15, 0x05, 0, 0, 0, 0, 0, 0, 0};
    assert(decode_middle_report(0x15, notMiddle, 9, &middleDown) && !middleDown);
    uint8_t middleWithoutID[] = {0, 0x04, 0, 0, 0, 0, 0, 0};
    assert(!decode_middle_report(0x15, middleWithoutID, 8, &middleDown));

    puts("trackpointd self-test: ok");
    return 0;
}

int main(int argc, const char *argv[]) {
    if (argc == 2 && strcmp(argv[1], "--self-test") == 0) return run_self_test();
    freopen("/tmp/trackpointd.log", "a", stderr);
    setvbuf(stderr, NULL, _IONBF, 0);

    @autoreleasepool {
        NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
        [ud registerDefaults:@{
            PREF_SENSITIVITY: @(TP_SENSITIVITY_DEFAULT),
            PREF_F18: @YES,
            PREF_SWAP: @YES,
            PREF_SCROLL_SPEED: @(SCROLL_SPEED),
            PREF_SCROLL: @YES,
            PREF_FN_LOCK: @NO,
            PREF_F12_MODE: @(TPF12OpenURL),
            PREF_F12_URL: @"https://support.lenovo.com/accessories/trackpoint_keyboard",
            PREF_F12_TEXT: @"",
            PREF_F12_FILES: @[],
        }];
        s_sensitivity = (int)MAX(1, MIN(9, [ud integerForKey:PREF_SENSITIVITY]));
        s_f18Enabled = [ud boolForKey:PREF_F18];
        s_swapEnabled = [ud boolForKey:PREF_SWAP];
        s_scrollSpeed = MAX(1.0, MIN(8.0, [ud doubleForKey:PREF_SCROLL_SPEED]));
        s_preferredScroll = [ud boolForKey:PREF_SCROLL];
        s_fnLock = [ud boolForKey:PREF_FN_LOCK];
        s_f12Mode = (TPF12Mode)MAX(TPF12Disabled,
            MIN(TPF12TypeText, [ud integerForKey:PREF_F12_MODE]));
        if ([[ud objectForKey:PREF_F12_URL] isKindOfClass:NSString.class])
            s_f12URL = [ud stringForKey:PREF_F12_URL];
        if ([[ud objectForKey:PREF_F12_TEXT] isKindOfClass:NSString.class])
            s_f12Text = [ud stringForKey:PREF_F12_TEXT];
        NSArray *storedFiles = [ud arrayForKey:PREF_F12_FILES];
        if (storedFiles) {
            NSMutableArray<NSString *> *validFiles = [NSMutableArray array];
            for (id path in storedFiles)
                if ([path isKindOfClass:NSString.class] && validFiles.count < 4)
                    [validFiles addObject:path];
            s_f12Files = [validFiles copy];
        }

        LOG("prefs: sensitivity=%d scroll=%.1f preferred=%s fnLock=%s f18=%s swap=%s",
            s_sensitivity, s_scrollSpeed, s_preferredScroll ? "on" : "off",
            s_fnLock ? "on" : "off", s_f18Enabled ? "on" : "off",
            s_swapEnabled ? "on" : "off");

        NSApplication *app = [NSApplication sharedApplication];
        app.activationPolicy = NSApplicationActivationPolicyAccessory;
        AppDelegate *delegate = [AppDelegate new];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
