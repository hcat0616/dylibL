// SubDump - 订阅链接导出工具
// 目标 App: Apps Connect (uk.skynet.ios)
//
// 设计原则：
//   1. 零依赖：不用 CydiaSubstrate / Logos / ElleKit，只用 objc runtime 的
//      method_setImplementation，TrollStore 注入后可直接加载。
//   2. 不改业务逻辑：只观测（读文件、读 UserDefaults、抓网络），不修改任何
//      返回值，不干预鉴权与订阅状态。
//   3. 三路取证：
//        A. 沙盒内所有文件里的 http(s) URL
//        B. NSUserDefaults 全量键值
//        C. NSURLSession 的请求 URL + 响应体（订阅 YAML / 面板 JSON 都能拿到）
//   4. 结果只放内存：可滚动面板 + 剪贴板，不写任何文件

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <stdarg.h>

#define SD_VERSION   @"0.3.0"
#define SD_BTN_TAG   0x5B0D1E

#pragma mark - 日志

static void SDLog(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[SubDump] %@", msg);
}

#pragma mark - 全局状态

static NSMutableArray<NSString *> *gRequests;
static NSMutableArray<NSString *> *gCaptures;
static NSLock *gLock;

#pragma mark - URL 提取

static inline BOOL SDIsURLByte(unsigned char c) {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
           (c >= '0' && c <= '9') ||
           c == ':' || c == '/' || c == '.' || c == '-' || c == '_' ||
           c == '~' || c == '?' || c == '#' || c == '[' || c == ']' ||
           c == '@' || c == '!' || c == '$' || c == '&' || c == '\'' ||
           c == '(' || c == ')' || c == '*' || c == '+' || c == ',' ||
           c == ';' || c == '=' || c == '%';
}

static void SDScanBytes(const uint8_t *b, NSUInteger len,
                        NSMutableOrderedSet<NSString *> *out) {
    if (!b || len < 12) return;
    NSUInteger i = 0;
    while (i + 8 < len) {
        if (b[i] == 'h' && b[i + 1] == 't' && b[i + 2] == 't' && b[i + 3] == 'p' &&
            ((b[i + 4] == 's' && b[i + 5] == ':' && b[i + 6] == '/' && b[i + 7] == '/') ||
             (b[i + 4] == ':' && b[i + 5] == '/' && b[i + 6] == '/'))) {
            NSUInteger j = i;
            while (j < len && SDIsURLByte(b[j])) j++;
            NSUInteger n = j - i;
            if (n > 10 && n < 8192) {
                NSString *s = [[NSString alloc] initWithBytes:(b + i)
                                                       length:n
                                                     encoding:NSUTF8StringEncoding];
                if (s.length > 10) {
                    // 去掉尾部常见的标点噪音
                    while (s.length &&
                           ([s hasSuffix:@"."] || [s hasSuffix:@","] ||
                            [s hasSuffix:@")"] || [s hasSuffix:@";"] ||
                            [s hasSuffix:@"'"] || [s hasSuffix:@"]"])) {
                        s = [s substringToIndex:s.length - 1];
                    }
                    if (s.length > 10) [out addObject:s];
                }
            }
            i = (j > i) ? j : (i + 1);
        } else {
            i++;
        }
    }
}

static NSMutableOrderedSet<NSString *> *SDExtractURLs(NSData *data) {
    NSMutableOrderedSet<NSString *> *set = [NSMutableOrderedSet orderedSet];
    if (data.length < 12) return set;
    SDScanBytes((const uint8_t *)data.bytes, data.length, set);
    return set;
}

static NSMutableOrderedSet<NSString *> *SDExtractURLsFromString(NSString *s) {
    NSMutableOrderedSet<NSString *> *set = [NSMutableOrderedSet orderedSet];
    if (!s.length) return set;
    NSData *d = [s dataUsingEncoding:NSUTF8StringEncoding];
    if (d.length) SDScanBytes((const uint8_t *)d.bytes, d.length, set);
    return set;
}

