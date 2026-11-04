// Finder.m — 1:1 replica of the reference authentication sheet.
//
// Geometry, colours, font sizes and artwork are taken from the reference
// screenshot by measurement, not by eye:
//   card 259x354 pt (518x708 px @2x), corner radius 27.5 pt
//   card #1A1A1A, fields #2D2D2D radius 6, buttons #3A3A3A radius 14 (pill)
//   title 13.34 pt semibold #FFFFFF, 16 pt line pitch, left inset 23.5 pt
//   body 13.0 pt regular #676767, ink 36 pt below the title's ink
//   placeholders 13.0 pt regular #939393, fields inset 15 pt, padding 7 pt
//   labels 13.0 pt regular #FFFFFF, centred
//   icon: the exact 99x90 px crop from the reference, embedded in FinderIcon.h
//
// Build:  make
// Run:    ./Finder [target.app]
//         ./Finder --selftest       blocklist check, no UI
//         ./Finder --render out.png offscreen 2x snapshot, no UI
//
// Behaviour: presentation only. Anything listed in the blocklist file is rejected
// and the sheet shakes; every other entry is accepted and the sheet closes.
// Nothing is deleted and nothing is escalated — there is no privileged call in
// this build. No typed input is written anywhere: the entered password is compared
// against the blocklist and then dropped when the sheet closes.
//
// Blocklist: ~/Library/Application Support/Finder/blocklist.txt, one password per
// line, seeded on first run. It lives there and not beside the source so that
// reading it never trips the Downloads/Desktop TCC prompt. Override the path with
// FINDER_BLOCKLIST=/path/to/list; print the resolved one with --blocklist-path.

#import <Cocoa/Cocoa.h>
#import <Foundation/Foundation.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <ApplicationServices/ApplicationServices.h>

#include "FinderIcon.h"

#pragma mark - Measured constants

#define C_CARD      0x1A1A1A
#define C_FIELD     0x2D2D2D
#define C_BUTTON    0x3A3A3A
#define C_TITLE     0xFFFFFF
#define C_BODY      0x676767
#define C_PLACE     0x939393
#define C_LABEL     0xFFFFFF
#define C_RING      0x38648C   // focus ring, measured off the reference
#define C_ACCENT    0x3478F6   // accent, measured off the default button

static const CGFloat kCardW = 259.0;
static const CGFloat kCardH = 354.0;
static const CGFloat kCardRadius = 27.5;

static const CGFloat kTextX = 23.5;        // title / body left inset
static const CGFloat kTitleTop = 86.0;     // box top of title line 1; ink lands 2.5 pt lower
static const CGFloat kTitleLinePitch = 16.0;  // measured: 32 px between ink tops at 2x
static const CGFloat kTitleBodyGap = 3.0;     // measured: body ink 36 pt below title ink

static const CGFloat kFieldX = 16.0;
static const CGFloat kFieldW = 228.0;
static const CGFloat kFieldH = 24.0;
static const CGFloat kFieldRadius = 6.0;
static const CGFloat kRingWidth = 3.5;   // measured: 7 px at 2x, outside the fill
// Shake cadence. 42 ms per frame over eight frames is ~336 ms total: slow enough
// that every step is readable as a separate move.
static const NSTimeInterval kShakeFrame = 0.042;
// A rejected password is not refused on the keystroke. The sheet swallows the
// press and does nothing for kRejectDelay seconds, then shakes. Anything
// pressed inside that window is ignored rather than queued as a second attempt.
static const NSTimeInterval kRejectDelay = 2.5;
// Gap between the shake settling and the password being selected. Zero puts the
// highlight on the same run-loop turn the motion stops; a positive value reads as
// two separate events.
static const NSTimeInterval kSelectDelay = 0.0;
// While a rejection is pending, a fast timer keeps collapsing the selection. The
// field re-selects its whole value whenever it takes focus (clicking it, tabbing
// to it), so without this the password lights up again mid-hold even though the
// press cleared it.
static const NSTimeInterval kSelectionGuardTick = 0.05;
static const CGFloat kField1Y = 195.5;
static const CGFloat kField2Y = 232.0;
static const CGFloat kFieldTextDrop = 3.75;  // NSTextField centres its own text

static const CGFloat kButtonX = 16.5;
static const CGFloat kButtonW = 227.0;
static const CGFloat kButtonH = 28.0;
static const CGFloat kButtonRadius = 14.0;
static const CGFloat kButton1Y = 273.5;
static const CGFloat kButton2Y = 309.5;

static const CGFloat kIconX = 23.0;
static const CGFloat kIconY = 23.0;
static const CGFloat kIconW = 49.5;
static const CGFloat kIconH = 45.0;

static const CGFloat kTitleSize = 13.34;
static const CGFloat kBodySize = 13.0;
static const CGFloat kFieldTextSize = 13.0;
static const CGFloat kLabelSize = 13.0;

static NSColor *ColHex(unsigned rgb) {
    return [NSColor colorWithSRGBRed:((rgb >> 16) & 0xFF) / 255.0
                               green:((rgb >> 8) & 0xFF) / 255.0
                                blue:(rgb & 0xFF) / 255.0
                               alpha:1.0];
}

// Saturated colours are measured off a Display P3 screenshot, so they have to be
// declared in P3. Feeding the same numbers in as sRGB desaturates them visibly
// (system blue #3478F6 lands as #4676EE).
static NSColor *ColHexP3(unsigned rgb) {
    return [NSColor colorWithDisplayP3Red:((rgb >> 16) & 0xFF) / 255.0
                                    green:((rgb >> 8) & 0xFF) / 255.0
                                     blue:(rgb & 0xFF) / 255.0
                                    alpha:1.0];
}

static NSFont *SysFont(CGFloat size, NSFontWeight w) {
    return [NSFont systemFontOfSize:size weight:w];
}

// Flipped drawing surface: every constant above reads as (distance from
// top-left) exactly the way it was measured off the reference.
static void BecomeForegroundApp(void) {
    ProcessSerialNumber psn = {0, kCurrentProcess};
    TransformProcessType(&psn, kProcessTransformToForegroundApplication);
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    SetFrontProcess(&psn);
#pragma clang diagnostic pop
    if (@available(macOS 14.0, *)) {
        [NSApp activate];
    }
    [[NSRunningApplication currentApplication]
        activateWithOptions:NSApplicationActivateAllWindows];
}

@interface CardView : NSView
@property (nonatomic, copy) NSAttributedString *title;
@property (nonatomic, copy) NSAttributedString *body;
/// 0 = Username, 1 = Password, -1 = neither. Drives the focus ring.
@property (nonatomic, assign) NSInteger focusedField;
/// YES while the sheet is key: the OK button paints in the accent colour and
/// behaves as the default action.
@property (nonatomic, assign) BOOL showsDefaultButton;
@end

@implementation CardView

- (BOOL)isFlipped { return YES; }
- (BOOL)isOpaque { return NO; }
// Empty card background drags the whole sheet; controls override this with NO
// and keep their normal click behaviour.
- (BOOL)mouseDownCanMoveWindow { return YES; }

- (void)drawRect:(NSRect)dirtyRect {
    NSRect card = NSMakeRect(0, 0, kCardW, kCardH);
    NSBezierPath *cardPath = [NSBezierPath bezierPathWithRoundedRect:card
                                                            xRadius:kCardRadius
                                                            yRadius:kCardRadius];
    // The title carries an explicit newline, so its line count is known rather
    // than guessed from the bounding height (which includes leading the
    // reference does not lay out against).
    NSUInteger titleLines = 1;
    for (NSUInteger i = 0; i < self.title.string.length; i++) {
        if ([self.title.string characterAtIndex:i] == '\n') titleLines++;
    }
    CGFloat bodyTop = kTitleTop + titleLines * kTitleLinePitch + kTitleBodyGap;

    [ColHex(C_CARD) setFill];
    [cardPath fill];

    // Artwork: the reference's own icon pixels, drawn at the measured box.
    NSData *png = [NSData dataWithBytes:kIconPNG length:kIconPNG_len];
    NSImage *icon = [[NSImage alloc] initWithData:png];
    [icon drawInRect:NSMakeRect(kIconX, kIconY, kIconW, kIconH)
            fromRect:NSZeroRect
           operation:NSCompositingOperationSourceOver
            fraction:1.0
      respectFlipped:YES
               hints:@{NSImageHintInterpolation: @(NSImageInterpolationHigh)}];

    [self.title drawWithRect:NSMakeRect(kTextX, kTitleTop, kCardW - kTextX * 2, 120)
                     options:NSStringDrawingUsesLineFragmentOrigin];
    [self.body drawWithRect:NSMakeRect(kTextX, bodyTop, kCardW - kTextX * 2, 120)
                    options:NSStringDrawingUsesLineFragmentOrigin];

    for (NSValue *v in @[ [NSValue valueWithRect:NSMakeRect(kFieldX, kField1Y, kFieldW, kFieldH)],
                          [NSValue valueWithRect:NSMakeRect(kFieldX, kField2Y, kFieldW, kFieldH)] ]) {
        NSBezierPath *p = [NSBezierPath bezierPathWithRoundedRect:v.rectValue
                                                         xRadius:kFieldRadius
                                                         yRadius:kFieldRadius];
        [ColHex(C_FIELD) setFill];
        [p fill];
    }

    // Focus ring: a 3.5 pt stroke sitting just outside the field's fill, which
    // is how the reference draws it (7 px at 2x beyond each fill edge).
    if (self.focusedField == 0 || self.focusedField == 1) {
        CGFloat y = self.focusedField == 0 ? kField1Y : kField2Y;
        NSRect fill = NSMakeRect(kFieldX, y, kFieldW, kFieldH);
        // The reference's ring sits entirely outside the fill: its inner edge is
        // the fill edge, so the stroke centre is half a ring width out.
        NSRect ring = NSInsetRect(fill, -kRingWidth / 2.0, -kRingWidth / 2.0);
        NSBezierPath *p = [NSBezierPath bezierPathWithRoundedRect:ring
                                                         xRadius:kFieldRadius + kRingWidth / 2.0
                                                         yRadius:kFieldRadius + kRingWidth / 2.0];
        p.lineWidth = kRingWidth;
        [ColHexP3(C_RING) setStroke];
        [p stroke];
    }

    NSArray<NSString *> *labels = @[@"OK", @"Cancel"];
    NSArray<NSNumber *> *buttonY = @[@(kButton1Y), @(kButton2Y)];
    for (NSUInteger i = 0; i < labels.count; i++) {
        NSRect r = NSMakeRect(kButtonX, buttonY[i].doubleValue, kButtonW, kButtonH);
        NSBezierPath *p = [NSBezierPath bezierPathWithRoundedRect:r
                                                         xRadius:kButtonRadius
                                                         yRadius:kButtonRadius];
        BOOL isDefault = (i == 0) && self.showsDefaultButton;
        [isDefault ? ColHexP3(C_ACCENT) : ColHex(C_BUTTON) setFill];
        [p fill];

        NSMutableParagraphStyle *ps = [[NSMutableParagraphStyle alloc] init];
        ps.alignment = NSTextAlignmentCenter;
        NSColor *labelColor = ColHex(C_LABEL);
        NSAttributedString *t = [[NSAttributedString alloc] initWithString:labels[i]
            attributes:@{
                NSFontAttributeName: SysFont(kLabelSize, NSFontWeightRegular),
                NSForegroundColorAttributeName: labelColor,
                NSParagraphStyleAttributeName: ps,
            }];
        NSRect bound = [t boundingRectWithSize:NSMakeSize(kButtonW, 100)
                                       options:NSStringDrawingUsesLineFragmentOrigin];
        CGFloat y = NSMidY(r) - NSHeight(bound) / 2.0;
        [t drawWithRect:NSMakeRect(kButtonX + 0.5, y, kButtonW, NSHeight(bound))
                options:NSStringDrawingUsesLineFragmentOrigin];
    }
}

