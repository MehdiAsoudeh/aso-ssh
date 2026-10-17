#import <Cocoa/Cocoa.h>
#import <unistd.h>
#import "VPNSessionPolicy.h"

@interface FlippedView : NSView
@end
@implementation FlippedView
- (BOOL)isFlipped { return YES; }
@end

@interface VPNProfile : NSObject
@property (copy) NSString *profileId, *name, *host, *user, *password, *port, *key;
- (NSString *)displayTitle;
- (NSString *)subtitle;
- (NSDictionary *)toDict;
- (BOOL)writeShellConfToURL:(NSURL *)url error:(NSError **)error;
+ (instancetype)fromDict:(NSDictionary *)d;
+ (instancetype)profileWithName:(NSString *)name host:(NSString *)host user:(NSString *)user password:(NSString *)password port:(NSString *)port key:(NSString *)key;
@end

@implementation VPNProfile
+ (instancetype)profileWithName:(NSString *)name host:(NSString *)host user:(NSString *)user password:(NSString *)password port:(NSString *)port key:(NSString *)key {
    VPNProfile *p = [VPNProfile new];
    p.profileId = [[NSUUID UUID] UUIDString];
    p.name = name ?: @"";
    p.host = host ?: @"";
    p.user = user ?: @"";
    p.password = password ?: @"";
    p.port = port ?: @"";
    p.key = key ?: @"";
    return p;
}
+ (instancetype)fromDict:(NSDictionary *)d {
    if (![d isKindOfClass:[NSDictionary class]]) return nil;
    VPNProfile *p = [VPNProfile new];
    p.profileId = [d[@"id"] isKindOfClass:[NSString class]] ? d[@"id"] : [[NSUUID UUID] UUIDString];
    p.name = [d[@"name"] isKindOfClass:[NSString class]] ? d[@"name"] : @"";
    p.host = [d[@"host"] isKindOfClass:[NSString class]] ? d[@"host"] : @"";
    p.user = [d[@"user"] isKindOfClass:[NSString class]] ? d[@"user"] : @"";
    p.password = [d[@"password"] isKindOfClass:[NSString class]] ? d[@"password"] : @"";
    p.port = [d[@"port"] isKindOfClass:[NSString class]] ? d[@"port"] : @"";
    p.key = [d[@"key"] isKindOfClass:[NSString class]] ? d[@"key"] : @"";
    return p;
}
- (NSDictionary *)toDict {
    return @{
        @"id": self.profileId ?: @"",
        @"name": self.name ?: @"",
        @"host": self.host ?: @"",
        @"user": self.user ?: @"",
        @"password": self.password ?: @"",
        @"port": self.port ?: @"",
        @"key": self.key ?: @""
    };
}
- (NSString *)displayTitle {
    if (self.name.length) return self.name;
    if (self.host.length) return self.host;
    return @"Untitled";
}
- (NSString *)subtitle {
    NSString *port = self.port.length ? self.port : @"22";
    if (!self.user.length && !self.host.length) return @"Not configured";
    return [NSString stringWithFormat:@"%@@%@:%@", self.user.length ? self.user : @"?", self.host.length ? self.host : @"?", port];
}
- (BOOL)writeShellConfToURL:(NSURL *)url error:(NSError **)error {
    NSString *(^q)(NSString *) = ^(NSString *s) {
        return [NSString stringWithFormat:@"'%@'", [s stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"] ?: @""];
    };
    NSString *body = [NSString stringWithFormat:@"SSH_HOST=%@\nSSH_USER=%@\nSSH_PASS=%@\nSSH_PORT=%@\nSSH_KEY=%@\nSSH_EXTRA_OPTS=''\n",
                      q(self.host), q(self.user), q(self.password), q(self.port), q(self.key)];
    return [body writeToURL:url atomically:YES encoding:NSUTF8StringEncoding error:error];
}
@end

@interface AppDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate>
@property (strong) NSWindow *window, *configWindow;
@property (strong) NSView *statusDot;
@property (strong) NSTextField *statusLabel, *detailLabel, *ipLabel, *busyLabel, *footerLabel, *versionLabel, *configStatusLabel, *modeLabel, *profilesHeader, *emptyListLabel;
@property (strong) NSTextField *nameField, *hostField, *userField, *portField, *keyField;
@property (strong) NSSecureTextField *passField;
@property (strong) NSButton *actionButton, *addButton, *editButton, *deleteButton, *saveButton, *resetPermButton, *cancelButton, *themeButton;
@property (strong) NSTableView *profilesTable;
@property (strong) NSScrollView *profilesScroll, *configScrollView;
@property (strong) NSTextField *configTitleLabel;
@property (strong) NSTimer *pollTimer, *opTimeout;
@property (strong) NSTask *activeTask;
@property (strong) NSMutableArray<VPNProfile *> *profiles;
@property (copy) NSString *activeProfileId;
@property (copy) NSString *editingProfileId;
@property (strong) VPNSessionPolicy *session;
@property (assign) BOOL isBusy, isOn, hasAuth, cancelRequested, autoReconnectPending, suppressSelectionHandler, darkTheme;
@end

@implementation AppDelegate

static const CGFloat kMainW = 420, kMainH = 520, kCfgW = 420, kCfgH = 520, kCfgBottomH = 100, kFieldRowH = 62, kFieldH = 32;
static const CGFloat kProfileRowH = 52; // ~3 visible rows in the list
static NSString * const kThemeDarkKey = @"ASOVPNDarkTheme";

- (NSURL *)projectDir {
    return [[[[[NSBundle mainBundle] bundleURL] URLByDeletingLastPathComponent] URLByDeletingLastPathComponent] URLByDeletingLastPathComponent];
}
- (NSURL *)supportDir {
    NSURL *base = [[NSFileManager defaultManager] URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
    return [base URLByAppendingPathComponent:@"ASO VPN" isDirectory:YES];
}
- (NSURL *)scriptURL {
    NSURL *b = [[NSBundle mainBundle] URLForResource:@"vpn" withExtension:@"sh"];
    return (b && [[NSFileManager defaultManager] fileExistsAtPath:b.path]) ? b : [[self projectDir] URLByAppendingPathComponent:@"vpn.sh"];
}
- (NSURL *)configURL { return [[self supportDir] URLByAppendingPathComponent:@"vpn.conf"]; }
- (NSURL *)profilesStoreURL { return [[self supportDir] URLByAppendingPathComponent:@"profiles.json"]; }
- (void)ensureSupportFiles {
    [[NSFileManager defaultManager] createDirectoryAtURL:[self supportDir] withIntermediateDirectories:YES attributes:nil error:nil];
}
- (void)invalidateTunnelSession {
    NSString *session = [NSHomeDirectory() stringByAppendingPathComponent:@".aso-vpn/session.env"];
    [[NSFileManager defaultManager] removeItemAtPath:session error:nil];
}

- (VPNProfile *)profileWithId:(NSString *)pid {
    if (!pid.length) return nil;
    for (VPNProfile *p in self.profiles) {
        if ([p.profileId isEqualToString:pid]) return p;
    }
    return nil;
}
- (VPNProfile *)activeProfile {
    VPNProfile *p = [self profileWithId:self.activeProfileId];
    if (p) return p;
    return self.profiles.firstObject;
}
- (NSInteger)indexOfActiveProfile {
    VPNProfile *p = [self activeProfile];
    if (!p) return -1;
    return (NSInteger)[self.profiles indexOfObject:p];
}

- (VPNProfile *)legacyProfileFromVpnConf {
    NSURL *url = [self configURL];
    if (![[NSFileManager defaultManager] fileExistsAtPath:url.path]) return nil;
    NSString *text = [NSString stringWithContentsOfURL:url encoding:NSUTF8StringEncoding error:nil];
    if (!text.length) return nil;
    NSString *host = @"", *user = @"", *password = @"", *port = @"", *key = @"";
    for (NSString *raw in [text componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        NSString *line = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (!line.length || [line hasPrefix:@"#"]) continue;
        NSRange eq = [line rangeOfString:@"="];
        if (eq.location == NSNotFound) continue;
        NSString *k = [[line substringToIndex:eq.location] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        NSString *value = [[line substringFromIndex:eq.location + 1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (([value hasPrefix:@"\""] && [value hasSuffix:@"\""]) || ([value hasPrefix:@"'"] && [value hasSuffix:@"'"]))
            value = [value substringWithRange:NSMakeRange(1, value.length - 2)];
        if ([k isEqualToString:@"SSH_HOST"]) host = value;
        else if ([k isEqualToString:@"SSH_USER"]) user = value;
        else if ([k isEqualToString:@"SSH_PASS"]) password = value;
        else if ([k isEqualToString:@"SSH_PORT"]) port = value;
        else if ([k isEqualToString:@"SSH_KEY"]) key = value;
    }
    if (!host.length && !user.length) return nil;
    NSString *name = host.length ? host : @"Imported";
    return [VPNProfile profileWithName:name host:host user:user password:password port:port key:key];
}

- (void)loadProfilesStore {
    self.profiles = [NSMutableArray array];
    self.activeProfileId = nil;
    [self ensureSupportFiles];
    NSData *data = [NSData dataWithContentsOfURL:[self profilesStoreURL]];
    if (data.length) {
        NSDictionary *root = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if ([root isKindOfClass:[NSDictionary class]]) {
            NSArray *arr = root[@"profiles"];
            if ([arr isKindOfClass:[NSArray class]]) {
                for (NSDictionary *d in arr) {
                    VPNProfile *p = [VPNProfile fromDict:d];
                    if (p) [self.profiles addObject:p];
                }
            }
            if ([root[@"activeId"] isKindOfClass:[NSString class]]) self.activeProfileId = root[@"activeId"];
        }
    }
    if (self.profiles.count == 0) {
        VPNProfile *legacy = [self legacyProfileFromVpnConf];
        if (legacy) {
            [self.profiles addObject:legacy];
            self.activeProfileId = legacy.profileId;
            [self saveProfilesStore];
        }
    }
    if (![self profileWithId:self.activeProfileId]) {
        self.activeProfileId = self.profiles.firstObject.profileId;
    }
    [self syncActiveToVpnConf];
}

- (BOOL)saveProfilesStore {
    [self ensureSupportFiles];
    NSMutableArray *arr = [NSMutableArray array];
    for (VPNProfile *p in self.profiles) [arr addObject:[p toDict]];
    NSDictionary *root = @{
        @"activeId": self.activeProfileId ?: @"",
        @"profiles": arr
    };
    NSData *data = [NSJSONSerialization dataWithJSONObject:root options:NSJSONWritingPrettyPrinted error:nil];
    if (!data) return NO;
    return [data writeToURL:[self profilesStoreURL] atomically:YES];
}

- (BOOL)syncActiveToVpnConf {
    VPNProfile *p = [self activeProfile];
    if (!p) {
        [[NSFileManager defaultManager] removeItemAtURL:[self configURL] error:nil];
        return YES;
    }
    [self ensureSupportFiles];
    return [p writeShellConfToURL:[self configURL] error:nil];
}

- (void)selectProfileAtIndex:(NSInteger)idx {
    if (idx < 0 || idx >= (NSInteger)self.profiles.count) return;
    if (![self.session allowsConfigChangeWhileConnected:self.isOn]) {
        self.busyLabel.stringValue = @"Disconnect before changing config";
        self.busyLabel.textColor = NSColor.systemOrangeColor;
        self.suppressSelectionHandler = YES;
        NSInteger cur = [self indexOfActiveProfile];
        if (cur >= 0) [self.profilesTable selectRowIndexes:[NSIndexSet indexSetWithIndex:cur] byExtendingSelection:NO];
        self.suppressSelectionHandler = NO;
        return;
    }
    VPNProfile *p = self.profiles[idx];
    BOOL changed = ![p.profileId isEqualToString:self.activeProfileId];
    self.activeProfileId = p.profileId;
    [self saveProfilesStore];
    [self syncActiveToVpnConf];
    self.suppressSelectionHandler = YES;
    [self.profilesTable selectRowIndexes:[NSIndexSet indexSetWithIndex:idx] byExtendingSelection:NO];
    [self.profilesTable reloadData];
    self.suppressSelectionHandler = NO;
    [self updateDetailFromActiveProfile];
    if (changed) {
        [self invalidateTunnelSession];
        [self refreshStatus];
    }
}

- (void)updateDetailFromActiveProfile {
    // SSH target line removed from main UI; selection is visible in the list.
}

- (void)layoutCenteredStatus {
    NSString *text = self.statusLabel.stringValue ?: @"";
    NSDictionary *attrs = @{NSFontAttributeName: self.statusLabel.font ?: [NSFont systemFontOfSize:16 weight:NSFontWeightSemibold]};
    CGFloat textW = ceil([text sizeWithAttributes:attrs].width) + 2;
    CGFloat dotW = 12, gap = 6;
    CGFloat total = dotW + gap + textW;
    CGFloat x = floor((kMainW - total) / 2.0);
    CGFloat y = self.statusLabel.frame.origin.y;
    self.statusDot.frame = NSMakeRect(x, y + 4, dotW, dotW);
    self.statusLabel.alignment = NSTextAlignmentLeft;
    self.statusLabel.frame = NSMakeRect(x + dotW + gap, y, textW, 20);
}

- (void)reloadProfilesUI {
    self.suppressSelectionHandler = YES;
    [self.profilesTable reloadData];
    NSInteger idx = [self indexOfActiveProfile];
    if (idx >= 0) {
        [self.profilesTable selectRowIndexes:[NSIndexSet indexSetWithIndex:idx] byExtendingSelection:NO];
    } else {
        [self.profilesTable deselectAll:nil];
    }
    self.suppressSelectionHandler = NO;
    BOOL empty = self.profiles.count == 0;
    self.emptyListLabel.hidden = !empty;
    if (empty) {
        NSRect r = self.profilesScroll.frame;
        self.emptyListLabel.frame = NSMakeRect(r.origin.x + 12, r.origin.y + (r.size.height - 20) / 2.0, r.size.width - 24, 20);
    }
    [self updateProfileButtons];
    [self updateDetailFromActiveProfile];
}

- (void)updateProfileButtons {
    BOOL has = self.profiles.count > 0;
    BOOL canChange = [self.session allowsConfigChangeWhileConnected:self.isOn];
    self.addButton.enabled = !self.isBusy && canChange;
    self.editButton.enabled = has && !self.isBusy && canChange;
    self.deleteButton.enabled = has && !self.isBusy && canChange;
    self.profilesTable.enabled = !self.isBusy && canChange;
}

- (NSTextField *)makeLabel:(NSString *)text size:(CGFloat)size weight:(NSFontWeight)weight color:(NSColor *)color {
    NSTextField *l = [NSTextField labelWithString:text];
    l.font = [NSFont systemFontOfSize:size weight:weight]; l.textColor = color; l.bezeled = NO; l.editable = NO;
    return l;
}
- (NSColor *)bgColor {
    return self.darkTheme
        ? [NSColor colorWithCalibratedRed:0.11 green:0.12 blue:0.15 alpha:1]
        : [NSColor colorWithCalibratedRed:0.95 green:0.95 blue:0.97 alpha:1];
}
- (NSColor *)panelColor {
    return self.darkTheme
        ? [NSColor colorWithCalibratedWhite:0.16 alpha:1]
        : [NSColor colorWithCalibratedWhite:1.0 alpha:1];
}
- (NSColor *)primaryTextColor {
    return self.darkTheme ? NSColor.whiteColor : [NSColor colorWithCalibratedWhite:0.12 alpha:1];
}
- (NSColor *)secondaryTextColor:(CGFloat)alpha {
    return [[self primaryTextColor] colorWithAlphaComponent:alpha];
}
- (void)styleInputField:(NSTextField *)field {
    field.font = [NSFont systemFontOfSize:14]; field.bezeled = YES; field.bezelStyle = NSTextFieldRoundedBezel;
    field.drawsBackground = YES; field.backgroundColor = [NSColor textBackgroundColor]; field.textColor = [NSColor textColor];
}
- (void)styleActionButton:(NSButton *)btn color:(NSColor *)color {
    btn.bordered = NO; btn.wantsLayer = YES; btn.layer.backgroundColor = color.CGColor;
    btn.layer.cornerRadius = 10; btn.layer.masksToBounds = YES;
    btn.attributedTitle = [[NSAttributedString alloc] initWithString:btn.title attributes:@{
        NSForegroundColorAttributeName: NSColor.whiteColor, NSFontAttributeName: [NSFont systemFontOfSize:16 weight:NSFontWeightSemibold]}];
}
- (void)loadThemePreference {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    if ([ud objectForKey:kThemeDarkKey] == nil) self.darkTheme = YES;
    else self.darkTheme = [ud boolForKey:kThemeDarkKey];
}
- (void)saveThemePreference {
    [[NSUserDefaults standardUserDefaults] setBool:self.darkTheme forKey:kThemeDarkKey];
}
- (void)themeTapped {
    self.darkTheme = !self.darkTheme;
    [self saveThemePreference];
    [self applyTheme];
}
- (void)recolorConfigFormLabels {
    NSView *form = self.configScrollView.documentView;
    for (NSView *v in form.subviews) {
        if (![v isKindOfClass:[NSTextField class]]) continue;
        NSTextField *tf = (NSTextField *)v;
        if (tf.editable || [tf isKindOfClass:[NSSecureTextField class]]) continue;
        tf.textColor = [self secondaryTextColor:0.75];
    }
}

- (void)applyTheme {
    NSAppearance *app = [NSAppearance appearanceNamed:self.darkTheme ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua];
    self.window.appearance = app;
    self.configWindow.appearance = app;
    self.window.backgroundColor = [self bgColor];
    self.configWindow.backgroundColor = [self bgColor];
    self.themeButton.title = self.darkTheme ? @"☀︎" : @"☾";
    self.statusLabel.textColor = self.isOn ? NSColor.systemGreenColor : [self secondaryTextColor:0.85];
    self.ipLabel.textColor = [self secondaryTextColor:0.85];
    self.profilesHeader.textColor = [self secondaryTextColor:0.7];
    self.emptyListLabel.textColor = [self secondaryTextColor:0.45];
    self.modeLabel.textColor = self.hasAuth ? NSColor.systemGreenColor : NSColor.systemOrangeColor;
    self.footerLabel.textColor = [self secondaryTextColor:0.32];
    self.versionLabel.textColor = [self secondaryTextColor:0.28];
    if (self.busyLabel.stringValue.length == 0)
        self.busyLabel.textColor = [self secondaryTextColor:0.45];
    self.profilesScroll.backgroundColor = [self panelColor];
    self.profilesTable.backgroundColor = [self panelColor];
    self.configScrollView.backgroundColor = [self panelColor];
    self.configTitleLabel.textColor = [self primaryTextColor];
    [self recolorConfigFormLabels];
    [self.profilesTable reloadData];
    [self layoutCenteredStatus];
    [self applyUIOn:self.isOn detail:nil];
}

- (void)refreshPublicIP {
    self.ipLabel.stringValue = @"Your IP: ...";
    NSURL *url = [NSURL URLWithString:@"https://api.ipify.org"];
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSString *ip = @"—";
        if (data.length > 0) {
            NSString *raw = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            if (raw.length > 0) {
                ip = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                if (ip.length == 0) ip = @"—";
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            self.ipLabel.stringValue = [NSString stringWithFormat:@"Your IP: %@", ip];
        });
    }];
    [task resume];
}

- (void)applicationDidFinishLaunching:(NSNotification *)n {
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    self.session = [[VPNSessionPolicy alloc] initWithMaxReconnectAttempts:3];
    [self loadThemePreference];
    [self loadProfilesStore];
    [self buildMainWindow]; [self buildConfigWindow];
    [self applyTheme];
    [self reloadProfilesUI];
    [self refreshPublicIP];
    [self refreshAuthAndStatus];
    self.pollTimer = [NSTimer scheduledTimerWithTimeInterval:2.0 target:self selector:@selector(refreshStatus) userInfo:nil repeats:YES];
    [NSApp activateIgnoringOtherApps:YES]; [self.window makeKeyAndOrderFront:nil];
}
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)s { return !self.window.isVisible; }

- (void)buildMainWindow {
    self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,kMainW,kMainH)
        styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskMiniaturizable backing:NSBackingStoreBuffered defer:NO];
    self.window.title = @"ASO VPN"; [self.window center]; self.window.releasedWhenClosed = NO;
    self.window.titlebarAppearsTransparent = YES; self.window.backgroundColor = [self bgColor]; self.window.delegate = self;
    NSView *c = [[NSView alloc] initWithFrame:NSMakeRect(0,0,kMainW,kMainH)]; self.window.contentView = c;

    CGFloat side = 16;

    // Bottom stack first so list can sit above Add with a fixed 3-row height.
    CGFloat vGap = 16;
    // Busy/error line sits above email/version; keep permission row clear of footer.
    CGFloat permRowY = 64;
    CGFloat connectY = permRowY + 26 + vGap;
    CGFloat addRowY = connectY + 44 + vGap;
    CGFloat listH = 3 * kProfileRowH;
    CGFloat listBottom = addRowY + 26 + 12;
    CGFloat listTop = listBottom + listH;

    // Your IP → Configs gap is 3× the previous ~12px gap → 36px
    CGFloat ipConfigsGap = 36;
    CGFloat headerH = 16;
    CGFloat headerY = listTop + 6;
    CGFloat ipY = headerY + headerH + ipConfigsGap;
    CGFloat statusY = ipY + 44; // 2× gap between status and IP (was 22)
    // 2× top inset above status (~18 → 36); window height already includes this.

    self.themeButton = [[NSButton alloc] initWithFrame:NSMakeRect(kMainW - side - 32, kMainH - 36, 32, 28)];
    self.themeButton.title = @"☀︎";
    self.themeButton.bezelStyle = NSBezelStyleRounded;
    self.themeButton.font = [NSFont systemFontOfSize:16 weight:NSFontWeightMedium];
    self.themeButton.target = self;
    self.themeButton.action = @selector(themeTapped);
    self.themeButton.toolTip = @"Toggle light / dark theme";
    [c addSubview:self.themeButton];

    self.statusDot = [[NSView alloc] initWithFrame:NSMakeRect(0, statusY + 4, 12, 12)];
    self.statusDot.wantsLayer = YES; self.statusDot.layer.cornerRadius = 6;
    self.statusDot.layer.backgroundColor = NSColor.systemOrangeColor.CGColor; [c addSubview:self.statusDot];

    self.statusLabel = [self makeLabel:@"Checking…" size:16 weight:NSFontWeightSemibold color:[self primaryTextColor]];
    self.statusLabel.frame = NSMakeRect(0, statusY, kMainW, 20);
    [c addSubview:self.statusLabel];

    self.detailLabel = [self makeLabel:@"" size:12 weight:NSFontWeightRegular color:[self secondaryTextColor:0.5]];
    self.detailLabel.hidden = YES;

    self.ipLabel = [self makeLabel:@"Your IP: ..." size:12 weight:NSFontWeightMedium color:[self secondaryTextColor:0.85]];
    self.ipLabel.alignment = NSTextAlignmentCenter;
    self.ipLabel.frame = NSMakeRect(side, ipY, kMainW - side*2, 16); [c addSubview:self.ipLabel];
    [self layoutCenteredStatus];

    self.profilesHeader = [self makeLabel:@"Configs" size:12 weight:NSFontWeightSemibold color:[self secondaryTextColor:0.7]];
    self.profilesHeader.frame = NSMakeRect(side, headerY, kMainW - side*2, headerH); [c addSubview:self.profilesHeader];

    self.profilesScroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(side, listBottom, kMainW - side*2, listH)];
    self.profilesScroll.hasVerticalScroller = YES;
    self.profilesScroll.borderType = NSBezelBorder;
    self.profilesScroll.autohidesScrollers = YES;
    self.profilesScroll.wantsLayer = YES;
    self.profilesScroll.layer.cornerRadius = 8;
    self.profilesScroll.backgroundColor = [self panelColor];

    self.profilesTable = [[NSTableView alloc] initWithFrame:NSZeroRect];
    NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:@"profile"];
    col.width = kMainW - side*2 - 20;
    [self.profilesTable addTableColumn:col];
    self.profilesTable.headerView = nil;
    self.profilesTable.rowHeight = kProfileRowH;
    self.profilesTable.backgroundColor = [self panelColor];
    self.profilesTable.selectionHighlightStyle = NSTableViewSelectionHighlightStyleRegular;
    self.profilesTable.allowsEmptySelection = YES;
    self.profilesTable.allowsMultipleSelection = NO;
    self.profilesTable.dataSource = self;
    self.profilesTable.delegate = self;
    self.profilesTable.target = self;
    self.profilesTable.doubleAction = @selector(editConfigTapped);
    self.profilesScroll.documentView = self.profilesTable;
    [c addSubview:self.profilesScroll];

    self.emptyListLabel = [self makeLabel:@"No config yet" size:14 weight:NSFontWeightMedium color:[self secondaryTextColor:0.45]];
    self.emptyListLabel.alignment = NSTextAlignmentCenter;
    NSRect lr = self.profilesScroll.frame;
    self.emptyListLabel.frame = NSMakeRect(lr.origin.x + 8, lr.origin.y + (lr.size.height - 20) / 2.0, lr.size.width - 16, 20);
    [c addSubview:self.emptyListLabel];
    self.emptyListLabel.hidden = YES;

    CGFloat btnGap = 10;
    CGFloat btnW = (kMainW - side*2 - 2 * btnGap) / 3.0;
    self.addButton = [[NSButton alloc] initWithFrame:NSMakeRect(side, addRowY, btnW, 26)];
    self.addButton.title = @"Add"; self.addButton.bezelStyle = NSBezelStyleRounded;
    self.addButton.target = self; self.addButton.action = @selector(addConfigTapped);
    [c addSubview:self.addButton];

    self.editButton = [[NSButton alloc] initWithFrame:NSMakeRect(side + btnW + btnGap, addRowY, btnW, 26)];
    self.editButton.title = @"Edit"; self.editButton.bezelStyle = NSBezelStyleRounded;
    self.editButton.target = self; self.editButton.action = @selector(editConfigTapped);
    [c addSubview:self.editButton];

    self.deleteButton = [[NSButton alloc] initWithFrame:NSMakeRect(side + 2 * (btnW + btnGap), addRowY, btnW, 26)];
    self.deleteButton.title = @"Delete"; self.deleteButton.bezelStyle = NSBezelStyleRounded;
    self.deleteButton.target = self; self.deleteButton.action = @selector(deleteConfigTapped);
    [c addSubview:self.deleteButton];

    self.actionButton = [[NSButton alloc] initWithFrame:NSMakeRect(side, connectY, kMainW - side*2, 44)];
    self.actionButton.title = @"Connect"; self.actionButton.target = self; self.actionButton.action = @selector(toggleTapped);
    [self styleActionButton:self.actionButton color:NSColor.systemGreenColor]; [c addSubview:self.actionButton];

    self.resetPermButton = [[NSButton alloc] initWithFrame:NSMakeRect(0, 0, 10, 26)];
    self.resetPermButton.title = @"Reset";
    self.resetPermButton.bezelStyle = NSBezelStyleRounded;
    self.resetPermButton.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
    self.resetPermButton.target = self;
    self.resetPermButton.action = @selector(resetPermissionTapped);
    [self.resetPermButton sizeToFit];
    NSSize resetSz = self.resetPermButton.frame.size;
    CGFloat resetW = MAX(ceil(resetSz.width) + 14, 56);
    CGFloat resetH = 24;
    self.resetPermButton.frame = NSMakeRect(kMainW - side - resetW, permRowY, resetW, resetH);
    [c addSubview:self.resetPermButton];

    self.cancelButton = [[NSButton alloc] initWithFrame:self.resetPermButton.frame];
    self.cancelButton.title = @"Cancel";
    self.cancelButton.bezelStyle = NSBezelStyleRounded;
    self.cancelButton.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
    self.cancelButton.target = self;
    self.cancelButton.action = @selector(cancelTapped);
    self.cancelButton.hidden = YES;
    [self.cancelButton sizeToFit];
    NSSize cancelSz = self.cancelButton.frame.size;
    CGFloat cancelW = MAX(ceil(cancelSz.width) + 14, 56);
    self.cancelButton.frame = NSMakeRect(kMainW - side - cancelW, permRowY, cancelW, resetH);
    [c addSubview:self.cancelButton];

    self.modeLabel = [self makeLabel:@"Permission: checking…" size:10 weight:NSFontWeightRegular color:[self secondaryTextColor:0.45]];
    CGFloat modeRightPad = MAX(resetW, cancelW) + 8;
    self.modeLabel.frame = NSMakeRect(side, permRowY + 4, kMainW - side*2 - modeRightPad, 16);
    [c addSubview:self.modeLabel];

    // Email & version +20%
    self.footerLabel = [self makeLabel:@"asoodeh.dev@gmail.com" size:11 weight:NSFontWeightRegular color:[self secondaryTextColor:0.32]];
    self.footerLabel.alignment = NSTextAlignmentCenter;
    self.footerLabel.frame = NSMakeRect(side, 46, kMainW - side*2, 14); [c addSubview:self.footerLabel];

    NSString *ver = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"—";
    self.versionLabel = [self makeLabel:[NSString stringWithFormat:@"v%@", ver] size:11 weight:NSFontWeightRegular color:[self secondaryTextColor:0.28]];
    self.versionLabel.alignment = NSTextAlignmentCenter;
    self.versionLabel.frame = NSMakeRect(side, 30, kMainW - side*2, 14); [c addSubview:self.versionLabel];

    // Status/error line: +10% font (10→11), 3× bottom inset (was ~4 → 12)
    self.busyLabel = [self makeLabel:@"" size:11 weight:NSFontWeightRegular color:[self secondaryTextColor:0.45]];
    self.busyLabel.alignment = NSTextAlignmentCenter;
    self.busyLabel.frame = NSMakeRect(side, 12, kMainW - side*2, 14); [c addSubview:self.busyLabel];
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return (NSInteger)self.profiles.count;
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    if (row < 0 || row >= (NSInteger)self.profiles.count) return nil;
    VPNProfile *p = self.profiles[row];
    NSString *ident = @"ProfileCellRightCheck";
    NSTableCellView *cell = [tableView makeViewWithIdentifier:ident owner:self];
    if (!cell) {
        cell = [[NSTableCellView alloc] initWithFrame:NSMakeRect(0, 0, 280, kProfileRowH)];
        cell.identifier = ident;
        NSTextField *title = [self makeLabel:@"" size:16 weight:NSFontWeightSemibold color:[self primaryTextColor]];
        title.tag = 1;
        [cell addSubview:title];
        NSTextField *sub = [self makeLabel:@"" size:13 weight:NSFontWeightRegular color:[self secondaryTextColor:0.5]];
        sub.tag = 2;
        [cell addSubview:sub];
        NSTextField *check = [self makeLabel:@"" size:17 weight:NSFontWeightSemibold color:[self primaryTextColor]];
        check.alignment = NSTextAlignmentCenter;
        check.tag = 3;
        [cell addSubview:check];
    }
    NSTextField *title = [cell viewWithTag:1];
    NSTextField *sub = [cell viewWithTag:2];
    NSTextField *check = [cell viewWithTag:3];
    CGFloat cellW = MAX(tableView.bounds.size.width, tableColumn.width);
    if (cellW < 80) cellW = kMainW - 40;
    CGFloat checkW = 22, checkPad = 6;
    check.frame = NSMakeRect(cellW - checkW - checkPad, (kProfileRowH - 22) / 2.0, checkW, 22);
    CGFloat textW = MAX(40, cellW - checkW - checkPad - 16);
    title.frame = NSMakeRect(10, 26, textW, 20);
    sub.frame = NSMakeRect(10, 6, textW, 18);
    BOOL active = [p.profileId isEqualToString:self.activeProfileId];
    check.stringValue = active ? @"✓" : @"";
    title.stringValue = p.displayTitle;
    title.textColor = [self primaryTextColor];
    check.textColor = [self primaryTextColor];
    sub.textColor = [self secondaryTextColor:0.5];
    sub.stringValue = p.subtitle;
    return cell;
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    if (self.suppressSelectionHandler) return;
    if (self.isBusy || ![self.session allowsConfigChangeWhileConnected:self.isOn]) {
        self.suppressSelectionHandler = YES;
        NSInteger idx = [self indexOfActiveProfile];
        if (idx >= 0) [self.profilesTable selectRowIndexes:[NSIndexSet indexSetWithIndex:idx] byExtendingSelection:NO];
        self.suppressSelectionHandler = NO;
        if (self.isOn && !self.isBusy) {
            self.busyLabel.stringValue = @"Disconnect before changing config";
            self.busyLabel.textColor = NSColor.systemOrangeColor;
        }
        return;
    }
    NSInteger row = self.profilesTable.selectedRow;
    if (row < 0) return;
    [self selectProfileAtIndex:row];
}