// 只留下和订阅/面板相关的候选，避免把规则集里几百个测试 URL 全糊脸上
static BOOL SDLooksInteresting(NSString *u) {
    if (!u.length) return NO;
    NSString *l = u.lowercaseString;
    static NSArray<NSString *> *kws;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        kws = @[ @"sub", @"panel", @"relay", @"clash", @"token", @"userinfo",
                 @"sky", @"skynet", @"node", @"api", @"/v1/", @"config" ];
    });
    for (NSString *k in kws) {
        if ([l containsString:k]) return YES;
    }
    return NO;
}

#pragma mark - UserDefaults 展开

static void SDFlatten(id obj, NSString *prefix, NSUInteger depth,
                      NSMutableArray<NSString *> *out) {
    if (!obj || depth > 6) return;

    if ([obj isKindOfClass:[NSString class]]) {
        NSString *s = (NSString *)obj;
        if (s.length > 2000) s = [[s substringToIndex:2000] stringByAppendingString:@"...(截断)"];
        [out addObject:[NSString stringWithFormat:@"%@ = %@", prefix, s]];
    } else if ([obj isKindOfClass:[NSNumber class]]) {
        [out addObject:[NSString stringWithFormat:@"%@ = %@", prefix, obj]];
    } else if ([obj isKindOfClass:[NSData class]]) {
        NSData *d = (NSData *)obj;
        NSString *preview = [[NSString alloc] initWithData:[d subdataWithRange:NSMakeRange(0, MIN(d.length, 256))]
                                                  encoding:NSUTF8StringEncoding];
        [out addObject:[NSString stringWithFormat:@"%@ = <NSData %lu bytes> %@",
                        prefix, (unsigned long)d.length, preview ?: @""]];
    } else if ([obj isKindOfClass:[NSURL class]]) {
        [out addObject:[NSString stringWithFormat:@"%@ = %@", prefix, [(NSURL *)obj absoluteString]]];
    } else if ([obj isKindOfClass:[NSDate class]]) {
        [out addObject:[NSString stringWithFormat:@"%@ = %@", prefix, obj]];
    } else if ([obj isKindOfClass:[NSDictionary class]]) {
        NSDictionary *d = (NSDictionary *)obj;
        for (id k in d) {
            SDFlatten(d[k], [prefix stringByAppendingFormat:@".%@", k], depth + 1, out);
        }
    } else if ([obj isKindOfClass:[NSArray class]]) {
        NSArray *a = (NSArray *)obj;
        NSUInteger i = 0;
        for (id v in a) {
            if (i >= 40) { [out addObject:[NSString stringWithFormat:@"%@...[共%lu项]", prefix, (unsigned long)a.count]]; break; }
            SDFlatten(v, [prefix stringByAppendingFormat:@"[%lu]", (unsigned long)i], depth + 1, out);
            i++;
        }
    } else if ([obj isKindOfClass:[NSSet class]]) {
        NSUInteger i = 0;
        for (id v in (NSSet *)obj) {
            if (i >= 20) break;
            SDFlatten(v, [prefix stringByAppendingFormat:@"{%lu}", (unsigned long)i], depth + 1, out);
            i++;
        }
    } else {
        [out addObject:[NSString stringWithFormat:@"%@ = <%@>", prefix, [obj class]]];
    }
}

#pragma mark - 沙盒文件扫描