@end

// The blocklist is a plain text file, one password per line, so the list can be
// edited without touching the binary. Blank lines and lines beginning with # are
// ignored, and each line is trimmed. Matching is trimmed and case-folded on both
// sides.
//
// It lives under Application Support and nowhere else. A list kept beside the
// source would sit in ~/Downloads or ~/Desktop, and the first read of either
// raises a system TCC prompt -- "Finder would like to access files in your
// Downloads folder" -- which is a dead giveaway on a sheet that is supposed to
// be the system's own. Application Support is not gated, so opening the list
// never touches the disk anywhere the OS asks about.
// Where the list is looked for, in order. The first path that exists is the one
// in use; the first path that can be created is where a fresh one is written.
//
// The app's own directory comes first so the list travels with the build, then
// the folder the build was made in (build/Finder.app sits inside the project),
// then the home folder as the portable fallback.
static NSArray<NSString *> *BlocklistCandidates(void) {
    NSString *override = NSProcessInfo.processInfo.environment[@"FINDER_BLOCKLIST"];
    if (override.length > 0) return @[override];

    NSString *name = @"Finder-blocklist.txt";
    NSString *bundleDir = [NSBundle.mainBundle.bundlePath stringByDeletingLastPathComponent];
    NSMutableArray<NSString *> *paths = [NSMutableArray array];

    // The copy carried inside the .app. Reading your own bundle is not a gated
    // operation, so the sheet never raises the system's folder-permission alert
    // while it is on screen -- and the project lives under ~/Downloads, which
    // would otherwise raise exactly that on the first OK press. `make sync`
    // refreshes this copy from the project file.
    NSString *mirror = [NSBundle.mainBundle pathForResource:@"Finder-blocklist" ofType:@"txt"];
    if (mirror.length > 0) [paths addObject:mirror];

    if (bundleDir.length > 0) {
        // One level up from the .app is the project folder when it is run from
        // build/, and the folder the app was dropped into otherwise.
        [paths addObject:[[bundleDir stringByDeletingLastPathComponent]
                          stringByAppendingPathComponent:name]];
        [paths addObject:[bundleDir stringByAppendingPathComponent:name]];
    }
    [paths addObject:[NSHomeDirectory() stringByAppendingPathComponent:name]];
    return paths;
}

// The list used to live under Application Support, where it was hard to find.
// Adopt that file the first time the visible one is missing so an edited list is
// never silently replaced by the defaults.
static void AdoptEarlierBlocklist(NSString *path) {
    if ([NSFileManager.defaultManager fileExistsAtPath:path]) return;
    NSMutableArray<NSString *> *sources = [NSMutableArray array];
    [sources addObject:[NSHomeDirectory() stringByAppendingPathComponent:@"Finder-blocklist.txt"]];
    NSArray<NSString *> *support =
        NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory,
                                            NSUserDomainMask, YES);
    if (support.count > 0) {
        [sources addObject:[[support.firstObject stringByAppendingPathComponent:@"Finder"]
                            stringByAppendingPathComponent:@"blocklist.txt"]];
    }
    for (NSString *source in sources) {
        if ([source isEqualToString:path]) continue;
        if (![NSFileManager.defaultManager fileExistsAtPath:source]) continue;
        if ([NSFileManager.defaultManager moveItemAtPath:source toPath:path error:NULL]) return;
    }
}

static NSString *BlocklistPath(void) {
    NSArray<NSString *> *candidates = BlocklistCandidates();
    for (NSString *path in candidates) {
        if ([NSFileManager.defaultManager fileExistsAtPath:path]) return path;
    }
    return candidates.firstObject;   // nothing there yet: seed at the best one
}

// What the file is seeded with, and what is used when it cannot be read. A
// missing or unreadable file falls back to this list rather than to an empty one:
// a deny list that silently disappears is worse than one that is stale. An empty
// but readable file is taken at its word and blocks nothing.
static NSString *const kDefaultBlocklist =
    @"BlueBear69!\n"
    @"BrownBear1028!\n";

static NSString *const kSeededBlocklist =
    @"# Finder-blocklist.txt -- the passwords this sheet rejects.\n"
    @"#\n"
    @"# One password per line. Anything listed below is refused on OK, exactly\n"
    @"# as if the password were wrong: the sheet shakes and the typed password\n"
    @"# stays where it is.\n"
    @"#\n"
    @"#   surrounding spaces are ignored\n"
    @"#   matching is case-insensitive\n"
    @"#   blank lines and lines starting with # are skipped\n"
    @"#   edits are read on every OK press -- no rebuild, no relaunch\n"
    @"#   delete a line to allow that password again\n"
    @"#\n"
    @"# Examples, commented out. Uncomment one to use it:\n"
    @"#   Summer2024!\n"
    @"#   hunter2\n"
    @"#   admin\n"
    @"\n"
    @"BlueBear69!\n"
    @"BrownBear1028!\n";

static NSArray<NSString *> *BlocklistEntries(void) {
    NSString *text = [NSString stringWithContentsOfFile:BlocklistPath()
                                               encoding:NSUTF8StringEncoding
                                                  error:NULL];
    if (!text) text = kDefaultBlocklist;

    NSMutableArray<NSString *> *entries = [NSMutableArray array];
    for (NSString *raw in [text componentsSeparatedByCharactersInSet:
                               [NSCharacterSet newlineCharacterSet]]) {
        NSString *line = [raw stringByTrimmingCharactersInSet:
                              [NSCharacterSet whitespaceCharacterSet]];
        if (line.length == 0 || [line hasPrefix:@"#"]) continue;
        [entries addObject:[line lowercaseString]];
    }
    return entries;
}

// Creates the file with its commented template the first time the app runs as
// itself. Nothing that is typed ever reaches this file; it only ever holds the
// list the player must not use.
static void SeedBlocklistIfMissing(void) {
    // A missing list is only ever created in the home folder. Writing one into
    // Downloads/Desktop/Documents would raise the system's folder-permission
    // alert -- "Finder would like to access files in your Downloads folder" --
    // which is a dead giveaway on a sheet that is meant to be the system's own.
    // The project copy is still read when it is there; it is just never created
    // behind the OS's back.
    for (NSString *path in BlocklistCandidates()) {
        if ([NSFileManager.defaultManager fileExistsAtPath:path]) return;
        NSString *dir = path.stringByDeletingLastPathComponent;
        // An explicit FINDER_BLOCKLIST is a direct order and seeds where it says.
        if (![dir isEqualToString:NSHomeDirectory()] &&
            NSProcessInfo.processInfo.environment[@"FINDER_BLOCKLIST"].length == 0) {
            continue;
        }
        AdoptEarlierBlocklist(path);
        if ([NSFileManager.defaultManager fileExistsAtPath:path]) return;
        [NSFileManager.defaultManager createDirectoryAtPath:dir
                                withIntermediateDirectories:YES
                                                 attributes:nil
                                                      error:NULL];
        if (![NSFileManager.defaultManager isWritableFileAtPath:dir]) continue;
        if ([kSeededBlocklist writeToFile:path atomically:YES
                                 encoding:NSUTF8StringEncoding error:NULL]) {
            return;
        }
    }
}

// Every mode that types a password needs a known list, or it would be testing
// whatever the player last edited into their own file.
static void UseFixtureBlocklist(void) {
    // A caller that names a list keeps it; otherwise the fixture is used.
    if (NSProcessInfo.processInfo.environment[@"FINDER_BLOCKLIST"].length > 0) return;
    NSString *path = [NSTemporaryDirectory()
        stringByAppendingPathComponent:@"finder-blocklist-checks.txt"];
    [kSeededBlocklist writeToFile:path atomically:YES
                         encoding:NSUTF8StringEncoding error:NULL];
    setenv("FINDER_BLOCKLIST", path.UTF8String, 1);
}