- (NSTextField *)addLabeledField:(NSString *)label inView:(FlippedView *)parent y:(CGFloat)y width:(CGFloat)w x:(CGFloat)x secure:(BOOL)secure {
    NSTextField *cap = [self makeLabel:label size:12 weight:NSFontWeightMedium color:[self secondaryTextColor:0.75]];
    cap.frame = NSMakeRect(x,y,w,16); [parent addSubview:cap];
    NSTextField *field = secure ? [[NSSecureTextField alloc] initWithFrame:NSMakeRect(x,y+20,w,kFieldH)] : [[NSTextField alloc] initWithFrame:NSMakeRect(x,y+20,w,kFieldH)];
    [self styleInputField:field]; [parent addSubview:field]; return field;
}

- (void)buildConfigWindow {
    self.configWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,kCfgW,kCfgH) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO];
    self.configWindow.title = @"Connection Settings"; self.configWindow.releasedWhenClosed = NO;
    self.configWindow.titlebarAppearsTransparent = YES; self.configWindow.backgroundColor = [self bgColor]; self.configWindow.delegate = self;
    NSView *c = [[NSView alloc] initWithFrame:NSMakeRect(0,0,kCfgW,kCfgH)]; self.configWindow.contentView = c;
    self.configTitleLabel = [self makeLabel:@"Connection settings" size:18 weight:NSFontWeightBold color:[self primaryTextColor]];
    self.configTitleLabel.frame = NSMakeRect(24,kCfgH-44,kCfgW-48,26); [c addSubview:self.configTitleLabel];
    self.configScrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(16,kCfgBottomH,kCfgW-32,kCfgH-80-kCfgBottomH)];
    self.configScrollView.hasVerticalScroller = YES; self.configScrollView.autohidesScrollers = YES; self.configScrollView.borderType = NSBezelBorder;
    self.configScrollView.backgroundColor = [self panelColor];
    CGFloat pad = 16, full = kCfgW-32-pad*2, gap = 12, portW = 72, hostW = full - gap - portW;
    FlippedView *form = [[FlippedView alloc] initWithFrame:NSMakeRect(0,0,kCfgW-32,420)];
    CGFloat y = pad;
    self.nameField = [self addLabeledField:@"Name" inView:form y:y width:full x:pad secure:NO]; y += kFieldRowH;
    self.hostField = [self addLabeledField:@"Host" inView:form y:y width:hostW x:pad secure:NO];
    self.portField = [self addLabeledField:@"Port" inView:form y:y width:portW x:pad + hostW + gap secure:NO]; y += kFieldRowH;
    self.userField = [self addLabeledField:@"User" inView:form y:y width:full x:pad secure:NO]; y += kFieldRowH;
    self.passField = (NSSecureTextField *)[self addLabeledField:@"Password" inView:form y:y width:full x:pad secure:YES]; y += kFieldRowH;
    self.keyField = [self addLabeledField:@"SSH Key path (optional)" inView:form y:y width:full x:pad secure:NO]; y += kFieldRowH+12;
    form.frame = NSMakeRect(0,0,kCfgW-32,y); self.configScrollView.documentView = form; [c addSubview:self.configScrollView];
    self.configStatusLabel = [self makeLabel:@"" size:11 weight:NSFontWeightRegular color:NSColor.systemGreenColor];
    self.configStatusLabel.alignment = NSTextAlignmentCenter; self.configStatusLabel.frame = NSMakeRect(24,56,kCfgW-48,16); [c addSubview:self.configStatusLabel];
    self.saveButton = [[NSButton alloc] initWithFrame:NSMakeRect(24,16,kCfgW-48,44)]; self.saveButton.title = @"Save Config";
    self.saveButton.target = self; self.saveButton.action = @selector(saveConfig);
    [self styleActionButton:self.saveButton color:[NSColor colorWithCalibratedRed:0.20 green:0.45 blue:0.95 alpha:1]]; [c addSubview:self.saveButton];
}

