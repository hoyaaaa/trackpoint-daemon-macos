/* Regenerate PNG: clang -fobjc-arc scripts/render-icon.m -framework Cocoa
 * -framework ImageIO -o /tmp/render-icon && /tmp/render-icon TrackPointD.png */
#import <Cocoa/Cocoa.h>
#import <ImageIO/ImageIO.h>
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
        const uint8_t *pixels=CGBitmapContextGetData(context);
        const uint8_t *center=pixels+(size/2*size+size/2)*4;
        assert(center[0]==226 && center[1]==35 && center[2]==26 && center[3]==255);
        assert(pixels[3]==0); /* Preserve transparent padding, never stretch to square. */
        CGImageRef image=CGBitmapContextCreateImage(context);
        NSURL *output=[NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[1]]];
        CGImageDestinationRef destination=CGImageDestinationCreateWithURL(
            (__bridge CFURLRef)output,CFSTR("public.png"),1,NULL);
        assert(destination);
        CGImageDestinationAddImage(destination,image,NULL);
        BOOL saved=CGImageDestinationFinalize(destination);
        CFRelease(destination);
        CGImageRelease(image); CGContextRelease(context); CGColorSpaceRelease(space);
        return saved ? 0 : 1;
    }
}
