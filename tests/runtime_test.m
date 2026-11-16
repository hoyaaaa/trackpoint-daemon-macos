/* Exercise real daemon paths against in-process substitutes, never the user's devices. */
#import <Cocoa/Cocoa.h>
#import <objc/runtime.h>
#import <ApplicationServices/ApplicationServices.h>
#import <CoreAudio/CoreAudio.h>
#import <IOKit/hid/IOHIDManager.h>
#import <IOKit/hid/IOHIDKeys.h>
#import <IOKit/hidsystem/IOHIDLib.h>

static BOOL guideVisible;
static NSMutableArray *events, *reports, *tasks, *urls;
static BOOL trusted = YES, writableMute = YES, hasMute = YES;
static int beeps, uiRefreshes, openedSettings, failedPID;
static OSStatus defaultStatus, muteReadStatus, muteWriteStatus, settableStatus;
static AudioDeviceID inputDevice = 42;
static UInt32 muted, writtenMute;
static IOHIDAccessType accessState = kIOHIDAccessTypeGranted;
static BOOL tapEnabled;
static CFStringRef prop(IOHIDDeviceRef dev, CFStringRef key) {
    return dev ? CFDictionaryGetValue((CFDictionaryRef)dev, key) : NULL;
}
static IOReturn set_report(IOHIDDeviceRef dev, IOHIDReportType type, CFIndex rid,
                           const uint8_t *bytes, CFIndex length) {
    int pid = [((__bridge NSDictionary *)dev)[@kIOHIDProductIDKey] intValue];
    [reports addObject:@{@"pid":@(pid), @"type":@(type), @"id":@(rid),
                         @"bytes":[NSData dataWithBytes:bytes length:length]}];
    return pid == failedPID || [((__bridge NSDictionary *)dev)[@"rejectConfig"] boolValue]
        ? kIOReturnError : kIOReturnSuccess;
}
static CFArrayRef config_elements(IOHIDDeviceRef dev,CFDictionaryRef matching,IOOptionBits options) {
    assert(options==kIOHIDOptionsTypeNone);
    NSDictionary *properties=(__bridge NSDictionary *)dev;
    NSDictionary *match=(__bridge NSDictionary *)matching;
    int pid=[properties[@kIOHIDProductIDKey] intValue];
    int reportID=[match[@kIOHIDElementReportIDKey] intValue];
    int type=[match[@kIOHIDElementTypeKey] intValue];
    assert((pid==0x60EE && reportID==0x13 && type==kIOHIDElementTypeFeature) ||
           (pid==0x60E1 && reportID==0x18 && type==kIOHIDElementTypeOutput));
    if ([properties[@"elementsUnavailable"] boolValue]) return NULL;
    if (properties[@"reportCapabilities"]) {
        NSMutableArray *matches=[NSMutableArray array];
        for (NSDictionary *capability in properties[@"reportCapabilities"])
            if ([capability[@kIOHIDElementReportIDKey] intValue]==reportID &&
                [capability[@kIOHIDElementTypeKey] intValue]==type)
                [matches addObject:capability];
        return (__bridge_retained CFArrayRef)matches;
    }
    bool supported=![properties[@"rejectConfig"] boolValue];
    return (__bridge_retained CFArrayRef)(supported ? @[@YES] : @[]);
}
static void post(CGEventTapLocation tap, CGEventRef event) {
    assert(tap == kCGSessionEventTap);
    UniChar text[1001]; UniCharCount length = 0;
    CGEventKeyboardGetUnicodeString(event, 1000, &length, text);
    [events addObject:@{@"type":@(CGEventGetType(event)),
        @"flags":@(CGEventGetFlags(event)),
        @"key":@(CGEventGetIntegerValueField(event,kCGKeyboardEventKeycode)),
        @"x":@(CGEventGetIntegerValueField(event,kCGScrollWheelEventPointDeltaAxis2)),
        @"y":@(CGEventGetIntegerValueField(event,kCGScrollWheelEventPointDeltaAxis1)),
        @"text":[NSString stringWithCharacters:text length:length]}];
}
static OSStatus audio_read(AudioObjectID obj, const AudioObjectPropertyAddress *addr,
        UInt32 qualifierSize, const void *qualifier, UInt32 *size, void *out) {
    (void)obj; (void)qualifierSize; (void)qualifier; (void)size;
    if (addr->mSelector == kAudioHardwarePropertyDefaultInputDevice) {
        *(AudioDeviceID *)out = inputDevice; return defaultStatus;
    }
    assert(addr->mSelector == kAudioDevicePropertyMute);
    *(UInt32 *)out = muted; return muteReadStatus;
}
static Boolean audio_has(AudioObjectID obj, const AudioObjectPropertyAddress *addr) {
    (void)obj; assert(addr->mSelector == kAudioDevicePropertyMute); return hasMute;
}
static OSStatus audio_settable(AudioObjectID obj,const AudioObjectPropertyAddress *addr,Boolean *out) {
    (void)obj; (void)addr; *out = writableMute; return settableStatus;
}
static OSStatus audio_write(AudioObjectID obj,const AudioObjectPropertyAddress *addr,
        UInt32 qs,const void *q,UInt32 size,const void *value) {
    (void)obj; (void)qs; (void)q;
    assert(addr->mSelector == kAudioDevicePropertyMute && size == sizeof(UInt32));
    writtenMute = *(const UInt32 *)value; return muteWriteStatus;
}
static bool ax_trusted(void) { return trusted; }
static Boolean ax_request(CFDictionaryRef options) { assert(options); return trusted; }
static IOHIDAccessType hid_access(IOHIDRequestType type) { (void)type; return accessState; }
static bool hid_request(IOHIDRequestType type) { (void)type; return accessState == kIOHIDAccessTypeGranted; }
static void async_now(dispatch_queue_t queue, dispatch_block_t block) { (void)queue; block(); }
static void beep(void) { beeps++; }
static void enable_tap(CFMachPortRef tap, bool enabled) { assert(tap); tapEnabled = enabled; }
static CGError test_display_list(uint32_t max,CGDirectDisplayID *ids,uint32_t *count) {
    assert(max); ids[0] = 1; ids[1] = 2; *count = 2; return kCGErrorSuccess;
}
static CGRect test_display_bounds(CGDirectDisplayID display) {
    return display == 1 ? CGRectMake(0,0,1920,1080) : CGRectMake(-1280,0,1280,720);
}
static IOHIDElementRef value_element(IOHIDValueRef value) { return (IOHIDElementRef)value; }
static IOHIDDeviceRef element_device(IOHIDElementRef element) {
    return (__bridge IOHIDDeviceRef)((__bridge NSDictionary *)element)[@"device"];
}
static uint32_t element_page(IOHIDElementRef e) { return [((__bridge NSDictionary *)e)[@"page"] unsignedIntValue]; }
static uint32_t element_usage(IOHIDElementRef e) { return [((__bridge NSDictionary *)e)[@"usage"] unsignedIntValue]; }
static CFIndex value_integer(IOHIDValueRef v) { return [((__bridge NSDictionary *)v)[@"value"] integerValue]; }

@interface TestDefaults : NSUserDefaults
+ (instancetype)standardUserDefaults;
@end
static NSString *suite;
@implementation TestDefaults
+ (instancetype)standardUserDefaults {
    static TestDefaults *instance;
    if (!instance) {
        suite = [@"trackpointd.tests." stringByAppendingString:NSUUID.UUID.UUIDString];
        instance = [[self alloc] initWithSuiteName:suite];
    }
    return instance;
}
@end
@interface TestTask : NSObject
@property(copy) NSString *launchPath;
@property(copy) NSArray *arguments;
@property(strong) id standardOutput;
@property(strong) id standardError;
@property int terminationStatus;
@property BOOL running;
@property(strong) id standardInput;
- (BOOL)launchAndReturnError:(NSError **)error;
- (void)launch;
- (void)waitUntilExit;
@end
@implementation TestTask
- (void)launch {
    assert(([@[@"/usr/bin/hidutil",@"/usr/sbin/screencapture"] containsObject:self.launchPath]));
    [tasks addObject:@{@"path":self.launchPath,@"args":self.arguments}];
}
- (void)waitUntilExit {}
- (BOOL)launchAndReturnError:(NSError **)error { (void)error; assert(!"Unexpected real upgrade task in runtime tests"); return NO; }
@end
@interface TestWorkspace : NSObject
+ (instancetype)sharedWorkspace;
- (BOOL)openURL:(NSURL *)url;
@property(readonly) NSRunningApplication *frontmostApplication;
- (void)activateFileViewerSelectingURLs:(NSArray *)urls;
- (NSNotificationCenter *)notificationCenter;
@end
@implementation TestWorkspace
+ (instancetype)sharedWorkspace { static TestWorkspace *w; if (!w) w=[self new]; return w; }
- (BOOL)openURL:(NSURL *)url { assert(url); [urls addObject:url.absoluteString]; return YES; }
- (NSNotificationCenter *)notificationCenter { return [NSNotificationCenter new]; }
- (NSRunningApplication *)frontmostApplication { return nil; }
- (void)activateFileViewerSelectingURLs:(NSArray *)files { [urls addObjectsFromArray:files]; }
@end

