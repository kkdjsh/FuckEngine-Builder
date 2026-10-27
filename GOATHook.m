//
//  GOATHook.m
//  纯 C 函数 IMP + 网络 Mock 版本
//

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dispatch/dispatch.h>
#import <string.h>

#pragma mark - 节段定义
__attribute__((used, section("__DATA,__goat_cr")))
static char g_copyright[0x400] = "@@GOATHOOK_COPYRIGHT@@";

__attribute__((used, section("__DATA,__goat_dl")))
static char g_delay[0x40] = "@@GOATHOOK_DELAY@@";

__attribute__((used, section("__DATA,__goat_hk")))
static char g_hooks_json[0x10000] = "@@GOATHOOK_HOOKCONFIG@@";

#pragma mark - 纯 C 函数 IMP（不使用 block，签名注入环境稳定）
// void 返回
static void goat_void_0(id self, SEL _cmd) {}
static void goat_void_1(id self, SEL _cmd, id a1) {}
static void goat_void_2(id self, SEL _cmd, id a1, id a2) {}

// BOOL 返回 NO
static BOOL goat_bool_no_0(id self, SEL _cmd) { return NO; }
static BOOL goat_bool_no_1(id self, SEL _cmd, id a1) { return NO; }
static BOOL goat_bool_no_2(id self, SEL _cmd, id a1, id a2) { return NO; }

// BOOL 返回 YES
static BOOL goat_bool_yes_0(id self, SEL _cmd) { return YES; }
static BOOL goat_bool_yes_1(id self, SEL _cmd, id a1) { return YES; }

// id 返回 nil
static id goat_id_nil_0(id self, SEL _cmd) { return nil; }
static id goat_id_nil_1(id self, SEL _cmd, id a1) { return nil; }
static id goat_id_nil_2(id self, SEL _cmd, id a1, id a2) { return nil; }

// NSInteger 返回 0
static NSInteger goat_int_0_0(id self, SEL _cmd) { return 0; }
static NSInteger goat_int_0_1(id self, SEL _cmd, id a1) { return 0; }

#pragma mark - IMP 选择器
static int count_params(Method method) {
    return method_getNumberOfArguments(method) - 2;
}

static IMP pick_imp(char ret_type, int nparams, id constant) {
    int np = nparams;
    if (np > 2) np = 2;

    switch (ret_type) {
        case 'v':  // void
            if (np == 0) return (IMP)goat_void_0;
            if (np == 1) return (IMP)goat_void_1;
            return (IMP)goat_void_2;

        case 'B':  // BOOL
        case 'c': { // signed char (old BOOL)
            BOOL v = [constant boolValue];
            if (v) {
                if (np == 0) return (IMP)goat_bool_yes_0;
                return (IMP)goat_bool_yes_1;
            } else {
                if (np == 0) return (IMP)goat_bool_no_0;
                if (np == 1) return (IMP)goat_bool_no_1;
                return (IMP)goat_bool_no_2;
            }
        }

        case 'i': case 's': case 'l': case 'q':  // integer types
            if (np == 0) return (IMP)goat_int_0_0;
            return (IMP)goat_int_0_1;

        case 'f': case 'd':  // float/double - return 0
            if (np == 0) return (IMP)goat_int_0_0;
            return (IMP)goat_int_0_1;

        default:  // id, objects, blocks, structs
            if (np == 0) return (IMP)goat_id_nil_0;
            if (np == 1) return (IMP)goat_id_nil_1;
            return (IMP)goat_id_nil_2;
    }
}

#pragma mark - 单条 Hook 应用
static void apply_single_hook(NSDictionary *hook) {
    NSString *class_name  = hook[@"className"];
    NSString *method_name = hook[@"methodName"];
    BOOL is_class_method  = [hook[@"isClassMethod"] boolValue];
    id hook_value         = hook[@"hookValue"];
    BOOL enabled          = YES;
    if (hook[@"enabled"]) enabled = [hook[@"enabled"] boolValue];

    if (!enabled) return;
    if (!class_name || !method_name) return;

    Class cls = NSClassFromString(class_name);
    if (!cls) return;

    SEL sel = NSSelectorFromString(method_name);
    Method m = is_class_method
        ? class_getClassMethod(cls, sel)
        : class_getInstanceMethod(cls, sel);

    if (!m) return;

    const char *ret_type = method_copyReturnType(m);
    int nparams = count_params(m);
    IMP new_imp = pick_imp(ret_type[0], nparams, hook_value);
    free((void *)ret_type);

    method_setImplementation(m, new_imp);
}

