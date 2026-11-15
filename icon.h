/* App and menu bar use identical 18x16 coordinates; square assets are letterboxed. */
static NSColor *trackpoint_red(void) {
    return [NSColor colorWithSRGBRed:226.0/255.0 green:35.0/255.0 blue:26.0/255.0 alpha:1.0];
}
static void draw_trackpoint_icon(NSRect bounds, NSColor *background, NSColor *dot) {
    CGFloat scale=MIN(bounds.size.width/18.0,bounds.size.height/16.0);
    NSAffineTransform *transform=[NSAffineTransform transform];
    [transform translateXBy:NSMidX(bounds)-9*scale yBy:NSMidY(bounds)-8*scale];
    [transform scaleBy:scale];
    [NSGraphicsContext saveGraphicsState];
    [transform concat];
    [background setFill];
    [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(1,2,16,12) xRadius:3 yRadius:3] fill];
    [dot setFill];
    [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(6.5,5.5,5,5)] fill];
    [NSGraphicsContext restoreGraphicsState];
}
