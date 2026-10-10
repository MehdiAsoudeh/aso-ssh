#import <Cocoa/Cocoa.h>
#import <unistd.h>

@interface FlippedView : NSView
@end
@implementation FlippedView
- (BOOL)isFlipped { return YES; }
@end

@interface VPNConfig : NSObject
@property (copy) NSString *host, *user, *password, *port, *key, *extraOpts;
+ (instancetype)loadFromURL:(NSURL *)url;
- (BOOL)saveToURL:(NSURL *)url error:(NSError **)error;
@end

@implementation VPNConfig
+ (instancetype)loadFromURL:(NSURL *)url {
    VPNConfig *cfg = [VPNConfig new];
    cfg.host = cfg.user = cfg.password = cfg.port = cfg.key = cfg.extraOpts = @"";
    NSString *text = [NSString stringWithContentsOfURL:url encoding:NSUTF8StringEncoding error:nil];
    if (!text) return cfg;
    for (NSString *raw in [text componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        NSString *line = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (!line.length || [line hasPrefix:@"#"]) continue;
        NSRange eq = [line rangeOfString:@"="];
        if (eq.location == NSNotFound) continue;
        NSString *key = [[line substringToIndex:eq.location] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        NSString *value = [[line substringFromIndex:eq.location + 1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (([value hasPrefix:@"\""] && [value hasSuffix:@"\""]) || ([value hasPrefix:@"'"] && [value hasSuffix:@"'"]))
            value = [value substringWithRange:NSMakeRange(1, value.length - 2)];
        if ([key isEqualToString:@"SSH_HOST"]) cfg.host = value;
        else if ([key isEqualToString:@"SSH_USER"]) cfg.user = value;
        else if ([key isEqualToString:@"SSH_PASS"]) cfg.password = value;
        else if ([key isEqualToString:@"SSH_PORT"]) cfg.port = value;
        else if ([key isEqualToString:@"SSH_KEY"]) cfg.key = value;
        else if ([key isEqualToString:@"SSH_EXTRA_OPTS"]) cfg.extraOpts = value;
    }
    return cfg;
}
- (BOOL)saveToURL:(NSURL *)url error:(NSError **)error {
    NSString *(^q)(NSString *) = ^(NSString *s) {
        return [NSString stringWithFormat:@"'%@'", [s stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"] ?: @""];
    };
    NSString *body = [NSString stringWithFormat:@"SSH_HOST=%@\nSSH_USER=%@\nSSH_PASS=%@\nSSH_PORT=%@\nSSH_KEY=%@\nSSH_EXTRA_OPTS=%@\n",
                      q(self.host), q(self.user), q(self.password), q(self.port), q(self.key), q(self.extraOpts ?: @"")];
    return [body writeToURL:url atomically:YES encoding:NSUTF8StringEncoding error:error];
}
@end

@interface AppDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate>
@property (strong) NSWindow *window, *configWindow;
@property (strong) NSView *statusDot;
@property (strong) NSTextField *statusLabel, *detailLabel, *ipLabel, *busyLabel, *footerLabel, *configStatusLabel, *modeLabel;
@property (strong) NSTextField *hostField, *userField, *portField, *keyField;
@property (strong) NSSecureTextField *passField;
@property (strong) NSButton *actionButton, *configButton, *saveButton, *resetPermButton, *cancelButton;
@property (strong) NSTimer *pollTimer, *opTimeout;
@property (strong) NSTask *activeTask;
@property (strong) NSScrollView *configScrollView;
@property (assign) BOOL isBusy, isOn, hasAuth, cancelRequested;
@end

@implementation AppDelegate

static const CGFloat kMainW = 360, kMainH = 350, kCfgW = 440, kCfgH = 520, kCfgBottomH = 100, kFieldRowH = 62, kFieldH = 32;

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
- (void)ensureSupportFiles {
    [[NSFileManager defaultManager] createDirectoryAtURL:[self supportDir] withIntermediateDirectories:YES attributes:nil error:nil];
}
- (void)invalidateTunnelSession {
    NSString *session = [NSHomeDirectory() stringByAppendingPathComponent:@".aso-vpn/session.env"];
    [[NSFileManager defaultManager] removeItemAtPath:session error:nil];
}

- (NSTextField *)makeLabel:(NSString *)text size:(CGFloat)size weight:(NSFontWeight)weight color:(NSColor *)color {
    NSTextField *l = [NSTextField labelWithString:text];
    l.font = [NSFont systemFontOfSize:size weight:weight]; l.textColor = color; l.bezeled = NO; l.editable = NO;
    return l;
}
- (NSColor *)bgColor { return [NSColor colorWithCalibratedRed:0.11 green:0.12 blue:0.15 alpha:1]; }
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
    [self ensureSupportFiles]; [self buildMainWindow]; [self buildConfigWindow];
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

    NSTextField *t = [self makeLabel:@"ASO VPN" size:22 weight:NSFontWeightBold color:NSColor.whiteColor];
    t.frame = NSMakeRect(24,kMainH-52,200,28); [c addSubview:t];
    NSTextField *sub = [self makeLabel:@"System-wide SSH tunnel" size:12 weight:NSFontWeightRegular color:[NSColor.whiteColor colorWithAlphaComponent:0.55]];
    sub.frame = NSMakeRect(24,kMainH-74,220,18); [c addSubview:sub];

    self.configButton = [[NSButton alloc] initWithFrame:NSMakeRect(kMainW-108,kMainH-54,84,28)];
    self.configButton.title = @"Config"; self.configButton.bezelStyle = NSBezelStyleRounded;
    self.configButton.target = self; self.configButton.action = @selector(openConfig);
    [c addSubview:self.configButton];

    self.statusDot = [[NSView alloc] initWithFrame:NSMakeRect(24,kMainH-118,14,14)];
    self.statusDot.wantsLayer = YES; self.statusDot.layer.cornerRadius = 7;
    self.statusDot.layer.backgroundColor = NSColor.systemOrangeColor.CGColor; [c addSubview:self.statusDot];

    self.statusLabel = [self makeLabel:@"Checking…" size:18 weight:NSFontWeightSemibold color:NSColor.whiteColor];
    self.statusLabel.frame = NSMakeRect(48,kMainH-124,kMainW-72,24); [c addSubview:self.statusLabel];

    self.detailLabel = [self makeLabel:@"—" size:12 weight:NSFontWeightRegular color:[NSColor.whiteColor colorWithAlphaComponent:0.5]];
    self.detailLabel.frame = NSMakeRect(24,kMainH-148,kMainW-48,18); [c addSubview:self.detailLabel];

    self.ipLabel = [self makeLabel:@"Your IP: ..." size:13 weight:NSFontWeightMedium color:[NSColor.whiteColor colorWithAlphaComponent:0.85]];
    self.ipLabel.frame = NSMakeRect(24,kMainH-172,kMainW-48,18); [c addSubview:self.ipLabel];

    self.modeLabel = [self makeLabel:@"Permission: checking…" size:11 weight:NSFontWeightRegular color:[NSColor.whiteColor colorWithAlphaComponent:0.45]];
    self.modeLabel.frame = NSMakeRect(24,kMainH-192,kMainW-48,16); [c addSubview:self.modeLabel];

    self.actionButton = [[NSButton alloc] initWithFrame:NSMakeRect(24,100,kMainW-48,48)];
    self.actionButton.title = @"Connect"; self.actionButton.target = self; self.actionButton.action = @selector(toggleTapped);
    [self styleActionButton:self.actionButton color:NSColor.systemGreenColor]; [c addSubview:self.actionButton];

    self.cancelButton = [[NSButton alloc] initWithFrame:NSMakeRect(24,68,kMainW-48,26)];
    self.cancelButton.title = @"Cancel";
    self.cancelButton.bezelStyle = NSBezelStyleRounded;
    self.cancelButton.font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
    self.cancelButton.target = self;
    self.cancelButton.action = @selector(cancelTapped);
    self.cancelButton.hidden = YES;
    [c addSubview:self.cancelButton];

    self.resetPermButton = [[NSButton alloc] initWithFrame:NSMakeRect(24,58,kMainW-48,26)];
    self.resetPermButton.title = @"Reset Permission";
    self.resetPermButton.bezelStyle = NSBezelStyleRounded;
    self.resetPermButton.font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
    self.resetPermButton.target = self;
    self.resetPermButton.action = @selector(resetPermissionTapped);
    [c addSubview:self.resetPermButton];

    self.footerLabel = [self makeLabel:@"asoodeh.dev@gmail.com" size:9 weight:NSFontWeightRegular color:[NSColor.whiteColor colorWithAlphaComponent:0.32]];
    self.footerLabel.alignment = NSTextAlignmentCenter;
    self.footerLabel.frame = NSMakeRect(24,34,kMainW-48,12); [c addSubview:self.footerLabel];

    self.busyLabel = [self makeLabel:@"" size:10 weight:NSFontWeightRegular color:[NSColor.whiteColor colorWithAlphaComponent:0.45]];
    self.busyLabel.alignment = NSTextAlignmentCenter;
    self.busyLabel.frame = NSMakeRect(24,12,kMainW-48,18); [c addSubview:self.busyLabel];
}

- (NSTextField *)addLabeledField:(NSString *)label inView:(FlippedView *)parent y:(CGFloat)y width:(CGFloat)w x:(CGFloat)x secure:(BOOL)secure {
    NSTextField *cap = [self makeLabel:label size:12 weight:NSFontWeightMedium color:[NSColor.whiteColor colorWithAlphaComponent:0.75]];
    cap.frame = NSMakeRect(x,y,w,16); [parent addSubview:cap];
    NSTextField *field = secure ? [[NSSecureTextField alloc] initWithFrame:NSMakeRect(x,y+20,w,kFieldH)] : [[NSTextField alloc] initWithFrame:NSMakeRect(x,y+20,w,kFieldH)];
    [self styleInputField:field]; [parent addSubview:field]; return field;
}

- (void)buildConfigWindow {
    self.configWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,kCfgW,kCfgH) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO];
    self.configWindow.title = @"Connection Settings"; self.configWindow.releasedWhenClosed = NO;
    self.configWindow.titlebarAppearsTransparent = YES; self.configWindow.backgroundColor = [self bgColor]; self.configWindow.delegate = self;
    NSView *c = [[NSView alloc] initWithFrame:NSMakeRect(0,0,kCfgW,kCfgH)]; self.configWindow.contentView = c;
    NSTextField *h = [self makeLabel:@"Connection settings" size:18 weight:NSFontWeightBold color:NSColor.whiteColor];
    h.frame = NSMakeRect(24,kCfgH-44,kCfgW-48,26); [c addSubview:h];
    self.configScrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(16,kCfgBottomH,kCfgW-32,kCfgH-80-kCfgBottomH)];
    self.configScrollView.hasVerticalScroller = YES; self.configScrollView.autohidesScrollers = YES; self.configScrollView.borderType = NSBezelBorder;
    self.configScrollView.backgroundColor = [NSColor colorWithCalibratedWhite:0.16 alpha:1];
    CGFloat pad = 16, full = kCfgW-32-pad*2; FlippedView *form = [[FlippedView alloc] initWithFrame:NSMakeRect(0,0,kCfgW-32,360)];
    CGFloat y = pad;
    self.hostField = [self addLabeledField:@"Host" inView:form y:y width:full x:pad secure:NO]; y += kFieldRowH;
    self.userField = [self addLabeledField:@"User" inView:form y:y width:full x:pad secure:NO]; y += kFieldRowH;
    self.passField = (NSSecureTextField *)[self addLabeledField:@"Password" inView:form y:y width:full x:pad secure:YES]; y += kFieldRowH;
    self.portField = [self addLabeledField:@"SSH Port" inView:form y:y width:full x:pad secure:NO]; y += kFieldRowH;
    self.keyField = [self addLabeledField:@"SSH Key path (optional)" inView:form y:y width:full x:pad secure:NO]; y += kFieldRowH+12;
    form.frame = NSMakeRect(0,0,kCfgW-32,y); self.configScrollView.documentView = form; [c addSubview:self.configScrollView];
    self.configStatusLabel = [self makeLabel:@"" size:11 weight:NSFontWeightRegular color:NSColor.systemGreenColor];
    self.configStatusLabel.alignment = NSTextAlignmentCenter; self.configStatusLabel.frame = NSMakeRect(24,56,kCfgW-48,16); [c addSubview:self.configStatusLabel];
    self.saveButton = [[NSButton alloc] initWithFrame:NSMakeRect(24,16,kCfgW-48,44)]; self.saveButton.title = @"Save Config";
    self.saveButton.target = self; self.saveButton.action = @selector(saveConfig);
    [self styleActionButton:self.saveButton color:[NSColor colorWithCalibratedRed:0.20 green:0.45 blue:0.95 alpha:1]]; [c addSubview:self.saveButton];
}

- (void)loadConfigIntoFields {
    VPNConfig *cfg = [VPNConfig loadFromURL:[self configURL]];
    self.hostField.stringValue = cfg.host ?: @""; self.userField.stringValue = cfg.user ?: @"";
    self.passField.stringValue = cfg.password ?: @"";
    self.portField.stringValue = cfg.port ?: @"";
    self.keyField.stringValue = cfg.key ?: @"";
    self.configStatusLabel.stringValue = @"";
}
- (void)openConfig {
    [self loadConfigIntoFields];
    if (!self.configWindow.isVisible) {
        NSRect mf = self.window.frame, cf = self.configWindow.frame;
        cf.origin.x = NSMidX(mf)-cf.size.width/2; cf.origin.y = NSMidY(mf)-cf.size.height/2;
        [self.configWindow setFrame:cf display:NO];
    }
    [self.configWindow makeKeyAndOrderFront:nil]; [NSApp activateIgnoringOtherApps:YES];
}

- (void)saveConfig {
    [self ensureSupportFiles];
    VPNConfig *existing = [VPNConfig loadFromURL:[self configURL]];
    VPNConfig *cfg = [VPNConfig new];
    cfg.host = [self.hostField.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    cfg.user = [self.userField.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    cfg.password = self.passField.stringValue ?: @"";
    if (cfg.password.length == 0 && existing.password.length > 0) {
        cfg.password = existing.password;
    }
    cfg.port = [self.portField.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    cfg.key = [self.keyField.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    cfg.extraOpts = @"";
    if (!cfg.host.length || !cfg.user.length) {
        self.configStatusLabel.textColor = NSColor.systemRedColor;
        self.configStatusLabel.stringValue = @"Host and User are required";
        return;
    }
    if (cfg.port.length > 0 && cfg.port.integerValue <= 0) {
        self.configStatusLabel.textColor = NSColor.systemRedColor;
        self.configStatusLabel.stringValue = @"Port must be a number";
        return;
    }
    [[NSFileManager defaultManager] createDirectoryAtURL:[self supportDir] withIntermediateDirectories:YES attributes:nil error:nil];
    NSError *err = nil;
    if (![cfg saveToURL:[self configURL] error:&err]) {
        self.configStatusLabel.textColor = NSColor.systemRedColor;
        self.configStatusLabel.stringValue = @"Save failed";
        return;
    }

    [self invalidateTunnelSession];
    self.passField.stringValue = cfg.password ?: @"";
    self.detailLabel.stringValue = [NSString stringWithFormat:@"%@@%@:%@", cfg.user, cfg.host, cfg.port];
    self.configStatusLabel.textColor = NSColor.systemGreenColor;
    self.configStatusLabel.stringValue = @"Config saved — using new settings";

    BOOL reconnect = self.isOn;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self.configWindow orderOut:nil];
        [self.window makeKeyAndOrderFront:nil];
        if (reconnect) {
            [self applyNewConfigReconnect];
        } else {
            [self refreshStatus];
        }
    });
}

- (void)applyNewConfigReconnect {
    if (self.isBusy) return;
    self.cancelRequested = NO;
    [self setBusy:YES message:@"Applying new config…"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [self invalidateTunnelSession];
        [self runScriptEx:@[@"off"]];
        if (self.cancelRequested) return;
        if (![self ensureAuthBeforeConnectBlocking]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (self.cancelRequested) return;
                [self clearBusyUI];
                self.busyLabel.stringValue = @"Config saved — permission needed to connect";
                self.busyLabel.textColor = NSColor.systemOrangeColor;
                [self refreshStatus];
            });
            return;
        }
        NSDictionary *result = [self runScriptEx:@[@"on"]];
        if (self.cancelRequested) return;
        NSString *output = result[@"output"] ?: @"";
        NSInteger code = [result[@"code"] integerValue];
        BOOL needAuth = [output containsString:@"STATE=NEED_AUTH"] || code == 78;
        NSDictionary *st = [self runScriptEx:@[@"status"]];
        NSString *stOut = st[@"output"] ?: @"";
        BOOL on = [self parseStateOn:stOut];
        NSString *detail = [self parseTarget:stOut];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.cancelRequested) return;
            [self clearBusyUI];
            [self applyUIOn:on detail:detail];
            [self refreshPublicIP];
            if (needAuth) {
                self.hasAuth = NO; [self updateAuthLabel];
                self.busyLabel.stringValue = @"Config saved — click Connect to Allow";
                self.busyLabel.textColor = NSColor.systemOrangeColor;
            } else if (!on) {
                self.busyLabel.stringValue = @"Config saved — connection failed";
                self.busyLabel.textColor = NSColor.systemRedColor;
            } else {
                self.busyLabel.stringValue = @"Connected with new config";
                self.busyLabel.textColor = NSColor.systemGreenColor;
            }
        });
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
    return @"—";
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
    if (self.isOn) { [self runVPN:@"off"]; return; }
    if (![self ensureAuthBeforeConnect]) {
        self.busyLabel.stringValue = @"Permission cancelled";
        self.busyLabel.textColor = NSColor.systemOrangeColor;
        return;
    }
    [self runVPN:@"on"];
}