- (void)showConfigWindow {
    if (!self.configWindow.isVisible) {
        NSRect mf = self.window.frame, cf = self.configWindow.frame;
        cf.origin.x = NSMidX(mf)-cf.size.width/2; cf.origin.y = NSMidY(mf)-cf.size.height/2;
        [self.configWindow setFrame:cf display:NO];
    }
    [self.configWindow makeKeyAndOrderFront:nil]; [NSApp activateIgnoringOtherApps:YES];
}

- (void)loadFieldsFromProfile:(VPNProfile *)p {
    self.nameField.stringValue = p.name ?: @"";
    self.hostField.stringValue = p.host ?: @"";
    self.userField.stringValue = p.user ?: @"";
    self.passField.stringValue = p.password ?: @"";
    self.portField.stringValue = p.port ?: @"";
    self.keyField.stringValue = p.key ?: @"";
    self.configStatusLabel.stringValue = @"";
}

- (void)addConfigTapped {
    if (self.isBusy) return;
    if (![self.session allowsConfigChangeWhileConnected:self.isOn]) {
        self.busyLabel.stringValue = @"Disconnect before changing config";
        self.busyLabel.textColor = NSColor.systemOrangeColor;
        return;
    }
    self.editingProfileId = nil;
    self.configWindow.title = @"Add Config";
    [self loadFieldsFromProfile:[VPNProfile new]];
    self.portField.stringValue = @"22";
    [self showConfigWindow];
}

