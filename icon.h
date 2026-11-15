/* App and menu bar use identical 18x16 coordinates; square assets are letterboxed. */
static NSColor *trackpoint_red(void) {
    return [NSColor colorWithSRGBRed:226.0/255.0 green:35.0/255.0 blue:26.0/255.0 alpha:1.0];
}
static void draw_trackpoint_icon(NSRect bounds, NSColor *background, NSColor *dot) {
    CGFloat scale=MIN(bounds.size.width/18.0,bounds.size.height/16.0);
    CGContextRef context=NSGraphicsContext.currentContext.CGContext;
    CGContextSaveGState(context);
    CGContextTranslateCTM(context,NSMidX(bounds)-9*scale,NSMidY(bounds)-8*scale);
    CGContextScaleCTM(context,scale,scale);
    CGPathRef body=CGPathCreateWithRoundedRect(CGRectMake(1,2,16,12),3,3,NULL);
    CGContextSetFillColorWithColor(context,background.CGColor);
    CGContextAddPath(context,body); CGContextFillPath(context); CGPathRelease(body);
    CGContextSetFillColorWithColor(context,dot.CGColor);
    CGContextFillEllipseInRect(context,CGRectMake(6.5,5.5,5,5));
    CGContextRestoreGState(context);
}