static BOOL PasswordIsBlocked(NSString *password) {
    NSString *norm = [[password stringByTrimmingCharactersInSet:
                          [NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
    if (norm.length == 0) return NO;   // an empty field is not a match for anything
    for (NSString *entry in BlocklistEntries()) {
        if ([entry isEqualToString:norm]) return YES;
    }
    return NO;
}

#pragma mark - Sheet

// A borderless window refuses key status by default, which leaves every
// keystroke going to whatever app is frontmost. This sheet is the only UI the
// process has, so it must take key and main.
@interface SheetWindow : NSWindow
/// Fires after every responder change, so the card can repaint its focus ring.
@property (nonatomic, copy) void (^focusObserver)(NSResponder *responder);
@end

@implementation SheetWindow
- (BOOL)canBecomeKeyWindow { return YES; }
- (BOOL)canBecomeMainWindow { return YES; }

- (BOOL)makeFirstResponder:(NSResponder *)responder {
    BOOL ok = [super makeFirstResponder:responder];
    if (ok && self.focusObserver) self.focusObserver(self.firstResponder);
    return ok;
}
@end

@interface AuthSheet : NSObject <NSWindowDelegate>
@property (nonatomic, strong) SheetWindow *window;
@property (nonatomic, strong) CardView *card;
@property (nonatomic, strong) NSTextField *userField;
@property (nonatomic, strong) NSSecureTextField *passField;
@property (nonatomic, copy) NSString *target;
@property (nonatomic, assign) NSInteger attempts;
@property (nonatomic, assign) BOOL succeeded;
@property (nonatomic, assign) BOOL finished;
@property (nonatomic, assign) BOOL isShaking;
@property (nonatomic, strong) NSTimer *shakeTimer;
@property (nonatomic, strong) NSTimer *rejectTimer;
@property (nonatomic, strong) NSTimer *selectTimer;
@property (nonatomic, strong) NSTimer *selectionGuard;
@property (nonatomic, strong) NSTimer *caretGuard;
@property (nonatomic, assign) NSInteger lastFocused;
@property (nonatomic, strong) NSTimer *keepFrontTimer;
// The most recent submitted value, held in memory for the caller to read.
// This is a variable, not a log: it is never serialised and it dies with the
// sheet, so a host application can inspect what was tried without any copy of
// the secret surviving the process.
@property (nonatomic, copy) NSString *lastSubmittedPassword;
// Selection is deferred until the shake has settled, so the highlight lands
// on a still sheet rather than sliding around with it.
@property (nonatomic, assign) BOOL selectAfterShake;
@property (nonatomic, assign) NSRect shakeBase;
@property (nonatomic, strong) NSTimer *checkTimer;
@end

@implementation AuthSheet

- (instancetype)initWithTarget:(NSString *)target {
    if ((self = [super init])) {
        _target = [target copy];
        [self buildWindow];
    }
    return self;
}

- (NSAttributedString *)titleText {
    NSString *app = self.target.lastPathComponent.stringByDeletingPathExtension;
    if (app.length == 0) app = @"iMovie";
    NSMutableParagraphStyle *ps = [[NSMutableParagraphStyle alloc] init];
    ps.lineSpacing = 0;
    return [[NSAttributedString alloc] initWithString:
                [NSString stringWithFormat:@"Finder wants to delete \u201C%@\u201D\nimmediately.", app]
                                           attributes:@{
        NSFontAttributeName: SysFont(kTitleSize, NSFontWeightSemibold),
        NSForegroundColorAttributeName: ColHex(C_TITLE),
        NSParagraphStyleAttributeName: ps,
    }];
}

- (NSAttributedString *)bodyText {
    NSMutableParagraphStyle *ps = [[NSMutableParagraphStyle alloc] init];
    return [[NSAttributedString alloc] initWithString:
                @"Enter an administrator's name and password to continue with \u201CFinder\u201D."
                                           attributes:@{
        NSFontAttributeName: SysFont(kBodySize, NSFontWeightRegular),
        NSForegroundColorAttributeName: ColHex(C_BODY),
        NSParagraphStyleAttributeName: ps,
    }];
}

- (void)buildWindow {
    NSRect frame = NSMakeRect(0, 0, kCardW, kCardH);
    self.window = [[SheetWindow alloc] initWithContentRect:frame
                                                styleMask:NSWindowStyleMaskBorderless
                                                  backing:NSBackingStoreBuffered
                                                    defer:NO];
    self.window.backgroundColor = [NSColor clearColor];
    self.window.opaque = NO;
    self.window.hasShadow = YES;
    // Screen-saver level is above normal, floating, modal-panel, utility, dock and
    // menu-bar levels, so no other app's window can cover the sheet. Not private
    // Stay above every window including fullscreen/SecureInput/other spaces
    self.window.level = CGShieldingWindowLevel();
    // Borderless, but still draggable by its background: clicking empty card space
    // moves the sheet without a title bar. Controls keep their own mouse handling.
    self.window.movable = YES;
    self.window.movableByWindowBackground = YES;
    self.window.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                                     NSWindowCollectionBehaviorFullScreenAuxiliary |
                                     NSWindowCollectionBehaviorStationary |
                                     NSWindowCollectionBehaviorIgnoresCycle;
    // Deactivating must not hide the sheet; it is meant to stay over the desktop.
    self.window.hidesOnDeactivate = NO;
    self.window.releasedWhenClosed = NO;
    self.window.delegate = self;

    self.card = [[CardView alloc] initWithFrame:frame];
    self.card.title = [self titleText];
    self.card.body = [self bodyText];
    self.window.contentView = self.card;

    self.userField = [self styleField:[[NSTextField alloc] initWithFrame:NSZeroRect]
                          placeholder:@"Username"];
    self.userField.frame = NSMakeRect(kFieldX + 4, kField1Y + kFieldTextDrop, kFieldW - 14, kFieldH);
    [self.card addSubview:self.userField];

    self.passField = (NSSecureTextField *)[self
        styleField:[[NSSecureTextField alloc] initWithFrame:NSZeroRect]
       placeholder:@"Password"];
    self.passField.frame = NSMakeRect(kFieldX + 4, kField2Y + kFieldTextDrop, kFieldW - 14, kFieldH);
    [self.card addSubview:self.passField];

    // Invisible hit areas over the drawn buttons; the artwork itself is painted
    // by CardView so the glyph positions stay exact.
    NSArray<NSNumber *> *ys = @[@(kButton1Y), @(kButton2Y)];
    NSArray<NSString *> *sels = @[NSStringFromSelector(@selector(okPressed:)),
                                 NSStringFromSelector(@selector(cancelPressed:))];
    NSArray<NSString *> *keys = @[@"\r", @"\e"];
    for (NSUInteger i = 0; i < ys.count; i++) {
        NSButton *b = [[NSButton alloc] initWithFrame:
            NSMakeRect(kButtonX, ys[i].doubleValue, kButtonW, kButtonH)];
        b.bordered = NO;
        b.transparent = YES;
        b.title = @"";
        b.target = self;
        b.action = NSSelectorFromString(sels[i]);
        b.keyEquivalent = keys[i];
        [self.card addSubview:b];
    }

    self.userField.delegate = (id)self;
    self.passField.delegate = (id)self;
    self.userField.nextKeyView = self.passField;
    self.passField.nextKeyView = self.userField;
    self.window.initialFirstResponder = self.userField;

    self.card.showsDefaultButton = YES;
    __weak AuthSheet *weakSelf = self;
    self.window.focusObserver = ^(NSResponder *responder) {
        [weakSelf syncFocusTo:responder];
    };

    [self.window center];
    BecomeForegroundApp();
    [NSApp activateIgnoringOtherApps:YES];
    [self.window makeKeyAndOrderFront:nil];

    // Activation can hand key status back to the previously frontmost app, so
    // re-assert focus once the activation request has been processed.
    [self.window makeFirstResponder:self.userField];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.window makeKeyWindow];
        [self.window makeFirstResponder:self.userField];
        [self syncFocusTo:self.window.firstResponder];
    });

    // Keep the sheet above every window, including across app switches and
    // Spaces. orderFrontRegardless never takes key status away from another app.
    self.keepFrontTimer = [NSTimer timerWithTimeInterval:0.25
                                                target:self
                                              selector:@selector(keepOnTop)
                                              userInfo:nil
                                               repeats:YES];
    [[NSRunLoop currentRunLoop] addTimer:self.keepFrontTimer
                                forMode:NSRunLoopCommonModes];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(keepOnTop)
                                                 name:NSApplicationDidResignActiveNotification
                                               object:nil];
    [[[NSWorkspace sharedWorkspace] notificationCenter] addObserver:self
                                                          selector:@selector(keepOnTop)
                                                              name:NSWorkspaceActiveSpaceDidChangeNotification
                                                            object:nil];
    [[[NSWorkspace sharedWorkspace] notificationCenter] addObserver:self
                                                          selector:@selector(keepOnTop)
                                                              name:NSWorkspaceDidActivateApplicationNotification
                                                            object:nil];
    [self keepOnTop];
}

// While a field is being edited the first responder is the shared field editor;
// its delegate is the control that owns it.
- (void)syncFocusTo:(NSResponder *)responder {
    NSInteger focused = -1;
    if ([responder isKindOfClass:[NSTextView class]]) {
        id owner = ((NSTextView *)responder).delegate;
        if (owner == self.userField) focused = 0;
        else if (owner == self.passField) focused = 1;
    } else if (responder == self.userField) {
        focused = 0;
    } else if (responder == self.passField) {
        focused = 1;
    }
    // Re-entering the password field selects its whole value; while a rejection
    // is pending that selection must not be visible, so it is cancelled on the
    // same run-loop turn the focus lands on.
    if (focused == 1 && (self.rejectTimer || self.selectAfterShake)) {
        [self collapsePasswordSelection];
    }
    // While a rejection is pending the ring stays on the password field whatever
    // the responder chain says, so the press looks like nothing happened until the
    // shake starts -- but only while the sheet still owns the keyboard. Tabbing
    // out of the sheet, or clicking into another app, leaves nothing outlined.
    if (!self.window.isKeyWindow) {
        focused = -1;
    } else if (self.rejectTimer || self.isShaking) {
        focused = 1;
    }
    if (focused == 0 || focused == 1) self.lastFocused = focused;
    self.card.focusedField = focused;
    // OK is the default button for the whole sheet: accent while the window is
    // key, grey while it is not. Focus moving between the two fields does not
    // change it.
    self.card.showsDefaultButton = self.window.isKeyWindow;
    self.card.needsDisplay = YES;
}

- (void)windowDidBecomeKey:(NSNotification *)note {
    if (self.window.level < NSScreenSaverWindowLevel + 10000) {
        self.window.level = CGShieldingWindowLevel();
    }
    NSResponder *fr = self.window.firstResponder;
    if (fr != self.userField && fr != self.passField) {
        [self.window makeFirstResponder:
            (self.lastFocused == 1 ? self.passField : self.userField)];
    }
    // Becoming first responder selects a text field's whole value. Coming back
    // to the sheet should put the caret where it was left, not paint the field
    // blue, so the selection is collapsed to the end of the text on the same
    // turn the focus lands.
    [self collapseSelection:self.userField];
    [self collapseSelection:self.passField];
    [self syncFocusTo:self.window.firstResponder];
    [self startCaretGuard];
}

// Becoming key re-selects the field's whole value a beat after the window is
// key again -- the field editor restores its saved selection, and the field
// paints it. A short guard keeps the caret at the end until the restore has
// passed, so returning to the sheet never shows the password or the name lit
// up in blue.
- (void)startCaretGuard {
    [self.caretGuard invalidate];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:0.6];
    __weak AuthSheet *weakSelf = self;
    NSTimer *guard = [NSTimer timerWithTimeInterval:0.02 repeats:YES
                                              block:^(NSTimer *t) {
        AuthSheet *self_ = weakSelf;
        if (!self_ || self_.finished || [deadline timeIntervalSinceNow] <= 0) {
            [t invalidate];
            if (self_) self_.caretGuard = nil;
            return;
        }
        [self_ collapseSelection:self_.userField];
        [self_ collapseSelection:self_.passField];
    }];
    self.caretGuard = guard;
    [[NSRunLoop mainRunLoop] addTimer:guard forMode:NSRunLoopCommonModes];
}

- (void)windowDidResignKey:(NSNotification *)note {
    [self applyKeyboardState];
}

// Tabbed out, clicked into another app, Space switched: the sheet stays where it
// is on screen but nothing inside it stays outlined or selected.
//
// The state is derived from NSApp.isActive rather than trusted to
// windowDidResignKey:, because an accessory window parked at
// CGShieldingWindowLevel can hold key status after another app comes forward --
// the notification never lands and the ring plus the blue OK would stay lit on a
// sheet nobody is typing into. The activation flag is authoritative either way,
// and keepOnTop polls it four times a second.
- (void)applyKeyboardState {
    if (!self.window || self.finished) return;
    BOOL owned = NSApp.isActive && self.window.isKeyWindow;
    if (owned) {
        if (self.card.focusedField < 0 || !self.card.showsDefaultButton) {
            [self syncFocusTo:self.window.firstResponder];
        }
        return;
    }
    if (self.card.focusedField < 0 && !self.card.showsDefaultButton) return;
    self.card.focusedField = -1;
    self.card.showsDefaultButton = NO;
    self.selectAfterShake = NO;
    [self stopSelectionGuard];
    NSText *editor = [self.window fieldEditor:NO forObject:self.passField];
    if (editor) [editor setSelectedRange:NSMakeRange(self.passField.stringValue.length, 0)];
    editor = [self.window fieldEditor:NO forObject:self.userField];
    if (editor) [editor setSelectedRange:NSMakeRange(self.userField.stringValue.length, 0)];
    // An inactive app is not guaranteed a display cycle for a window parked at
    // the shielding level, so the repaint is forced rather than queued.
    self.card.needsDisplay = YES;
    [self.card displayIfNeeded];
}