- (void)clearBusyUI {
    [self.opTimeout invalidate]; self.opTimeout = nil;
    self.isBusy = NO;
    self.cancelRequested = NO;
    self.activeTask = nil;
    self.actionButton.enabled = YES;
    self.configButton.enabled = YES;
    self.saveButton.enabled = YES;
    self.resetPermButton.enabled = YES;
    self.cancelButton.hidden = YES;
    self.resetPermButton.hidden = NO;
}

- (void)setBusy:(BOOL)busy message:(NSString *)message {
    self.isBusy = busy;
    self.actionButton.enabled = !busy;
    self.configButton.enabled = !busy;
    self.saveButton.enabled = !busy;
    self.resetPermButton.enabled = !busy;
    self.cancelButton.hidden = !busy;
    self.resetPermButton.hidden = busy;
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
        self.statusLabel.stringValue = @"Disconnected"; self.statusLabel.textColor = [NSColor.whiteColor colorWithAlphaComponent:0.85];
        if (!self.isBusy) { self.actionButton.title = @"Connect"; [self styleActionButton:self.actionButton color:NSColor.systemGreenColor]; }
    }
    self.detailLabel.stringValue = detail ?: @"—";
}

- (void)refreshAuthAndStatus {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0), ^{
        NSDictionary *auth = [self runScriptEx:@[@"auth-status"]];
        NSDictionary *st = [self runScriptEx:@[@"status"]];
        NSString *out = st[@"output"] ?: @"";
        BOOL ok = [self parseAuthOK:auth[@"output"] ?: @""] || [self parseAuthOK:out];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.hasAuth = ok;
            [self updateAuthLabel];
            [self applyUIOn:[self parseStateOn:out] detail:[self parseTarget:out]];
        });
    });
}