static NSArray<NSURL *> *selectedFiles;
static NSModalResponse panelResponse=NSModalResponseOK;
static int limitWarnings;
static NSModalResponse updateChoice=NSAlertThirdButtonReturn;
static NSString *alertTitle, *alertText, *copiedCommand;
static NSView *alertAccessory;
static int downloadCount;
static void (^pendingDownload)(NSData *,NSURLResponse *,NSError *);
@interface TestOpenPanel : NSObject
@property BOOL canChooseFiles, canChooseDirectories, allowsMultipleSelection;
@property(copy) NSString *message;
@property(copy) NSArray<NSURL *> *URLs;
+ (instancetype)openPanel;
- (void)beginSheetModalForWindow:(NSWindow *)window completionHandler:(void (^)(NSModalResponse))handler;
@end
@implementation TestOpenPanel
+ (instancetype)openPanel { TestOpenPanel *p=[self new]; p.URLs=selectedFiles; return p; }
- (void)beginSheetModalForWindow:(NSWindow *)window completionHandler:(void (^)(NSModalResponse))handler {
    (void)window; assert(self.canChooseFiles && !self.canChooseDirectories && self.allowsMultipleSelection);
    handler(panelResponse);
}
@end
@interface TestAlert : NSObject
@property(copy) NSString *messageText, *informativeText;
@property(strong) NSView *accessoryView;
- (NSButton *)addButtonWithTitle:(NSString *)title;
- (NSModalResponse)runModal;
- (void)beginSheetModalForWindow:(NSWindow *)window completionHandler:(void (^)(NSModalResponse))handler;
@end
@implementation TestAlert
- (NSButton *)addButtonWithTitle:(NSString *)title { return [NSButton buttonWithTitle:title target:nil action:NULL]; }
- (NSModalResponse)runModal { alertTitle=self.messageText; alertText=self.informativeText; alertAccessory=self.accessoryView; return updateChoice; }
- (void)beginSheetModalForWindow:(NSWindow *)window completionHandler:(void (^)(NSModalResponse))handler {
    (void)window; (void)handler; limitWarnings++;
}
@end
@interface TestDownload : NSObject
- (void)resume;
@end
@implementation TestDownload
- (void)resume {}
@end
@interface TestSession : NSObject
+ (instancetype)sharedSession;
- (TestDownload *)dataTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSData *,NSURLResponse *,NSError *))handler;
@end
@implementation TestSession
+ (instancetype)sharedSession { static TestSession *s; if (!s) s=[self new]; return s; }
- (TestDownload *)dataTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSData *,NSURLResponse *,NSError *))handler {
    assert([request.URL.absoluteString isEqual:@"https://api.github.com/repos/hoyaaaa/trackpoint-daemon-macos/releases/latest"]);
    assert(request.timeoutInterval==15 && [request valueForHTTPHeaderField:@"User-Agent"]);
    pendingDownload=[handler copy]; downloadCount++; return [TestDownload new];
}
@end
@interface TestPasteboard : NSObject
+ (instancetype)generalPasteboard;
- (NSInteger)clearContents;
- (BOOL)setString:(NSString *)text forType:(NSPasteboardType)type;
@end
@implementation TestPasteboard
+ (instancetype)generalPasteboard { static TestPasteboard *p; if (!p) p=[self new]; return p; }
- (NSInteger)clearContents { copiedCommand=nil; return 0; }
- (BOOL)setString:(NSString *)text forType:(NSPasteboardType)type { assert([type isEqual:NSPasteboardTypeString]); copiedCommand=[text copy]; return YES; }
@end
#define NSURLSession TestSession
#define NSPasteboard TestPasteboard
#define NSOpenPanel TestOpenPanel
#define NSAlert TestAlert
static NSMutableArray *managerCalls;
static BOOL failTap, failTapSource;
static CFMutableDictionaryRef fake_cf(void) {
    return CFDictionaryCreateMutable(NULL,0,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);
}
static IOHIDManagerRef manager_create(void) {
    managerCalls=[NSMutableArray arrayWithObject:@"create"];
    return (IOHIDManagerRef)fake_cf();
}
static void manager_match(CFArrayRef array) {
    NSArray *matches=(__bridge NSArray *)array;
    assert(matches.count==3);
    NSMutableSet *pids=[NSMutableSet set];
    for(NSDictionary *match in matches) {
        assert([match[@kIOHIDVendorIDKey] intValue]==0x17EF);
        [pids addObject:match[@kIOHIDProductIDKey]];
    }
    assert(([pids isEqual:[NSSet setWithArray:@[@(0x60EE),@(0x60E1),@(0x6048)]]]));
    [managerCalls addObject:@"matching"];
}
static IOReturn manager_open(void) {
    assert(([managerCalls isEqual:@[@"create",@"matching",@"values",@"attach",@"detach",@"reports",@"input",@"schedule"]]));
    [managerCalls addObject:@"open"]; return kIOReturnSuccess;
}
static CFMachPortRef tap_create(CGEventTapLocation location,CGEventTapOptions options,CGEventMask mask) {
    assert(location==kCGHIDEventTap && options==kCGEventTapOptionDefault);
    assert(mask & CGEventMaskBit(kCGEventOtherMouseDragged));
    return failTap ? NULL : (CFMachPortRef)fake_cf();
}
static CFRunLoopSourceRef tap_source(void) { return failTapSource ? NULL : (CFRunLoopSourceRef)fake_cf(); }
#define IOHIDManagerCreate(a,o) manager_create()
#define IOHIDManagerSetDeviceMatchingMultiple(m,a) manager_match(a)
#define IOHIDManagerSetInputValueMatchingMultiple(m,a) [managerCalls addObject:@"values"]
#define IOHIDManagerRegisterDeviceMatchingCallback(m,c,x) do { assert((c)==hid_added); [managerCalls addObject:@"attach"]; } while (0)
#define IOHIDManagerRegisterDeviceRemovalCallback(m,c,x) do { assert((c)==hid_removed); [managerCalls addObject:@"detach"]; } while (0)
#define IOHIDManagerRegisterInputReportCallback(m,c,x) do { assert((c)==hid_report); [managerCalls addObject:@"reports"]; } while (0)
#define IOHIDManagerRegisterInputValueCallback(m,c,x) do { assert((c)==hid_value); [managerCalls addObject:@"input"]; } while (0)
#define IOHIDManagerScheduleWithRunLoop(m,r,mode) [managerCalls addObject:@"schedule"]
#define IOHIDManagerOpen(m,o) manager_open()
#define IOHIDManagerUnscheduleFromRunLoop(m,r,mode) [managerCalls addObject:@"unschedule"]
#define IOHIDManagerClose(m,o) ([managerCalls addObject:@"close"], kIOReturnSuccess)
#define CGEventTapCreate(t,p,o,m,c,r) tap_create(t,o,m)
#define CFMachPortCreateRunLoopSource(a,t,o) tap_source()
#define CFRunLoopAddSource(r,s,m) ((void)0)
#define CFRunLoopRemoveSource(r,s,m) ((void)0)
#define IOHIDDeviceGetProperty prop
static NSArray *permissionWindows, *permissionApps;
@interface TestRunningApp : NSObject
@property pid_t processIdentifier;
+ (NSArray *)runningApplicationsWithBundleIdentifier:(NSString *)identifier;
@end
@implementation TestRunningApp
+ (NSArray *)runningApplicationsWithBundleIdentifier:(NSString *)identifier {
    assert([identifier isEqualToString:@"com.apple.systempreferences"]);
    return permissionApps;
}
@end
static CFArrayRef permission_windows(CGWindowListOption options, CGWindowID window) {
    assert(options==kCGWindowListOptionAll && window==kCGNullWindowID);
    return (__bridge_retained CFArrayRef)(permissionWindows ?: @[]);
}
#define NSRunningApplication TestRunningApp
#define CGWindowListCopyWindowInfo permission_windows
#define IOHIDDeviceSetReport set_report
#define IOHIDDeviceCopyMatchingElements config_elements
#define IOHIDValueGetElement value_element
#define IOHIDElementGetDevice element_device
#define IOHIDElementGetUsagePage element_page
#define IOHIDElementGetUsage element_usage
#define IOHIDValueGetIntegerValue value_integer
#define CGEventPost post
#define CGEventTapEnable enable_tap
#define CGGetActiveDisplayList test_display_list
#define CGDisplayBounds test_display_bounds
#define AXIsProcessTrusted ax_trusted
#define AXIsProcessTrustedWithOptions ax_request
#define IOHIDCheckAccess hid_access
#define IOHIDRequestAccess hid_request
#define AudioObjectGetPropertyData audio_read
#define AudioObjectHasProperty audio_has
#define AudioObjectIsPropertySettable audio_settable
#define AudioObjectSetPropertyData audio_write
#define dispatch_async async_now
#define NSBeep beep
#define NSUserDefaults TestDefaults
#define NSTask TestTask
#define NSWorkspace TestWorkspace
#define main daemon_main
#import "../trackpointd.m"
#undef main