static void SDScanFiles(NSMutableArray<NSString *> *lines,
                        NSMutableOrderedSet<NSString *> *allURLs) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *home = NSHomeDirectory();
    NSDirectoryEnumerator *en = [fm enumeratorAtPath:home];

    NSUInteger files = 0, hitFiles = 0, hitLines = 0;
    unsigned long long total = 0;

    for (NSString *rel in en) {
        @autoreleasepool {
            NSDictionary *attr = [en fileAttributes];
            if (![attr[NSFileType] isEqualToString:NSFileTypeRegular]) continue;
            if (total > 800ULL * 1024 * 1024) break;

            unsigned long long size = [attr[NSFileSize] unsignedLongLongValue];
            if (size == 0 || size > 40ULL * 1024 * 1024) continue;
            if ([rel hasSuffix:@"SubDump.txt"]) continue;

            NSString *full = [home stringByAppendingPathComponent:rel];
            NSData *data = [NSData dataWithContentsOfFile:full
                                                  options:NSDataReadingMappedIfSafe
                                                    error:NULL];
            if (!data.length) continue;

            files++;
            total += data.length;

            NSMutableOrderedSet<NSString *> *found = SDExtractURLs(data);
            if (found.count) {
                hitFiles++;
                if (hitLines < 200) {
                    [lines addObject:[NSString stringWithFormat:@"-- %@  (%lu 条 URL)",
                                      rel, (unsigned long)found.count]];
                    hitLines++;
                }
                [allURLs unionOrderedSet:found];
            }
        }
    }

    [lines insertObject:[NSString stringWithFormat:@"扫描 %lu 个文件 / %.1f MB，命中 %lu 个",
                         (unsigned long)files, total / 1048576.0, (unsigned long)hitFiles]
                atIndex:0];
}

#pragma mark - 网络观测

typedef void (^SDCompletion)(NSData *, NSURLResponse *, NSError *);

static id (*origDataTaskRequest)(id, SEL, NSURLRequest *, SDCompletion);
static id (*origDataTaskURL)(id, SEL, NSURL *, SDCompletion);
static void (*origResume)(id, SEL);

static void SDRecordRequest(NSURLRequest *req) {
    if (!req || !req.URL) return;
    NSString *line = [NSString stringWithFormat:@"%@ %@",
                      req.HTTPMethod.length ? req.HTTPMethod : @"GET",
                      req.URL.absoluteString ?: @"?"];
    [gLock lock];
    BOOL isNew = ![gRequests containsObject:line];
    if (isNew) [gRequests addObject:line];
    [gLock unlock];
    if (isNew) SDLog(@"REQ %@", line);
}

static void SDCaptureResponse(NSString *url, NSData *data, NSURLResponse *resp) {
    if (!url.length || !data.length) return;
    if (data.length > 4ULL * 1024 * 1024) return;   // 超大文件不存

    NSString *body = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!body) body = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
    if (!body.length) return;
    if (body.length > 512 * 1024) body = [[body substringToIndex:512 * 1024] stringByAppendingString:@"\n...(截断)"];

    NSMutableString *rec = [NSMutableString string];
    if ([resp isKindOfClass:[NSHTTPURLResponse class]]) {
        NSHTTPURLResponse *h = (NSHTTPURLResponse *)resp;
        [rec appendFormat:@"[HTTP %ld]\n", (long)h.statusCode];
        NSDictionary *hdrs = h.allHeaderFields;
        for (NSString *want in @[ @"subscription-userinfo", @"content-type",
                                  @"profile-update-interval", @"content-disposition" ]) {
            for (id k in hdrs) {
                if ([[k description].lowercaseString isEqualToString:want]) {
                    [rec appendFormat:@"%@: %@\n", want, hdrs[k]];
                    break;
                }
            }
        }
    }
    [rec appendString:body];

    [gLock lock];
    [gCaptures addObject:[NSString stringWithFormat:@"### %@\n%@", url, rec]];
    [gLock unlock];
    SDLog(@"CAPTURE %@ (%lu bytes)", url, (unsigned long)data.length);
}

static void SDWrapAndCall(NSString *url, SDCompletion handler,
                          NSData *data, NSURLResponse *resp, NSError *err) {
    @try {
        [gLock lock];
        BOOL seen = NO;
        for (NSString *c in gCaptures) {
            if ([c hasPrefix:[NSString stringWithFormat:@"### %@\n", url]]) { seen = YES; break; }
        }
        [gLock unlock];
        if (!seen) SDCaptureResponse(url, data, resp);
    } @catch (__unused NSException *e) {}
    if (handler) handler(data, resp, err);
}