#pragma mark - 批量应用
static void apply_all_hooks(void) {
    @autoreleasepool {
        NSData *json_data = [NSData dataWithBytesNoCopy:g_hooks_json
                                                 length:strnlen(g_hooks_json, sizeof(g_hooks_json))
                                           freeWhenDone:NO];
        NSError *error = nil;
        id obj = [NSJSONSerialization JSONObjectWithData:json_data
                                                 options:0
                                                   error:&error];
        if (!obj) return;

        NSArray *hooks = nil;
        NSArray *mocks = nil;
        if ([obj isKindOfClass:[NSArray class]]) {
            hooks = (NSArray *)obj;
        } else if ([obj isKindOfClass:[NSDictionary class]]) {
            hooks = obj[@"hooks"];
            mocks = obj[@"networkMocks"];
        }

        for (NSDictionary *h in hooks) {
            @try { apply_single_hook(h); } @catch (__unused NSException *e) {}
        }

        // 应用网络 mock
        if (mocks) {
            @try { apply_network_mocks(mocks); } @catch (__unused NSException *e) {}
        }
    }
}

#pragma mark - 网络 Mock
static NSArray *g_mocks = nil;
static IMP g_orig_dataTask = NULL;

// 替换 NSURLSession dataTaskWithRequest:completionHandler: 的 IMP
static id goat_dataTask_mock(id self, SEL _cmd, NSURLRequest *req, void (^completion)(NSData *, NSURLResponse *, NSError *)) {
    // 检查 URL 是否匹配 mock
    NSString *url = req.URL.absoluteString;
    for (NSDictionary *mock in g_mocks) {
        NSString *pattern = mock[@"urlContains"];
        if (pattern && [url containsString:pattern]) {
            // 匹配到了，直接返回假响应
            NSString *body = mock[@"responseBody"] ?: @"{}";
            NSData *data = [body dataUsingEncoding:NSUTF8StringEncoding];
            NSInteger code = [mock[@"statusCode"] integerValue] ?: 200;
            NSHTTPURLResponse *resp = [[NSHTTPURLResponse alloc]
                initWithURL:req.URL statusCode:code HTTPVersion:@"1.1"
                headerFields:@{@"Content-Type": @"application/json"}];
            // 异步调用 completion，模拟网络延迟
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.1 * NSEC_PER_SEC),
                           dispatch_get_main_queue(), ^{
                if (completion) completion(data, resp, nil);
            });
            // 返回一个空的 dataTask（不真发请求）
            // 调用原始方法取消它
            typedef id (*dt_fn)(id, SEL, NSURLRequest *, void (^)(NSData *, NSURLResponse *, NSError *));
            dt_fn orig = (dt_fn)g_orig_dataTask;
            id task = orig(self, _cmd, req, ^(NSData *d, NSURLResponse *r, NSError *e) {});
            return task;
        }
    }
    // 不匹配，走原始方法
    typedef id (*dt_fn)(id, SEL, NSURLRequest *, void (^)(NSData *, NSURLResponse *, NSError *));
    dt_fn orig = (dt_fn)g_orig_dataTask;
    return orig(self, _cmd, req, completion);
}

static void apply_network_mocks(NSArray *mocks) {
    if (!mocks || mocks.count == 0) return;
    g_mocks = mocks;

    // swizzle NSURLSession dataTaskWithRequest:completionHandler:
    Class cls = NSClassFromString(@"NSURLSession");
    if (!cls) return;
    SEL sel = @selector(dataTaskWithRequest:completionHandler:);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;

    g_orig_dataTask = method_getImplementation(m);
    method_setImplementation(m, (IMP)goat_dataTask_mock);
}
__attribute__((constructor))
static void GOATHookEntry(void) {
    @autoreleasepool {
        double delay = atof(g_delay);
        if (delay <= 0) delay = 0.3;
        if (delay > 1.0) delay = 0.3;  // 强制短延迟，避免广告先加载完

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            apply_all_hooks();
        });
    }
}
