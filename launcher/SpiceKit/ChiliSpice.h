// Native SPICE client for Chili, built directly on spice-client-glib (no GTK).
//
// Threading: spice-glib runs on its own GLib main loop thread (CSSpiceThread).
// Everything here is called from the main thread; calls into spice-glib are
// marshalled to the SPICE thread, and change notifications arrive on the main thread.
//
// This header is imported by Swift, so it must not include any GLib header.

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, CSMouseMode) {
    CSMouseModeServer = 1,   // relative motion, pointer must be captured
    CSMouseModeClient = 2,   // absolute positions (guest agent or USB tablet)
};

typedef NS_ENUM(NSInteger, CSConnectionState) {
    CSConnectionStateConnecting,
    CSConnectionStateConnected,
    CSConnectionStateDisconnected,
};

/// Sets up the process-wide environment (GStreamer plugins for audio, etc.)
/// and starts the SPICE thread. Call once at launch, before any connection.
void CSSpiceInitialize(NSString *_Nullable gstPluginDir, NSString *_Nullable gstScanner,
                       NSString *_Nullable gstRegistry);

/// Posted on the main thread whenever any observable property of a connection
/// changes (state, display, mouse mode, agent, cursor). Object: the connection.
extern NSNotificationName const CSConnectionDidChangeNotification;

@interface CSConnection : NSObject

/// Options are the keys of a virt-viewer .vv file: host, port, tls-port,
/// password, ca, host-subject, proxy, title…
- (instancetype)initWithOptions:(NSDictionary<NSString *, NSString *> *)options NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@property (nonatomic, readonly) NSDictionary<NSString *, NSString *> *options;
@property (nonatomic, readonly) NSString *title;
@property (nonatomic, readonly) CSConnectionState state;
/// Human-readable reason for the last disconnection, if it was an error.
@property (nonatomic, readonly, nullable) NSString *errorMessage;
@property (nonatomic, readonly) CSMouseMode mouseMode;
@property (nonatomic, readonly) BOOL agentConnected;
/// Size of the guest's primary surface in pixels (zero until it appears).
@property (nonatomic, readonly) CGSize displaySize;
/// The guest says the display content is valid (false while e.g. rebooting).
@property (nonatomic, readonly) BOOL displayReady;
/// Cursor image sent by the guest (client mouse mode), nil = hidden.
@property (nonatomic, readonly, nullable) NSCursor *cursor;
@property (nonatomic, readonly) BOOL cursorHidden;
/// Two-way clipboard sharing with the guest agent. Default YES.
@property (nonatomic) BOOL shareClipboard;
/// Play guest audio and allow recording. Default YES; set before -connect.
@property (nonatomic) BOOL enableAudio;

- (void)connect;
- (void)disconnect;

// Input. Buttons: 1 left, 2 middle, 3 right, 4 wheel up, 5 wheel down.
// Masks: bit 0 left, bit 1 middle, bit 2 right.
- (void)sendKey:(uint16_t)scancode pressed:(BOOL)pressed;
- (void)sendMacKeyCode:(uint16_t)keyCode pressed:(BOOL)pressed;
- (void)sendCtrlAltDel;
- (void)releaseAllKeys;
- (void)sendMotionDx:(int)dx dy:(int)dy buttonMask:(int)mask;
- (void)sendPositionX:(int)x y:(int)y buttonMask:(int)mask;
- (void)sendButton:(int)button pressed:(BOOL)pressed buttonMask:(int)mask;

/// Asks the guest agent to switch to this resolution (no-op without agent).
- (void)requestResolutionWidth:(int)width height:(int)height;

/// Copy of the current frame, or NULL when there is nothing to show.
/// Clears the "dirty" flag; call from the main thread.
- (nullable CGImageRef)copyFrameIfChanged:(BOOL)onlyIfChanged CF_RETURNS_RETAINED;

@end

/// Shows a connection's display and forwards keyboard and mouse to it.
@interface CSDisplayView : NSView

@property (nonatomic, strong, nullable) CSConnection *connection;
/// Resize the guest to the view (requires the guest agent). Default YES.
@property (nonatomic) BOOL resizeGuestToFit;
/// Use backing (Retina) pixels for the guest resolution. Default NO.
@property (nonatomic) BOOL useRetinaResolution;
/// In server mouse mode the pointer is captured after a click; Ctrl+Alt releases it.
@property (nonatomic, readonly) BOOL pointerCaptured;
/// Called on capture changes so the UI can show "Press Ctrl+Alt to release".
@property (nonatomic, copy, nullable) void (^captureChanged)(BOOL captured);

- (void)releasePointer;

@end

NS_ASSUME_NONNULL_END