static id SDDataTaskRequest(id self, SEL _cmd, NSURLRequest *req, SDCompletion handler) {
    if (!origDataTaskRequest) return nil;
    SDRecordRequest(req);
    NSString *url = req.URL.absoluteString;
    if (handler && url.length && SDLooksInteresting(url)) {
        SDCompletion wrapped = ^(NSData *data, NSURLResponse *resp, NSError *err) {
            SDWrapAndCall(url, handler, data, resp, err);
        };
        return origDataTaskRequest(self, _cmd, req, [wrapped copy]);
    }
    return origDataTaskRequest(self, _cmd, req, handler);
}

static id SDDataTaskURL(id self, SEL _cmd, NSURL *url, SDCompletion handler) {
    if (!origDataTaskURL) return nil;
    if (url) SDRecordRequest([NSURLRequest requestWithURL:url]);
    NSString *abs = url.absoluteString;
    if (handler && abs.length && SDLooksInteresting(abs)) {
        SDCompletion wrapped = ^(NSData *data, NSURLResponse *resp, NSError *err) {
            SDWrapAndCall(abs, handler, data, resp, err);
        };
        return origDataTaskURL(self, _cmd, url, [wrapped copy]);
    }
    return origDataTaskURL(self, _cmd, url, handler);
}

static void SDResume(id self, SEL _cmd) {
    @try {
        NSURLRequest *r = [(NSURLSessionTask *)self originalRequest];
        if (!r) r = [(NSURLSessionTask *)self currentRequest];
        SDRecordRequest(r);
    } @catch (__unused NSException *e) {}
    if (origResume) origResume(self, _cmd);
}

static IMP SDSwap(Class cls, SEL sel, IMP imp) {
    if (!cls || !sel) return NULL;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NULL;
    return method_setImplementation(m, imp);
}

static void SDInstallHooks(void) {
    Class sess = NSClassFromString(@"NSURLSession");
    if (sess) {
        origDataTaskRequest = (id (*)(id, SEL, NSURLRequest *, SDCompletion))
            SDSwap(sess, @selector(dataTaskWithRequest:completionHandler:), (IMP)SDDataTaskRequest);
        origDataTaskURL = (id (*)(id, SEL, NSURL *, SDCompletion))
            SDSwap(sess, @selector(dataTaskWithURL:completionHandler:), (IMP)SDDataTaskURL);
    }
    Class task = NSClassFromString(@"NSURLSessionTask");
    if (task) {
        origResume = (void (*)(id, SEL))SDSwap(task, @selector(resume), (IMP)SDResume);
    }
    SDLog(@"hooks: request=%p url=%p resume=%p",
          (void *)origDataTaskRequest, (void *)origDataTaskURL, (void *)origResume);
}

#pragma mark - UI

static UIWindow *SDKeyWindow(void) {
    UIApplication *app = UIApplication.sharedApplication;
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in app.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            if (scene.activationState != UISceneActivationStateForegroundActive) continue;
            UIWindowScene *ws = (UIWindowScene *)scene;
            for (UIWindow *w in ws.windows) {
                if (w.isKeyWindow) return w;
            }
            if (ws.windows.firstObject) return ws.windows.firstObject;
        }
    }
    return app.windows.firstObject;
}

static UIViewController *SDTopViewController(void) {
    UIWindow *win = SDKeyWindow();
    UIViewController *vc = win.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}

static void SDShowAlert(NSString *title, NSString *message) {
    UIViewController *vc = SDTopViewController();
    if (!vc) return;

    UIAlertController *ac = [UIAlertController alertControllerWithTitle:title
                                                              message:message
                                                       preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"好"
                                          style:UIAlertActionStyleCancel
                                        handler:nil]];
    [vc presentViewController:ac animated:YES completion:nil];
}

