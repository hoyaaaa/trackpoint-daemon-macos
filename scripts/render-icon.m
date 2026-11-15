#import <Cocoa/Cocoa.h>
#import "../icon.h"
int main(int argc,const char **argv) {
    @autoreleasepool {
        if(argc!=2) return 2;
        const size_t size=1024;
        CGColorSpaceRef space=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        CGContextRef context=CGBitmapContextCreate(NULL,size,size,8,size*4,space,
            kCGImageAlphaPremultipliedLast|kCGBitmapByteOrder32Big);
        assert(context);
        [NSGraphicsContext saveGraphicsState];
        [NSGraphicsContext setCurrentContext:[NSGraphicsContext graphicsContextWithCGContext:context flipped:NO]];
        draw_trackpoint_icon(NSMakeRect(0,0,size,size),
            [NSColor colorWithSRGBRed:36.0/255.0 green:36.0/255.0 blue:36.0/255.0 alpha:1],trackpoint_red());
        [NSGraphicsContext restoreGraphicsState];
        CGImageRef image=CGBitmapContextCreateImage(context);
        NSBitmapImageRep *rep=[[NSBitmapImageRep alloc] initWithCGImage:image];
        BOOL saved=[[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}]
            writeToFile:[NSString stringWithUTF8String:argv[1]] atomically:YES];
        CGImageRelease(image); CGContextRelease(context); CGColorSpaceRelease(space);
        return saved ? 0 : 1;
    }
}