- (void)editConfigTapped {
    if (self.isBusy) return;
    if (![self.session allowsConfigChangeWhileConnected:self.isOn]) {
        self.busyLabel.stringValue = @"Disconnect before editing";
        self.busyLabel.textColor = NSColor.systemOrangeColor;
        return;
    }
    NSInteger row = self.profilesTable.selectedRow;
    if (row < 0) row = [self indexOfActiveProfile];
    if (row < 0 || row >= (NSInteger)self.profiles.count) {
        self.busyLabel.stringValue = @"Select a config first";
        self.busyLabel.textColor = NSColor.systemOrangeColor;
        return;
    }
    VPNProfile *p = self.profiles[row];
    self.editingProfileId = p.profileId;
    self.configWindow.title = @"Edit Config";
    [self loadFieldsFromProfile:p];
    [self showConfigWindow];
}

- (void)deleteConfigTapped {
    if (self.isBusy) return;
    if (![self.session allowsConfigChangeWhileConnected:self.isOn]) {
        self.busyLabel.stringValue = @"Disconnect before changing config";
        self.busyLabel.textColor = NSColor.systemOrangeColor;
        return;
    }
    NSInteger row = self.profilesTable.selectedRow;
    if (row < 0) row = [self indexOfActiveProfile];
    if (row < 0 || row >= (NSInteger)self.profiles.count) return;
    VPNProfile *p = self.profiles[row];
    NSAlert *alert = [NSAlert new];
    alert.alertStyle = NSAlertStyleWarning;
    alert.messageText = @"Delete this config?";
    alert.informativeText = [NSString stringWithFormat:@"\"%@\" (%@) will be removed permanently.", p.displayTitle, p.subtitle];
    [alert addButtonWithTitle:@"Delete"];
    [alert addButtonWithTitle:@"Cancel"];
    if ([alert runModal] != NSAlertFirstButtonReturn) return;

    BOOL wasActive = [p.profileId isEqualToString:self.activeProfileId];
    [self.profiles removeObjectAtIndex:row];
    if (wasActive) {
        self.activeProfileId = self.profiles.firstObject.profileId;
        [self invalidateTunnelSession];
        if (self.isOn) {
            [self.session userClearedIntent];
            self.autoReconnectPending = NO;
            [self runVPN:@"off" busyMessage:@"Disconnecting deleted config…"];
        }
    }
    [self saveProfilesStore];
    [self syncActiveToVpnConf];
    [self reloadProfilesUI];
    [self refreshStatus];
}