- (void)refreshStatus {
    if (self.isBusy) return;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0), ^{
        NSDictionary *r = [self runScriptEx:@[@"status"]];
        NSString *out = r[@"output"] ?: @"";
        dispatch_async(dispatch_get_main_queue(), ^{
            if ([out containsString:@"AUTH="] || [out containsString:@"STATE=AUTH"]) {
                self.hasAuth = [self parseAuthOK:out];
                [self updateAuthLabel];
            }
            [self applyUIOn:[self parseStateOn:out] detail:[self parseTarget:out]];
        });
    });
}

- (void)runVPN:(NSString *)command {
    BOOL connecting = [command isEqualToString:@"on"];
    self.cancelRequested = NO;
    [self setBusy:YES message:connecting ? @"Connecting…" : @"Disconnecting…"];
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
            if (needAuth) {
                self.hasAuth = NO; [self updateAuthLabel];
                self.busyLabel.stringValue = @"Need one-time setup — click Connect again";
                self.busyLabel.textColor = NSColor.systemOrangeColor;
            } else if (failed) {
                self.busyLabel.stringValue = connecting ? @"Connection failed — check config" : @"Disconnect incomplete";
                self.busyLabel.textColor = NSColor.systemRedColor;
            } else {
                self.busyLabel.stringValue = @"";
                self.busyLabel.textColor = [NSColor.whiteColor colorWithAlphaComponent:0.45];
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