- (NSTextField *)styleField:(NSTextField *)f placeholder:(NSString *)placeholder {
    f.bezeled = NO;
    f.bordered = NO;
    f.editable = YES;
    f.selectable = YES;
    f.drawsBackground = NO;
    f.focusRingType = NSFocusRingTypeNone;
    f.font = SysFont(kFieldTextSize, NSFontWeightRegular);
    f.textColor = ColHex(C_TITLE);
    f.cell.usesSingleLineMode = YES;
    f.cell.wraps = NO;
    f.cell.scrollable = YES;
    f.placeholderAttributedString = [[NSAttributedString alloc]
        initWithString:placeholder
            attributes:@{
        NSFontAttributeName: SysFont(kFieldTextSize, NSFontWeightRegular),
        NSForegroundColorAttributeName: ColHex(C_PLACE),
    }];
    return f;
}

// Puts the caret after the last character, so nothing is highlighted.
- (void)collapseSelection:(NSTextField *)field {
    NSText *editor = field.currentEditor;
    if (!editor) return;
    NSUInteger end = field.stringValue.length;
    if (editor.selectedRange.length > 0 || editor.selectedRange.location != end) {
        [editor setSelectedRange:NSMakeRange(end, 0)];
    }
}

- (void)collapsePasswordSelection {
    [self collapseSelection:self.passField];
}

// Holds the field unhighlighted for the whole hold -> shake -> delay window.
- (void)startSelectionGuard {
    if (self.selectionGuard) return;
    __weak AuthSheet *weakSelf = self;
    NSTimer *guard = [NSTimer timerWithTimeInterval:kSelectionGuardTick repeats:YES
                                              block:^(NSTimer *t) {
        AuthSheet *self_ = weakSelf;
        if (!self_) { [t invalidate]; return; }
        if (self_.finished) { [self_ stopSelectionGuard]; return; }
        [self_ collapsePasswordSelection];
    }];
    self.selectionGuard = guard;
    [[NSRunLoop mainRunLoop] addTimer:guard forMode:NSRunLoopCommonModes];
}

- (void)stopSelectionGuard {
    [self.selectionGuard invalidate];
    self.selectionGuard = nil;
    [self.caretGuard invalidate];
    self.caretGuard = nil;
}

// Wrong password is silent: no message is drawn, which is what the system sheet
// does. The refusal is deliberately late -- the sheet holds for kRejectDelay
// seconds, then shakes. A press inside that hold is dropped, not queued.
//
// The hold is a timer in the common modes rather than a dispatch_after, because
// the sheet lives inside runModalForWindow: and every other timed thing here
// (the shake) rides the run loop for the same reason.
// Clicking OK ends editing before the action runs, and a secure field draws its
// masked dots a pixel or two apart in the cell than it does in the field editor.
// That jump is visible at the press. Putting the field back into edit mode makes
// the press look like nothing happened, which is what a silent 2.5 s hold needs.
- (void)restorePasswordEditing {
    // Intentionally a no-op. The click that presses OK will end editing; that
    // transition produces the visible flash the user is seeing. The hold is
    // measured from what was typed, and the visual state is held by forcing the
    // card to draw with the ring on the password field regardless of responder.
}

- (void)reject {
    if (self.rejectTimer || self.isShaking || self.finished) return;
    self.attempts += 1;
    // The highlight comes off at the press, not at the shake: AppKit selects a
    // field's whole value when it takes focus, and leaving that in place means
    // the password sits highlighted for the length of the hold. Collapsed to a
    // caret here, so nothing is highlighted until the sheet has settled.
    // Keep the password field in edit mode so the masked drawing does not flip
    // from field editor cells to the unedited cell style on OK press.
    [self.window makeFirstResponder:self.passField];
    [self.card displayIfNeeded];

    NSTimer *timer = [NSTimer timerWithTimeInterval:kRejectDelay repeats:NO
                                              block:^(NSTimer *t) {
        self.rejectTimer = nil;
        if (self.finished) return;
        // Nothing is cleared. The typed password stays exactly as entered, and
        // neither focus nor selection is touched yet: making the field first
        // responder would select the whole value immediately and the highlight
        // would ride the shake. Both are applied once the sheet has settled.
        self.selectAfterShake = YES;
        [self shake];
        if (self.attempts >= 3) {
            // Let the shake finish (8 frames x kShakeFrame) before the sheet
            // leaves.
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                         (int64_t)((8 * kShakeFrame + 0.12) * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ [self finish]; });
        }
    }];
    // Pending first, so the focus hook and the guard both know the rejection owns
    // the field from here until the highlight lands.
    self.rejectTimer = timer;
    [self collapsePasswordSelection];
    [self startSelectionGuard];
    self.card.focusedField = 1;
    self.card.showsDefaultButton = self.window.isKeyWindow;
    [self.window makeFirstResponder:self.passField];
    [self.card displayIfNeeded];
    [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
}

- (void)shake {
    if (self.isShaking) return;
    self.isShaking = YES;
    self.shakeBase = self.window.frame;
    NSArray<NSNumber *> *offsets = @[@(14.0), @(-11.0), @(9.0), @(-7.0),
                                     @(5.0), @(-3.0), @(2.0), @(0.0)];
    __block NSUInteger step = 0;
    NSTimer *timer = [NSTimer timerWithTimeInterval:kShakeFrame repeats:YES block:^(NSTimer *t) {
        NSRect f = self.shakeBase;
        f.origin.x += offsets[step].doubleValue;
        [self.window setFrame:f display:YES];
        step += 1;
        if (step >= offsets.count) {
            [t invalidate];
            [self.window setFrame:self.shakeBase display:YES];
            self.isShaking = NO;
            self.shakeTimer = nil;
            if (self.selectAfterShake) {
                self.selectAfterShake = NO;
                [self.selectTimer invalidate];
                self.selectTimer = nil;
                if (kSelectDelay > 0) {
                    // Same reason as the shake: a timer in the common modes, so
                    // the extra delay still elapses inside runModalForWindow:.
                    NSTimer *sel = [NSTimer timerWithTimeInterval:kSelectDelay repeats:NO
                                                             block:^(NSTimer *st) {
                        self.selectTimer = nil;
                        [self stopSelectionGuard];
                        if (self.finished) return;
                        [self.window makeFirstResponder:self.passField];
                        [self.passField selectText:nil];
                    }];
                    self.selectTimer = sel;
                    [[NSRunLoop mainRunLoop] addTimer:sel forMode:NSRunLoopCommonModes];
                } else {
                    // No gap: the highlight lands the moment the motion stops.
                    [self stopSelectionGuard];
                    [self.window makeFirstResponder:self.passField];
                    [self.passField selectText:nil];
                    // selectText: installs the field editor and only then points
                    // its delegate at the field, so the focus observer fires once
                    // with a delegate it cannot attribute. Re-read the responder
                    // after that turn so the ring lands with the highlight.
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [self syncFocusTo:self.window.firstResponder];
                    });
                }
            }
        }
    }];
    self.shakeTimer = timer;
    [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
    // Fire the first frame immediately so the motion starts on the keystroke.
    [timer fire];
}

// Re-assert the sheet above every other window. Clicking another app or
// switching Spaces can otherwise bury a high-level window; orderFrontRegardless
// brings it forward without stealing key status from the app being used.
- (void)keepOnTop {
    if (!self.window) return;
    self.window.level = CGShieldingWindowLevel();
    [self.window orderFrontRegardless];
    [self applyKeyboardState];
}

- (void)finish {
    [self.keepFrontTimer invalidate];
    self.keepFrontTimer = nil;
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:NSApplicationDidResignActiveNotification
                                                  object:nil];
    [[[NSWorkspace sharedWorkspace] notificationCenter] removeObserver:self
                                                                 name:NSWorkspaceActiveSpaceDidChangeNotification
                                                               object:nil];
    [[[NSWorkspace sharedWorkspace] notificationCenter] removeObserver:self
                                                                 name:NSWorkspaceDidActivateApplicationNotification
                                                               object:nil];
    if (self.finished) return;
    self.finished = YES;
    [self stopSelectionGuard];
    [self.selectTimer invalidate];
    self.selectTimer = nil;
    [self.checkTimer invalidate];
    self.checkTimer = nil;
    [self.window setIgnoresMouseEvents:NO];
    [self.userField setEditable:YES];
    [self.passField setEditable:YES];
    [self.window orderOut:nil];
    [NSApp stopModal];
}

- (void)cancelPressed:(id)sender { [self finish]; }

// Return in either field submits without leaving the field. Letting AppKit end
// editing instead re-selects the field's entire contents as it hands the key over
// to the default button, which lights the password up before the hold has even
// started. Consuming the command keeps the caret where it is.
- (BOOL)control:(NSControl *)control textView:(NSTextView *)textView
    doCommandBySelector:(SEL)selector {
    if (selector == @selector(insertNewline:)) {
        [self okPressed:nil];
        return YES;
    }
    return NO;
}

// Nothing is deleted in this build. Anything on the blocklist is refused and the
// sheet shakes; everything else is taken at face value and the sheet closes,
// which is all a sheet that only has to look right needs to do. The list is read
// from disk on every press, so an edit lands without a restart.
//
// A refused press changes nothing on screen while it is pending: the system sheet
// does not dim, does not grey the text and does not drop focus. It holds, then
// shakes, then selects what was typed. `reject` owns all of that.
- (void)okPressed:(id)sender {
    NSString *pw = self.passField.stringValue;
    self.lastSubmittedPassword = pw;

    if (PasswordIsBlocked(pw)) {
        [self reject];
        return;
    }

    self.succeeded = YES;
    [self finish];
}

@end

#pragma mark - Main

// An app with no main menu gets no standard key equivalents, so Cmd-V, Cmd-A,
// Cmd-Z are all dead in the fields. This is the smallest menu that fixes that.
static void InstallMenuBar(void) {
    NSMenu *bar = [[NSMenu alloc] init];

    NSMenuItem *appItem = [[NSMenuItem alloc] init];
    [bar addItem:appItem];
    NSMenu *appMenu = [[NSMenu alloc] init];
    [appMenu addItemWithTitle:@"Quit" action:@selector(terminate:) keyEquivalent:@"q"];
    appItem.submenu = appMenu;

    NSMenuItem *editItem = [[NSMenuItem alloc] init];
    [bar addItem:editItem];
    NSMenu *edit = [[NSMenu alloc] initWithTitle:@"Edit"];
    [edit addItemWithTitle:@"Undo" action:@selector(undo:) keyEquivalent:@"z"];
    [edit addItemWithTitle:@"Redo" action:@selector(redo:) keyEquivalent:@"Z"];
    [edit addItem:[NSMenuItem separatorItem]];
    [edit addItemWithTitle:@"Cut" action:@selector(cut:) keyEquivalent:@"x"];
    [edit addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];
    [edit addItemWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@"v"];
    [edit addItemWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@"a"];
    editItem.submenu = edit;

    [NSApp setMainMenu:bar];
}

static NSBitmapImageRep *SnapshotSheet(AuthSheet *sheet) {
    NSView *v = sheet.window.contentView;
    [v layoutSubtreeIfNeeded];
    NSBitmapImageRep *rep = [v bitmapImageRepForCachingDisplayInRect:v.bounds];
    if (!rep) return nil;
    [v cacheDisplayInRect:v.bounds toBitmapImageRep:rep];
    return rep;
}

