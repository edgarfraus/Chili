// CSDisplayView: draws a CSConnection's display and turns AppKit events into SPICE input.

#import "ChiliSpice.h"
#import <QuartzCore/QuartzCore.h>
#import <Carbon/Carbon.h>   // kVK_* key codes

static BOOL cs_modifier_key_down(NSEvent *event);

@interface CSDisplayView () {
    NSTimer *_frameTimer;
    NSTrackingArea *_tracking;
    int _buttonMask;
    CGFloat _scrollAccumulator;
    CGFloat _motionRemainderX, _motionRemainderY;
    NSEventModifierFlags _modifiers;
    NSTimer *_resizeTimer;
    CGSize _requestedGuestSize;
}
@property (nonatomic, readwrite) BOOL pointerCaptured;
@end

@implementation CSDisplayView

- (instancetype)initWithFrame:(NSRect)frame
{
    if ((self = [super initWithFrame:frame])) {
        self.wantsLayer = YES;
        self.layer.backgroundColor = NSColor.blackColor.CGColor;
        self.layer.contentsGravity = kCAGravityResizeAspect;
        self.layer.magnificationFilter = kCAFilterLinear;
        self.layer.minificationFilter = kCAFilterTrilinear;
        self.layerContentsRedrawPolicy = NSViewLayerContentsRedrawNever;
        _resizeGuestToFit = YES;
    }
    return self;
}

- (void)dealloc
{
    [self releasePointer];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }
- (BOOL)wantsUpdateLayer { return YES; }

// Only used for offscreen rendering (cacheDisplayInRect:); on screen the layer shows the frame.
- (void)drawRect:(NSRect)dirtyRect
{
    [NSColor.blackColor setFill];
    NSRectFill(self.bounds);
    CGImageRef image = [self.connection copyFrameIfChanged:NO];
    if (!image) return;
    CGContextRef ctx = NSGraphicsContext.currentContext.CGContext;
    NSRect r = [self imageRect];
    CGContextSaveGState(ctx);
    CGContextTranslateCTM(ctx, r.origin.x, r.origin.y + r.size.height);
    CGContextScaleCTM(ctx, 1, -1);
    CGContextDrawImage(ctx, CGRectMake(0, 0, r.size.width, r.size.height), image);
    CGContextRestoreGState(ctx);
    CGImageRelease(image);
}

#pragma mark Connection

- (void)setConnection:(CSConnection *)connection
{
    if (_connection == connection) return;
    [self releasePointer];
    [_connection releaseAllKeys];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:CSConnectionDidChangeNotification object:_connection];
    _connection = connection;
    self.layer.contents = nil;
    if (connection) {
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(connectionChanged:)
                                                     name:CSConnectionDidChangeNotification object:connection];
        [self showFrame:YES];
    }
    [self updateTimer];
    [self.window invalidateCursorRectsForView:self];
}

- (void)connectionChanged:(NSNotification *)note
{
    if (self.connection.mouseMode == CSMouseModeClient) [self releasePointer];
    if (self.connection.state != CSConnectionStateConnected) [self releasePointer];
    [self.window invalidateCursorRectsForView:self];
    [self scheduleGuestResize];
    [self showFrame:NO];
}

- (void)viewDidMoveToWindow
{
    [super viewDidMoveToWindow];
    [self updateTimer];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:NSWindowDidResignKeyNotification object:nil];
    if (self.window) {
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(windowResignedKey:)
                                                     name:NSWindowDidResignKeyNotification object:self.window];
    } else {
        [self releasePointer];
    }
}

- (void)windowResignedKey:(NSNotification *)note
{
    [self releasePointer];
    [self.connection releaseAllKeys];
    _modifiers = 0;
}

- (void)updateTimer
{
    BOOL want = self.window && self.connection;
    if (want && !_frameTimer) {
        __weak CSDisplayView *weakSelf = self;
        _frameTimer = [NSTimer timerWithTimeInterval:1.0 / 60 repeats:YES block:^(NSTimer *t) {
            [weakSelf showFrame:NO];
        }];
        [[NSRunLoop mainRunLoop] addTimer:_frameTimer forMode:NSRunLoopCommonModes];
    } else if (!want && _frameTimer) {
        [_frameTimer invalidate];
        _frameTimer = nil;
    }
}