// 只存在内存里的结果面板：可滚动、可长按选取、可一键复制。
// 不写任何文件，App 沙盒不留痕。
@interface SDReportVC : UIViewController
@property (nonatomic, copy) NSString *candidates;   // 候选链接（默认显示）
@property (nonatomic, copy) NSString *details;      // 全部细节（点「全部」切换）
@property (nonatomic, strong) UITextView *textView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UIButton *switchBtn;
@property (nonatomic, assign) BOOL showingDetails;
@end

@implementation SDReportVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.55];

    UIView *card = [[UIView alloc] init];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.backgroundColor = [UIColor systemBackgroundColor];
    card.layer.cornerRadius = 14;
    card.clipsToBounds = YES;
    [self.view addSubview:card];

    self.titleLabel = [[UILabel alloc] init];
    self.titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.titleLabel.font = [UIFont boldSystemFontOfSize:17];
    [card addSubview:self.titleLabel];

    self.switchBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    self.switchBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [self.switchBtn setTitle:@"全部" forState:UIControlStateNormal];
    [self.switchBtn addTarget:self action:@selector(toggleMode)
             forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:self.switchBtn];

    UIButton *copyBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    copyBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [copyBtn setTitle:@"复制" forState:UIControlStateNormal];
    [copyBtn addTarget:self action:@selector(copyAll)
      forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:copyBtn];

    UIButton *closeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    closeBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [closeBtn setTitle:@"关闭" forState:UIControlStateNormal];
    [closeBtn addTarget:self action:@selector(closeSelf)
       forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:closeBtn];

    self.textView = [[UITextView alloc] init];
    self.textView.translatesAutoresizingMaskIntoConstraints = NO;
    self.textView.editable = NO;
    self.textView.selectable = YES;
    self.textView.alwaysBounceVertical = YES;
    self.textView.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    self.textView.textContainerInset = UIEdgeInsetsMake(8, 8, 8, 8);
    self.textView.backgroundColor = [UIColor secondarySystemBackgroundColor];
    self.textView.layer.cornerRadius = 10;
    self.textView.clipsToBounds = YES;
    [card addSubview:self.textView];

    UILayoutGuide *g = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [card.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:14],
        [card.trailingAnchor constraintEqualToAnchor:g.trailingAnchor constant:-14],
        [card.centerYAnchor constraintEqualToAnchor:g.centerYAnchor],
        [card.heightAnchor constraintEqualToAnchor:g.heightAnchor multiplier:0.64],

        [self.titleLabel.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
        [self.titleLabel.topAnchor constraintEqualToAnchor:card.topAnchor constant:14],

        [closeBtn.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-12],
        [closeBtn.centerYAnchor constraintEqualToAnchor:self.titleLabel.centerYAnchor],
        [copyBtn.trailingAnchor constraintEqualToAnchor:closeBtn.leadingAnchor constant:-10],
        [copyBtn.centerYAnchor constraintEqualToAnchor:self.titleLabel.centerYAnchor],
        [self.switchBtn.trailingAnchor constraintEqualToAnchor:copyBtn.leadingAnchor constant:-10],
        [self.switchBtn.centerYAnchor constraintEqualToAnchor:self.titleLabel.centerYAnchor],

        [self.textView.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:12],
        [self.textView.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-12],
        [self.textView.topAnchor constraintEqualToAnchor:self.titleLabel.bottomAnchor constant:10],
        [self.textView.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-12],
    ]];

    [self render];
}

- (void)render {
    BOOL details = self.showingDetails;
    self.textView.text = details ? self.details : self.candidates;
    self.titleLabel.text = details ? @"SubDump 全部细节" : @"SubDump 候选链接";
    [self.switchBtn setTitle:(details ? @"候选" : @"全部") forState:UIControlStateNormal];
}

- (void)toggleMode {
    self.showingDetails = !self.showingDetails;
    [self render];
    [self.textView setContentOffset:CGPointZero animated:NO];
}

- (void)copyAll {
    NSString *text = self.showingDetails ? self.details : self.candidates;
    if (text.length) {
        UIPasteboard.generalPasteboard.string = text;
    }
    [self closeSelf];
}

