// SubDump - 订阅链接/配置导出工具
// 目标 App: Apps Connect (uk.skynet.ios)
//
// 设计原则：
//   1. 零依赖：不用 CydiaSubstrate / Logos / ElleKit，只用 objc runtime 的
//      method_setImplementation，TrollStore 注入后可直接加载。
//   2. 不改业务逻辑：只观测（读文件、读 UserDefaults、抓网络、抓 NE 配置），
//      不修改任何返回值，不干预鉴权与订阅状态。
//   3. 取证路线：
//        A. 沙盒 + AppGroup 容器里的 yaml（config.yaml 就是明文）
//        B. NSURLSession 请求 URL + 响应体（按内容分类，不靠 URL 猜）
//        C. NETunnelProviderProtocol 的 providerConfiguration（配置可能整包塞给 NE）
//        D. NSUserDefaults 全量键值
//   4. 结果只放内存：可滚动面板 + 剪贴板，不写任何文件

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <ctype.h>
#import <stdarg.h>

#define SD_VERSION   @"0.4.1"
#define SD_BTN_TAG   0x5B0D1E
#define SD_MAX_TEXT  (64 * 1024)

#pragma mark - 日志

static void SDLog(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[SubDump] %@", msg);
}

static NSString *SDTrim(NSString *s, NSUInteger n) {
    if (!s) return @"";
    if (s.length <= n) return s;
    return [[s substringToIndex:n] stringByAppendingString:@"…"];
}

#pragma mark - 全局状态

static NSMutableArray<NSString *> *gRequests;          // "GET url"
static NSMutableArray<NSDictionary *> *gCaptures;      // {url,status,headers,body}
static NSMutableArray<NSString *> *gProviderCfgs;      // NE providerConfiguration 转储
static NSString *gBestYAML;                           // 最近扫到的最完整 config.yaml 全文
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

static NSString *SDRegexFirst(NSString *text, NSString *pattern) {
    if (!text.length) return nil;
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:pattern
                                                                       options:0
                                                                         error:NULL];
    if (!re) return nil;
    NSTextCheckingResult *m = [re firstMatchInString:text
                                             options:0
                                               range:NSMakeRange(0, text.length)];
    if (!m || m.numberOfRanges < 2) return nil;
    NSRange r = [m rangeAtIndex:1];
    if (r.location == NSNotFound) return nil;
    return [text substringWithRange:r];
}

// 已知噪声：规则集、测速探针、文档、示例
static BOOL SDIsNoise(NSString *u) {
    NSString *l = u.lowercaseString;
    static NSArray<NSString *> *noise;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        noise = @[ @"jsdelivr", @"gstatic.com", @"generate_204", @"apps.apple.com",
                   @"t.me/", @"dns.alidns.com", @"doh.pub", @"cloudflare-dns.com",
                   @"w3.org", @"github.com/meta", @"baidu.com", @"qq.com",
                   @"wikipedia.org", @"netflix.com", @"youtube.com", @"disney",
                   @"spotify.com", @"openai.com", @"claude.ai", @"gemini.google",
                   @"bilibili.com", @"hulu.jp", @"dmm.com", @"tving.com",
                   @"localhost", @"127.0.0.1", @"0.0.0.0" ];
    });
    for (NSString *n in noise) if ([l containsString:n]) return YES;
    if ([l hasSuffix:@".mrs"] || [l hasSuffix:@".dat"] || [l hasSuffix:@".mmdb"]) return YES;
    return NO;
}

static BOOL SDLooksInteresting(NSString *u) {
    if (!u.length) return NO;
    NSString *l = u.lowercaseString;
    static NSArray<NSString *> *kws;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        kws = @[ @"sub", @"panel", @"relay", @"clash", @"token", @"userinfo",
                 @"sky", @"skynet", @"node", @"api", @"config" ];
    });
    for (NSString *k in kws) if ([l containsString:k]) return YES;
    return NO;
}

static NSInteger SDScore(NSString *u) {
    NSString *l = u.lowercaseString;
    NSInteger s = 0;
    if ([l containsString:@"/subscribe"]) s += 20;
    if ([l containsString:@"/sub?"]) s += 16;
    if ([l containsString:@"token="]) s += 12;
    if ([l containsString:@"userinfo"]) s += 10;
    if ([l containsString:@"relay"]) s += 8;
    if ([l containsString:@"panel"]) s += 8;
    if ([l containsString:@"/sub"]) s += 6;
    if ([l containsString:@"clash"]) s += 5;
    if ([l containsString:@"skynet"] || [l containsString:@"skyapp"]) s += 5;
    if (SDIsNoise(u)) s -= 40;
    return s;
}

#pragma mark - UserDefaults 展开