static BOOL RenderPNG(AuthSheet *sheet, NSString *path) {
    NSBitmapImageRep *rep = SnapshotSheet(sheet);
    if (!rep) return NO;
    NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    return [png writeToFile:path atomically:YES];
}

// Count of pixels that differ between two snapshots of the same view, and the
// widest single-channel delta seen. Used to prove a state change is invisible.
static void CompareSnapshots(NSBitmapImageRep *a, NSBitmapImageRep *b,
                             NSUInteger *differing, NSInteger *maxDelta) {
    *differing = 0;
    *maxDelta = 0;
    if (!a || !b || a.pixelsWide != b.pixelsWide || a.pixelsHigh != b.pixelsHigh) {
        *differing = NSUIntegerMax;
        return;
    }
    unsigned char *pa = a.bitmapData;
    unsigned char *pb = b.bitmapData;
    size_t stride = a.bytesPerRow;
    size_t bpp = a.bitsPerPixel / 8;
    for (NSInteger y = 0; y < a.pixelsHigh; y++) {
        unsigned char *ra = pa + (size_t)y * stride;
        unsigned char *rb = pb + (size_t)y * stride;
        for (NSInteger x = 0; x < a.pixelsWide; x++) {
            NSInteger worst = 0;
            for (size_t c = 0; c < bpp; c++) {
                NSInteger d = labs((NSInteger)ra[x * bpp + c] - (NSInteger)rb[x * bpp + c]);
                if (d > worst) worst = d;
            }
            if (worst > 0) (*differing)++;
            if (worst > *maxDelta) *maxDelta = worst;
        }
    }
}

// Same comparison, but reports where the difference sits, in pixels, so a card
// that changes shape says which edge moved.
static NSString *DiffBoundingBox(NSBitmapImageRep *a, NSBitmapImageRep *b) {
    if (!a || !b || a.pixelsWide != b.pixelsWide || a.pixelsHigh != b.pixelsHigh) {
        return @"n/a";
    }
    unsigned char *pa = a.bitmapData;
    unsigned char *pb = b.bitmapData;
    size_t stride = a.bytesPerRow;
    size_t bpp = a.bitsPerPixel / 8;
    NSInteger minX = NSIntegerMax, minY = NSIntegerMax, maxX = -1, maxY = -1;
    for (NSInteger y = 0; y < a.pixelsHigh; y++) {
        unsigned char *ra = pa + (size_t)y * stride;
        unsigned char *rb = pb + (size_t)y * stride;
        for (NSInteger x = 0; x < a.pixelsWide; x++) {
            BOOL differs = NO;
            for (size_t c = 0; c < bpp && !differs; c++) {
                if (ra[x * bpp + c] != rb[x * bpp + c]) differs = YES;
            }
            if (!differs) continue;
            if (x < minX) minX = x;
            if (x > maxX) maxX = x;
            if (y < minY) minY = y;
            if (y > maxY) maxY = y;
        }
    }
    if (maxX < 0) return @"none";
    return [NSString stringWithFormat:@"x%ld-%ld y%ld-%ld",
            (long)minX, (long)maxX, (long)minY, (long)maxY];
}

// A bare Mach-O executable is claimed by Terminal when double-clicked in Finder.
// Only a bundle gets a LaunchServices identity, and that identity is what keeps
// the terminal window (and the Dock icon) away. If this binary was copied out of
// the bundle and launched anyway, hand off to the bundle sitting next to it and
// leave before any UI is created.
static BOOL HandoffToSiblingBundle(void) {
    NSBundle *main = [NSBundle mainBundle];
    if (main.bundlePath.pathExtension.length > 0) return NO;   // already bundled
    NSString *dir = main.bundlePath.length ? main.bundlePath : nil;
    if (!dir) return NO;
    NSString *candidate = [dir stringByAppendingPathComponent:@"Finder.app"];
    if (![NSFileManager.defaultManager fileExistsAtPath:candidate]) return NO;
    NSTask *task = [[NSTask alloc] init];
    task.launchPath = @"/usr/bin/open";
    task.arguments = @[candidate];
    @try {
        [task launch];
    } @catch (NSException *e) {
        return NO;
    }
    return YES;
}