- (void)closeSelf {
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end

static void SDShowReport(NSString *candidates, NSString *details) {
    UIViewController *vc = SDTopViewController();
    if (!vc) return;
    SDReportVC *r = [[SDReportVC alloc] init];
    r.candidates = candidates;
    r.details = details;
    r.modalPresentationStyle = UIModalPresentationOverFullScreen;
    r.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
    [vc presentViewController:r animated:YES completion:nil];
}

static NSInteger SDScore(NSString *u) {
    NSString *l = u.lowercaseString;
    NSInteger s = 0;
    if ([l containsString:@"/subscribe"]) s += 12;
    if ([l containsString:@"/sub?"]) s += 10;
    if ([l containsString:@"token="]) s += 8;
    if ([l containsString:@"userinfo"]) s += 6;
    if ([l containsString:@"sub"]) s += 6;
    if ([l containsString:@"relay"]) s += 5;
    if ([l containsString:@"panel"]) s += 5;
    if ([l containsString:@"clash"]) s += 4;
    if ([l containsString:@"skynet"] || [l containsString:@"skyapp"]) s += 4;
    if ([l containsString:@"config"]) s += 3;
    if ([l containsString:@"jsdelivr"] || [l containsString:@"gstatic"] ||
        [l containsString:@"t.me/"] || [l containsString:@"apps.apple.com"]) s -= 8;
    if ([l hasSuffix:@".mrs"] || [l hasSuffix:@".dat"] || [l hasSuffix:@".mmdb"]) s -= 10;
    return s;
}

#pragma mark - 扫描主流程

static void SDRunScan(NSString *reason) {
    NSMutableArray<NSString *> *flat = [NSMutableArray array];
    NSMutableArray<NSString *> *fileLines = [NSMutableArray array];
    NSMutableOrderedSet<NSString *> *allURLs = [NSMutableOrderedSet orderedSet];
    NSMutableOrderedSet<NSString *> *interesting = [NSMutableOrderedSet orderedSet];

    [gLock lock];
    NSArray<NSString *> *reqs = [gRequests copy];
    NSArray<NSString *> *caps = [gCaptures copy];
    [gLock unlock];

    // 1. UserDefaults
    @try {
        NSDictionary *dict = [[NSUserDefaults standardUserDefaults] dictionaryRepresentation];
        SDFlatten(dict, @"defaults", 0, flat);
    } @catch (__unused NSException *e) {}
    for (NSString *s in flat) {
        [allURLs unionOrderedSet:SDExtractURLsFromString(s)];
    }

    // 2. 沙盒文件
    @try {
        SDScanFiles(fileLines, allURLs);
    } @catch (__unused NSException *e) {}

    // 3. 候选合并
    for (NSString *u in allURLs) {
        if (SDLooksInteresting(u)) [interesting addObject:u];
    }
    for (NSString *line in reqs) {
        NSRange sp = [line rangeOfString:@" "];
        if (sp.location != NSNotFound) {
            [interesting addObject:[line substringFromIndex:sp.location + 1]];
        }
    }
    for (NSString *c in caps) {
        [interesting unionOrderedSet:SDExtractURLsFromString(c)];
    }

    // 4. 候选排序：越像订阅链接的越靠前
    NSArray<NSString *> *ranked =
        [[interesting array] sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
            NSInteger sa = SDScore(a), sb = SDScore(b);
            if (sa == sb) return NSOrderedSame;
            return sa > sb ? NSOrderedAscending : NSOrderedDescending;
        }];

    // 5. 两份文本，全部只存在于内存，不落盘
    NSMutableString *cand = [NSMutableString string];
    [cand appendFormat:@"共 %lu 条（按可能性排序）\n\n", (unsigned long)ranked.count];
    for (NSString *u in ranked) [cand appendFormat:@"%@\n\n", u];
    if (ranked.count == 0) {
        [cand appendString:@"暂时没抓到。\n请回 App 里点一次「刷新」订阅/面板，再按左上角 🔗。"];
    }

    NSMutableString *details = [NSMutableString string];
    [details appendFormat:@"SubDump %@   %@   触发=%@\n\n", SD_VERSION, [NSDate date], reason];
    [details appendFormat:@"=== 候选（%lu）===\n", (unsigned long)ranked.count];
    for (NSString *u in ranked) [details appendFormat:@"%@\n", u];
    [details appendFormat:@"\n=== UserDefaults（%lu）===\n", (unsigned long)flat.count];
    for (NSString *s in flat) [details appendFormat:@"%@\n", s];
    [details appendString:@"\n=== 沙盒文件命中 ===\n"];
    for (NSString *s in fileLines) [details appendFormat:@"%@\n", s];
    [details appendFormat:@"\n=== 网络请求（%lu）===\n", (unsigned long)reqs.count];
    for (NSString *s in reqs) [details appendFormat:@"%@\n", s];
    [details appendFormat:@"\n=== 响应体（%lu）===\n", (unsigned long)caps.count];
    for (NSString *s in caps) [details appendFormat:@"%@\n\n", s];
    [details appendFormat:@"\n=== 全部 URL（%lu）===\n", (unsigned long)allURLs.count];
    for (NSString *s in allURLs) [details appendFormat:@"%@\n", s];

    // 6. 剪贴板：只放候选，方便直接粘到 Loon
    if (ranked.count) {
        @try {
            UIPasteboard.generalPasteboard.string = [ranked componentsJoinedByString:@"\n"];
        } @catch (__unused NSException *e) {}
    }

    // 7. 内存面板展示
    NSString *candText = [cand copy];
    NSString *detailText = [details copy];
    dispatch_async(dispatch_get_main_queue(), ^{
        SDShowReport(candText, detailText);
    });

    SDLog(@"scan done: candidates=%lu all=%lu",
          (unsigned long)ranked.count, (unsigned long)allURLs.count);
}