static void SDFlatten(id obj, NSString *prefix, NSUInteger depth,
                      NSMutableArray<NSString *> *out) {
    if (!obj || depth > 6) return;

    if ([obj isKindOfClass:[NSString class]]) {
        NSString *s = (NSString *)obj;
        [out addObject:[NSString stringWithFormat:@"%@ = %@", prefix, SDTrim(s, 1800)]];
    } else if ([obj isKindOfClass:[NSNumber class]]) {
        [out addObject:[NSString stringWithFormat:@"%@ = %@", prefix, obj]];
    } else if ([obj isKindOfClass:[NSData class]]) {
        NSData *d = (NSData *)obj;
        NSUInteger n = MIN(d.length, (NSUInteger)256);
        NSString *preview = [[NSString alloc] initWithData:[d subdataWithRange:NSMakeRange(0, n)]
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
            if (i >= 40) {
                [out addObject:[NSString stringWithFormat:@"%@...[共%lu项]",
                                prefix, (unsigned long)a.count]];
                break;
            }
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

#pragma mark - 沙盒根目录（含 AppGroup）

typedef void *(*SDCreateTaskFn)(CFAllocatorRef);
typedef CFTypeRef (*SDSecTaskCopyFn)(void *task, CFStringRef entitlement, CFErrorRef *error);

static NSArray<NSString *> *SDSandboxRoots(void) {
    NSMutableArray<NSString *> *roots = [NSMutableArray array];
    NSString *home = NSHomeDirectory();
    if (home.length) [roots addObject:home];

    // 用 dlsym 拿 SecTask，避免链接期绑定失败
    SDCreateTaskFn createTask = (SDCreateTaskFn)dlsym(RTLD_DEFAULT, "SecTaskCreateFromSelf");
    SDSecTaskCopyFn copyEnt = (SDSecTaskCopyFn)dlsym(RTLD_DEFAULT, "SecTaskCopyValueForEntitlement");
    if (!createTask || !copyEnt) {
        SDLog(@"SecTask unavailable");
        return roots;
    }
    void *task = createTask(kCFAllocatorDefault);
    if (!task) return roots;

    CFTypeRef val = copyEnt(task, CFSTR("com.apple.security.application-groups"), NULL);
    if (val && CFGetTypeID(val) == CFArrayGetTypeID()) {
        for (id g in (__bridge NSArray *)val) {
            if (![g isKindOfClass:[NSString class]]) continue;
            NSURL *u = [[NSFileManager defaultManager]
                        containerURLForSecurityApplicationGroupIdentifier:(NSString *)g];
            if (u.path.length) {
                [roots addObject:u.path];
                SDLog(@"app group: %@ -> %@", g, u.path);
            }
        }
    }
    if (val) CFRelease(val);
    CFRelease(task);
    return roots;
}

#pragma mark - YAML 解析

// 取顶层键（proxies / proxy-providers / proxy-groups / rules）的整段内容
static NSString *SDYamlBlock(NSString *text, NSString *key) {
    if (!text.length || !key.length) return nil;
    NSArray<NSString *> *lines = [text componentsSeparatedByString:@"\n"];
    NSString *head = [key stringByAppendingString:@":"];
    NSInteger start = -1;
    for (NSUInteger i = 0; i < lines.count; i++) {
        if ([lines[i] hasPrefix:head]) { start = (NSInteger)i; break; }
    }
    if (start < 0) return nil;

    NSMutableString *out = [NSMutableString string];
    for (NSUInteger i = (NSUInteger)start; i < lines.count; i++) {
        NSString *ln = lines[i];
        if (i > (NSUInteger)start && ln.length &&
            ![ln hasPrefix:@" "] && ![ln hasPrefix:@"\t"] && ![ln hasPrefix:@"-"] &&
            ![ln hasPrefix:@"#"]) {
            break;
        }
        [out appendFormat:@"%@\n", ln];
        if (out.length > 20000) break;
    }
    return out.length ? out : nil;
}

// proxies 段里数节点：行首是 "- " 的都算（- name: / - {name: / - {...}）
static NSUInteger SDCountProxyEntries(NSString *block) {
    if (!block.length) return 0;
    NSUInteger n = 0;
    for (NSString *ln in [block componentsSeparatedByString:@"\n"]) {
        if ([ln hasPrefix:@"- "] || [ln hasPrefix:@"  - "] || [ln hasPrefix:@"    - "]) n++;
    }
    return n;
}

// 节点名预览
static NSArray<NSString *> *SDProxyNames(NSString *block, NSUInteger limit) {
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    for (NSString *ln in [block componentsSeparatedByString:@"\n"]) {
        NSRange r = [ln rangeOfString:@"name:"];
        if (r.location == NSNotFound) continue;
        if (![ln hasPrefix:@"- "] && ![ln hasPrefix:@"  - "] && ![ln hasPrefix:@"    - "]) continue;
        NSString *name = [[ln substringFromIndex:r.location + r.length]
                          stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        name = [name stringByTrimmingCharactersInSet:
                [NSCharacterSet characterSetWithCharactersInString:@"\"'"]];
        if (name.length) [out addObject:SDTrim(name, 40)];
        if (out.count >= limit) break;
    }
    return out;
}

static NSString *SDProviderURL(NSString *provBlock) {
    return SDRegexFirst(provBlock, @"(?m)^\\s*url:\\s*['\"]?(https?://[^\\s'\"]+)");
}

// 计数用于响应体判断（不做行首假设）
static NSUInteger SDCountNodes(NSString *yaml) {
    if (!yaml.length) return 0;
    NSUInteger n = 0;
    for (NSString *pat in @[ @"- name:", @"- {name:", @"- { name:" ]) {
        NSUInteger loc = 0;
        while (loc < yaml.length) {
            NSRange r = [yaml rangeOfString:pat
                                    options:0
                                      range:NSMakeRange(loc, yaml.length - loc)];
            if (r.location == NSNotFound) break;
            n++;
            loc = r.location + r.length;
        }
    }
    return n;
}

#pragma mark - 文件扫描

static void SDScanFiles(NSArray<NSString *> *roots,
                        NSMutableArray<NSString *> *lines,
                        NSMutableArray<NSDictionary *> *yamlFiles,
                        NSMutableOrderedSet<NSString *> *allURLs) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSUInteger files = 0, hitFiles = 0;
    unsigned long long total = 0;

    for (NSString *root in roots) {
        NSDirectoryEnumerator *en = [fm enumeratorAtPath:root];
        for (NSString *rel in en) {
            @autoreleasepool {
                NSDictionary *attr = [en fileAttributes];
                if (![attr[NSFileType] isEqualToString:NSFileTypeRegular]) continue;
                if (total > 1000ULL * 1024 * 1024) break;

                unsigned long long size = [attr[NSFileSize] unsignedLongLongValue];
                if (size == 0 || size > 60ULL * 1024 * 1024) continue;

                NSString *full = [root stringByAppendingPathComponent:rel];
                NSData *data = [NSData dataWithContentsOfFile:full
                                                      options:NSDataReadingMappedIfSafe
                                                        error:NULL];
                if (!data.length) continue;

                files++;
                total += data.length;

                NSMutableOrderedSet<NSString *> *found = SDExtractURLs(data);
                if (found.count) {
                    hitFiles++;
                    if (lines.count < 200) {
                        [lines addObject:[NSString stringWithFormat:@"-- %@  (%lu 条 URL)",
                                          full, (unsigned long)found.count]];
                    }
                    [allURLs unionOrderedSet:found];
                }

                // yaml：解析出 proxies / proxy-providers 段落
                if (data.length < 16ULL * 1024 * 1024) {
                    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                    if (text && ([text containsString:@"proxies:"] ||
                                 [text containsString:@"proxy-providers:"])) {
                        NSString *proxies = SDYamlBlock(text, @"proxies");
                        NSString *provs = SDYamlBlock(text, @"proxy-providers");
                        if (proxies.length || provs.length) {
                            NSUInteger nodes = SDCountProxyEntries(proxies);
                            [yamlFiles addObject:@{
                                @"path": full,
                                @"size": @(size),
                                @"text": SDTrim(text, 200 * 1024),
                                @"proxies": proxies ?: @"",
                                @"providers": provs ?: @"",
                                @"nodes": @(nodes),
                                @"provURL": SDProviderURL(provs) ?: @""
                            }];
                            if (proxies.length) [allURLs unionOrderedSet:SDExtractURLsFromString(proxies)];
                            if (provs.length) [allURLs unionOrderedSet:SDExtractURLsFromString(provs)];
                        }
                    }
                }
            }
        }
    }

    [lines insertObject:[NSString stringWithFormat:
        @"扫描 %lu 个文件 / %.1f MB，命中 %lu 个，yaml 配置 %lu 个",
        (unsigned long)files, total / 1048576.0,
        (unsigned long)hitFiles, (unsigned long)yamlFiles.count] atIndex:0];
}

#pragma mark - 网络 / NE 观测

typedef void (^SDCompletion)(NSData *, NSURLResponse *, NSError *);

static id (*origDataTaskRequest)(id, SEL, NSURLRequest *, SDCompletion);
static id (*origDataTaskURL)(id, SEL, NSURL *, SDCompletion);
static void (*origResume)(id, SEL);
static void (*origSetProvCfg)(id, SEL, NSDictionary *);

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

static void SDAddCapture(NSString *url, NSInteger status,
                         NSString *headers, NSString *body) {
    if (!url.length) return;
    [gLock lock];
    for (NSDictionary *c in gCaptures) {
        if ([c[@"url"] isEqualToString:url]) { [gLock unlock]; return; }
    }
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"url"] = url;
    d[@"status"] = @(status);
    d[@"headers"] = headers ?: @"";
    d[@"body"] = body ?: @"";
    [gCaptures addObject:d];
    [gLock unlock];
}

static void SDCaptureResponse(NSString *url, NSData *data, NSURLResponse *resp) {
    if (!url.length || !data.length || data.length > 8ULL * 1024 * 1024) return;

    NSString *body = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!body) body = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
    if (!body.length) return;
    body = SDTrim(body, SD_MAX_TEXT);

    NSMutableString *hdrs = [NSMutableString string];
    NSInteger status = 0;
    if ([resp isKindOfClass:[NSHTTPURLResponse class]]) {
        NSHTTPURLResponse *h = (NSHTTPURLResponse *)resp;
        status = h.statusCode;
        NSDictionary *all = h.allHeaderFields;
        for (NSString *want in @[ @"subscription-userinfo", @"profile-web-page-url",
                                  @"profile-update-interval", @"content-type",
                                  @"content-disposition", @"x-app-version" ]) {
            for (id k in all) {
                if ([[k description].lowercaseString isEqualToString:want]) {
                    [hdrs appendFormat:@"%@: %@\n", want, all[k]];
                    break;
                }
            }
        }
    }
    if ([body containsString:@"proxies:"] || [body containsString:@"proxy-providers:"]) {
        [hdrs appendFormat:@"[yaml] nodes=%lu\n", (unsigned long)SDCountNodes(body)];
    }
    SDAddCapture(url, status, hdrs, body);
    SDLog(@"CAPTURE %@ (%lu bytes)", url, (unsigned long)data.length);
}

static void SDWrapAndCall(NSString *url, SDCompletion handler,
                          NSData *data, NSURLResponse *resp, NSError *err) {
    @try {
        [gLock lock];
        BOOL seen = NO;
        for (NSDictionary *c in gCaptures) {
            if ([c[@"url"] isEqualToString:url]) { seen = YES; break; }
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

// 关键：App 可能把整份配置塞进 providerConfiguration 交给 NE
static void SDSetProviderConfiguration(id self, SEL _cmd, NSDictionary *cfg) {
    @try {
        if (cfg.count) {
            NSMutableString *s = [NSMutableString string];
            [s appendFormat:@"=== providerConfiguration (%lu keys) ===\n", (unsigned long)cfg.count];
            for (id k in cfg) {
                NSString *v;
                id val = cfg[k];
                if ([val isKindOfClass:[NSString class]]) {
                    v = SDTrim((NSString *)val, 4000);
                } else if ([val isKindOfClass:[NSData class]]) {
                    NSData *d = (NSData *)val;
                    NSString *t = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
                    v = t ? SDTrim(t, 4000) : [NSString stringWithFormat:@"<NSData %lu>",
                                               (unsigned long)d.length];
                } else {
                    v = SDTrim([val description], 2000);
                }
                [s appendFormat:@"%@ = %@\n", k, v];
            }
            [gLock lock];
            [gProviderCfgs addObject:[s copy]];
            [gLock unlock];
            SDLog(@"providerConfiguration dumped (%lu keys)", (unsigned long)cfg.count);
        }
    } @catch (__unused NSException *e) {}
    if (origSetProvCfg) origSetProvCfg(self, _cmd, cfg);
}

static IMP SDSwap(Class cls, SEL sel, IMP imp) {
    if (!cls || !sel) return NULL;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NULL;
    return method_setImplementation(m, imp);
}

// NetworkExtension 可能比 dylib 晚加载，所以这个 hook 要能重复尝试
static void SDInstallNEHook(void) {
    if (origSetProvCfg) return;
    Class proto = NSClassFromString(@"NETunnelProviderProtocol");
    if (!proto) return;
    origSetProvCfg = (void (*)(id, SEL, NSDictionary *))
        SDSwap(proto, @selector(setProviderConfiguration:), (IMP)SDSetProviderConfiguration);
    if (origSetProvCfg) SDLog(@"NE hook installed");
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
    SDInstallNEHook();
    SDLog(@"hooks: req=%p url=%p resume=%p ne=%p",
          (void *)origDataTaskRequest, (void *)origDataTaskURL,
          (void *)origResume, (void *)origSetProvCfg);
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

@interface SDReportVC : UIViewController
@property (nonatomic, copy) NSString *candidates;
@property (nonatomic, copy) NSString *details;
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

    UIButton *yamlBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    yamlBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [yamlBtn setTitle:@"YAML" forState:UIControlStateNormal];
    [yamlBtn addTarget:self action:@selector(copyYAML)
      forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:yamlBtn];

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
        [card.heightAnchor constraintEqualToAnchor:g.heightAnchor multiplier:0.7],

        [self.titleLabel.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
        [self.titleLabel.topAnchor constraintEqualToAnchor:card.topAnchor constant:14],

        [closeBtn.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-12],
        [closeBtn.centerYAnchor constraintEqualToAnchor:self.titleLabel.centerYAnchor],
        [copyBtn.trailingAnchor constraintEqualToAnchor:closeBtn.leadingAnchor constant:-10],
        [copyBtn.centerYAnchor constraintEqualToAnchor:self.titleLabel.centerYAnchor],
        [yamlBtn.trailingAnchor constraintEqualToAnchor:copyBtn.leadingAnchor constant:-10],
        [yamlBtn.centerYAnchor constraintEqualToAnchor:self.titleLabel.centerYAnchor],
        [self.switchBtn.trailingAnchor constraintEqualToAnchor:yamlBtn.leadingAnchor constant:-10],
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
    self.titleLabel.text = details ? @"SubDump 全部细节" : @"SubDump 关键线索";
    [self.switchBtn setTitle:(details ? @"线索" : @"全部") forState:UIControlStateNormal];
}

- (void)toggleMode {
    self.showingDetails = !self.showingDetails;
    [self render];
    [self.textView setContentOffset:CGPointZero animated:NO];
}

- (void)copyAll {
    NSString *text = self.showingDetails ? self.details : self.candidates;
    if (text.length) UIPasteboard.generalPasteboard.string = text;
    [self closeSelf];
}

- (void)closeSelf {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)copyYAML {
    [gLock lock];
    NSString *yaml = [gBestYAML copy];
    [gLock unlock];
    if (!yaml.length) {
        [self flashTitle:@"没有 yaml"];
        return;
    }
    UIPasteboard.generalPasteboard.string = yaml;
    [self flashTitle:@"已复制 YAML"];
}

- (void)flashTitle:(NSString *)text {
    NSString *old = self.titleLabel.text;
    self.titleLabel.text = text;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (self.titleLabel) self.titleLabel.text = old;
    });
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

#pragma mark - 响应分类

typedef NS_ENUM(NSInteger, SDKind) {
    SDKindOther = 0,
    SDKindJSON,
    SDKindNodes,
    SDKindYAML,
};

// 从 JSON 里挖 link/url/token 等关键字段
static void SDCollectJSON(id obj, NSString *path, NSMutableArray<NSString *> *out, int depth) {
    if (!obj || depth > 5 || out.count > 60) return;
    if ([obj isKindOfClass:[NSDictionary class]]) {
        NSDictionary *d = (NSDictionary *)obj;
        for (id k in d) {
            id v = d[k];
            NSString *kp = [path stringByAppendingFormat:@".%@", k];
            if ([v isKindOfClass:[NSString class]]) {
                NSString *s = (NSString *)v;
                BOOL keyHit = ([k isEqual:@"link"] || [k isEqual:@"url"] ||
                               [k isEqual:@"subscribe"] || [k isEqual:@"subscribe_url"] ||
                               [k isEqual:@"token"] || [k isEqual:@"configs"] ||
                               [k isEqual:@"configsNode"] || [k isEqual:@"email"] ||
                               [k isEqual:@"plan"] || [k isEqual:@"expired"] ||
                               [k isEqual:@"residue"] || [k isEqual:@"transfer_enable"]);
                BOOL urlHit = ([s containsString:@"http://"] || [s containsString:@"https://"]);
                if ((keyHit || urlHit) && s.length < 4000) {
                    [out addObject:[NSString stringWithFormat:@"  %@ = %@", kp, SDTrim(s, 300)]];
                }
            } else {
                SDCollectJSON(v, kp, out, depth + 1);
            }
        }
    } else if ([obj isKindOfClass:[NSArray class]]) {
        NSArray *a = (NSArray *)obj;
        NSUInteger i = 0;
        for (id v in a) {
            if (i >= 30) break;
            SDCollectJSON(v, [path stringByAppendingFormat:@"[%lu]", (unsigned long)i], out, depth + 1);
            i++;
        }
    }
}

static BOOL SDIsNodeListText(NSString *t) {
    return [t containsString:@"ss://"] || [t containsString:@"vmess://"] ||
           [t containsString:@"trojan://"] || [t containsString:@"vless://"] ||
           [t containsString:@"hysteria://"] || [t containsString:@"tuic://"];
}

static NSString *SDBase64Decode(NSString *s) {
    NSMutableString *clean = [NSMutableString string];
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar c = [s characterAtIndex:i];
        if (isalnum(c) || c == '+' || c == '/' || c == '=') [clean appendFormat:@"%C", c];
    }
    if (clean.length < 16) return nil;
    NSData *d = [[NSData alloc] initWithBase64EncodedString:clean
                                                    options:NSDataBase64DecodingIgnoreUnknownCharacters];
    if (!d.length) return nil;
    return [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
}

static void SDClassifyCapture(NSDictionary *cap,
                              NSMutableArray<NSString *> *subLines,
                              NSMutableArray<NSString *> *jsonLines,
                              NSMutableArray<NSString *> *otherLines) {
    NSString *url = cap[@"url"];
    NSString *body = cap[@"body"] ?: @"";
    NSString *hdrs = cap[@"headers"] ?: @"";
    NSInteger status = [cap[@"status"] integerValue];

    BOOL hasUserinfo = [hdrs.lowercaseString containsString:@"subscription-userinfo"];

    if ([body containsString:@"proxies:"] &&
        ([body containsString:@"rules:"] || [body containsString:@"proxy-groups:"])) {
        NSUInteger nodes = SDCountNodes(body);
        NSString *prov = SDRegexFirst(body, @"(?m)^\\s*url:\\s*['\"]?(https?://[^\\s'\"]+)");
        NSMutableString *line = [NSMutableString string];
        [line appendFormat:@"[Clash YAML] %@\n  HTTP %ld, %.1f KB, 约 %lu 节点%@\n",
         url, (long)status, body.length / 1024.0, (unsigned long)nodes,
         hasUserinfo ? @", 带 subscription-userinfo 头" : @""];
        if (prov.length) [line appendFormat:@"  proxy-providers url = %@\n", prov];
        [subLines addObject:line];
        return;
    }

    if (SDIsNodeListText(body)) {
        NSMutableString *line = [NSMutableString string];
        [line appendFormat:@"[节点链接列表] %@\n  HTTP %ld, %.1f KB%@\n",
         url, (long)status, body.length / 1024.0,
         hasUserinfo ? @", 带 subscription-userinfo 头" : @""];
        if (hasUserinfo) {
            NSString *ui = SDRegexFirst(hdrs, @"(?i)subscription-userinfo:\\s*([^\\n]+)");
            if (ui.length) [line appendFormat:@"  %@\n", ui];
        }
        [subLines addObject:line];
        return;
    }

    // base64 订阅（很多机场的订阅是 base64 过的节点列表）
    NSString *b64 = SDBase64Decode(body);
    if (b64.length && SDIsNodeListText(b64)) {
        NSMutableString *line = [NSMutableString string];
        [line appendFormat:@"[节点列表/base64] %@\n  HTTP %ld%@\n",
         url, (long)status, hasUserinfo ? @", 带 subscription-userinfo 头" : @""];
        NSString *ui = SDRegexFirst(hdrs, @"(?i)subscription-userinfo:\\s*([^\\n]+)");
        if (ui.length) [line appendFormat:@"  %@\n", ui];
        [subLines addObject:line];
        return;
    }

    NSData *bd = [body dataUsingEncoding:NSUTF8StringEncoding];
    id json = bd ? [NSJSONSerialization JSONObjectWithData:bd
                                                  options:NSJSONReadingAllowFragments
                                                    error:NULL] : nil;
    if (json) {
        NSMutableArray<NSString *> *fields = [NSMutableArray array];
        SDCollectJSON(json, @"json", fields, 0);
        NSMutableString *line = [NSMutableString string];
        [line appendFormat:@"[JSON] %@\n  HTTP %ld, %lu 个关键字段\n",
         url, (long)status, (unsigned long)fields.count];
        for (NSString *f in fields) [line appendFormat:@"%@\n", f];
        if (fields.count) [jsonLines addObject:line];
        else [otherLines addObject:[NSString stringWithFormat:@"%@  (JSON, 无关键字段)", url]];
        return;
    }

    [otherLines addObject:[NSString stringWithFormat:@"%@  (HTTP %ld, %lu 字节)",
                           url, (long)status, (unsigned long)body.length]];
}

#pragma mark - 扫描主流程

static void SDRunScan(NSString *reason) {
    @try { SDInstallNEHook(); } @catch (__unused NSException *e) {}

    NSMutableArray<NSString *> *flat = [NSMutableArray array];
    NSMutableArray<NSString *> *fileLines = [NSMutableArray array];
    NSMutableArray<NSDictionary *> *yamlFiles = [NSMutableArray array];
    NSMutableOrderedSet<NSString *> *allURLs = [NSMutableOrderedSet orderedSet];

    [gLock lock];
    NSArray<NSString *> *reqs = [gRequests copy];
    NSArray<NSDictionary *> *caps = [gCaptures copy];
    NSArray<NSString *> *provs = [gProviderCfgs copy];
    [gLock unlock];

    // 1. UserDefaults
    @try {
        NSDictionary *dict = [[NSUserDefaults standardUserDefaults] dictionaryRepresentation];
        SDFlatten(dict, @"defaults", 0, flat);
    } @catch (__unused NSException *e) {}
    for (NSString *s in flat) [allURLs unionOrderedSet:SDExtractURLsFromString(s)];

    // 2. 沙盒 + AppGroup
    NSArray<NSString *> *roots = SDSandboxRoots();
    @try { SDScanFiles(roots, fileLines, yamlFiles, allURLs); } @catch (__unused NSException *e) {}

    // 2b. 把 yaml 整理成可读摘要，并留一份完整文本供「YAML」按钮复制
    NSMutableArray<NSString *> *yamlLines = [NSMutableArray array];
    NSDictionary *bestYAML = nil;
    NSUInteger bestNodes = 0;
    for (NSDictionary *y in yamlFiles) {
        NSUInteger nodes = [y[@"nodes"] unsignedIntegerValue];
        NSString *path = y[@"path"];
        NSString *provURL = y[@"provURL"];
        NSString *providers = y[@"providers"];
        NSString *proxies = y[@"proxies"];

        NSMutableString *e = [NSMutableString string];
        [e appendFormat:@"== %@\n", path];
        [e appendFormat:@"   %.1f KB, proxies 节点 %lu 个\n",
         [y[@"size"] doubleValue] / 1024.0, (unsigned long)nodes];
        if (provURL.length) {
            [e appendFormat:@"   ★ 订阅源 url = %@\n", provURL];
        }
        if (providers.length) {
            [e appendFormat:@"   --- proxy-providers ---\n%@\n", SDTrim(providers, 1200)];
        }
        if (proxies.length) {
            NSArray<NSString *> *names = SDProxyNames(proxies, 40);
            if (names.count) {
                [e appendFormat:@"   节点名: %@%@\n",
                 [names componentsJoinedByString:@", "],
                 nodes > names.count ? @" …" : @""];
            }
            [e appendFormat:@"   --- proxies 前 12 行 ---\n%@\n", SDTrim(proxies, 1200)];
        }
        [yamlLines addObject:e];

        if (nodes > bestNodes) {
            bestNodes = nodes;
            bestYAML = y;
        }
    }
    if (!bestYAML && yamlFiles.count) bestYAML = yamlFiles.firstObject;
    [gLock lock];
    gBestYAML = bestYAML[@"text"] ?: @"";
    [gLock unlock];

    // 3. 响应分类
    NSMutableArray<NSString *> *subLines = [NSMutableArray array];
    NSMutableArray<NSString *> *jsonLines = [NSMutableArray array];
    NSMutableArray<NSString *> *otherLines = [NSMutableArray array];
    for (NSDictionary *c in caps) {
        @try { SDClassifyCapture(c, subLines, jsonLines, otherLines); }
        @catch (__unused NSException *e) {}
    }

    // 4. 候选排序（去噪）
    NSMutableOrderedSet<NSString *> *interesting = [NSMutableOrderedSet orderedSet];
    for (NSString *u in allURLs) {
        if (SDIsNoise(u)) continue;
        [interesting addObject:u];
    }
    for (NSString *line in reqs) {
        NSRange sp = [line rangeOfString:@" "];
        if (sp.location == NSNotFound) continue;
        NSString *u = [line substringFromIndex:sp.location + 1];
        if (!SDIsNoise(u)) [interesting addObject:u];
    }

    NSArray<NSString *> *ranked =
        [[interesting array] sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
            NSInteger sa = SDScore(a), sb = SDScore(b);
            if (sa == sb) return NSOrderedSame;
            return sa > sb ? NSOrderedAscending : NSOrderedDescending;
        }];

    // 5. 关键线索页
    NSMutableString *cand = [NSMutableString string];
    [cand appendString:@"★ 关键线索（先看这里）\n\n"];

    [cand appendFormat:@"【1】NE 配置转储 %lu 条\n", (unsigned long)provs.count];
    if (provs.count == 0) [cand appendString:@"  （没抓到，说明配置是走文件/API 的）\n"];
    for (NSString *p in provs) [cand appendFormat:@"%@\n", SDTrim(p, 3000)];

    [cand appendFormat:@"\n【2】订阅类响应 %lu 条\n", (unsigned long)subLines.count];
    if (subLines.count == 0) [cand appendString:@"  （暂无：进 App 点一次「刷新订阅」再按 🔗）\n"];
    for (NSString *s in subLines) [cand appendFormat:@"%@\n", s];

    [cand appendFormat:@"\n【3】本地 yaml 配置 %lu 个\n", (unsigned long)yamlLines.count];
    if (yamlLines.count == 0) {
        [cand appendString:@"  （没找到 config.yaml，可能还没连过一次 VPN）\n"];
    }
    if (yamlLines.count) {
        [cand appendString:@"  （点顶部「YAML」按钮可复制整份 config.yaml）\n"];
    }
    for (NSString *y in yamlLines) [cand appendFormat:@"%@\n", SDTrim(y, 6000)];

    [cand appendFormat:@"\n【4】面板类 JSON %lu 条\n", (unsigned long)jsonLines.count];
    for (NSString *j in jsonLines) [cand appendFormat:@"%@\n", j];

    [cand appendFormat:@"\n【5】候选链接 %lu 条（已过滤规则集/测速/文档）\n", (unsigned long)ranked.count];
    NSUInteger shown = 0;
    for (NSString *u in ranked) {
        [cand appendFormat:@"%@\n", u];
        if (++shown >= 40) { [cand appendString:@"…（更多见「全部」）\n"]; break; }
    }

    // 6. 全部细节
    NSMutableString *details = [NSMutableString string];
    [details appendFormat:@"SubDump %@   %@   触发=%@\n", SD_VERSION, [NSDate date], reason];
    [details appendFormat:@"扫了 %lu 个根目录\n\n", (unsigned long)roots.count];
    [details appendFormat:@"=== NE providerConfiguration（%lu）===\n", (unsigned long)provs.count];
    for (NSString *p in provs) [details appendFormat:@"%@\n", p];
    [details appendFormat:@"\n=== 订阅类响应（%lu）===\n", (unsigned long)subLines.count];
    for (NSString *s in subLines) [details appendFormat:@"%@\n", s];
    [details appendFormat:@"\n=== 本地 yaml 摘要（%lu）===\n", (unsigned long)yamlLines.count];
    for (NSString *y in yamlLines) [details appendFormat:@"%@\n", y];
    [details appendFormat:@"\n=== 本地 yaml 全文（%lu）===\n", (unsigned long)yamlFiles.count];
    for (NSDictionary *y in yamlFiles) {
        [details appendFormat:@"\n##### %@ #####\n%@\n",
         y[@"path"], SDTrim(y[@"text"], 60 * 1024)];
    }
    [details appendFormat:@"\n=== 面板 JSON（%lu）===\n", (unsigned long)jsonLines.count];
    for (NSString *j in jsonLines) [details appendFormat:@"%@\n", j];
    [details appendFormat:@"\n=== 其它响应（%lu）===\n", (unsigned long)otherLines.count];
    for (NSString *o in otherLines) [details appendFormat:@"%@\n", o];
    [details appendFormat:@"\n=== 网络请求（%lu）===\n", (unsigned long)reqs.count];
    for (NSString *r in reqs) [details appendFormat:@"%@\n", r];
    [details appendFormat:@"\n=== UserDefaults（%lu）===\n", (unsigned long)flat.count];
    for (NSString *f in flat) [details appendFormat:@"%@\n", f];
    [details appendString:@"\n=== 文件命中 ===\n"];
    for (NSString *f in fileLines) [details appendFormat:@"%@\n", f];
    [details appendFormat:@"\n=== 全部 URL（%lu）===\n", (unsigned long)allURLs.count];
    for (NSString *u in allURLs) [details appendFormat:@"%@\n", u];

    // 7. 剪贴板：把最有把握的东西放前面
    NSMutableArray<NSString *> *clip = [NSMutableArray array];
    for (NSString *u in ranked) {
        if (SDScore(u) >= 10) [clip addObject:u];
    }
    if (clip.count == 0) {
        for (NSString *u in ranked) {
            [clip addObject:u];
            if (clip.count >= 5) break;
        }
    }
    if (clip.count) {
        @try { UIPasteboard.generalPasteboard.string = [clip componentsJoinedByString:@"\n"]; }
        @catch (__unused NSException *e) {}
    }

    NSString *candText = [cand copy];
    NSString *detailText = [details copy];
    dispatch_async(dispatch_get_main_queue(), ^{
        SDShowReport(candText, detailText);
    });

    SDLog(@"scan done: yaml=%lu sub=%lu json=%lu other=%lu cand=%lu ne=%lu",
          (unsigned long)yamlLines.count, (unsigned long)subLines.count,
          (unsigned long)jsonLines.count, (unsigned long)otherLines.count,
          (unsigned long)ranked.count, (unsigned long)provs.count);
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
        gProviderCfgs = [NSMutableArray array];

        @try { SDInstallHooks(); } @catch (__unused NSException *e) {}

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            @try { SDInstallButton(); } @catch (__unused NSException *e) {}
            @try { SDInstallNEHook(); } @catch (__unused NSException *e) {}   // NE 框架可能此时才加载
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                @try { SDRunScan(@"auto"); } @catch (__unused NSException *e) {}
            });
        });
    });
}