/* Avoid permission polling and visible windows while exercising controller actions. */
@interface QuietSettings : SettingsWindowController
@end
@implementation QuietSettings
- (void)syncState {}
@end
@interface QuietApp : AppDelegate
@end
@implementation QuietApp
- (void)refresh { uiRefreshes++; }
- (void)openSettings:(id)sender { (void)sender; openedSettings++; }
@end
static TPHIDDevice *make_device(int pid) {
    NSDictionary *properties = @{@kIOHIDVendorIDKey:@(LENOVO_VID),@kIOHIDProductIDKey:@(pid)};
    return [[TPHIDDevice alloc] initWithDevice:(__bridge IOHIDDeviceRef)properties];
}
static void clear(void) {
    events = [NSMutableArray array]; reports = [NSMutableArray array];
    tasks = [NSMutableArray array]; urls = [NSMutableArray array];
    s_tpDevices = [NSMutableArray array];
    s_enabled = s_preferredScroll = trusted = YES;
    s_naturalScroll = NO; s_scrollSpeed = 3; s_sensitivity = 5;
    s_swapEnabled = s_f18Enabled = YES; s_fnLock = s_blockMiddle = NO;
    s_lastMiddleClickTime = 0; failedPID = beeps = 0;
    reset_gesture_state();
}
static void report(TPHIDDevice *dev,uint32_t rid,uint8_t *data,CFIndex length) {
    hid_report(NULL,kIOReturnSuccess,(void *)dev->device,kIOHIDReportTypeInput,rid,data,length);
}
static void value(TPHIDDevice *dev,int page,int usage,int number) {
    NSDictionary *v = @{@"device": (__bridge id)dev->device,@"page":@(page),@"usage":@(usage),@"value":@(number)};
    hid_value(NULL,kIOReturnSuccess,NULL,(__bridge IOHIDValueRef)v);
}
/* hidutil accepts hex integer literals, which Foundation's strict JSON parser does not. */
static NSDictionary *hid_json(NSString *input) {
    NSMutableString *json=[input mutableCopy];
    NSRegularExpression *hex=[NSRegularExpression regularExpressionWithPattern:@"0x[0-9a-fA-F]+" options:0 error:NULL];
    NSArray *matches=[hex matchesInString:input options:0 range:NSMakeRange(0,input.length)];
    for (NSTextCheckingResult *match in matches.reverseObjectEnumerator) {
        unsigned long long number=0;
        assert([[NSScanner scannerWithString:[input substringWithRange:match.range]] scanHexLongLong:&number]);
        [json replaceCharactersInRange:match.range withString:[NSString stringWithFormat:@"%llu",number]];
    }
    NSDictionary *result=[NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL];
    assert(result); return result;
}
static void test_devices_and_settings(void) {
    clear();
    TPHIDDevice *usb=make_device(TP_USB_PID), *ble=make_device(TP_BLE_PID), *compact=make_device(TP_COMPACT_PID);
    assert(is_trackpoint_keyboard_ii(usb->device) && is_trackpoint_keyboard_ii(ble->device));
    assert(is_trackpoint_keyboard_ii(compact->device));
    TPHIDDevice *other=make_device(1234); assert(!is_trackpoint_keyboard_ii(other->device));
    [s_tpDevices addObjectsFromArray:@[usb,ble,compact]];
    s_sensitivity=9; s_fnLock=YES;
    apply_hardware_settings();
    assert(reports.count==6 && usb->hardwareSensitivityApplied && ble->hardwareSensitivityApplied);
    assert(!compact->hardwareSensitivityApplied);
    const uint8_t *bytes = [reports[0][@"bytes"] bytes];
    assert(bytes[1]==2 && bytes[2]==9);
    assert(!send_config_command(compact->device,2,5)); assert(reports.count==6);
    [s_tpDevices removeObject:compact]; [reports removeAllObjects];
    apply_hardware_settings(); assert(usb->hardwareSensitivityApplied && ble->hardwareSensitivityApplied);
    failedPID=TP_BLE_PID; apply_hardware_settings();
    assert(usb->hardwareSensitivityApplied && !ble->hardwareSensitivityApplied);
    [reports removeAllObjects]; s_enabled=NO;
    apply_hardware_settings(); assert(reports.count==0);

    s_enabled=YES; s_swapEnabled=s_f18Enabled=YES;
    [s_tpDevices addObject:compact];
    apply_key_remap(); assert(tasks.count==2);
    for (NSDictionary *task in tasks) {
        NSArray *args=task[@"args"];
        assert([args[1] isEqual:@"--matching"] && [args[3] isEqual:@"--set"]);
        NSDictionary *match=hid_json(args[2]);
        assert([match[@"VendorID"] intValue]==LENOVO_VID);
        assert([match[@"ProductID"] intValue]!=TP_COMPACT_PID);
        NSDictionary *mapping=hid_json(args[4]);
        assert([mapping[@"UserKeyMapping"] count]==3);
    }
    for(int enabled=0;enabled<=1;enabled++) for(int swap=0;swap<=1;swap++) for(int f18=0;f18<=1;f18++) {
        [tasks removeAllObjects]; s_enabled=enabled; s_swapEnabled=swap; s_f18Enabled=f18;
        apply_key_remap();
        for(NSDictionary *task in tasks) {
            NSDictionary *map=hid_json(task[@"args"][4]);
            assert([map[@"UserKeyMapping"] count]==(enabled ? 2*swap+f18 : 0));
            NSMutableDictionary *pairs=[NSMutableDictionary dictionary];
            for(NSDictionary *pair in map[@"UserKeyMapping"])
                pairs[pair[@"HIDKeyboardModifierMappingSrc"]]=pair[@"HIDKeyboardModifierMappingDst"];
            assert(([pairs[@(0x7000000E2ULL)] unsignedLongLongValue]==(enabled && swap ? 0x7000000E3ULL : 0)));
            assert(([pairs[@(0x7000000E3ULL)] unsignedLongLongValue]==(enabled && swap ? 0x7000000E2ULL : 0)));
            assert(([pairs[@(0x7000000E6ULL)] unsignedLongLongValue]==(enabled && f18 ? 0x70000006DULL : 0)));
        }
    }
    [s_tpDevices removeAllObjects]; [tasks removeAllObjects]; apply_key_remap(); assert(tasks.count==0);
}
static void test_hid_input(void) {
    clear(); TPHIDDevice *usb=make_device(TP_USB_PID), *ble=make_device(TP_BLE_PID);
    [s_tpDevices addObjectsFromArray:@[usb,ble]];
    uint8_t wheel[]={0x16,2,3};
    report(usb,0x16,wheel,3);
    assert(events.count==1 && [events[0][@"x"] intValue]==6 && [events[0][@"y"] intValue]==9);
    assert(usb->nativeScrolled && !usb->bleVerticalPending);
    [events removeAllObjects]; s_naturalScroll=YES; report(usb,0x16,wheel,3);
    assert([events[0][@"x"] intValue]==-6 && [events[0][@"y"] intValue]==-9);
    [events removeAllObjects]; s_naturalScroll=NO; report(ble,0x16,wheel,3);
    assert(events.count==1 && [events[0][@"x"] intValue]==6 && [events[0][@"y"] intValue]==0);
    assert(consume_ble_vertical_scroll() && !consume_ble_vertical_scroll());
    ble->bleVerticalPending=YES; ble->lastNativeScrollTime=1;
    assert(!consume_ble_vertical_scroll());
    [events removeAllObjects]; s_enabled=NO; report(usb,0x16,wheel,3); assert(!events.count);
    s_enabled=YES; s_preferredScroll=NO; report(usb,0x16,wheel,3); assert(!events.count);
    s_preferredScroll=YES;
    hid_report(NULL,kIOReturnError,(void *)usb->device,kIOHIDReportTypeInput,0x16,wheel,3);
    hid_report(NULL,kIOReturnSuccess,(void *)usb->device,kIOHIDReportTypeOutput,0x16,wheel,3);
    report(usb,0x16,wheel,2); assert(!events.count);
    value(usb,kHIDPage_GenericDesktop,kHIDUsage_GD_X,0); assert(!usb->inputConfirmed);
    value(usb,kHIDPage_GenericDesktop,kHIDUsage_GD_X,2); assert(usb->inputConfirmed);
    value(usb,kHIDPage_Button,3,1); assert(usb->rawMiddleDown);
    value(usb,kHIDPage_Button,3,0); assert(!usb->rawMiddleDown);
    value(usb,0xFFA0,0xFB,1); assert(usb->nativeMiddleDown);
    value(usb,0xFFA0,0xFB,0); assert(!usb->nativeMiddleDown && events.count==2);
    [events removeAllObjects]; s_lastMiddleClickTime=0;
    uint8_t middle[]={0x15,0,4,0,0,0,0,0,0}; report(ble,0x15,middle,9);
    assert(ble->nativeMiddleDown); middle[2]=0; report(ble,0x15,middle,9);
    assert(!ble->nativeMiddleDown && events.count==2);
    [reports removeAllObjects]; uint8_t hotkey[]={5,0xB5};
    report(usb,5,hotkey,2); BOOL lock=s_fnLock; NSUInteger n=reports.count;
    report(usb,5,hotkey,2); assert(s_fnLock==lock && reports.count==n);
    hotkey[1]=0; report(usb,5,hotkey,2); hotkey[1]=0xB5; report(usb,5,hotkey,2);
    assert(s_fnLock!=lock && reports.count>n);
}
static void test_pointer_and_scroll(void) {
    clear(); TPHIDDevice *usb=make_device(TP_USB_PID); [s_tpDevices addObject:usb];
    CGEventRef move=CGEventCreateMouseEvent(NULL,kCGEventMouseMoved,CGPointMake(100,100),0);
    assert(move); CGEventSetDoubleValueField(move,kCGMouseEventDeltaX,10);
    s_sensitivity=9;
    assert(unified_callback(NULL,kCGEventMouseMoved,move,NULL)==move);
    assert(CGEventGetDoubleValueField(move,kCGMouseEventDeltaX)==10);
    usb->inputConfirmed=YES; usb->lastPointerTime=mach_absolute_time();
    unified_callback(NULL,kCGEventMouseMoved,move,NULL);
    assert(fabs(CGEventGetDoubleValueField(move,kCGMouseEventDeltaX)-10*sensitivity_factor())<=1);
    CGEventSetDoubleValueField(move,kCGMouseEventDeltaX,10);
    usb->hardwareSensitivityApplied=YES; usb->lastPointerTime=mach_absolute_time();
    unified_callback(NULL,kCGEventMouseMoved,move,NULL);
    assert(CGEventGetDoubleValueField(move,kCGMouseEventDeltaX)==10); CFRelease(move);
    assert(CGPointEqualToPoint(clamp_to_active_display(CGPointMake(-500,100)),CGPointMake(-500,100)));
    assert(CGPointEqualToPoint(clamp_to_active_display(CGPointMake(3000,2000)),CGPointMake(1919,1079)));
    TPHIDDevice *ble=make_device(TP_BLE_PID); [s_tpDevices addObject:ble];
    CGEventRef scroll=CGEventCreateScrollWheelEvent(NULL,kCGScrollEventUnitPixel,1,10);
    assert(scroll); CGEventSetIntegerValueField(scroll,kCGScrollWheelEventPointDeltaAxis1,10);
    s_scrollSpeed=SCROLL_SPEED*2; ble->bleVerticalPending=YES; ble->lastNativeScrollTime=mach_absolute_time();
    unified_callback(NULL,kCGEventScrollWheel,scroll,NULL);
    assert(CGEventGetIntegerValueField(scroll,kCGScrollWheelEventPointDeltaAxis1)==20);
    unified_callback(NULL,kCGEventScrollWheel,scroll,NULL);
    assert(CGEventGetIntegerValueField(scroll,kCGScrollWheelEventPointDeltaAxis1)==20); CFRelease(scroll);
    s_middleDown=YES; s_tap=(CFMachPortRef)1;
    unified_callback(NULL,kCGEventTapDisabledByTimeout,NULL,NULL);
    assert(!s_middleDown && tapEnabled);
    s_enabled=NO; tapEnabled=NO; unified_callback(NULL,kCGEventTapDisabledByUserInput,NULL,NULL);
    assert(!tapEnabled); s_tap=NULL;
}
static void test_lifecycle(void) {
    clear();
    TPHIDDevice *usb=make_device(TP_USB_PID), *compact=make_device(TP_COMPACT_PID), *unknown=make_device(1234);
    s_tap=(CFMachPortRef)1;
    hid_added(NULL,0,NULL,unknown->device); assert(!tp_count());
    hid_added(NULL,0,NULL,usb->device); assert(tp_count()==1 && tapEnabled);
    NSUInteger count=reports.count;
    hid_added(NULL,0,NULL,usb->device); assert(tp_count()==1 && reports.count==count);
    hid_added(NULL,0,NULL,compact->device); assert(tp_count()==2);
    [g_app toggleEnabled:nil]; assert(!s_enabled && !tapEnabled);
    assert(![[TestDefaults standardUserDefaults] boolForKey:PREF_ENABLED]);
    [g_app toggleEnabled:nil]; assert(s_enabled && tapEnabled);
    assert([[TestDefaults standardUserDefaults] boolForKey:PREF_ENABLED]);
    s_middleDown=YES;
    TPHIDDevice *connected=s_tpDevices.firstObject;
    connected->inputConfirmed=YES; connected->lastPointerTime=mach_absolute_time();
    [[TestDefaults standardUserDefaults] setBool:NO forKey:@"com.apple.swipescrolldirection"];
    [g_app systemDidWake:nil]; assert(!s_middleDown && !connected->inputConfirmed && !s_naturalScroll);
    [[TestDefaults standardUserDefaults] setBool:YES forKey:@"com.apple.swipescrolldirection"];
    [g_app systemDidWake:nil]; assert(s_naturalScroll);
    hid_removed(NULL,0,NULL,unknown->device); assert(tp_count()==2);
    hid_removed(NULL,0,NULL,usb->device); assert(tp_count()==1);
    hid_removed(NULL,0,NULL,compact->device); assert(!tp_count() && !tapEnabled);
    s_tap=NULL;
}
static void test_manager_and_tap_lifecycle(void) {
    clear(); s_hidManager=NULL;
    accessState=kIOHIDAccessTypeDenied;
    [g_app pollIM:nil]; assert(!s_hidManager);
    accessState=kIOHIDAccessTypeGranted;
    [g_app pollIM:nil]; assert(s_hidManager && [managerCalls.lastObject isEqual:@"open"]);
    NSUInteger calls=managerCalls.count;
    [g_app pollIM:nil]; assert(managerCalls.count==calls);
    failTap=YES; try_create_event_tap(); assert(!s_tap && !s_tapSource);
    failTap=NO; failTapSource=YES; try_create_event_tap(); assert(!s_tap && !s_tapSource);
    failTapSource=NO; try_create_event_tap(); assert(s_tap && s_tapSource && !tapEnabled);
    TPHIDDevice *usb=make_device(TP_USB_PID);
    hid_added(NULL,0,NULL,usb->device); assert(tapEnabled);
    BOOL oldSwap=s_swapEnabled, oldF18=s_f18Enabled;
    [tasks removeAllObjects];
    [g_app applicationWillTerminate:[NSNotification notificationWithName:NSApplicationWillTerminateNotification object:nil]];
    assert(!s_tap && !s_tapSource && !s_hidManager && !tp_count());
    assert(s_swapEnabled==oldSwap && s_f18Enabled==oldF18);
    assert([managerCalls containsObject:@"close"] && [managerCalls containsObject:@"unschedule"]);
    NSDictionary *map=hid_json(tasks.lastObject[@"args"][4]);
    assert([map[@"UserKeyMapping"] count]==0);
}
static void test_actions(void) {
    clear();
    s_f12Mode=TPF12Disabled; run_f12_action(); assert(!urls.count && !events.count);
    s_f12Mode=TPF12OpenURL; s_f12URL=@"https://example.com/test"; run_f12_action();
    assert([urls.lastObject isEqual:s_f12URL]);
    [urls removeAllObjects]; s_f12URL=@"file:///tmp/no"; run_f12_action(); assert(!urls.count && beeps==1);
    s_f12Mode=TPF12OpenFiles; s_f12Files=@[@"/dev/null",@"/trackpointd-test-does-not-exist"];
    run_f12_action(); assert(urls.count==1 && [urls[0] isEqual:@"file:///dev/null"]);
    s_f12Mode=TPF12TypeText; s_f12Text=@"한글🙂"; run_f12_action();
    assert(events.count==2 && [events[0][@"text"] isEqual:s_f12Text]);
    [events removeAllObjects]; trusted=NO; type_text(@"blocked"); show_notification_center(); assert(!events.count);
    trusted=YES; type_text(@""); assert(!events.count);
    type_text([@"x" stringByPaddingToLength:1200 withString:@"x" startingAtIndex:0]);
    assert([events[0][@"text"] length]==1000);
    [events removeAllObjects]; show_notification_center();
    assert(events.count==2 && [events[0][@"key"] intValue]==45);
    assert(([events[0][@"flags"] unsignedLongLongValue]&kCGEventFlagMaskSecondaryFn)!=0);
    [events removeAllObjects]; [tasks removeAllObjects]; [urls removeAllObjects];
    handle_hotkey(0xB6); assert([urls.lastObject hasSuffix:@"com.apple.BluetoothSettings"]);
    handle_hotkey(0xBC); assert([urls.lastObject isEqual:@"x-apple.systempreferences:"]);
    handle_hotkey(0xB9); assert([tasks.lastObject[@"path"] isEqual:@"/usr/sbin/screencapture"]);
    handle_hotkey(0xC1); assert(events.count==2);
    int count=openedSettings; handle_hotkey(0xB7); assert(openedSettings==count+1);
    [events removeAllObjects]; s_f12Mode=TPF12TypeText; s_f12Text=@"F12"; handle_hotkey(0xB8);
    assert(events.count==2); NSUInteger n=events.count; handle_hotkey(0xFFFF); assert(events.count==n);
    muted=0; assert(toggle_default_input_mute() && writtenMute==1);
    muted=1; assert(toggle_default_input_mute() && writtenMute==0);
    defaultStatus=-1; assert(!toggle_default_input_mute()); defaultStatus=0;
    inputDevice=kAudioObjectUnknown; assert(!toggle_default_input_mute()); inputDevice=42;
    hasMute=NO; assert(!toggle_default_input_mute()); hasMute=YES;
    writableMute=NO; assert(!toggle_default_input_mute()); writableMute=YES;
    settableStatus=-1; assert(!toggle_default_input_mute()); settableStatus=0;
    muteReadStatus=-1; assert(!toggle_default_input_mute()); muteReadStatus=0;
    muteWriteStatus=-1; assert(!toggle_default_input_mute()); muteWriteStatus=0;
}
static void finish_update(NSInteger status,NSData *data,NSError *error) {
    NSHTTPURLResponse *response=[[NSHTTPURLResponse alloc] initWithURL:[NSURL URLWithString:@"https://api.github.com/"]
        statusCode:status HTTPVersion:@"HTTP/1.1" headerFields:nil];
    assert(pendingDownload); pendingDownload(data,response,error); pendingDownload=nil;
    assert(!g_app.checkingForUpdates);
}
static void test_update_requests(void) {
    clear();
    g_app.upgrading=YES;
    int before=downloadCount;
    [g_app checkForUpdates:nil]; assert(downloadCount==before);
    assert([g_app applicationShouldTerminate:NSApp]==NSTerminateCancel);
    g_app.upgrading=NO; assert([g_app applicationShouldTerminate:NSApp]==NSTerminateNow);
    [g_app checkForUpdates:nil]; int count=downloadCount;
    [g_app checkForUpdates:nil]; assert(downloadCount==count && g_app.checkingForUpdates);
    finish_update(404,nil,nil); assert([alertText containsString:@"No stable release"]);
    [g_app checkForUpdates:nil]; finish_update(403,nil,nil);
    assert([alertText containsString:@"Could not check"]);
    [g_app checkForUpdates:nil]; finish_update(200,[NSData data],nil);
    assert([alertText containsString:@"Invalid release"]);
    [g_app checkForUpdates:nil]; finish_update(200,[NSMutableData dataWithLength:1024*1024+1],nil);
    assert([alertText containsString:@"too large"]);
    [g_app checkForUpdates:nil]; finish_update(200,nil,[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorTimedOut userInfo:nil]);
    assert([alertText containsString:@"Could not check"]);
    NSDictionary *payload=@{@"tag_name":@"v99.0.0",@"draft":@NO,@"prerelease":@NO,@"body":@"notes"};
    NSData *data=[NSJSONSerialization dataWithJSONObject:payload options:0 error:NULL];
    updateChoice=NSAlertFirstButtonReturn; [g_app checkForUpdates:nil]; finish_update(200,data,nil);
    // The test executable is not a Homebrew app: upgrade is disabled.
    assert(!g_app.upgrading);
    assert([((NSTextView *)((NSScrollView *)alertAccessory).documentView).string isEqual:@"notes"]);
    updateChoice=NSAlertSecondButtonReturn; [g_app checkForUpdates:nil]; finish_update(200,data,nil);
    assert([urls.lastObject hasSuffix:@"/releases/tag/v99.0.0"]);
    assert(!copiedCommand);
    updateChoice=NSAlertThirdButtonReturn;
    payload=@{@"tag_name":@"v0.0.0",@"draft":@NO,@"prerelease":@NO};
    data=[NSJSONSerialization dataWithJSONObject:payload options:0 error:NULL];
    [g_app checkForUpdates:nil]; finish_update(200,data,nil);
    assert([alertTitle isEqual:@"You’re up to date"]);
}
static void test_startup_preferences(void) {
    TestDefaults *defaults=[TestDefaults standardUserDefaults];
    [defaults removePersistentDomainForName:suite];
    load_preferences();
    assert(s_enabled && !s_blockMiddle && s_sensitivity==TP_SENSITIVITY_DEFAULT);
    assert(s_f18Enabled && s_swapEnabled && s_preferredScroll && !s_fnLock);
    assert(s_scrollSpeed==SCROLL_SPEED && s_f12Mode==TPF12OpenURL);
    [defaults setInteger:99 forKey:PREF_SENSITIVITY];
    [defaults setDouble:99 forKey:PREF_SCROLL_SPEED];
    [defaults setInteger:99 forKey:PREF_F12_MODE];
    [defaults setObject:@[@"/a",@1,@"/b",@"/c",@"/d",@"/e"] forKey:PREF_F12_FILES];
    [defaults setObject:@123 forKey:PREF_F12_URL];
    [defaults setObject:@123 forKey:PREF_F12_TEXT];
    s_f12URL=@"https://example.com/default"; s_f12Text=@"default";
    load_preferences();
    assert(s_sensitivity==9 && s_scrollSpeed==8 && s_f12Mode==TPF12TypeText);
    assert(( [s_f12Files isEqual:@[@"/a",@"/b",@"/c",@"/d"]] ));
    assert([s_f12URL isEqual:@"https://example.com/default"] && [s_f12Text isEqual:@"default"]);
    [defaults setInteger:-99 forKey:PREF_SENSITIVITY];
    [defaults setDouble:-99 forKey:PREF_SCROLL_SPEED];
    [defaults setInteger:-99 forKey:PREF_F12_MODE];
    [defaults setBool:NO forKey:PREF_ENABLED]; [defaults setBool:YES forKey:PREF_BLOCK_MIDDLE];
    [defaults setObject:@"https://example.com/saved" forKey:PREF_F12_URL];
    [defaults setObject:@"saved text" forKey:PREF_F12_TEXT];
    load_preferences();
    assert(s_sensitivity==1 && s_scrollSpeed==1 && s_f12Mode==TPF12Disabled);
    assert(!s_enabled && s_blockMiddle && [s_f12Text isEqual:@"saved text"]);
    assert([s_f12URL isEqual:@"https://example.com/saved"]);
}
static void test_config_report_capability(void) {
    clear();
    /* Physical USB descriptor facts: keyboard output 00; vendor feature 04 only. */
    for (NSDictionary *capability in @[
        @{@kIOHIDElementTypeKey:@(kIOHIDElementTypeOutput),@kIOHIDElementReportIDKey:@0},
        @{@kIOHIDElementTypeKey:@(kIOHIDElementTypeFeature),@kIOHIDElementReportIDKey:@4},
        @{@kIOHIDElementTypeKey:@(kIOHIDElementTypeOutput),@kIOHIDElementReportIDKey:@0x13}
    ]) {
        NSDictionary *properties=@{@kIOHIDVendorIDKey:@(LENOVO_VID),
            @kIOHIDProductIDKey:@(TP_USB_PID),@"reportCapabilities":@[capability]};
        TPHIDDevice *auxiliary=[[TPHIDDevice alloc] initWithDevice:(__bridge IOHIDDeviceRef)properties];
        assert(!send_config_command(auxiliary->device,2,6));
        assert(!send_config_command(auxiliary->device,5,0));
        assert(!send_config_command(auxiliary->device,9,1));
        assert(!reports.count);
    }
    NSDictionary *properties=@{@kIOHIDVendorIDKey:@(LENOVO_VID),
        @kIOHIDProductIDKey:@(TP_USB_PID), @"elementsUnavailable":@YES};
    TPHIDDevice *unknown=[[TPHIDDevice alloc] initWithDevice:(__bridge IOHIDDeviceRef)properties];
    assert(!send_config_command(unknown->device,2,6));
    assert(!reports.count); /* Enumeration failure must not become a blind write. */
    TPHIDDevice *usb=make_device(TP_USB_PID), *ble=make_device(TP_BLE_PID);
    assert(send_config_command(usb->device,2,6));
    assert(send_config_command(ble->device,2,6));
    assert(reports.count==2);
    assert([reports[0][@"type"] intValue]==kIOHIDReportTypeFeature && [reports[0][@"id"] intValue]==0x13);
    assert([reports[1][@"type"] intValue]==kIOHIDReportTypeOutput && [reports[1][@"id"] intValue]==0x18);
    failedPID=TP_USB_PID;
    assert(!send_config_command(usb->device,2,6));
    assert(reports.count==3); /* Supported report, real write failure: preserve fallback. */
}
static void test_pointer_sensitivity_display(void) {
    clear();
    QuietSettings *settings=[QuietSettings new];
    void (*sync)(id,SEL)=(void (*)(id,SEL))class_getMethodImplementation(SettingsWindowController.class,@selector(syncState));
    s_sensitivity=6;
    sync(settings,@selector(syncState));
    assert([settings.keyboardStatus.stringValue containsString:@"Disconnected"]);
    TPHIDDevice *pointer=make_device(TP_USB_PID);
    NSDictionary *auxiliaryProperties=@{@kIOHIDVendorIDKey:@(LENOVO_VID),
        @kIOHIDProductIDKey:@(TP_USB_PID), @"rejectConfig":@YES};
    TPHIDDevice *keys=[[TPHIDDevice alloc] initWithDevice:(__bridge IOHIDDeviceRef)auxiliaryProperties];
    TPHIDDevice *vendor=[[TPHIDDevice alloc] initWithDevice:(__bridge IOHIDDeviceRef)auxiliaryProperties];
    [s_tpDevices addObjectsFromArray:@[pointer,keys,vendor]];
    apply_hardware_settings();
    assert(pointer->hardwareSensitivityApplied && !keys->hardwareSensitivityApplied && !vendor->hardwareSensitivityApplied);
    assert(reports.count==3); /* Never write configuration to keyboard/vendor collections. */
    NSUInteger writes=reports.count;
    assert(!send_config_command(keys->device,2,6) && !send_config_command(vendor->device,2,6));
    assert(reports.count==writes);
    sync(settings,@selector(syncState));
    assert([settings.keyboardStatus.stringValue containsString:@"move TrackPoint"]);
    /* Real USB regression: other interfaces reject configuration, but do not move. */
    value(pointer,kHIDPage_GenericDesktop,kHIDUsage_GD_X,1);
    sync(settings,@selector(syncState));
    assert([settings.keyboardStatus.stringValue containsString:@"(hardware sensitivity)"]);
    assert([settings.applyStatus.stringValue containsString:@"Level 6"]);
    assert(![settings.applyStatus.stringValue containsString:@"fallback"]);
    /* A genuine pointer setting failure must still be shown as fallback. */
    pointer->hardwareSensitivityApplied=NO;
    sync(settings,@selector(syncState));
    assert([settings.keyboardStatus.stringValue containsString:@"software fallback"]);
    assert([settings.applyStatus.stringValue containsString:@"software fallback active"]);
    pointer->hardwareSensitivityApplied=YES;
    TPHIDDevice *compact=make_device(TP_COMPACT_PID);
    [s_tpDevices addObject:compact];
    sync(settings,@selector(syncState));
    assert([settings.keyboardStatus.stringValue containsString:@"(hardware sensitivity)"]);
    value(compact,kHIDPage_GenericDesktop,kHIDUsage_GD_Y,1);
    sync(settings,@selector(syncState));
    assert([settings.keyboardStatus.stringValue containsString:@"hardware + software"]);
    assert([settings.applyStatus.stringValue containsString:@"per device"]);
    [s_tpDevices removeObject:compact];
    sync(settings,@selector(syncState));
    assert([settings.keyboardStatus.stringValue containsString:@"(hardware sensitivity)"]);
    [pointer resetAfterWake];
    sync(settings,@selector(syncState));
    assert([settings.applyStatus.stringValue containsString:@"verify sensitivity"]);
    value(pointer,kHIDPage_GenericDesktop,kHIDUsage_GD_X,1);
    sync(settings,@selector(syncState));
    assert([settings.keyboardStatus.stringValue containsString:@"(hardware sensitivity)"]);
    s_enabled=NO; sync(settings,@selector(syncState));
    assert([settings.keyboardStatus.stringValue containsString:@"Paused"]);
    assert([settings.applyStatus.stringValue containsString:@"Paused"]);
    settings.permissionGuide=[TPPermissionGuide new];
    guideVisible=YES; trusted=NO;
    [settings.permissionGuide showForAccessibility:YES]; assert(settings.permissionGuide.permissionTimer.valid);
    SettingsWindowController *previousSettings=g_settings; g_settings=settings;
    AppDelegate *delegate=[AppDelegate new];
    [delegate settingsWindowClosed:nil]; assert(!settings.permissionGuide.permissionTimer);
    g_settings=previousSettings; guideVisible=NO; trusted=YES;
    [settings.window close];
}
static void test_preferences_and_editor(void) {
    clear();
    QuietSettings *settings=[QuietSettings new];
    NSButton *button=[NSButton checkboxWithTitle:@"test" target:nil action:NULL];
    button.state=NSControlStateValueOff;
    [settings toggleF18:button]; assert(!s_f18Enabled && ![[TestDefaults standardUserDefaults] boolForKey:PREF_F18]);
    [settings toggleSwap:button]; assert(!s_swapEnabled && ![[TestDefaults standardUserDefaults] boolForKey:PREF_SWAP]);
    button.state=NSControlStateValueOn;
    [settings toggleFnLock:button]; assert(s_fnLock && [[TestDefaults standardUserDefaults] boolForKey:PREF_FN_LOCK]);
    [settings toggleBlockMiddleSetting:button]; assert(s_blockMiddle && [[TestDefaults standardUserDefaults] boolForKey:PREF_BLOCK_MIDDLE]);
    s_middleDown=YES; button.state=NSControlStateValueOff;
    [settings togglePreferredScroll:button]; assert(!s_preferredScroll && !s_middleDown);
    assert(![[TestDefaults standardUserDefaults] boolForKey:PREF_SCROLL]);
    [settings trySlow:nil]; assert(s_sensitivity==1 && [[TestDefaults standardUserDefaults] integerForKey:PREF_SENSITIVITY]==1);
    [settings tryFast:nil]; assert(s_sensitivity==9 && [[TestDefaults standardUserDefaults] integerForKey:PREF_SENSITIVITY]==9);
    settings.scrollSlider.doubleValue=4; [settings scrollSliderChanged:settings.scrollSlider];
    assert(s_scrollSpeed==4 && [[TestDefaults standardUserDefaults] doubleForKey:PREF_SCROLL_SPEED]==4);
    [settings buildF12Editor];
    settings.f12DraftMode=TPF12OpenURL; settings.f12DraftURL=@"https://example.com";
    [settings configureF12Controls]; assert(!settings.f12Value.hidden && settings.f12FilesScroll.hidden);
    settings.f12Value.stringValue=@"javascript:alert(1)";
    TPF12Mode old=s_f12Mode; [settings saveF12Editor:nil]; assert(s_f12Mode==old && !settings.f12Warning.hidden);
    settings.f12Value.stringValue=@"https://example.com/new"; [settings saveF12Editor:nil];
    assert(s_f12Mode==TPF12OpenURL && [s_f12URL isEqual:@"https://example.com/new"]);
    assert([[[TestDefaults standardUserDefaults] stringForKey:PREF_F12_URL] isEqual:s_f12URL]);
    settings.f12DraftMode=TPF12TypeText; settings.f12DraftText=@"hello\nworld";
    [settings configureF12Controls]; assert(!settings.f12Warning.hidden);
    [settings saveF12Editor:nil]; assert([s_f12Text isEqual:@"hello\nworld"]);
    assert([settings.f12DetailValue.stringValue isEqual:@"hello world"]);
    settings.f12DraftMode=TPF12OpenFiles; settings.f12DraftFiles=@[@"/tmp/a",@"/tmp/b"];
    [settings configureF12Controls]; assert(!settings.f12FilesScroll.hidden && settings.f12Value.hidden);
    [settings saveF12Editor:nil]; assert(s_f12Files.count==2);
    settings.f12DraftMode=TPF12Disabled; [settings configureF12Controls]; assert(settings.f12Value.hidden);
    [settings cancelF12Editor:nil]; assert(s_f12Mode==TPF12OpenFiles);
    settings.f12DraftMode=TPF12OpenFiles;
    settings.f12DraftFiles=@[@"/tmp/a"];
    selectedFiles=@[[NSURL fileURLWithPath:@"/tmp/a"],[NSURL fileURLWithPath:@"/tmp/b"],
                    [NSURL fileURLWithPath:@"/tmp/c"],[NSURL fileURLWithPath:@"/tmp/d"],
                    [NSURL fileURLWithPath:@"/tmp/e"]];
    [settings chooseF12Files:nil];
    assert(settings.f12DraftFiles.count==4 && limitWarnings==1);
    NSTextField *fileRow=(NSTextField *)[settings tableView:settings.f12FilesTable
        viewForTableColumn:settings.f12FilesTable.tableColumns.firstObject row:0];
    assert([fileRow.font.fontName containsString:@"Tahoma"]);
    assert(fileRow.font.pointSize==11);
    assert([settings.f12DraftFiles.lastObject isEqual:@"/tmp/d"]);
    panelResponse=NSModalResponseCancel; selectedFiles=@[[NSURL fileURLWithPath:@"/tmp/z"]];
    [settings chooseF12Files:nil]; assert(settings.f12DraftFiles.count==4); panelResponse=NSModalResponseOK;
    [settings.f12FilesTable selectRowIndexes:[NSIndexSet indexSetWithIndex:1] byExtendingSelection:NO];
    [settings removeF12Files:nil];
    assert(settings.f12DraftFiles.count==3 && ![settings.f12DraftFiles containsObject:@"/tmp/b"]);
    settings.f12DraftMode=TPF12Disabled;
    [settings saveF12Editor:nil]; assert(s_f12Mode==TPF12Disabled);
    NSTabView *tabs=settings.window.contentView.subviews.firstObject;
    assert([tabs tabViewItemAtIndex:3] && [[tabs tabViewItemAtIndex:3].identifier isEqual:@"support"]);
    for (NSView *label in ((NSScrollView *)[tabs tabViewItemAtIndex:3].view).documentView.subviews) {
        if (![label isKindOfClass:NSTextField.class]) continue;
        NSTextField *field=(NSTextField *)label;
        assert([field.cell cellSizeForBounds:NSMakeRect(0,0,field.frame.size.width,1000)].height<=field.frame.size.height);
    }
    trusted=NO; s_accessibilityRequestAttempted=NO;
    [settings requestAccessibility:nil]; assert(s_accessibilityRequestAttempted);
    assert(settings.permissionGuide.forAccessibility);
    assert([urls.lastObject containsString:@"Privacy_Accessibility"]);
    [urls removeAllObjects]; [settings requestAccessibility:nil];
    assert([urls.lastObject containsString:@"Privacy_Accessibility"]);
    accessState=kIOHIDAccessTypeUnknown; [urls removeAllObjects];
    [settings requestInputMonitoring:nil]; assert([urls.lastObject containsString:@"Privacy_ListenEvent"]);
    assert(!settings.permissionGuide.forAccessibility);
    accessState=kIOHIDAccessTypeDenied; [settings requestInputMonitoring:nil];
    assert([urls.lastObject containsString:@"Privacy_ListenEvent"]);
    trusted=YES; accessState=kIOHIDAccessTypeGranted;
    void (*sync)(id,SEL)=(void (*)(id,SEL))class_getMethodImplementation(SettingsWindowController.class,@selector(syncState));
    s_enabled=NO; sync(settings,@selector(syncState)); assert(!settings.slider.enabled && !settings.blockMiddleCheck.enabled);
    s_enabled=YES; sync(settings,@selector(syncState)); assert(settings.slider.enabled && settings.blockMiddleCheck.enabled);
    [settings.window close];
    assert(NSEqualSizes(settings.window.frame.size, NSMakeSize(500,516)));
    assert([settings.window isKindOfClass:TPWindowsPropertyWindow.class]);
    assert(settings.propertyTabs.tabViewType==NSNoTabsNoBorder);
    BOOL speedTitleFound=NO;
    for (NSView *view in [settings.propertyTabs tabViewItemAtIndex:0].view.subviews)
        if ([view isKindOfClass:TPWindowsGroupBox.class] && [((TPWindowsGroupBox *)view).title isEqualToString:@"Pointer speed"])
            speedTitleFound=YES;
    assert(speedTitleFound);
    assert(settings.propertyTabButtons.count==4);
    for (NSButton *tab in settings.propertyTabButtons) {
        assert(tab.target==settings && tab.action==@selector(selectPropertyTab:));
        [tab performClick:nil];
        assert(settings.propertyTabs.selectedTabViewItem==[settings.propertyTabs tabViewItemAtIndex:tab.tag]);
    }
    [settings.propertyTabButtons.firstObject performClick:nil];
    // Group contents share one coordinate space: no NSBox content-view offset/clipping.
    assert([[settings.propertyTabs tabViewItemAtIndex:0].label isEqualToString:@"TrackPoint"]);
    assert([[settings.propertyTabs tabViewItemAtIndex:1].label isEqualToString:@"Keyboard"]);
    assert([[settings.propertyTabs tabViewItemAtIndex:2].label isEqualToString:@"Permissions"]);
    NSUInteger groupCount=0;
    NSMutableArray *pageContents=[NSMutableArray array];
    for (NSTabViewItem *item in settings.propertyTabs.tabViewItems) {
        NSView *page=item.view;
        if ([page isKindOfClass:NSScrollView.class]) page=((NSScrollView *)page).documentView;
        [pageContents addObject:page];
        for (NSView *view in page.subviews) {
            if (![view isKindOfClass:TPWindowsGroupBox.class]) continue;
            groupCount++;
            NSRect body=NSMakeRect(0,0,view.bounds.size.width,view.bounds.size.height-8);
            for (NSView *control in view.subviews)
                assert(NSContainsRect(NSInsetRect(body,12,8),control.frame));
        }
    }
    assert(groupCount==6);
    NSArray *supportLabels=((NSView *)pageContents[3]).subviews;
    assert(supportLabels.count==2);
    assert(NSMinY(((NSView *)supportLabels[0]).frame)-NSMaxY(((NSView *)supportLabels[1]).frame)==16);
    for (NSView *label in supportLabels) assert(NSContainsRect(((NSView *)pageContents[3]).bounds,label.frame));
    assert(settings.scrollSlider.superview.superview==pageContents[0]);
    assert(settings.blockMiddleCheck.superview==settings.scrollSlider.superview);
    assert(settings.fnLockCheck.superview.superview==pageContents[1]);
    assert(settings.f12Summary.superview.superview==pageContents[1]);
    // Nonselected tab views are not descendants of the live NSTabView hierarchy.
    // They must receive the theme explicitly rather than retaining native controls.
    for (NSButton *button in @[settings.fnLockCheck,settings.f18Check,settings.swapCheck,
            settings.accessibilityBtn,settings.inputMonitoringBtn])
        assert([button.cell isKindOfClass:TPWindowsButtonCell.class]);
    assert([settings.scrollSlider.cell isKindOfClass:TPWindowsSliderCell.class]);
    assert([settings.keyboardStatus.font.fontName containsString:@"Tahoma"]);
    assert(settings.accessStatus.superview.superview==pageContents[2]);
    assert(settings.keyboardStatus.superview.superview==pageContents[2]);
    NSView *deviceGroup=settings.keyboardStatus.superview;
    NSRect status=[settings.keyboardStatus convertRect:settings.keyboardStatus.bounds toView:deviceGroup];
    assert(fabs(NSMidY(status)-(deviceGroup.bounds.size.height-8)/2)<.5);
    assert(settings.accessStatus.superview==settings.accessibilityBtn.superview);
    assert(NSMidY(settings.accessStatus.frame)==NSMidY(settings.accessibilityBtn.frame));
    assert(NSMidY(settings.inputStatus.frame)==NSMidY(settings.inputMonitoringBtn.frame));
    assert(NSMidY(settings.scrollSlider.frame)==NSMidY(settings.scrollLabel.frame));
    assert(NSMidY(settings.scrollValueLabel.frame)==NSMidY(settings.scrollLabel.frame));
    // Windows property pages preview changes, Cancel restores the last Apply checkpoint.
    [settings beginWindowsEditing];
    int savedSensitivity=s_sensitivity;
    BOOL savedPreferred=s_preferredScroll;
    settings.slider.integerValue=savedSensitivity==9 ? 1 : 9;
    [settings sliderChanged:settings.slider];
    settings.preferredCheck.state=savedPreferred ? NSControlStateValueOff : NSControlStateValueOn;
    [settings togglePreferredScroll:settings.preferredCheck];
    assert(s_sensitivity!=savedSensitivity && s_preferredScroll!=savedPreferred);
    assert([[TestDefaults standardUserDefaults] integerForKey:PREF_SENSITIVITY]==savedSensitivity);
    [settings restoreWindowsSettings];
    assert(s_sensitivity==savedSensitivity && s_preferredScroll==savedPreferred);
    assert([[TestDefaults standardUserDefaults] integerForKey:PREF_SENSITIVITY]==savedSensitivity);
    [settings beginWindowsEditing];
    settings.slider.integerValue=3; [settings sliderChanged:settings.slider];
    [settings applyWindowsSettings:nil];
    settings.slider.integerValue=7; [settings sliderChanged:settings.slider];
    [settings restoreWindowsSettings]; assert(s_sensitivity==3);
    assert([settings.slider.cell isKindOfClass:TPWindowsSliderCell.class]);
    assert([settings.preferredCheck.cell isKindOfClass:TPWindowsButtonCell.class]);
    assert(((TPWindowsButtonCell *)settings.preferredCheck.cell).checkboxStyle);
    assert(!((TPWindowsButtonCell *)settings.windowsApplyButton.cell).checkboxStyle);

}
@interface TestPermissionIcon : TPPermissionIcon
@property (strong) NSArray<NSDraggingItem *> *capturedItems;
@end
@implementation TestPermissionIcon
- (NSDraggingSession *)beginDraggingSessionWithItems:(NSArray<NSDraggingItem *> *)items
    event:(NSEvent *)event source:(id<NSDraggingSource>)source {
    assert(event && source==self); self.capturedItems=items; return nil;
}
@end
static BOOL upgradeSucceeds, restartSucceeds;
static int upgradeCalls, restartCalls, terminateCalls;
@interface QuietUpgradeController : TPUpgradeController
@end
@implementation QuietUpgradeController
- (BOOL)runForInstallation:(NSDictionary *)installation version:(NSString *)version error:(NSString **)error {
    assert(!s_enabled && [version isEqual:@"99.0.0"] && installation);
    upgradeCalls++;
    if (!upgradeSucceeds && error) *error=@"simulated brew failure";
    return upgradeSucceeds;
}
- (BOOL)relaunchForInstallation:(NSDictionary *)installation error:(NSString **)error {
    assert(installation); restartCalls++;
    if (!restartSucceeds && error) *error=@"simulated restart failure";
    return restartSucceeds;
}
@end
static id quiet_upgrade_new(id object, SEL selector) __attribute__((ns_returns_retained));
static id quiet_upgrade_new(id object, SEL selector) {
    (void)object; (void)selector; return [[QuietUpgradeController alloc] init];
}
static void quiet_terminate(id object, SEL selector, id sender) {
    (void)object; (void)selector; (void)sender; terminateCalls++;
}
static void test_upgrade_state(void) {
    class_addMethod(object_getClass(TPUpgradeController.class),@selector(new),(IMP)quiet_upgrade_new,"@@:");
    Method terminate=class_getInstanceMethod(NSApplication.class,@selector(terminate:));
    IMP original=method_setImplementation(terminate,(IMP)quiet_terminate);
    NSDictionary *install=@{@"prefix":@"/opt/homebrew",@"brew":@"/opt/homebrew/bin/brew"};
    NSDictionary *release=@{@"version":@"99.0.0"};
    NSDictionary *prefs=[[TestDefaults standardUserDefaults].dictionaryRepresentation copy];
    for (NSNumber *enabled in @[@NO,@YES]) {
        s_enabled=enabled.boolValue; upgradeSucceeds=NO; restartSucceeds=NO;
        int count=upgradeCalls;
        [g_app upgradeToRelease:release installation:install];
        assert(upgradeCalls==count+1 && s_enabled==enabled.boolValue && !g_app.upgrading);
        assert(!terminateCalls && [alertTitle isEqual:@"Could not upgrade TrackPointD"]);
    }
    s_enabled=YES; upgradeSucceeds=YES; restartSucceeds=NO;
    [g_app upgradeToRelease:release installation:install];
    assert(s_enabled && !terminateCalls && restartCalls==1 && [alertTitle containsString:@"reopen"]);
    upgradeSucceeds=YES; restartSucceeds=YES;
    [g_app upgradeToRelease:release installation:install];
    assert(!s_enabled && terminateCalls==1 && !g_app.upgrading);
    s_enabled=YES; int count=upgradeCalls;
    g_app.upgrading=YES;
    [g_app upgradeToRelease:release installation:install]; assert(upgradeCalls==count && s_enabled);
    g_app.upgrading=NO;
    [g_app upgradeToRelease:release installation:nil];
    [g_app upgradeToRelease:@{@"version":@"bad"} installation:install];
    assert(upgradeCalls==count && s_enabled);
    assert([prefs isEqual:[TestDefaults standardUserDefaults].dictionaryRepresentation]);
    method_setImplementation(terminate,original);
}
static BOOL test_guide_visible(id panel, SEL selector) { (void)panel; (void)selector; return guideVisible; }
static void quiet_guide_front(id panel, SEL selector, id sender) {
    (void)panel; (void)selector; (void)sender;
}
static void test_permission_guide(void) {
    NSRect screen=NSMakeRect(0,0,1440,900);
    NSSize size=NSMakeSize(280,260);
    NSRect right=permission_guide_frame(NSMakeRect(100,200,700,600),screen,size);
    assert(right.origin.x==310 && right.origin.y==0);
    NSRect left=permission_guide_frame(NSMakeRect(700,200,700,600),screen,size);
    assert(left.origin.x==910 && left.origin.y==0);
    NSRect below=permission_guide_frame(NSMakeRect(100,400,700,400),screen,size);
    assert(NSMidX(below)==450 && NSMaxY(below)==388); // Centered, 12 points below settings.
    NSRect clamped=permission_guide_frame(NSMakeRect(-100,-500,1500,1600),screen,size);
    assert(NSContainsRect(screen,clamped));
    NSRect secondary=NSMakeRect(-1280,-200,1280,900);
    assert(NSContainsRect(secondary,permission_guide_frame(NSMakeRect(-1200,-100,900,700),secondary,size)));
    TestPermissionIcon *icon=[[TestPermissionIcon alloc] initWithFrame:NSMakeRect(0,0,72,72)];
    NSEvent *event=[NSEvent mouseEventWithType:NSEventTypeLeftMouseDown location:NSZeroPoint
        modifierFlags:0 timestamp:0 windowNumber:0 context:nil eventNumber:0 clickCount:1 pressure:1];
    [icon mouseDown:event]; assert(!icon.capturedItems); // No invalid URL drag.
    icon.applicationURL=[NSURL fileURLWithPath:@"/tmp/TrackPointD.app"];
    icon.image=[[NSImage alloc] initWithSize:NSMakeSize(72,72)];
    [icon mouseDown:event];
    assert(icon.capturedItems.count==1);
    assert([icon.capturedItems.firstObject.item isEqual:icon.applicationURL]);
    assert(NSEqualRects(icon.capturedItems.firstObject.draggingFrame,icon.bounds));
    TPPermissionGuide *guide=[TPPermissionGuide new];
    // The test executable is not an app: never offer a wrong executable to TCC.
    assert(!guide.applicationIcon.applicationURL);
    assert(guide.level==NSFloatingWindowLevel && !guide.hidesOnDeactivate);
    assert([guide.applicationIcon draggingSession:(NSDraggingSession *)[NSObject new] sourceOperationMaskForDraggingContext:NSDraggingContextOutsideApplication]==NSDragOperationCopy);
    trusted=NO; accessState=kIOHIDAccessTypeDenied;
    [guide showForAccessibility:YES];
    assert([guide.instructions.stringValue containsString:@"Accessibility"]);
    assert(!guide.permissionTimer);
    guideVisible=YES;
    [guide showForAccessibility:YES];
    assert(guide.permissionTimer.valid);
    NSTimer *previous=guide.permissionTimer;
    [guide showForAccessibility:NO];
    assert(!previous.valid && guide.permissionTimer.valid);
    trusted=YES;
    [guide updatePermissionGuide];
    assert(guide.permissionTimer.valid); // Accessibility does not satisfy Input Monitoring.
    accessState=kIOHIDAccessTypeGranted;
    [guide updatePermissionGuide]; assert(!guide.permissionTimer);
    accessState=kIOHIDAccessTypeDenied;
    [guide showForAccessibility:YES]; assert(!guide.permissionTimer); // Already allowed.
    trusted=NO;
    [guide showForAccessibility:YES]; assert(guide.permissionTimer.valid);
    [guide close]; assert(!guide.permissionTimer);
    TestRunningApp *settingsApp=[TestRunningApp new]; settingsApp.processIdentifier=42;
    permissionApps=@[settingsApp];
    NSDictionary *settingsBounds=CFBridgingRelease(CGRectCreateDictionaryRepresentation(CGRectMake(100,100,700,500)));
    permissionWindows=@[@{(__bridge id)kCGWindowOwnerPID:@42, (__bridge id)kCGWindowLayer:@0,
        (__bridge id)kCGWindowBounds:settingsBounds}];
    [guide showForAccessibility:NO];
    assert(guide.sawSettingsWindow && guide.permissionTimer.valid);
    permissionWindows=@[]; [guide updatePermissionGuide]; assert(!guide.permissionTimer);
    // Startup must allow the Settings window to appear asynchronously.
    [guide showForAccessibility:NO]; assert(!guide.sawSettingsWindow && guide.permissionTimer.valid);
    permissionWindows=@[@{(__bridge id)kCGWindowOwnerPID:@42, (__bridge id)kCGWindowLayer:@0,
        (__bridge id)kCGWindowBounds:settingsBounds}];
    [guide updatePermissionGuide]; assert(guide.sawSettingsWindow);
    permissionApps=@[]; [guide updatePermissionGuide]; assert(!guide.permissionTimer);
    permissionWindows=@[];
    guideVisible=NO;
    [guide showForAccessibility:NO];
    assert([guide.instructions.stringValue containsString:@"Input Monitoring"]);
    trusted=YES; accessState=kIOHIDAccessTypeGranted;
    [guide updatePermissionGuide]; assert(!guide.permissionTimer && !guide.visible);
}
int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        class_addMethod(TPPermissionGuide.class,@selector(orderFront:),(IMP)quiet_guide_front,"v@:@");
        class_addMethod(TPPermissionGuide.class,@selector(isVisible),(IMP)test_guide_visible,"B@:");
        test_permission_guide();
        g_app=[QuietApp new];
        int previousOpens=openedSettings;
        assert([g_app applicationShouldHandleReopen:NSApp hasVisibleWindows:NO]);
        assert(openedSettings==previousOpens+1);
        assert([g_app applicationShouldHandleReopen:NSApp hasVisibleWindows:YES]);
        assert(openedSettings==previousOpens+1);
        test_devices_and_settings(); test_hid_input(); test_pointer_and_scroll();
        test_lifecycle(); test_manager_and_tap_lifecycle(); test_actions(); test_update_requests(); test_startup_preferences(); test_upgrade_state(); test_config_report_capability(); test_pointer_sensitivity_display(); test_preferences_and_editor();
        [[TestDefaults standardUserDefaults] removePersistentDomainForName:suite];
        puts("runtime/device/action/preferences tests: ok (all external effects intercepted)");
    }
}