- (void)saveConfig {
    if (![self.session allowsConfigChangeWhileConnected:self.isOn]) {
        self.configStatusLabel.textColor = NSColor.systemOrangeColor;
        self.configStatusLabel.stringValue = @"Disconnect before saving";
        return;
    }
    [self ensureSupportFiles];
    NSString *name = [self.nameField.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *host = [self.hostField.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *user = [self.userField.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *password = self.passField.stringValue ?: @"";
    NSString *port = [self.portField.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *key = [self.keyField.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

    if (!host.length || !user.length) {
        self.configStatusLabel.textColor = NSColor.systemRedColor;
        self.configStatusLabel.stringValue = @"Host and User are required";
        return;
    }
    if (port.length > 0 && port.integerValue <= 0) {
        self.configStatusLabel.textColor = NSColor.systemRedColor;
        self.configStatusLabel.stringValue = @"Port must be a number";
        return;
    }
    if (!name.length) name = host;

    VPNProfile *existing = [self profileWithId:self.editingProfileId];
    if (password.length == 0 && existing.password.length > 0) password = existing.password;

    BOOL isNew = (existing == nil);
    VPNProfile *cfg = existing ?: [VPNProfile profileWithName:name host:host user:user password:password port:port key:key];
    cfg.name = name; cfg.host = host; cfg.user = user; cfg.password = password; cfg.port = port; cfg.key = key;
    if (isNew) [self.profiles addObject:cfg];

    self.activeProfileId = cfg.profileId;
    if (![self saveProfilesStore] || ![self syncActiveToVpnConf]) {
        self.configStatusLabel.textColor = NSColor.systemRedColor;
        self.configStatusLabel.stringValue = @"Save failed";
        return;
    }

    [self invalidateTunnelSession];
    self.passField.stringValue = password;
    self.configStatusLabel.textColor = NSColor.systemGreenColor;
    self.configStatusLabel.stringValue = isNew ? @"Config added" : @"Config saved";
    [self reloadProfilesUI];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self.configWindow orderOut:nil];
        [self.window makeKeyAndOrderFront:nil];
        [self refreshStatus];
    });
}

- (BOOL)ensureAuthBeforeConnectBlocking {
    NSDictionary *st = [self runScriptEx:@[@"auth-status"]];
    BOOL ok = [self parseAuthOK:st[@"output"] ?: @""];
    dispatch_sync(dispatch_get_main_queue(), ^{
        self.hasAuth = ok;
        [self updateAuthLabel];
    });
    if (ok) return YES;
    __block BOOL granted = NO;
    dispatch_sync(dispatch_get_main_queue(), ^{
        granted = [self grantAdminOnceOnMainThread];
    });
    return granted;
}

- (NSString *)stripAnsi:(NSString *)s {
    if (!s.length) return @"";
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"\\x1B\\[[0-9;]*m" options:0 error:nil];
    if (!re) return s;
    return [re stringByReplacingMatchesInString:s options:0 range:NSMakeRange(0, s.length) withTemplate:@""];
}
- (BOOL)parseAuthOK:(NSString *)output {
    for (NSString *line in [output componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        NSString *t = [[self stripAnsi:line] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if ([t isEqualToString:@"AUTH=OK"] || [t isEqualToString:@"STATE=AUTH_OK"]) return YES;
    }
    return NO;
}
- (BOOL)parseStateOn:(NSString *)output {
    for (NSString *line in [output componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        NSString *t = [[self stripAnsi:line] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if ([t isEqualToString:@"STATE=ON"]) return YES;
        if ([t isEqualToString:@"STATE=OFF"] || [t isEqualToString:@"STATE=NEED_AUTH"]) return NO;
    }
    return [output containsString:@"Tunnel: RUNNING"];
}
- (NSString *)parseTarget:(NSString *)output {
    for (NSString *line in [output componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        NSString *t = [self stripAnsi:line];
        if ([t hasPrefix:@"Target: "]) return [t substringFromIndex:8];
    }
    VPNProfile *p = [self activeProfile];
    return p ? [NSString stringWithFormat:@"%@ — %@", p.displayTitle, p.subtitle] : @"—";
}

- (void)updateAuthLabel {
    if (self.hasAuth) {
        self.modeLabel.stringValue = @"Permission: granted (one-time)";
        self.modeLabel.textColor = [NSColor systemGreenColor];
    } else {
        self.modeLabel.stringValue = @"Permission: needed once (before connect)";
        self.modeLabel.textColor = [NSColor systemOrangeColor];
    }
}

- (BOOL)grantAdminOnceOnMainThread {
    [NSApp activateIgnoringOtherApps:YES];
    [self.window makeKeyAndOrderFront:nil];
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"One-time setup";
    alert.informativeText = @"ASO VPN will install tools if needed and save admin access once.\n\nNext: enter your Mac password.";
    [alert addButtonWithTitle:@"Allow & Install"];
    [alert addButtonWithTitle:@"Cancel"];
    if ([alert runModal] != NSAlertFirstButtonReturn) return NO;

    NSString *scriptPath = [self scriptURL].path;
    NSString *escaped = [[scriptPath stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"] stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
    NSString *source = [NSString stringWithFormat:@"do shell script \"/bin/bash \\\"%@\\\" install-priv\" with administrator privileges", escaped];
    NSDictionary *errorInfo = nil;
    NSAppleScript *appleScript = [[NSAppleScript alloc] initWithSource:source];
    NSAppleEventDescriptor *result = [appleScript executeAndReturnError:&errorInfo];
    if (!result || errorInfo) return NO;
    NSDictionary *st = [self runScriptEx:@[@"auth-status"]];
    self.hasAuth = [self parseAuthOK:st[@"output"] ?: @""];
    [self updateAuthLabel];
    return self.hasAuth;
}

- (BOOL)ensureAuthBeforeConnect {
    NSDictionary *st = [self runScriptEx:@[@"auth-status"]];
    self.hasAuth = [self parseAuthOK:st[@"output"] ?: @""];
    [self updateAuthLabel];
    if (self.hasAuth) return YES;
    return [self grantAdminOnceOnMainThread];
}

- (void)cancelTapped {
    if (!self.isBusy) return;
    self.cancelRequested = YES;
    [self.session userClearedIntent];
    self.autoReconnectPending = NO;
    self.busyLabel.stringValue = @"Cancelling…";
    NSTask *task = self.activeTask;
    if (task.running) [task terminate];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [self runScriptEx:@[@"off"]];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self clearBusyUI];
            self.busyLabel.stringValue = @"Cancelled";
            self.busyLabel.textColor = NSColor.systemOrangeColor;
            [self refreshStatus];
            [self refreshPublicIP];
        });
    });
}

- (void)resetPermissionTapped {
    if (self.isBusy) return;
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"Reset Permission?";
    alert.informativeText = @"Clears one-time admin access. Connection settings are kept.";
    [alert addButtonWithTitle:@"Reset"];
    [alert addButtonWithTitle:@"Cancel"];
    if ([alert runModal] != NSAlertFirstButtonReturn) return;
    [self.session userClearedIntent];
    self.autoReconnectPending = NO;
    if (self.isOn) [self runScriptEx:@[@"off"]];
    NSString *scriptPath = [self scriptURL].path;
    NSString *escaped = [[scriptPath stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"] stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
    NSString *source = [NSString stringWithFormat:@"do shell script \"/bin/bash \\\"%@\\\" reset-priv\" with administrator privileges", escaped];
    NSDictionary *errorInfo = nil;
    [[[NSAppleScript alloc] initWithSource:source] executeAndReturnError:&errorInfo];
    self.hasAuth = NO;
    [self updateAuthLabel];
    self.busyLabel.stringValue = errorInfo ? @"Reset cancelled or failed" : @"Permission reset — click Connect to Allow again";
    self.busyLabel.textColor = errorInfo ? NSColor.systemOrangeColor : NSColor.systemGreenColor;
    [self refreshAuthAndStatus];
}

- (void)toggleTapped {
    if (self.isBusy) return;
    if (self.isOn) {
        [self.session userClearedIntent];
        self.autoReconnectPending = NO;
        [self runVPN:@"off" busyMessage:nil];
        return;
    }
    if (![self activeProfile]) {
        self.busyLabel.stringValue = @"Add a config first";
        self.busyLabel.textColor = NSColor.systemOrangeColor;
        return;
    }
    [self syncActiveToVpnConf];
    if (![self ensureAuthBeforeConnect]) {
        self.busyLabel.stringValue = @"Permission cancelled";
        self.busyLabel.textColor = NSColor.systemOrangeColor;
        return;
    }
    [self.session userTappedConnect];
    self.autoReconnectPending = NO;
    [self runVPN:@"on" busyMessage:nil];
}

- (void)scheduleAutoReconnect {
    if (self.autoReconnectPending) return;
    if (![self.session shouldAutoReconnectWhileTunnelUp:NO isBusy:self.isBusy]) {
        if (self.session.userWantsConnect && self.session.didConnectSuccessfully &&
            self.session.reconnectAttempts >= self.session.maxReconnectAttempts) {
            [self.session userClearedIntent];
            self.busyLabel.stringValue = @"Couldn't stay connected — click Connect";
            self.busyLabel.textColor = NSColor.systemOrangeColor;
        }
        return;
    }
    [self.session noteReconnectScheduled];
    self.autoReconnectPending = YES;
    NSInteger attempt = self.session.reconnectAttempts;
    NSInteger maxA = self.session.maxReconnectAttempts;
    NSTimeInterval delay = MIN(0.35 * pow(1.55, (double)(attempt - 1)), 6.0);
    self.busyLabel.stringValue = [NSString stringWithFormat:@"Connection dropped — reconnecting… (%ld/%ld)", (long)attempt, (long)maxA];
    self.busyLabel.textColor = NSColor.systemOrangeColor;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        self.autoReconnectPending = NO;
        // Attempt was already counted; run it unless user cancelled / busy.
        if (!self.session.userWantsConnect || !self.session.didConnectSuccessfully || self.isBusy) return;
        [self syncActiveToVpnConf];
        if (![self ensureAuthBeforeConnect]) {
            [self.session userClearedIntent];
            self.busyLabel.stringValue = @"Reconnect needs permission — click Connect";
            self.busyLabel.textColor = NSColor.systemOrangeColor;
            return;
        }
        [self runVPN:@"on" busyMessage:[NSString stringWithFormat:@"Reconnecting… (%ld/%ld)", (long)attempt, (long)maxA]];
    });
}

- (void)clearBusyUI {
    [self.opTimeout invalidate]; self.opTimeout = nil;
    self.isBusy = NO;
    self.cancelRequested = NO;
    self.activeTask = nil;
    self.actionButton.enabled = YES;
    self.saveButton.enabled = YES;
    self.resetPermButton.enabled = YES;
    self.cancelButton.hidden = YES;
    self.resetPermButton.hidden = NO;
    [self updateProfileButtons];
}

- (void)setBusy:(BOOL)busy message:(NSString *)message {
    self.isBusy = busy;
    self.actionButton.enabled = !busy;
    self.saveButton.enabled = !busy;
    self.resetPermButton.enabled = !busy;
    self.profilesTable.enabled = !busy;
    self.cancelButton.hidden = !busy;
    self.resetPermButton.hidden = busy;
    [self updateProfileButtons];
    self.busyLabel.stringValue = message ?: @"";
    if (busy) {
        self.actionButton.title = @"Please wait…";
        [self styleActionButton:self.actionButton color:[NSColor colorWithCalibratedWhite:0.35 alpha:1]];
        [self.opTimeout invalidate];
        self.opTimeout = [NSTimer scheduledTimerWithTimeInterval:45.0 repeats:NO block:^(NSTimer *timer) {
            if (!self.isBusy) return;
            self.busyLabel.stringValue = @"Timed out — cancelling…";
            [self cancelTapped];
        }];
    }
}

- (void)applyUIOn:(BOOL)on detail:(NSString *)detail {
    self.isOn = on;
    if (on) {
        self.statusDot.layer.backgroundColor = NSColor.systemGreenColor.CGColor;
        self.statusLabel.stringValue = @"Connected"; self.statusLabel.textColor = NSColor.systemGreenColor;
        if (!self.isBusy) { self.actionButton.title = @"Disconnect"; [self styleActionButton:self.actionButton color:NSColor.systemRedColor]; }
    } else {
        self.statusDot.layer.backgroundColor = NSColor.systemRedColor.CGColor;
        self.statusLabel.stringValue = @"Disconnected"; self.statusLabel.textColor = [self secondaryTextColor:0.85];
        if (!self.isBusy) { self.actionButton.title = @"Connect"; [self styleActionButton:self.actionButton color:NSColor.systemGreenColor]; }
    }
    [self layoutCenteredStatus];
    [self updateProfileButtons];
    (void)detail;
}

- (void)refreshAuthAndStatus {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0), ^{
        [self syncActiveToVpnConf];
        NSDictionary *auth = [self runScriptEx:@[@"auth-status"]];
        NSDictionary *st = [self runScriptEx:@[@"status"]];
        NSString *out = st[@"output"] ?: @"";
        BOOL ok = [self parseAuthOK:auth[@"output"] ?: @""] || [self parseAuthOK:out];
        BOOL on = [self parseStateOn:out];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.hasAuth = ok;
            [self updateAuthLabel];
            // Do NOT arm auto-reconnect from leftover tunnels — only UI state.
            [self applyUIOn:on detail:[self parseTarget:out]];
            [self reloadProfilesUI];
        });
    });
}