- (void)showFrame:(BOOL)force
{
    CGImageRef image = [self.connection copyFrameIfChanged:!force];
    if (!image) return;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.layer.contents = (__bridge id)image;
    [CATransaction commit];
    CGImageRelease(image);
}

#pragma mark Geometry

/// Where the guest image is drawn inside the view (aspect fit).
- (NSRect)imageRect
{
    CGSize g = self.connection.displaySize;
    NSRect b = self.bounds;
    if (g.width <= 0 || g.height <= 0 || b.size.width <= 0 || b.size.height <= 0) return NSZeroRect;
    CGFloat scale = MIN(b.size.width / g.width, b.size.height / g.height);
    CGFloat w = g.width * scale, h = g.height * scale;
    return NSMakeRect(NSMidX(b) - w / 2, NSMidY(b) - h / 2, w, h);
}

- (BOOL)guestPoint:(NSEvent *)event x:(int *)x y:(int *)y
{
    NSRect r = [self imageRect];
    if (NSIsEmptyRect(r)) return NO;
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    CGSize g = self.connection.displaySize;
    double gx = (p.x - r.origin.x) * g.width / r.size.width;
    double gy = (p.y - r.origin.y) * g.height / r.size.height;
    *x = (int)MAX(0, MIN(g.width - 1, floor(gx)));
    *y = (int)MAX(0, MIN(g.height - 1, floor(gy)));
    return NSPointInRect(p, r);
}

- (void)setFrameSize:(NSSize)newSize
{
    [super setFrameSize:newSize];
    [self scheduleGuestResize];
}

- (void)viewDidChangeBackingProperties
{
    [super viewDidChangeBackingProperties];
    [self scheduleGuestResize];
}

- (void)setResizeGuestToFit:(BOOL)value { _resizeGuestToFit = value; [self scheduleGuestResize]; }
- (void)setUseRetinaResolution:(BOOL)value { _useRetinaResolution = value; [self scheduleGuestResize]; }

/// Ask the guest for the view's size once resizing settles (needs the agent).
- (void)scheduleGuestResize
{
    if (!self.resizeGuestToFit || !self.connection.agentConnected || !self.window) return;
    [_resizeTimer invalidate];
    __weak CSDisplayView *weakSelf = self;
    _resizeTimer = [NSTimer scheduledTimerWithTimeInterval:0.4 repeats:NO block:^(NSTimer *t) {
        [weakSelf sendGuestResize];
    }];
}

- (void)sendGuestResize
{
    if (self.inLiveResize) { [self scheduleGuestResize]; return; }
    CGFloat scale = self.useRetinaResolution ? self.window.backingScaleFactor : 1;
    CGSize size = CGSizeMake(floor(self.bounds.size.width * scale), floor(self.bounds.size.height * scale));
    if (CGSizeEqualToSize(size, _requestedGuestSize) && CGSizeEqualToSize(size, self.connection.displaySize)) return;
    _requestedGuestSize = size;
    [self.connection requestResolutionWidth:(int)size.width height:(int)size.height];
}

- (void)viewDidEndLiveResize
{
    [super viewDidEndLiveResize];
    [self scheduleGuestResize];
}

#pragma mark Cursor

- (void)updateTrackingAreas
{
    [super updateTrackingAreas];
    if (_tracking) [self removeTrackingArea:_tracking];
    _tracking = [[NSTrackingArea alloc] initWithRect:NSZeroRect
                                             options:NSTrackingMouseMoved | NSTrackingActiveInKeyWindow |
                                                     NSTrackingInVisibleRect | NSTrackingCursorUpdate |
                                                     NSTrackingMouseEnteredAndExited
                                               owner:self userInfo:nil];
    [self addTrackingArea:_tracking];
}

+ (NSCursor *)invisibleCursor
{
    static NSCursor *cursor;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSImage *image = [[NSImage alloc] initWithSize:NSMakeSize(1, 1)];
        cursor = [[NSCursor alloc] initWithImage:image hotSpot:NSZeroPoint];
    });
    return cursor;
}

