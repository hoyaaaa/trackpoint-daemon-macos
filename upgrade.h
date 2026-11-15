/* No downloaded installers: an explicit button runs the existing local Homebrew. */
static NSDictionary *homebrew_installation(NSString *bundlePath) {
    NSString *path = bundlePath.stringByResolvingSymlinksInPath;
    for (NSString *prefix in @[@"/opt/homebrew", @"/usr/local"]) {
        NSString *root = [prefix stringByAppendingString:@"/Cellar/trackpointd/"];
        if (![path hasPrefix:root]) continue;
        NSArray *parts = [[path substringFromIndex:root.length] pathComponents];
        if (parts.count != 2 || !version_parts(parts[0]) || ![parts[1] isEqual:@"TrackPointD.app"]) return nil;
        return @{@"prefix":prefix, @"brew":[prefix stringByAppendingString:@"/bin/brew"]};
    }
    return nil;
}
static NSAttributedString *render_release_notes(NSString *markdown) {
    NSString *input=[markdown stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length ? markdown : @"No release notes were provided.";
    NSAttributedString *parsed=[[NSAttributedString alloc] initWithMarkdownString:input
        options:nil baseURL:nil error:NULL];
    if (!parsed.length) parsed=[[NSAttributedString alloc] initWithString:input];
    NSMutableAttributedString *result=[NSMutableAttributedString new];
    NSMutableSet<NSNumber *> *listItems=[NSMutableSet set];
    [parsed enumerateAttribute:NSPresentationIntentAttributeName inRange:NSMakeRange(0,parsed.length)
        options:0 usingBlock:^(NSPresentationIntent *intent, NSRange range, BOOL *stop) {
        (void)stop;
        NSAttributedString *source=[parsed attributedSubstringFromRange:range];
        if (![source.string stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length) return;
        NSInteger heading=0, depth=0;
        NSPresentationIntent *item=nil;
        BOOL ordered=NO, codeBlock=NO;
        for (NSPresentationIntent *part=intent; part; part=part.parentIntent) {
            if (part.intentKind==NSPresentationIntentKindHeader) heading=part.headerLevel;
            if (part.intentKind==NSPresentationIntentKindCodeBlock) codeBlock=YES;
            if (part.intentKind==NSPresentationIntentKindListItem && !item) {
                item=part; ordered=part.parentIntent.intentKind==NSPresentationIntentKindOrderedList;
            }
            if (part.intentKind==NSPresentationIntentKindOrderedList || part.intentKind==NSPresentationIntentKindUnorderedList) depth++;
        }
        NSFont *font=heading ? [NSFont boldSystemFontOfSize:heading==1 ? 20 : heading==2 ? 17 : 15] :
            codeBlock ? [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular] : [NSFont systemFontOfSize:13];
        NSMutableParagraphStyle *style=[NSMutableParagraphStyle new];
        style.lineSpacing=3;
        style.paragraphSpacing=heading ? 8 : 7;
        style.paragraphSpacingBefore=heading && result.length ? 10 : 0;
        NSString *marker=@"";
        if (item) {
            style.firstLineHeadIndent=MAX(0,depth-1)*18;
            style.headIndent=style.firstLineHeadIndent+28;
            style.tabStops=@[[[NSTextTab alloc] initWithTextAlignment:NSTextAlignmentLeft location:style.headIndent options:@{}]];
            if (![listItems containsObject:@(item.identity)]) {
                marker=ordered ? [NSString stringWithFormat:@"%ld.\t",(long)item.ordinal] : @"•\t";
                [listItems addObject:@(item.identity)];
            } else style.firstLineHeadIndent=style.headIndent;
        }
        NSDictionary *attributes=@{NSFontAttributeName:font,NSForegroundColorAttributeName:NSColor.labelColor,
            NSParagraphStyleAttributeName:style};
        // Rebuild from text and selected styling only: no remote images, HTML or active links.
        NSMutableAttributedString *body=[[NSMutableAttributedString alloc] initWithString:source.string attributes:attributes];
        [source enumerateAttribute:NSInlinePresentationIntentAttributeName inRange:NSMakeRange(0,source.length)
            options:0 usingBlock:^(NSNumber *value, NSRange span, BOOL *innerStop) {
            (void)innerStop;
            NSInlinePresentationIntent inlineStyle=value.unsignedIntegerValue;
            NSFont *inlineFont=(inlineStyle & NSInlinePresentationIntentCode) ?
                [NSFont monospacedSystemFontOfSize:13 weight:NSFontWeightRegular] : font;
            NSFontTraitMask traits=0;
            if (inlineStyle & NSInlinePresentationIntentStronglyEmphasized) traits|=NSBoldFontMask;
            if (inlineStyle & NSInlinePresentationIntentEmphasized) traits|=NSItalicFontMask;
            if (traits) inlineFont=[NSFontManager.sharedFontManager convertFont:inlineFont toHaveTrait:traits];
            [body addAttribute:NSFontAttributeName value:inlineFont range:span];
            if (inlineStyle & NSInlinePresentationIntentStrikethrough)
                [body addAttribute:NSStrikethroughStyleAttributeName value:@(NSUnderlineStyleSingle) range:span];
            if (inlineStyle & NSInlinePresentationIntentSoftBreak)
                [body.mutableString replaceOccurrencesOfString:@"\n" withString:@" " options:0 range:span];
            if (inlineStyle & NSInlinePresentationIntentLineBreak)
                [body.mutableString replaceOccurrencesOfString:@"\n" withString:@"\u2028" options:0 range:span];
        }];
        if (result.length) [result appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n"
            attributes:[result attributesAtIndex:result.length-1 effectiveRange:NULL]]];
        [result appendAttributedString:[[NSAttributedString alloc] initWithString:marker attributes:attributes]];
        [result appendAttributedString:body];
    }];
    return result;
}

static NSScrollView *plain_text_view(NSString *notes) {
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0,0,480,240)];
    scroll.hasVerticalScroller = YES;
    scroll.borderType = NSBezelBorder;
    NSTextView *text = [[NSTextView alloc] initWithFrame:scroll.bounds];
    text.editable = NO;
    text.font = [NSFont systemFontOfSize:12];
    text.textContainerInset = NSMakeSize(16,14);
    text.autoresizingMask = NSViewWidthSizable;
    text.textContainer.widthTracksTextView = YES;
    text.minSize = NSMakeSize(0,scroll.bounds.size.height);
    text.maxSize = NSMakeSize(CGFLOAT_MAX,CGFLOAT_MAX);
    text.textContainer.containerSize = NSMakeSize(scroll.bounds.size.width,CGFLOAT_MAX);
    text.verticallyResizable = YES;
    text.horizontallyResizable = NO;
    text.string = notes.length ? notes : @"No release notes were provided.";
    [text setAccessibilityLabel:@"Upgrade log"];
    scroll.documentView = text;
    return scroll;
}

