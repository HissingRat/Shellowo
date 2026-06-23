#import <AppKit/AppKit.h>
#include <stdlib.h>
#include <string.h>

typedef struct ShellowoEmojiBitmap {
    unsigned char *pixels;
    int width;
    int height;
    int stride;
} ShellowoEmojiBitmap;

int shellowo_render_emoji_bitmap(
    const char *utf8,
    size_t utf8_len,
    double point_size,
    ShellowoEmojiBitmap *out_bitmap
) {
    if (out_bitmap == NULL) return 0;
    memset(out_bitmap, 0, sizeof(*out_bitmap));
    if (utf8 == NULL || utf8_len == 0 || point_size <= 0.0) return 0;

    @autoreleasepool {
        NSString *text = [[NSString alloc] initWithBytes:utf8
                                                  length:utf8_len
                                                encoding:NSUTF8StringEncoding];
        if (text == nil || text.length == 0) return 0;

        NSFont *font = [NSFont systemFontOfSize:(CGFloat)point_size];
        NSFont *emoji_font = [NSFont fontWithName:@"Apple Color Emoji" size:(CGFloat)point_size];
        if (emoji_font != nil) font = emoji_font;

        NSDictionary<NSAttributedStringKey, id> *attributes = @{
            NSFontAttributeName : font,
            NSForegroundColorAttributeName : NSColor.whiteColor,
        };
        NSSize measured = [text sizeWithAttributes:attributes];
        CGFloat padding_f = 0.0;

        int width = (int)ceil(measured.width + padding_f * 2.0);
        int height = (int)ceil(measured.height + padding_f * 2.0);
        int minimum = (int)ceil(point_size);
        if (width < minimum) width = minimum;
        if (height < minimum) height = minimum;
        if (width <= 0 || height <= 0 || width > 1024 || height > 1024) return 0;

        NSBitmapImageRep *rep = [[NSBitmapImageRep alloc]
            initWithBitmapDataPlanes:NULL
                          pixelsWide:width
                          pixelsHigh:height
                       bitsPerSample:8
                     samplesPerPixel:4
                            hasAlpha:YES
                            isPlanar:NO
                      colorSpaceName:NSDeviceRGBColorSpace
                         bytesPerRow:width * 4
                        bitsPerPixel:32];
        if (rep == nil || rep.bitmapData == NULL) return 0;

        NSGraphicsContext *context = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
        if (context == nil) return 0;

        [NSGraphicsContext saveGraphicsState];
        [NSGraphicsContext setCurrentContext:context];
        [NSColor.clearColor setFill];
        NSRectFill(NSMakeRect(0, 0, width, height));
        [text drawAtPoint:NSMakePoint(padding_f, padding_f) withAttributes:attributes];
        [NSGraphicsContext restoreGraphicsState];

        const int source_stride = (int)rep.bytesPerRow;
        unsigned char *source = rep.bitmapData;
        int min_x = width;
        int min_y = height;
        int max_x = -1;
        int max_y = -1;
        for (int y = 0; y < height; y++) {
            unsigned char *row = source + ((size_t)y * (size_t)source_stride);
            for (int x = 0; x < width; x++) {
                unsigned char alpha = row[(size_t)x * 4 + 3];
                if (alpha == 0) continue;
                if (x < min_x) min_x = x;
                if (y < min_y) min_y = y;
                if (x > max_x) max_x = x;
                if (y > max_y) max_y = y;
            }
        }

        if (max_x >= min_x && max_y >= min_y) {
            width = max_x - min_x + 1;
            height = max_y - min_y + 1;
        } else {
            min_x = 0;
            min_y = 0;
        }

        const int stride = width * 4;
        const size_t byte_len = (size_t)stride * (size_t)height;
        unsigned char *copy = (unsigned char *)malloc(byte_len);
        if (copy == NULL) return 0;
        for (int y = 0; y < height; y++) {
            unsigned char *dst_row = copy + ((size_t)y * (size_t)stride);
            unsigned char *src_row = source + ((size_t)(min_y + y) * (size_t)source_stride) + ((size_t)min_x * 4);
            memcpy(dst_row, src_row, (size_t)stride);
        }

        out_bitmap->pixels = copy;
        out_bitmap->width = width;
        out_bitmap->height = height;
        out_bitmap->stride = stride;
        return 1;
    }
}

void shellowo_free_emoji_bitmap(unsigned char *pixels) {
    free(pixels);
}