- (NSCursor *)currentCursor
{
    CSConnection *c = self.connection;
    if (c.state != CSConnectionStateConnected || c.mouseMode != CSMouseModeClient) return NSCursor.arrowCursor;
    if (c.cursorHidden) return [CSDisplayView invisibleCursor];
    return c.cursor ?: NSCursor.arrowCursor;
}

- (void)resetCursorRects
{
    [self addCursorRect:self.bounds cursor:[self currentCursor]];
}

- (void)cursorUpdate:(NSEvent *)event
{
    [[self currentCursor] set];
}

#pragma mark Pointer capture (server mouse mode)

- (void)capturePointer
{
    if (self.pointerCaptured || !self.window) return;
    self.pointerCaptured = YES;
    _motionRemainderX = _motionRemainderY = 0;
    // Park the cursor in the middle of the view and freeze it there: we read raw
    // deltas instead of warping, which macOS does poorly.
    NSRect r = [self convertRect:self.bounds toView:nil];
    r = [self.window convertRectToScreen:r];
    CGFloat screenTop = NSMaxY(NSScreen.screens.firstObject.frame);
    CGWarpMouseCursorPosition(CGPointMake(NSMidX(r), screenTop - NSMidY(r)));
    CGAssociateMouseAndMouseCursorPosition(false);
    [NSCursor hide];
    if (self.captureChanged) self.captureChanged(YES);
}

- (void)releasePointer
{
    if (!self.pointerCaptured) return;
    self.pointerCaptured = NO;
    CGAssociateMouseAndMouseCursorPosition(true);
    [NSCursor unhide];
    if (self.captureChanged) self.captureChanged(NO);
}

#pragma mark Mouse

- (int)maskForButton:(NSInteger)n
{
    switch (n) {
    case 0: return 1 << 0;   // left
    case 1: return 1 << 2;   // right
    case 2: return 1 << 1;   // middle
    default: return 0;
    }
}

- (int)spiceButton:(NSInteger)n
{
    switch (n) {
    case 0: return 1;
    case 1: return 3;
    case 2: return 2;
    default: return 0;
    }
}

- (void)handleMotion:(NSEvent *)event
{
    CSConnection *c = self.connection;
    if (c.state != CSConnectionStateConnected) return;
    if (c.mouseMode == CSMouseModeClient) {
        int x, y;
        if ([self guestPoint:event x:&x y:&y] || _buttonMask)
            [c sendPositionX:x y:y buttonMask:_buttonMask];
    } else if (self.pointerCaptured) {
        CGFloat dx = event.deltaX + _motionRemainderX, dy = event.deltaY + _motionRemainderY;
        int ix = (int)trunc(dx), iy = (int)trunc(dy);
        _motionRemainderX = dx - ix;
        _motionRemainderY = dy - iy;
        if (ix || iy) [c sendMotionDx:ix dy:iy buttonMask:_buttonMask];
    }
}

- (void)mouseMoved:(NSEvent *)event { [self handleMotion:event]; }
- (void)mouseDragged:(NSEvent *)event { [self handleMotion:event]; }
- (void)rightMouseDragged:(NSEvent *)event { [self handleMotion:event]; }
- (void)otherMouseDragged:(NSEvent *)event { [self handleMotion:event]; }

- (void)handleButton:(NSEvent *)event pressed:(BOOL)pressed
{
    CSConnection *c = self.connection;
    if (c.state != CSConnectionStateConnected) return;
    if (pressed) [self.window makeFirstResponder:self];
    if (pressed && c.mouseMode == CSMouseModeServer && !self.pointerCaptured) {
        [self capturePointer];   // this click only captures
        return;
    }
    int button = [self spiceButton:event.buttonNumber];
    if (!button) return;
    if (c.mouseMode == CSMouseModeClient) [self handleMotion:event];
    if (pressed) _buttonMask |= [self maskForButton:event.buttonNumber];
    else _buttonMask &= ~[self maskForButton:event.buttonNumber];
    [c sendButton:button pressed:pressed buttonMask:_buttonMask];
}