- (void)refreshStatus {
    if (self.isBusy) return;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0), ^{
        NSDictionary *r = [self runScriptEx:@[@"status"]];
        NSString *out = r[@"output"] ?: @"";
        BOOL on = [self parseStateOn:out];
        NSString *detail = [self parseTarget:out];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.isBusy) return;
            if ([out containsString:@"AUTH="] || [out containsString:@"STATE=AUTH"]) {
                self.hasAuth = [self parseAuthOK:out];
                [self updateAuthLabel];
            }
            BOOL shouldRetry = [self.session shouldAutoReconnectWhileTunnelUp:on isBusy:NO];
            if (on && self.session.didConnectSuccessfully) {
                // Stable again after a drop — reset attempt counter only if we already owned the session.
                [self.session connectSucceeded];
            }
            [self applyUIOn:on detail:detail];
            if (shouldRetry) [self scheduleAutoReconnect];
        });
    });
}

- (void)runVPN:(NSString *)command busyMessage:(NSString *)busyMessage {
    BOOL connecting = [command isEqualToString:@"on"];
    self.cancelRequested = NO;
    NSString *msg = busyMessage.length ? busyMessage : (connecting ? @"Connecting…" : @"Disconnecting…");
    [self syncActiveToVpnConf];
    [self setBusy:YES message:msg];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^{
        NSDictionary *result = [self runScriptEx:@[command]];
        if (self.cancelRequested) return;
        NSString *output = result[@"output"] ?: @""; NSInteger code = [result[@"code"] integerValue];
        BOOL needAuth = [output containsString:@"STATE=NEED_AUTH"] || code == 78;
        NSDictionary *st = [self runScriptEx:@[@"status"]];
        NSString *stOut = st[@"output"] ?: @"";
        BOOL on = [self parseStateOn:stOut];
        NSString *detail = [self parseTarget:stOut];
        BOOL failed = (connecting && !on) || (!connecting && on && code != 0);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.cancelRequested) return;
            [self clearBusyUI];
            [self applyUIOn:on detail:detail];
            [self refreshPublicIP];
            [self reloadProfilesUI];
            if (needAuth) {
                self.hasAuth = NO; [self updateAuthLabel];
                if (connecting) [self.session connectAttemptFailed];
                self.busyLabel.stringValue = @"Need one-time setup — click Connect again";
                self.busyLabel.textColor = NSColor.systemOrangeColor;
            } else if (failed) {
                if (connecting) {
                    BOOL mayRetry = self.session.didConnectSuccessfully && self.session.userWantsConnect;
                    [self.session connectAttemptFailed];
                    if (mayRetry && [self.session shouldAutoReconnectWhileTunnelUp:NO isBusy:NO]) {
                        self.busyLabel.stringValue = @"Reconnect failed — retrying…";
                        self.busyLabel.textColor = NSColor.systemOrangeColor;
                        [self scheduleAutoReconnect];
                    } else {
                        self.busyLabel.stringValue = @"Connection failed — check config";
                        self.busyLabel.textColor = NSColor.systemRedColor;
                    }
                } else {
                    self.busyLabel.stringValue = @"Disconnect incomplete";
                    self.busyLabel.textColor = NSColor.systemRedColor;
                }
            } else {
                if (connecting && on) [self.session connectSucceeded];
                if (!connecting && !on) [self.session userClearedIntent];
                self.busyLabel.stringValue = @"";
                self.busyLabel.textColor = [self secondaryTextColor:0.45];
            }
        });
    });
}