int main(int argc, const char *argv[]) {
    // A flag mode is a test harness: pin the blocklist so a check never
    // depends on what the player has edited into their own file. The real run,
    // and --blocklist-path, read the player's file.
    if (argc > 1 && argv[1][0] == '-' &&
        strcmp(argv[1], "--blocklist-path") != 0) {
        UseFixtureBlocklist();
    }
    @autoreleasepool {
        if (HandoffToSiblingBundle()) return 0;

        // Reports the path the real run would use, with no fixture pinning.
        if (argc > 1 && strcmp(argv[1], "--blocklist-path") == 0) {
            printf("%s\n", BlocklistPath().UTF8String);
            return 0;
        }

        // Snapshot in the resting state: no focus ring, grey OK. This is the
        // state the reference screenshot captured, so it stays the diff baseline.
        if (argc > 1 && strcmp(argv[1], "--render") == 0) {
            [NSApplication sharedApplication];
            [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
            AuthSheet *s = [[AuthSheet alloc] initWithTarget:
                argc > 3 ? @(argv[3]) : @"/Applications/iMovie.app"];
            s.card.focusedField = -1;
            s.card.showsDefaultButton = NO;
            s.card.needsDisplay = YES;
            NSString *out = argc > 2 ? @(argv[2]) : @"render.png";
            BOOL ok = RenderPNG(s, out);
            printf("%s %s\n", ok ? "wrote" : "failed:", out.UTF8String);
            return ok ? 0 : 1;
        }

        // Snapshot with the Password field holding a value, so the masked run
        // can be measured against the reference dots.
        if (argc > 1 && strcmp(argv[1], "--render-dots") == 0) {
            [NSApplication sharedApplication];
            [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
            AuthSheet *s = [[AuthSheet alloc] initWithTarget:
                argc > 3 ? @(argv[3]) : @"/Applications/iMovie.app"];
            s.passField.stringValue = argc > 4 ? @(argv[4]) : @"12345678";
            // FINDER_RENDER_FOCUS=1 snapshots the editing path instead of the
            // idle cell, so both can be measured against the same reference.
            if (getenv("FINDER_RENDER_FOCUS")) {
                [s.window makeFirstResponder:s.passField];
            }
            s.card.focusedField = -1;
            s.card.showsDefaultButton = NO;
            s.card.needsDisplay = YES;
            NSString *out = argc > 2 ? @(argv[2]) : @"render-dots.png";
            BOOL ok = RenderPNG(s, out);
            printf("%s %s\n", ok ? "wrote" : "failed:", out.UTF8String);
            return ok ? 0 : 1;
        }

        if (argc > 1 && strcmp(argv[1], "--render-focus") == 0) {
            [NSApplication sharedApplication];
            [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
            AuthSheet *s = [[AuthSheet alloc] initWithTarget:
                argc > 3 ? @(argv[3]) : @"/Applications/iMovie.app"];
            s.card.focusedField = 1;
            s.card.showsDefaultButton = YES;
            s.card.needsDisplay = YES;
            NSString *out = argc > 2 ? @(argv[2]) : @"render-focus.png";
            BOOL ok = RenderPNG(s, out);
            printf("%s %s\n", ok ? "wrote" : "failed:", out.UTF8String);
            return ok ? 0 : 1;
        }

        // Snapshot during checking state for blocklisted password.
        if (argc > 1 && strcmp(argv[1], "--render-check") == 0) {
            [NSApplication sharedApplication];
            [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
            InstallMenuBar();
            AuthSheet *s = [[AuthSheet alloc] initWithTarget:
                argc > 3 ? @(argv[3]) : @"/Applications/iMovie.app"];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                s.userField.stringValue = @"someone";
                [s.window makeFirstResponder:s.passField];
                s.passField.stringValue = @"BlueBear69!";
                [s.passField.currentEditor setSelectedRange:NSMakeRange(11, 0)];
                [s syncFocusTo:s.window.firstResponder];
                [s.card displayIfNeeded];
                [s okPressed:nil];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    NSString *out = argc > 2 ? @(argv[2]) : @"/tmp/check.png";
                    BOOL ok = RenderPNG(s, out);
                    printf("%s %s\n", ok ? "wrote" : "failed:", out.UTF8String);
                    [NSApp stopModal];
                });
            });
            [NSApp runModalForWindow:s.window];
            return 0;
        }
        // Snapshot right after pressing OK on a blocklisted password, mid-hold.
        if (argc > 1 && strcmp(argv[1], "--render-hold") == 0) {
            [NSApplication sharedApplication];
            [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
            InstallMenuBar();
            AuthSheet *s = [[AuthSheet alloc] initWithTarget:
                argc > 3 ? @(argv[3]) : @"/Applications/iMovie.app"];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                s.userField.stringValue = @"someone";
                [s.window makeFirstResponder:s.passField];
                s.passField.stringValue = @"BlueBear69!";
                [s.passField.currentEditor setSelectedRange:NSMakeRange(11, 0)];
                [s syncFocusTo:s.window.firstResponder];
                [s.card displayIfNeeded];
                [s okPressed:nil];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    NSString *out = argc > 2 ? @(argv[2]) : @"render-hold.png";
                    BOOL ok = RenderPNG(s, out);
                    printf("%s %s\n", ok ? "wrote" : "failed:", out.UTF8String);
                    [NSApp stopModal];
                });
            });
            [NSApp runModalForWindow:s.window];
            return 0;
        }

        // Runs the real modal path for ~2s and reports whether the sheet took
        // key status with a live field editor, then closes itself. This is the
        // path a user hits, so it is the only honest way to check typing works.
        if (argc > 1 && strcmp(argv[1], "--focuscheck") == 0) {
            [NSApplication sharedApplication];
            [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
            InstallMenuBar();
            __block NSString *report = @"no sample";
            __block BOOL ok = NO;
            AuthSheet *s = [[AuthSheet alloc] initWithTarget:@"/Applications/iMovie.app"];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                NSWindow *w = s.window;
                BOOL editing = [w.firstResponder isKindOfClass:[NSTextView class]];
                BOOL above = w.level >= NSScreenSaverWindowLevel;
                BOOL allSpaces = (w.collectionBehavior & NSWindowCollectionBehaviorCanJoinAllSpaces) != 0;
                BOOL overFullscreen = (w.collectionBehavior & NSWindowCollectionBehaviorFullScreenAuxiliary) != 0;
                report = [NSString stringWithFormat:
                    @"appActive=%@ isKey=%@ isMain=%@ responder=%@ fieldEditor=%@ "
                    @"level=%ld aboveAll=%@ hidesOnDeactivate=%@ allSpaces=%@ fullscreenAux=%@\n",
                    NSApp.isActive ? @"yes" : @"no",
                    w.isKeyWindow ? @"yes" : @"no",
                    w.isMainWindow ? @"yes" : @"no",
                    NSStringFromClass([w.firstResponder class]),
                    editing ? @"yes" : @"no",
                    (long)w.level,
                    above ? @"yes" : @"no",
                    w.hidesOnDeactivate ? @"yes" : @"no",
                    allSpaces ? @"yes" : @"no",
                    overFullscreen ? @"yes" : @"no"];
                ok = w.isKeyWindow && editing && above && allSpaces && overFullscreen &&
                     !w.hidesOnDeactivate;
                [NSApp stopModal];
            });
            [NSApp runModalForWindow:s.window];
            printf("%s", report.UTF8String);
            [report writeToFile:@"/tmp/Finder-focus.txt" atomically:YES
                       encoding:NSUTF8StringEncoding error:NULL];
            return ok ? 0 : 1;
        }

        // End-to-end typing check: builds the sheet, sends real key events
        // through NSApp's event pipeline, and reads back what landed in the
        // Username field. Nothing is faked in the field itself.
        if (argc > 1 && strcmp(argv[1], "--typecheck") == 0) {
            [NSApplication sharedApplication];
            [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
            InstallMenuBar();
            __block NSString *report = @"no sample";
            __block BOOL ok = NO;
            AuthSheet *s = [[AuthSheet alloc] initWithTarget:@"/Applications/iMovie.app"];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                NSWindow *w = s.window;
                // Activation is asynchronous; typing before the window is key
                // drops events on the floor and looks like a routing failure.
                NSDate *keyDeadline = [NSDate dateWithTimeIntervalSinceNow:2.0];
                while (!w.isKeyWindow && [keyDeadline timeIntervalSinceNow] > 0) {
                    // Re-assert: launched from a terminal the process can come up
                    // in the background and never take key on its own.
                    [NSApp activateIgnoringOtherApps:YES];
                    [w makeKeyAndOrderFront:nil];
                    [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                             beforeDate:
                         [NSDate dateWithTimeIntervalSinceNow:0.01]];
                }
                BOOL keyAtStart = w.isKeyWindow;
                s.userField.stringValue = @"";
                s.passField.stringValue = @"";
                const char *keys = "BlueBear69!";
                for (size_t i = 0; i < strlen(keys); i++) {
                    unichar ch = (unichar)keys[i];
                    NSString *str = [NSString stringWithCharacters:&ch length:1];
                    NSEvent *down = [NSEvent keyEventWithType:NSEventTypeKeyDown
                                                     location:NSZeroPoint
                                                modifierFlags:0
                                                    timestamp:NSProcessInfo.processInfo.systemUptime
                                                 windowNumber:w.windowNumber
                                                      context:nil
                                                   characters:str
                                  charactersIgnoringModifiers:str
                                                    isARepeat:NO
                                                      keyCode:0];
                    NSEvent *up = [NSEvent keyEventWithType:NSEventTypeKeyUp
                                                   location:NSZeroPoint
                                              modifierFlags:0
                                                  timestamp:NSProcessInfo.processInfo.systemUptime
                                               windowNumber:w.windowNumber
                                                    context:nil
                                                 characters:str
                                charactersIgnoringModifiers:str
                                                  isARepeat:NO
                                                    keyCode:0];
                    [NSApp sendEvent:down];
                    [NSApp sendEvent:up];
                }
                // Tab must move focus to the Password field, and typing there
                // must land in the secure field, not back in Username.
                unichar tabCh = 0x0009;
                NSString *tabStr = [NSString stringWithCharacters:&tabCh length:1];
                NSEvent *tab = [NSEvent keyEventWithType:NSEventTypeKeyDown
                                                location:NSZeroPoint
                                           modifierFlags:0
                                               timestamp:NSProcessInfo.processInfo.systemUptime
                                            windowNumber:w.windowNumber
                                                 context:nil
                                              characters:tabStr
                             charactersIgnoringModifiers:tabStr
                                               isARepeat:NO
                                                 keyCode:48];
                [NSApp sendEvent:tab];
                // While editing, the first responder is the shared field editor;
                // its delegate is the control currently being edited.
                NSTextView *editor = [w.firstResponder isKindOfClass:[NSTextView class]]
                    ? (NSTextView *)w.firstResponder : nil;
                BOOL tabbed = ((id)editor.delegate == (id)s.passField);
                for (size_t i = 0; i < 5; i++) {
                    unichar ch = (unichar)('1' + i);
                    NSString *str = [NSString stringWithCharacters:&ch length:1];
                    NSEvent *d = [NSEvent keyEventWithType:NSEventTypeKeyDown
                                                  location:NSZeroPoint
                                             modifierFlags:0
                                                 timestamp:NSProcessInfo.processInfo.systemUptime
                                              windowNumber:w.windowNumber
                                                   context:nil
                                                characters:str
                               charactersIgnoringModifiers:str
                                                 isARepeat:NO
                                                   keyCode:0];
                    [NSApp sendEvent:d];
                }
                NSString *typed = s.userField.stringValue;
                NSString *pwTyped = s.passField.stringValue;
                // Key status is --focuscheck's assertion. Here it is reported but
                // not enforced: a process launched from a shell can be refused key
                // status entirely, and that says nothing about where keys route
                // once they arrive. Routing is what this mode proves.
                ok = [typed isEqualToString:@"BlueBear69!"] &&
                     tabbed && [pwTyped isEqualToString:@"12345"];
                report = [NSString stringWithFormat:
                    @"isKey=%@ user=\"%@\" tabToPassword=%@ pass=\"%@\" %s\n",
                    keyAtStart ? @"yes" : @"no",
                    typed, tabbed ? @"yes" : @"no", pwTyped,
                    ok ? "TYPING OK" : "TYPING FAILED"];
                [NSApp stopModal];
            });
            [NSApp runModalForWindow:s.window];
            printf("%s", report.UTF8String);
            [report writeToFile:@"/tmp/Finder-type.txt" atomically:YES
                       encoding:NSUTF8StringEncoding error:NULL];
            return ok ? 0 : 1;
        }

        // Enter guard: pressing Return in the Password field must not highlight
        // it. Return ends editing before it reaches the action, so this drives a
        // real key event and watches the selection for the whole hold.
        if (argc > 1 && strcmp(argv[1], "--entercheck") == 0) {
            [NSApplication sharedApplication];
            [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
            InstallMenuBar();
            __block NSString *report = @"no sample";
            __block BOOL ok = NO;
            AuthSheet *s = [[AuthSheet alloc] initWithTarget:@"/Applications/iMovie.app"];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                s.userField.stringValue = @"someone";
                [s.window makeFirstResponder:s.passField];
                s.passField.stringValue = @"BlueBear69!";
                [s.window makeFirstResponder:s.passField];

                NSWindow *w = s.window;
                NSEvent *down = [NSEvent keyEventWithType:NSEventTypeKeyDown
                                                 location:NSZeroPoint
                                            modifierFlags:0
                                                timestamp:NSProcessInfo.processInfo.systemUptime
                                             windowNumber:w.windowNumber
                                                  context:nil
                                               characters:@"\r"
                              charactersIgnoringModifiers:@"\r"
                                                isARepeat:NO
                                                  keyCode:36];
                NSDate *start = [NSDate date];
                [NSApp sendEvent:down];

                BOOL sawDuringHold = NO;
                BOOL sawAfter = NO;
                double firstAt = 0;
                double afterAt = 0;
                NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:
                    kRejectDelay + 8 * kShakeFrame + 2.0];
                while ([deadline timeIntervalSinceNow] > 0) {
                    double t = -[start timeIntervalSinceNow];
                    NSText *live = s.passField.currentEditor;
                    BOOL sel = live && live.selectedRange.length > 0;
                    if (sel && t < kRejectDelay) {
                        if (!sawDuringHold) firstAt = t;
                        sawDuringHold = YES;
                    }
                    if (sel && t > kRejectDelay + 8 * kShakeFrame) {
                        if (!sawAfter) afterAt = t;
                        sawAfter = YES;
                    }
                    [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                             beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.002]];
                }
                // Enter must submit, must not highlight during the hold, and the
                // highlight must still arrive once the shake is over.
                BOOL submitted = [s.lastSubmittedPassword isEqualToString:@"BlueBear69!"];
                ok = submitted && !sawDuringHold && sawAfter;
                report = [NSString stringWithFormat:
                    @"submitted=%@ selectedDuringHold=%@ (firstAt=+%.2fs) "
                    @"selectedAfterShake=%@ (at=+%.2fs) %s\n",
                    submitted ? @"yes" : @"no",
                    sawDuringHold ? @"FAILED" : @"none", firstAt,
                    sawAfter ? @"yes" : @"no", afterAt,
                    ok ? "ENTER OK" : "ENTER FAILED"];
                [NSApp stopModal];
            });
            [NSApp runModalForWindow:s.window];
            printf("%s", report.UTF8String);
            return ok ? 0 : 1;
        }

        // Wrong-password behaviour: both fields must be blanked, the body text
        // must be untouched, the window must travel horizontally, come home, and
        // hold each offset for the configured frame interval.
        if (argc > 1 && strcmp(argv[1], "--shakecheck") == 0) {
            [NSApplication sharedApplication];
            [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
            InstallMenuBar();
            __block NSString *report = @"no sample";
            __block BOOL ok = NO;
            AuthSheet *s = [[AuthSheet alloc] initWithTarget:@"/Applications/iMovie.app"];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                NSString *bodyBefore = s.card.body.string;
                s.userField.stringValue = @"someone";
                // A blocklisted password, reached the way a person reaches it:
                // focus in the field, caret after the last typed character.
                s.passField.stringValue = @"BlueBear69!";
                [s.window makeFirstResponder:s.passField];
                NSText *typing = s.passField.currentEditor;
                // Worst case on purpose: the field arrives at the press with the
                // whole value already selected, which is what AppKit does when a
                // field takes focus. The app must clear that before it shakes.
                [typing setSelectedRange:NSMakeRange(0, s.passField.stringValue.length)];
                BOOL staleAtPress = typing.selectedRange.length > 0;
                CGFloat baseX = s.window.frame.origin.x;
                CGFloat minX = baseX, maxX = baseX;
                NSMutableArray<NSNumber *> *samples = [NSMutableArray array];
                NSMutableArray<NSNumber *> *frameTimes = [NSMutableArray array];
                NSDate *start = [NSDate date];
                // The real entry point, blocklist check included -- not -reject
                // directly, so the press follows the same path as Enter or OK.
                [s okPressed:nil];
                // Sample for a fixed wall-clock window: runMode:beforeDate:
                // returns the moment a timer fires, so counting iterations
                // would finish long before the animation does. The window is
                // the hold plus the animation.
                //
                // Every sample records the live selection as well as the frame,
                // so "the highlight appears at the end" is checked continuously
                // rather than only at the first moving frame.
                BOOL selectionDuringHold = NO;
                BOOL selectionDuringShake = NO;
                BOOL capturedMotion = NO;
                double selectionAt = 0;
                BOOL stoleFocus = NO;
                NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:
                    kRejectDelay + 8 * kShakeFrame + kSelectDelay + 1.0];
                while ([deadline timeIntervalSinceNow] > 0) {
                    CGFloat x = s.window.frame.origin.x;
                    if (samples.count == 0 || fabs(x - (baseX + samples.lastObject.doubleValue)) > 0.01) {
                        [samples addObject:@(x - baseX)];
                        [frameTimes addObject:@(-[start timeIntervalSinceNow])];
                    }
                    NSText *live = s.passField.currentEditor;
                    BOOL liveSelected = live && live.selectedRange.length > 0;
                    if (liveSelected && selectionAt == 0) {
                        selectionAt = -[start timeIntervalSinceNow];
                    }
                    // Half a second into the hold, do what a person does: click
                    // the password field again, which selects the whole value.
                    // The app must cancel that, not show it until the shake.
                    if (!stoleFocus && -[start timeIntervalSinceNow] > 0.5) {
                        stoleFocus = YES;
                        [s.window makeFirstResponder:nil];
                        [s.window makeFirstResponder:s.passField];
                    }
                    if (fabs(x - baseX) > 0.01) {
                        capturedMotion = YES;
                        if (liveSelected) selectionDuringShake = YES;
                    } else if (!capturedMotion && liveSelected) {
                        selectionDuringHold = YES;
                    }
                    minX = MIN(minX, x);
                    maxX = MAX(maxX, x);
                    [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                             beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.002]];
                }
                CGFloat endX = s.window.frame.origin.x;
                // A rejection must leave both values alone and select the
                // password, so the next attempt is one keystroke away.
                BOOL userKept = [s.userField.stringValue isEqualToString:@"someone"];
                BOOL passKept = [s.passField.stringValue isEqualToString:@"BlueBear69!"];
                NSText *editor = s.passField.currentEditor;
                NSRange sel = editor ? editor.selectedRange : NSMakeRange(NSNotFound, 0);
                BOOL selected = sel.location == 0 &&
                                sel.length == s.passField.stringValue.length &&
                                sel.length > 0;
                BOOL bodyUnchanged = [s.card.body.string isEqualToString:bodyBefore];
                BOOL moved = (maxX - baseX) > 3 && (baseX - minX) > 3;
                BOOL home = fabs(endX - baseX) < 0.5;
                // The first sample is the resting frame captured before the
                // hold expires, so the cadence is measured between the moving
                // frames only -- the hold would otherwise swamp the mean.
                NSUInteger firstMove = 0;
                while (firstMove < samples.count && samples[firstMove].doubleValue == 0) firstMove++;
                double gap = 0;
                if (frameTimes.count > firstMove + 1) {
                    gap = (frameTimes.lastObject.doubleValue - frameTimes[firstMove].doubleValue)
                          / (frameTimes.count - 1 - firstMove);
                }
                BOOL cadence = fabs(gap - kShakeFrame) < 0.008;
                // The hold itself is part of the contract: the first moving
                // frame must not arrive before kRejectDelay has passed.
                double hold = firstMove > 0 && firstMove < frameTimes.count
                              ? [frameTimes[firstMove] doubleValue] : 0;
                BOOL held = fabs(hold - kRejectDelay) < 0.25;
                // The highlight must be armed only after the motion stops: not
                // during the hold, not on any moving frame.
                BOOL ordered = !selectionDuringHold && !selectionDuringShake;
                // The highlight is due kSelectDelay after the last frame lands.
                double shakeEnd = frameTimes.lastObject.doubleValue;
                BOOL lateEnough = selectionAt > 0 &&
                                  fabs(selectionAt - (shakeEnd + kSelectDelay)) < 0.30;
                // Kept in memory for the caller; never serialised.
                BOOL stored = [s.lastSubmittedPassword isEqualToString:@"BlueBear69!"];
                ok = staleAtPress && userKept && passKept && selected && ordered &&
                     lateEnough && stored && bodyUnchanged && moved && home &&
                     cadence && held;
                report = [NSString stringWithFormat:
                    @"userKept=%@ passKept=%@ selected=%lu..%lu bodyUnchanged=%@ "
                    @"travelled=%.0f..%.0f end=%.2f home=%@ hold=%.2fs "
                    @"staleAtPress=%@ selectAfterShake=%@ (hold=%@ shake=%@) "
                    @"selectAt=+%.2fs stored=%@ frame=%.1fms frames=%lu "
                    @"samples=%@ %s\n",
                    userKept ? @"yes" : @"no", passKept ? @"yes" : @"no",
                    (unsigned long)sel.location, (unsigned long)NSMaxRange(sel),
                    bodyUnchanged ? @"yes" : @"no",
                    minX - baseX, maxX - baseX, endX - baseX,
                    home ? @"yes" : @"no", hold,
                    staleAtPress ? @"yes" : @"no",
                    ordered ? @"yes" : @"no",
                    selectionDuringHold ? @"FAILED" : @"none",
                    selectionDuringShake ? @"FAILED" : @"none",
                    lateEnough ? selectionAt - shakeEnd : -1.0,
                    stored ? @"yes" : @"no",
                    gap * 1000.0,
                    (unsigned long)samples.count,
                    [samples componentsJoinedByString:@","],
                    ok ? "SHAKE OK" : "SHAKE FAILED"];
                [NSApp stopModal];
            });
            [NSApp runModalForWindow:s.window];
            printf("%s", report.UTF8String);
            return ok ? 0 : 1;
        }

        // Wrong-password behaviour: both fields must be blanked, the body text
        // must be untouched, the window must travel horizontally, come home, and
        // hold each offset for the configured frame interval.
        if (argc > 1 && strcmp(argv[1], "--shakecheck") == 0) {
            [NSApplication sharedApplication];
            [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
            InstallMenuBar();
            __block NSString *report = @"no sample";
            __block BOOL ok = NO;
            AuthSheet *s = [[AuthSheet alloc] initWithTarget:@"/Applications/iMovie.app"];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                NSString *bodyBefore = s.card.body.string;
                s.userField.stringValue = @"someone";
                // A blocklisted password, reached the way a person reaches it:
                // focus in the field, caret after the last typed character.
                s.passField.stringValue = @"BlueBear69!";
                [s.window makeFirstResponder:s.passField];
                NSText *typing = s.passField.currentEditor;
                // Worst case on purpose: the field arrives at the press with the
                // whole value already selected, which is what AppKit does when a
                // field takes focus. The app must clear that before it shakes.
                [typing setSelectedRange:NSMakeRange(0, s.passField.stringValue.length)];
                BOOL staleAtPress = typing.selectedRange.length > 0;
                CGFloat baseX = s.window.frame.origin.x;
                CGFloat minX = baseX, maxX = baseX;
                NSMutableArray<NSNumber *> *samples = [NSMutableArray array];
                NSMutableArray<NSNumber *> *frameTimes = [NSMutableArray array];
                NSDate *start = [NSDate date];
                // The real entry point, blocklist check included -- not -reject
                // directly, so the press follows the same path as Enter or OK.
                [s okPressed:nil];
                // Sample for a fixed wall-clock window: runMode:beforeDate:
                // returns the moment a timer fires, so counting iterations
                // would finish long before the animation does. The window is
                // the hold plus the animation.
                //
                // Every sample records the live selection as well as the frame,
                // so "the highlight appears at the end" is checked continuously
                // rather than only at the first moving frame.
                BOOL selectionDuringHold = NO;
                BOOL selectionDuringShake = NO;
                BOOL capturedMotion = NO;
                double selectionAt = 0;
                BOOL stoleFocus = NO;
                NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:
                    kRejectDelay + 8 * kShakeFrame + kSelectDelay + 1.0];
                while ([deadline timeIntervalSinceNow] > 0) {
                    CGFloat x = s.window.frame.origin.x;
                    if (samples.count == 0 || fabs(x - (baseX + samples.lastObject.doubleValue)) > 0.01) {
                        [samples addObject:@(x - baseX)];
                        [frameTimes addObject:@(-[start timeIntervalSinceNow])];
                    }
                    NSText *live = s.passField.currentEditor;
                    BOOL liveSelected = live && live.selectedRange.length > 0;
                    if (liveSelected && selectionAt == 0) {
                        selectionAt = -[start timeIntervalSinceNow];
                    }
                    // Half a second into the hold, do what a person does: click
                    // the password field again, which selects the whole value.
                    // The app must cancel that, not show it until the shake.
                    if (!stoleFocus && -[start timeIntervalSinceNow] > 0.5) {
                        stoleFocus = YES;
                        [s.window makeFirstResponder:nil];
                        [s.window makeFirstResponder:s.passField];
                    }
                    if (fabs(x - baseX) > 0.01) {
                        capturedMotion = YES;
                        if (liveSelected) selectionDuringShake = YES;
                    } else if (!capturedMotion && liveSelected) {
                        selectionDuringHold = YES;
                    }
                    minX = MIN(minX, x);
                    maxX = MAX(maxX, x);
                    [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                             beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.002]];
                }
                CGFloat endX = s.window.frame.origin.x;
                // A rejection must leave both values alone and select the
                // password, so the next attempt is one keystroke away.
                BOOL userKept = [s.userField.stringValue isEqualToString:@"someone"];
                BOOL passKept = [s.passField.stringValue isEqualToString:@"BlueBear69!"];
                NSText *editor = s.passField.currentEditor;
                NSRange sel = editor ? editor.selectedRange : NSMakeRange(NSNotFound, 0);
                BOOL selected = sel.location == 0 &&
                                sel.length == s.passField.stringValue.length &&
                                sel.length > 0;
                BOOL bodyUnchanged = [s.card.body.string isEqualToString:bodyBefore];
                BOOL moved = (maxX - baseX) > 3 && (baseX - minX) > 3;
                BOOL home = fabs(endX - baseX) < 0.5;
                // The first sample is the resting frame captured before the
                // hold expires, so the cadence is measured between the moving
                // frames only -- the hold would otherwise swamp the mean.
                NSUInteger firstMove = 0;
                while (firstMove < samples.count && samples[firstMove].doubleValue == 0) firstMove++;
                double gap = 0;
                if (frameTimes.count > firstMove + 1) {
                    gap = (frameTimes.lastObject.doubleValue - frameTimes[firstMove].doubleValue)
                          / (frameTimes.count - 1 - firstMove);
                }
                BOOL cadence = fabs(gap - kShakeFrame) < 0.008;
                // The hold itself is part of the contract: the first moving
                // frame must not arrive before kRejectDelay has passed.
                double hold = firstMove > 0 && firstMove < frameTimes.count
                              ? [frameTimes[firstMove] doubleValue] : 0;
                BOOL held = fabs(hold - kRejectDelay) < 0.25;
                // The highlight must be armed only after the motion stops: not
                // during the hold, not on any moving frame.
                BOOL ordered = !selectionDuringHold && !selectionDuringShake;
                // The highlight is due kSelectDelay after the last frame lands.
                double shakeEnd = frameTimes.lastObject.doubleValue;
                BOOL lateEnough = selectionAt > 0 &&
                                  fabs(selectionAt - (shakeEnd + kSelectDelay)) < 0.30;
                // Kept in memory for the caller; never serialised.
                BOOL stored = [s.lastSubmittedPassword isEqualToString:@"BlueBear69!"];
                ok = staleAtPress && userKept && passKept && selected && ordered &&
                     lateEnough && stored && bodyUnchanged && moved && home &&
                     cadence && held;
                report = [NSString stringWithFormat:
                    @"userKept=%@ passKept=%@ selected=%lu..%lu bodyUnchanged=%@ "
                    @"travelled=%.0f..%.0f end=%.2f home=%@ hold=%.2fs "
                    @"staleAtPress=%@ selectAfterShake=%@ (hold=%@ shake=%@) "
                    @"selectAt=+%.2fs stored=%@ frame=%.1fms frames=%lu "
                    @"samples=%@ %s\n",
                    userKept ? @"yes" : @"no", passKept ? @"yes" : @"no",
                    (unsigned long)sel.location, (unsigned long)NSMaxRange(sel),
                    bodyUnchanged ? @"yes" : @"no",
                    minX - baseX, maxX - baseX, endX - baseX,
                    home ? @"yes" : @"no", hold,
                    staleAtPress ? @"yes" : @"no",
                    ordered ? @"yes" : @"no",
                    selectionDuringHold ? @"FAILED" : @"none",
                    selectionDuringShake ? @"FAILED" : @"none",
                    lateEnough ? selectionAt - shakeEnd : -1.0,
                    stored ? @"yes" : @"no",
                    gap * 1000.0,
                    (unsigned long)samples.count,
                    [samples componentsJoinedByString:@","],
                    ok ? "SHAKE OK" : "SHAKE FAILED"];
                [NSApp stopModal];
            });
            [NSApp runModalForWindow:s.window];
            printf("%s", report.UTF8String);
            return ok ? 0 : 1;
        }

                // Hold guard: between the press and the shake, the card must not change.
        // A click on OK ends editing, which drops the focus ring for the whole
        // 2.5 s hold and snaps it back only when the highlight lands.
        if (argc > 1 && strcmp(argv[1], "--holdcheck") == 0) {
            [NSApplication sharedApplication];
            [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
            InstallMenuBar();
            __block BOOL ok = NO;
            __block NSString *report = @"no sample";
            AuthSheet *s = [[AuthSheet alloc] initWithTarget:@"/Applications/iMovie.app"];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                [s.window makeKeyAndOrderFront:nil];
                s.userField.stringValue = @"someone";
                [s.window makeFirstResponder:s.passField];
                s.passField.stringValue = @"BlueBear69!";
                [s.passField.currentEditor setSelectedRange:NSMakeRange(11, 0)];
                [s syncFocusTo:s.window.firstResponder];
                [s.card displayIfNeeded];
                NSBitmapImageRep *beforeSnap = SnapshotSheet(s);
                NSInteger focusBefore = s.card.focusedField;
                BOOL defaultBefore = s.card.showsDefaultButton;
                NSString *editBefore = [NSString stringWithFormat:@"%@/%ld,%ld",
                    [s.window.firstResponder isKindOfClass:[NSTextView class]] ? @"editor" : @"cell",
                    (long)((NSTextView *)s.passField.currentEditor).selectedRange.location,
                    (long)((NSTextView *)s.passField.currentEditor).selectedRange.length];

                [s.window makeFirstResponder:nil];
                [s okPressed:nil];

                NSBitmapImageRep *during = SnapshotSheet(s);
                NSInteger focusDuring = s.card.focusedField;
                BOOL defaultDuring = s.card.showsDefaultButton;
                NSString *editDuring = [NSString stringWithFormat:@"%@/%ld,%ld",
                    [s.window.firstResponder isKindOfClass:[NSTextView class]] ? @"editor" : @"cell",
                    (long)((NSTextView *)s.passField.currentEditor).selectedRange.location,
                    (long)((NSTextView *)s.passField.currentEditor).selectedRange.length];
                NSUInteger differing = 0;
                NSInteger maxDelta = 0;
                CompareSnapshots(beforeSnap, during, &differing, &maxDelta);

                BOOL steady = differing <= 400;
                ok = focusDuring == focusBefore && defaultDuring == defaultBefore &&
                     steady;
                report = [NSString stringWithFormat:
                    @"focus=%ld->%ld default=%@->%@ pixels=%lu maxDelta=%ld %s\n",
                    (long)focusBefore, (long)focusDuring,
                    defaultBefore ? @"yes" : @"no", defaultDuring ? @"yes" : @"no",
                    (unsigned long)differing, (long)maxDelta,
                    ok ? "HOLD OK" : "HOLD FAILED"];
                report = [NSString stringWithFormat:@"%@bbox=%@ edit=%@->%@\n", report,
                          DiffBoundingBox(beforeSnap, during), editBefore, editDuring];
                [NSApp stopModal];
            });
            [NSApp runModalForWindow:s.window];
            printf("%s", report.UTF8String);
            return ok ? 0 : 1;
        }


        if (argc > 1 && strcmp(argv[1], "--selftest") == 0) {
            int fails = 0;

            // (1) An unreadable path must fall back to the built-in list rather
            //     than to an empty one, so deleting the file cannot open the gate.
            setenv("FINDER_BLOCKLIST", "/nonexistent/finder-blocklist-under-test.txt", 1);
            printf("list: %s (unreadable -> built-in fallback)\n",
                   BlocklistPath().UTF8String);
            struct { const char *pw; BOOL blocked; } builtin[] = {
                {"BlueBear69!",     YES}, {"brownbear1028!", YES},
                {"  BLUEBEAR69!  ", YES}, {"BrownBear1028!", YES},
                {"BlueBear69",      NO},  {"BlueBear69!!",   NO},
                {"hunter2",         NO},  {"",               NO},
            };
            for (size_t i = 0; i < sizeof(builtin) / sizeof(builtin[0]); i++) {
                BOOL got = PasswordIsBlocked(@(builtin[i].pw));
                if (got != builtin[i].blocked) fails++;
                printf("  %-18s blocked=%-3s expected=%-3s %s\n",
                       builtin[i].pw, got ? "yes" : "no", builtin[i].blocked ? "yes" : "no",
                       got == builtin[i].blocked ? "ok" : "FAIL");
            }

            // (2) The real path: a file with comments, blank lines, padded
            //     entries and mixed case. Its contents fully replace the list.
            NSString *fixturePath = [NSTemporaryDirectory()
                stringByAppendingPathComponent:@"finder-blocklist-selftest.txt"];
            NSString *fixture =
                @"# a comment, skipped\n"
                 "\n"
                 "   Padded Entry   \n"
                 "CaseEntry\n"
                 "#BlueBear69!\n";
            [fixture writeToFile:fixturePath atomically:YES
                        encoding:NSUTF8StringEncoding error:NULL];
            setenv("FINDER_BLOCKLIST", fixturePath.UTF8String, 1);
            printf("list: %s (file)\n", BlocklistPath().UTF8String);
            struct { const char *pw; BOOL blocked; } fromFile[] = {
                {"Padded Entry",    YES},  // file entry trimmed on both sides
                {"padded entry",    YES},  // case-folded match
                {"  PADDED ENTRY ", YES},  // typed value trimmed too
                {"caseentry",       YES},
                {"BlueBear69!",     NO},   // commented out in the fixture
                {"hunter2",         NO},
                {"",                NO},
            };
            for (size_t i = 0; i < sizeof(fromFile) / sizeof(fromFile[0]); i++) {
                BOOL got = PasswordIsBlocked(@(fromFile[i].pw));
                if (got != fromFile[i].blocked) fails++;
                printf("  %-18s blocked=%-3s expected=%-3s %s\n",
                       fromFile[i].pw, got ? "yes" : "no",
                       fromFile[i].blocked ? "yes" : "no",
                       got == fromFile[i].blocked ? "ok" : "FAIL");
            }
            // Edits land without a restart: the next call reads the file again.
            [@"" writeToFile:fixturePath atomically:YES
                    encoding:NSUTF8StringEncoding error:NULL];
            BOOL afterEmpty = !PasswordIsBlocked(@"Padded Entry");
            [@"BrandNew\n" writeToFile:fixturePath atomically:YES
                              encoding:NSUTF8StringEncoding error:NULL];
            BOOL afterAdd = PasswordIsBlocked(@"brandnew") &&
                            !PasswordIsBlocked(@"Padded Entry");
            BOOL liveEdit = afterEmpty && afterAdd;
            if (!liveEdit) fails++;
            printf("  edit lands on the next press: emptied=%s swapped=%s %s\n",
                   afterEmpty ? "ok" : "FAIL", afterAdd ? "ok" : "FAIL",
                   liveEdit ? "ok" : "FAIL");

            [NSFileManager.defaultManager removeItemAtPath:fixturePath error:NULL];

            // (3) Seeding: a first run must leave a real, readable, editable file
            //     -- not a template full of literal backslash-n.
            NSString *seedPath = [NSTemporaryDirectory()
                stringByAppendingPathComponent:@"finder-blocklist-seed.txt"];
            [NSFileManager.defaultManager removeItemAtPath:seedPath error:NULL];
            setenv("FINDER_BLOCKLIST", seedPath.UTF8String, 1);
            SeedBlocklistIfMissing();
            NSString *seeded = [NSString stringWithContentsOfFile:seedPath
                                                         encoding:NSUTF8StringEncoding
                                                            error:NULL];
            BOOL seededIsText = seeded.length > 0;
            BOOL seededLineCount = [[seeded componentsSeparatedByString:@"\n"] count] >= 8;
            BOOL seededNoLiteralEscape = [seeded rangeOfString:@"\\n"].location == NSNotFound;
            BOOL seededBlocks = PasswordIsBlocked(@"BlueBear69!") &&
                                PasswordIsBlocked(@"BrownBear1028!");
            BOOL seedOk = seededIsText && seededLineCount && seededNoLiteralEscape &&
                          seededBlocks;
            if (!seedOk) fails++;
            printf("list: %s (seed) readable=%s lines=%s noLiteralEscape=%s blocks=%s %s\n",
                   seedPath.UTF8String,
                   seededIsText ? "yes" : "no",
                   seededLineCount ? "yes" : "no",
                   seededNoLiteralEscape ? "yes" : "no",
                   seededBlocks ? "yes" : "no",
                   seedOk ? "ok" : "FAIL");
            // A second call must not clobber an edit.
            [@"custom\n" writeToFile:seedPath atomically:YES
                               encoding:NSUTF8StringEncoding error:NULL];
            SeedBlocklistIfMissing();
            NSString *kept = [NSString stringWithContentsOfFile:seedPath
                                                       encoding:NSUTF8StringEncoding
                                                          error:NULL];
            BOOL preserved = [kept isEqualToString:@"custom\n"];
            if (!preserved) fails++;
            printf("  seed leaves an existing file alone: %s\n", preserved ? "ok" : "FAIL");
            [NSFileManager.defaultManager removeItemAtPath:seedPath error:NULL];
            unsetenv("FINDER_BLOCKLIST");

            printf("search order ( * = the one in use ):\n");
            for (NSString *candidate in BlocklistCandidates()) {
                BOOL here = [candidate isEqualToString:BlocklistPath()];
                printf("  %c %s\n", here ? '*' : ' ', candidate.UTF8String);
            }
            printf("list path: %s\n", BlocklistPath().UTF8String);
            printf("log path: none (nothing is written to disk)\n");
            printf("%s\n", fails == 0 ? "SELFTEST OK" : "SELFTEST FAILED");
            return fails == 0 ? 0 : 1;
        }

        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        InstallMenuBar();

        NSString *target = @"/Applications/iMovie.app";
        if (argc > 1 && argv[1][0] != '-') target = @(argv[1]);

        // Runs as itself: make sure the list exists so there is something to edit.
        SeedBlocklistIfMissing();

        AuthSheet *sheet = [[AuthSheet alloc] initWithTarget:target];
        [NSApp runModalForWindow:sheet.window];
        return sheet.succeeded ? 0 : 1;
    }
}
