/* Independently drawn Windows-style controls; reference images are separate resources. */
static NSColor *tp_windows_blue(void) {
    return [NSColor colorWithSRGBRed:0 green:0.47 blue:0.84 alpha:1];
}
@interface TPWindowsButtonCell : NSButtonCell
@property BOOL checkboxStyle;
@end
@implementation TPWindowsButtonCell
- (void)drawWithFrame:(NSRect)frame inView:(NSView *)view {
    BOOL check = self.checkboxStyle;
    NSRect box = check ? NSMakeRect(frame.origin.x+2, NSMidY(frame)-6, 12, 12) : NSInsetRect(frame, 1, 2);
    [(check ? NSColor.whiteColor : [NSColor colorWithWhite:self.highlighted ? .81 : .89 alpha:1]) setFill];
    NSRectFill(box);
    [(self.enabled ? [NSColor colorWithWhite:.62 alpha:1] : NSColor.lightGrayColor) set];
    NSFrameRect(box);
    if (check && self.state == NSControlStateValueOn) {
        NSBezierPath *tick=[NSBezierPath bezierPath]; tick.lineWidth=1.7;
        [tick moveToPoint:NSMakePoint(NSMinX(box)+2,NSMidY(box))];
        [tick lineToPoint:NSMakePoint(NSMinX(box)+5,NSMinY(box)+3)];
        [tick lineToPoint:NSMakePoint(NSMaxX(box)-2,NSMaxY(box)-2)];
        if (view.isFlipped) {
            NSAffineTransform *flip=[NSAffineTransform transform];
            [flip translateXBy:0 yBy:2*NSMidY(box)];[flip scaleXBy:1 yBy:-1];
            [tick transformUsingAffineTransform:flip];
        }
        [NSColor.blackColor setStroke]; [tick stroke];
    }
    if (!check && [self.keyEquivalent isEqualToString:@"\r"] && self.enabled) {
        [tp_windows_blue() set]; NSFrameRectWithWidth(box,2);
    }
    NSMutableParagraphStyle *paragraph=[NSMutableParagraphStyle new];
    paragraph.alignment=check ? NSTextAlignmentLeft : NSTextAlignmentCenter;
    NSRect text=check ? NSMakeRect(NSMinX(frame)+20,NSMidY(frame)-7,frame.size.width-20,16) : NSMakeRect(NSMinX(frame),NSMidY(frame)-(view.isFlipped ? 9.5 : 4.5),frame.size.width,16);
    [self.title drawInRect:text withAttributes:@{NSFontAttributeName:self.font ?: [NSFont fontWithName:@"Tahoma" size:11], NSForegroundColorAttributeName:self.enabled ? NSColor.blackColor : NSColor.grayColor, NSParagraphStyleAttributeName:paragraph}];
    if (self.showsFirstResponder) { NSSetFocusRingStyle(NSFocusRingOnly); NSRectFill(NSInsetRect(box,-2,-2)); }
}
@end
@interface TPWindowsPopupCell : NSPopUpButtonCell
@end
@implementation TPWindowsPopupCell
- (void)drawWithFrame:(NSRect)frame inView:(NSView *)view {
    (void)view;[NSColor.whiteColor setFill];NSRectFill(NSInsetRect(frame,1,2));
    [[NSColor colorWithWhite:.6 alpha:1] set];NSFrameRect(NSInsetRect(frame,1,2));
    [self.title drawAtPoint:NSMakePoint(frame.origin.x+5,NSMidY(frame)-7) withAttributes:@{NSFontAttributeName:[NSFont fontWithName:@"Tahoma" size:11],NSForegroundColorAttributeName:NSColor.blackColor}];
    NSBezierPath *arrow=[NSBezierPath bezierPath];
    [arrow moveToPoint:NSMakePoint(NSMaxX(frame)-14,NSMidY(frame)+2)];
    [arrow lineToPoint:NSMakePoint(NSMaxX(frame)-6,NSMidY(frame)+2)];
    [arrow lineToPoint:NSMakePoint(NSMaxX(frame)-10,NSMidY(frame)-2)];
    [arrow closePath];
    if (view.isFlipped) {
        NSAffineTransform *flip=[NSAffineTransform transform];
        [flip translateXBy:0 yBy:2*NSMidY(frame)];[flip scaleXBy:1 yBy:-1];
        [arrow transformUsingAffineTransform:flip];
    }
    [NSColor.blackColor setFill];[arrow fill];
}
@end
@interface TPWindowsSliderCell : NSSliderCell
@end
@implementation TPWindowsSliderCell
- (void)drawBarInside:(NSRect)rect flipped:(BOOL)flipped {
    (void)flipped;
    [[NSColor colorWithWhite:.88 alpha:1] setFill];
    NSRectFill(NSMakeRect(rect.origin.x,NSMidY(rect)-2,rect.size.width,4));
}
- (void)drawKnob:(NSRect)rect {
    [tp_windows_blue() setFill];
    CGFloat height=MIN(20,rect.size.height-2);
    NSRect r=NSMakeRect(NSMidX(rect)-5,NSMidY(rect)-height/2,10,height);
    NSBezierPath *knob=[NSBezierPath bezierPath];
    [knob moveToPoint:NSMakePoint(NSMinX(r),NSMaxY(r))];
    [knob lineToPoint:NSMakePoint(NSMaxX(r),NSMaxY(r))];
    [knob lineToPoint:NSMakePoint(NSMaxX(r),NSMinY(r)+5)];
    [knob lineToPoint:NSMakePoint(NSMidX(r),NSMinY(r))];
    [knob lineToPoint:NSMakePoint(NSMinX(r),NSMinY(r)+5)];
    [knob closePath];
    if (self.controlView.isFlipped) {
        NSAffineTransform *flip=[NSAffineTransform transform];
        [flip translateXBy:0 yBy:2*NSMidY(rect)];[flip scaleXBy:1 yBy:-1];
        [knob transformUsingAffineTransform:flip];
    }
    [knob fill];
}
@end
// A single coordinate space avoids NSBox's extra title/content insets.
@interface TPWindowsGroupBox : NSView
@property (nonatomic, copy) NSString *title;
@end
@implementation TPWindowsGroupBox
- (void)setTitle:(NSString *)title {
    _title=[title copy];
    self.accessibilityLabel=title;
    self.accessibilityRole=NSAccessibilityGroupRole;
    [self setNeedsDisplay:YES];
}
- (void)drawRect:(NSRect)dirty {
    (void)dirty;
    [NSColor.whiteColor setFill]; NSRectFill(self.bounds);
    NSRect border=NSMakeRect(.5,.5,self.bounds.size.width-1,self.bounds.size.height-9);
    [[NSColor colorWithWhite:.82 alpha:1] set]; NSFrameRect(border);
    NSDictionary *attributes=@{NSFontAttributeName:[NSFont fontWithName:@"Tahoma" size:11],
        NSForegroundColorAttributeName:NSColor.blackColor};
    NSSize size=[self.title sizeWithAttributes:attributes];
    [NSColor.whiteColor setFill];
    NSRectFill(NSMakeRect(12,self.bounds.size.height-17,size.width+8,17));
    [self.title drawAtPoint:NSMakePoint(16,self.bounds.size.height-15) withAttributes:attributes];
}
@end
@interface TPWindowsPropertyWindow : NSWindow
@end
@implementation TPWindowsPropertyWindow
- (BOOL)canBecomeKeyWindow { return YES; }
- (BOOL)canBecomeMainWindow { return YES; }
@end
@interface TPWindowsPropertyPanel : NSPanel
@end
@implementation TPWindowsPropertyPanel
- (BOOL)canBecomeKeyWindow { return YES; }
@end
@interface TPWindowsTitleBar : NSView
@property (copy) NSString *caption;
@end
@implementation TPWindowsTitleBar
- (BOOL)mouseDownCanMoveWindow { return YES; }
- (void)drawRect:(NSRect)dirty {
    (void)dirty; [tp_windows_blue() setFill]; NSRectFill(self.bounds);
    [(self.caption ?: @"▱  Keyboard Properties") drawAtPoint:NSMakePoint(10,8) withAttributes:@{NSFontAttributeName:[NSFont fontWithName:@"Tahoma" size:12],NSForegroundColorAttributeName:NSColor.whiteColor}];
}
@end
@interface TPWindowsCloseCell : NSButtonCell
@end
@implementation TPWindowsCloseCell
- (void)drawWithFrame:(NSRect)frame inView:(NSView *)view {
    (void)view;
    if (self.highlighted) { [NSColor.systemRedColor setFill];NSRectFill(frame); }
    [@"×" drawAtPoint:NSMakePoint(NSMidX(frame)-5,NSMidY(frame)-10) withAttributes:@{NSFontAttributeName:[NSFont fontWithName:@"Tahoma" size:21],NSForegroundColorAttributeName:NSColor.whiteColor}];
}
@end
@interface TPWindowsTabView : NSTabView
@end
@implementation TPWindowsTabView
- (void)drawRect:(NSRect)dirty {
    (void)dirty; [NSColor.whiteColor setFill]; NSRectFill(self.bounds);
    [[NSColor colorWithWhite:.82 alpha:1] set]; NSFrameRect(self.bounds);
}
@end
@interface TPWindowsTabCell : NSButtonCell
@end
@implementation TPWindowsTabCell
- (void)drawWithFrame:(NSRect)frame inView:(NSView *)view {
    (void)view;
    [(self.state ? NSColor.whiteColor : [NSColor colorWithWhite:.94 alpha:1]) setFill]; NSRectFill(frame);
    [[NSColor colorWithWhite:.82 alpha:1] set]; NSFrameRect(frame);
    [self.title drawAtPoint:NSMakePoint(frame.origin.x+7,frame.origin.y+5) withAttributes:@{NSFontAttributeName:[NSFont fontWithName:@"Tahoma" size:11],NSForegroundColorAttributeName:NSColor.blackColor}];
}
@end
static void tp_apply_windows_theme(NSView *view) {
    view.appearance=[NSAppearance appearanceNamed:NSAppearanceNameAqua];
    if ([view isKindOfClass:NSTextField.class]) {
        NSTextField *field=(NSTextField *)view;
        field.font=[NSFont fontWithName:@"Tahoma" size:11];
        field.textColor=NSColor.blackColor;
    }
    if ([view isKindOfClass:NSPopUpButton.class]) {
        NSPopUpButton *popup=(NSPopUpButton *)view;
        NSPopUpButtonCell *old=popup.cell;
        NSInteger selected=popup.indexOfSelectedItem;
        TPWindowsPopupCell *cell=[[TPWindowsPopupCell alloc] initTextCell:@"" pullsDown:NO];
        cell.menu=old.menu;cell.target=old.target;cell.action=old.action;
        popup.cell=cell;[popup selectItemAtIndex:selected];
    }
    if ([view isKindOfClass:NSButton.class]) {
        NSButton *button=(NSButton *)view;
        if (![button isKindOfClass:NSPopUpButton.class]) {
            NSButtonCell *old=button.cell;
            TPWindowsButtonCell *cell=[[TPWindowsButtonCell alloc] initTextCell:button.title];
            cell.checkboxStyle = !button.bordered;
            [cell setButtonType:cell.checkboxStyle ? NSButtonTypeSwitch : NSButtonTypeMomentaryPushIn]; cell.state=old.state;
            cell.target=old.target;cell.action=old.action;cell.keyEquivalent=old.keyEquivalent;
            cell.enabled=old.enabled;cell.font=[NSFont fontWithName:@"Tahoma" size:11];
            button.cell=cell;
        }
    }
    if ([view isKindOfClass:NSSlider.class]) {
        NSSlider *slider=(NSSlider *)view;
        TPWindowsSliderCell *cell=[TPWindowsSliderCell new];
        cell.minValue=slider.minValue;cell.maxValue=slider.maxValue;
        cell.numberOfTickMarks=slider.numberOfTickMarks;cell.allowsTickMarkValuesOnly=slider.allowsTickMarkValuesOnly;
        cell.doubleValue=slider.doubleValue;cell.target=slider.target;cell.action=slider.action;
        cell.continuous=slider.continuous;slider.cell=cell;
    }
    for (NSView *child in view.subviews) tp_apply_windows_theme(child);
}
