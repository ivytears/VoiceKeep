// AppIcon.m — 画 留声 的应用图标（1024×1024 PNG），由 make-icon.sh 编译运行
// 用 Objective-C 而不是 Swift：CLT 的 swift 编译器和 SDK 版本经常对不上，clang 没这个问题
// 编译: clang -fobjc-arc -framework AppKit -o AppIcon AppIcon.m && ./AppIcon <输出 png 路径>
#import <AppKit/AppKit.h>

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSString *outPath = argc > 1 ? [NSString stringWithUTF8String:argv[1]] : @"icon-1024.png";
        const NSInteger size = 1024;

        NSBitmapImageRep *rep = [[NSBitmapImageRep alloc]
            initWithBitmapDataPlanes:NULL pixelsWide:size pixelsHigh:size bitsPerSample:8
                     samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace
                         bytesPerRow:0 bitsPerPixel:0];
        NSGraphicsContext *ctx = rep ? [NSGraphicsContext graphicsContextWithBitmapImageRep:rep] : nil;
        if (!ctx) {
            fprintf(stderr, "创建画布失败\n");
            return 1;
        }
        [NSGraphicsContext saveGraphicsState];
        [NSGraphicsContext setCurrentContext:ctx];

        // macOS 图标规范：图形占画布约 80%，四周留透明边，系统会自己加阴影
        CGFloat canvas = size;
        CGFloat inset = canvas * 0.1;
        NSRect rect = NSMakeRect(inset, inset, canvas - inset * 2, canvas - inset * 2);
        [[NSBezierPath bezierPathWithRoundedRect:rect
                                         xRadius:rect.size.width * 0.2237
                                         yRadius:rect.size.height * 0.2237] addClip];

        // 底色：靛蓝 → 紫，斜向渐变
        NSGradient *background = [[NSGradient alloc] initWithColors:@[
            [NSColor colorWithCalibratedRed:0.17 green:0.15 blue:0.48 alpha:1],
            [NSColor colorWithCalibratedRed:0.45 green:0.17 blue:0.86 alpha:1],
        ]];
        [background drawInRect:rect angle:60];
        // 顶部一点高光，避免死平
        NSGradient *gloss = [[NSGradient alloc] initWithColors:@[
            [[NSColor whiteColor] colorWithAlphaComponent:0.16],
            [[NSColor whiteColor] colorWithAlphaComponent:0.0],
        ]];
        [gloss drawInRect:rect angle:-90];

        // 声波：7 根圆头竖条，中间高两边低——"有人在说话"
        const CGFloat heights[] = {0.24, 0.44, 0.68, 0.92, 0.68, 0.44, 0.24};
        const NSInteger count = sizeof(heights) / sizeof(heights[0]);
        CGFloat barWidth = rect.size.width * 0.064;
        CGFloat gap = rect.size.width * 0.046;
        CGFloat totalWidth = count * barWidth + (count - 1) * gap;
        CGFloat maxHeight = rect.size.height * 0.54;
        CGFloat x = NSMidX(rect) - totalWidth / 2;
        [[NSColor whiteColor] setFill];
        for (NSInteger i = 0; i < count; i++) {
            CGFloat barHeight = maxHeight * heights[i];
            NSRect bar = NSMakeRect(x, NSMidY(rect) - barHeight / 2, barWidth, barHeight);
            [[NSBezierPath bezierPathWithRoundedRect:bar xRadius:barWidth / 2 yRadius:barWidth / 2] fill];
            x += barWidth + gap;
        }

        [NSGraphicsContext restoreGraphicsState];

        NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        NSError *error = nil;
        if (!png || ![png writeToFile:outPath options:NSDataWritingAtomic error:&error]) {
            fprintf(stderr, "写文件失败: %s\n", error ? error.localizedDescription.UTF8String : "PNG 导出失败");
            return 1;
        }
    }
    return 0;
}