- (NSDictionary *)runScriptEx:(NSArray<NSString *> *)args {
    NSString *path = [self scriptURL].path;
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) return @{@"output": @"error: vpn.sh not found", @"code": @127};

    NSString *outFile = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"aso-vpn-out-%d.txt", getpid()]];
    NSString *errFile = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"aso-vpn-err-%d.txt", getpid()]];
    [[NSFileManager defaultManager] createFileAtPath:outFile contents:nil attributes:nil];
    [[NSFileManager defaultManager] createFileAtPath:errFile contents:nil attributes:nil];
    NSFileHandle *outHandle = [NSFileHandle fileHandleForWritingAtPath:outFile];
    NSFileHandle *errHandle = [NSFileHandle fileHandleForWritingAtPath:errFile];

    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:@"/bin/bash"];
    task.arguments = [@[path] arrayByAddingObjectsFromArray:args];
    task.currentDirectoryURL = [[self scriptURL] URLByDeletingLastPathComponent];
    NSMutableDictionary *env = [[[NSProcessInfo processInfo] environment] mutableCopy];
    env[@"ASO_VPN_CONFIG"] = [self configURL].path;
    env[@"TMPDIR"] = @"/tmp";
    env[@"PATH"] = [NSString stringWithFormat:@"/opt/homebrew/bin:/usr/local/bin:%@", env[@"PATH"] ?: @"/usr/bin:/bin"];
    task.environment = env;
    task.standardOutput = outHandle;
    task.standardError = errHandle;

    dispatch_async(dispatch_get_main_queue(), ^{ self.activeTask = task; });

    NSError *err = nil;
    if (![task launchAndReturnError:&err]) {
        [outHandle closeFile]; [errHandle closeFile];
        return @{@"output": err.localizedDescription ?: @"launch failed", @"code": @1};
    }
    [task waitUntilExit];
    [outHandle closeFile]; [errHandle closeFile];
    dispatch_async(dispatch_get_main_queue(), ^{ if (self.activeTask == task) self.activeTask = nil; });

    NSString *stdoutStr = [NSString stringWithContentsOfFile:outFile encoding:NSUTF8StringEncoding error:nil] ?: @"";
    NSString *stderrStr = [NSString stringWithContentsOfFile:errFile encoding:NSUTF8StringEncoding error:nil] ?: @"";
    [[NSFileManager defaultManager] removeItemAtPath:outFile error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:errFile error:nil];
    NSString *combined = [stdoutStr stringByAppendingString:stderrStr];
    if (combined.length > 8000) combined = [combined substringFromIndex:combined.length - 8000];
    return @{@"output": combined, @"code": @(task.terminationStatus)};
}

- (BOOL)windowShouldClose:(NSWindow *)sender { if (sender == self.configWindow) { [sender orderOut:nil]; return NO; } return YES; }
@end

int main(int argc, const char *argv[]) {
    @autoreleasepool { NSApplication *app = [NSApplication sharedApplication]; AppDelegate *d = [AppDelegate new]; app.delegate = d; [app run]; }
    return 0;
}