#pragma mark - 悬浮按钮

@interface SDTarget : NSObject
@end

@implementation SDTarget

- (void)tap:(id)sender {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        SDRunScan(@"manual");
    });
}

- (void)pan:(UIPanGestureRecognizer *)g {
    UIView *v = g.view;
    if (!v.superview) return;
    CGPoint t = [g translationInView:v.superview];
    v.center = CGPointMake(v.center.x + t.x, v.center.y + t.y);
    [g setTranslation:CGPointZero inView:v.superview];
}

@end

static SDTarget *gTarget;

static void SDInstallButton(void) {
    UIWindow *win = SDKeyWindow();
    if (!win) return;
    if ([win viewWithTag:SD_BTN_TAG]) return;

    UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
    btn.tag = SD_BTN_TAG;
    btn.frame = CGRectMake(12, 120, 46, 46);
    btn.backgroundColor = [UIColor colorWithWhite:0.1 alpha:0.65];
    btn.layer.cornerRadius = 23;
    btn.layer.borderWidth = 1;
    btn.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.7].CGColor;
    btn.titleLabel.font = [UIFont systemFontOfSize:22];
    [btn setTitle:@"🔗" forState:UIControlStateNormal];
    [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];

    if (!gTarget) gTarget = [SDTarget new];
    [btn addTarget:gTarget action:@selector(tap:) forControlEvents:UIControlEventTouchUpInside];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:gTarget
                                                                        action:@selector(pan:)];
    [btn addGestureRecognizer:pan];
    [win addSubview:btn];
    SDLog(@"button installed");
}

#pragma mark - 入口

__attribute__((constructor))
static void SubDumpInit(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gLock = [NSLock new];
        gRequests = [NSMutableArray array];
        gCaptures = [NSMutableArray array];

        @try { SDInstallHooks(); } @catch (__unused NSException *e) {}

        // 等 App 自己把面板/订阅加载完，再扫一遍（此时 Core Data 已落盘）
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            @try { SDInstallButton(); } @catch (__unused NSException *e) {}
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                @try { SDRunScan(@"auto"); } @catch (__unused NSException *e) {}
            });
        });
    });
}