static NSScrollView *release_notes_view(NSString *notes) {
    NSScrollView *scroll=plain_text_view(@"");
    NSTextView *text=(NSTextView *)scroll.documentView;
    [text.textStorage setAttributedString:render_release_notes(notes)];
    [text setAccessibilityLabel:@"Release notes"];
    return scroll;
}

@interface TPUpgradeController : NSWindowController
@property (strong) NSTextView *output;
@property (strong) NSTask *task;
@property (strong) NSTimer *logTimer;
@property (strong) NSString *directory;
@property (strong) NSString *script;
@property (strong) NSString *logPath;
- (BOOL)runForInstallation:(NSDictionary *)installation version:(NSString *)version error:(NSString **)error;
- (BOOL)relaunchForInstallation:(NSDictionary *)installation error:(NSString **)error;
@end
@implementation TPUpgradeController
- (void)refreshLog {
    NSFileHandle *file = [NSFileHandle fileHandleForReadingAtPath:self.logPath];
    unsigned long long length = [file seekToEndOfFile];
    [file seekToFileOffset:length > 65536 ? length - 65536 : 0];
    NSData *data = [file readDataOfLength:65536];
    [file closeFile];
    self.output.string = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"Updating…";
    [self.output scrollRangeToVisible:NSMakeRange(self.output.string.length,0)];
}
- (BOOL)runForInstallation:(NSDictionary *)installation version:(NSString *)version error:(NSString **)error {
    if (!version_parts(version)) { if (error) *error=@"Invalid version."; return NO; }
    NSFileManager *files = NSFileManager.defaultManager;
    NSString *resource = [NSBundle.mainBundle pathForResource:@"upgrade" ofType:@"sh"];
    self.directory = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [@"trackpointd-upgrade." stringByAppendingString:NSUUID.UUID.UUIDString]];
    self.script = [self.directory stringByAppendingPathComponent:@"upgrade.sh"];
    self.logPath = [self.directory stringByAppendingPathComponent:@"upgrade.log"];
    NSError *failure = nil;
    if (!resource || ![files isExecutableFileAtPath:installation[@"brew"]] ||
        ![files createDirectoryAtPath:self.directory withIntermediateDirectories:NO
            attributes:@{NSFilePosixPermissions:@0700} error:&failure] ||
        ![files copyItemAtPath:resource toPath:self.script error:&failure] ||
        ![files createFileAtPath:self.logPath contents:nil attributes:@{NSFilePosixPermissions:@0600}]) {
        if (error) *error=failure.localizedDescription ?: @"Homebrew or the bundled updater is unavailable.";
        [files removeItemAtPath:self.directory error:NULL];
        return NO;
    }
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,560,360)
        styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    window.title = @"Updating TrackPointD";
    window.releasedWhenClosed = NO;
    self.window = window;
    NSTextField *label = [NSTextField labelWithString:@"Installing with Homebrew. TrackPointD enhancements are paused."];
    label.frame = NSMakeRect(18,320,524,22);
    [window.contentView addSubview:label];
    NSProgressIndicator *spinner = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(18,292,524,16)];
    spinner.style = NSProgressIndicatorStyleBar;
    spinner.indeterminate = YES;
    [spinner startAnimation:nil];
    [window.contentView addSubview:spinner];
    NSScrollView *scroll = plain_text_view(@"Starting…");
    scroll.frame = NSMakeRect(18,18,524,260);
    self.output = (NSTextView *)scroll.documentView;
    [window.contentView addSubview:scroll];
    NSFileHandle *log = [NSFileHandle fileHandleForWritingAtPath:self.logPath];
    self.task = [NSTask new];
    self.task.launchPath = @"/bin/bash";
    self.task.arguments = @[@"--",self.script,@"upgrade",installation[@"brew"],installation[@"prefix"],version];
    self.task.standardInput = [NSFileHandle fileHandleWithNullDevice];
    self.task.standardOutput = log;
    self.task.standardError = log;
    __weak TPUpgradeController *weakSelf = self;
    self.logTimer = [NSTimer timerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *timer) {
        TPUpgradeController *owner=weakSelf;
        [owner refreshLog];
        if (!owner.task.running) { [timer invalidate]; [NSApp stopModal]; }
    }];
    [[NSRunLoop mainRunLoop] addTimer:self.logTimer forMode:NSRunLoopCommonModes];
    if (![self.task launchAndReturnError:&failure]) {
        [self.logTimer invalidate]; [log closeFile];
        if (error) *error=failure.localizedDescription;
        [files removeItemAtPath:self.directory error:NULL];
        return NO;
    }
    [window center];
    [NSApp activateIgnoringOtherApps:YES];
    [NSApp runModalForWindow:window];
    [self.logTimer invalidate];
    [log closeFile];
    [self refreshLog];
    [window orderOut:nil];
    BOOL success=self.task.terminationStatus==0;
    if (!success) {
        if (error) *error=self.output.string.length ? self.output.string : @"Homebrew update failed.";
        [files removeItemAtPath:self.directory error:NULL];
    }
    return success;
}
- (BOOL)relaunchForInstallation:(NSDictionary *)installation error:(NSString **)error {
    NSTask *restart = [NSTask new];
    restart.launchPath = @"/bin/bash";
    restart.arguments = @[@"--",self.script,@"relaunch",[NSString stringWithFormat:@"%d",getpid()],installation[@"prefix"]];
    restart.standardInput = [NSFileHandle fileHandleWithNullDevice];
    restart.standardOutput = [NSFileHandle fileHandleWithNullDevice];
    restart.standardError = [NSFileHandle fileHandleWithNullDevice];
    NSError *failure=nil;
    BOOL launched=[restart launchAndReturnError:&failure];
    if (!launched && error) *error=failure.localizedDescription;
    return launched;
}
@end
