// Development check for SpiceKit: connects to a SPICE server, waits for the
// display, sends a little input and writes the frame to a PNG.
//   cs-snapshot <host> <port> <out.png> [seconds]
#import "../ChiliSpice.h"

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        if (argc < 4) { fprintf(stderr, "usage: cs-snapshot host port out.png [seconds]\n"); return 2; }
        CSSpiceInitialize(nil, nil, nil);
        CSConnection *c = [[CSConnection alloc] initWithOptions:@{ @"host": @(argv[1]), @"port": @(argv[2]) }];
        c.enableAudio = NO;
        __block int exitCode = 1;
        [[NSNotificationCenter defaultCenter] addObserverForName:CSConnectionDidChangeNotification object:c queue:nil
                                                      usingBlock:^(NSNotification *n) {
            printf("state=%ld mouse=%ld agent=%d display=%.0fx%.0f ready=%d cursor=%s err=%s\n",
                   (long)c.state, (long)c.mouseMode, c.agentConnected, c.displaySize.width, c.displaySize.height,
                   c.displayReady, c.cursor ? "yes" : "no", c.errorMessage.UTF8String ?: "-");
        }];
        [c connect];
        double seconds = argc > 4 ? atof(argv[4]) : 4;
        NSDate *end = [NSDate dateWithTimeIntervalSinceNow:seconds];
        BOOL sentInput = NO;
        while ([end timeIntervalSinceNow] > 0) {
            [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
            if (!sentInput && c.state == CSConnectionStateConnected && c.displaySize.width > 0) {
                [c sendMacKeyCode:0x00 pressed:YES];    // 'a'
                [c sendMacKeyCode:0x00 pressed:NO];
                [c sendPositionX:10 y:10 buttonMask:0];
                [c sendMotionDx:5 dy:5 buttonMask:0];
                [c sendButton:1 pressed:YES buttonMask:1];
                [c sendButton:1 pressed:NO buttonMask:0];
                sentInput = YES;
            }
        }
        CGImageRef img = [c copyFrameIfChanged:NO];
        if (img) {
            NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:img];
            [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:@(argv[3]) atomically:YES];
            printf("frame %zux%zu written to %s\n", CGImageGetWidth(img), CGImageGetHeight(img), argv[3]);
            CGImageRelease(img);
            exitCode = 0;
        } else {
            printf("no frame received\n");
        }
        [c disconnect];
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.5]];
        return exitCode;
    }
}