- (void)mouseDown:(NSEvent *)event { [self handleButton:event pressed:YES]; }
- (void)mouseUp:(NSEvent *)event { [self handleButton:event pressed:NO]; }
- (void)rightMouseDown:(NSEvent *)event { [self handleButton:event pressed:YES]; }
- (void)rightMouseUp:(NSEvent *)event { [self handleButton:event pressed:NO]; }
- (void)otherMouseDown:(NSEvent *)event { [self handleButton:event pressed:YES]; }
- (void)otherMouseUp:(NSEvent *)event { [self handleButton:event pressed:NO]; }

- (void)scrollWheel:(NSEvent *)event
{
    CSConnection *c = self.connection;
    if (c.state != CSConnectionStateConnected) return;
    if (c.mouseMode == CSMouseModeServer && !self.pointerCaptured) return;
    // Trackpads report pixels: roughly 10 points per wheel notch.
    CGFloat delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 10.0 : event.scrollingDeltaY;
    _scrollAccumulator += delta;
    while (fabs(_scrollAccumulator) >= 1) {
        int button = _scrollAccumulator > 0 ? 4 : 5;   // 4 = wheel up
        [c sendButton:button pressed:YES buttonMask:_buttonMask];
        [c sendButton:button pressed:NO buttonMask:_buttonMask];
        _scrollAccumulator -= _scrollAccumulator > 0 ? 1 : -1;
    }
}

#pragma mark Keyboard

- (void)keyDown:(NSEvent *)event
{
    if (self.connection.state == CSConnectionStateConnected)
        [self.connection sendMacKeyCode:event.keyCode pressed:YES];
}

- (void)keyUp:(NSEvent *)event
{
    if (self.connection.state == CSConnectionStateConnected)
        [self.connection sendMacKeyCode:event.keyCode pressed:NO];
}

static NSEventModifierFlags cs_flag_for_key(unsigned short keyCode)
{
    switch (keyCode) {
    case kVK_Shift: case kVK_RightShift: return NSEventModifierFlagShift;
    case kVK_Control: case kVK_RightControl: return NSEventModifierFlagControl;
    case kVK_Option: case kVK_RightOption: return NSEventModifierFlagOption;
    case kVK_Command: case kVK_RightCommand: return NSEventModifierFlagCommand;
    case kVK_CapsLock: return NSEventModifierFlagCapsLock;
    case kVK_Function: return NSEventModifierFlagFunction;
    default: return 0;
    }
}

- (void)flagsChanged:(NSEvent *)event
{
    CSConnection *c = self.connection;
    NSEventModifierFlags flag = cs_flag_for_key(event.keyCode);
    NSEventModifierFlags flags = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;

    // Ctrl+Alt releases a captured pointer (same as remote-viewer).
    if (self.pointerCaptured && (flags & NSEventModifierFlagControl) && (flags & NSEventModifierFlagOption)) {
        [self releasePointer];
    }
    if (c.state != CSConnectionStateConnected || !flag || flag == NSEventModifierFlagFunction) {
        _modifiers = flags;
        return;
    }
    if (flag == NSEventModifierFlagCapsLock) {
        // macOS reports the lock state, not the key: send a full press each toggle.
        [c sendMacKeyCode:event.keyCode pressed:YES];
        [c sendMacKeyCode:event.keyCode pressed:NO];
    } else {
        [c sendMacKeyCode:event.keyCode pressed:cs_modifier_key_down(event)];
    }
    _modifiers = flags;
}

/// Left and right modifier keys share one flag; the device-dependent bits
/// (NX_DEVICE*KEYMASK) tell whether this particular key is down.
static BOOL cs_modifier_key_down(NSEvent *event)
{
    NSUInteger raw = event.modifierFlags;
    switch (event.keyCode) {
    case kVK_Shift: return (raw & 0x00000002) != 0;
    case kVK_RightShift: return (raw & 0x00000004) != 0;
    case kVK_Control: return (raw & 0x00000001) != 0;
    case kVK_RightControl: return (raw & 0x00002000) != 0;
    case kVK_Option: return (raw & 0x00000020) != 0;
    case kVK_RightOption: return (raw & 0x00000040) != 0;
    case kVK_Command: return (raw & 0x00000008) != 0;
    case kVK_RightCommand: return (raw & 0x00000010) != 0;
    default: return NO;
    }
}

- (BOOL)resignFirstResponder
{
    [self.connection releaseAllKeys];
    _modifiers = 0;
    return [super resignFirstResponder];
}

@end
