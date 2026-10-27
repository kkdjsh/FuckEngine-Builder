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
        NSArray *networkRules = nil;
        if ([obj isKindOfClass:[NSArray class]]) {
            hooks = (NSArray *)obj;
        } else if ([obj isKindOfClass:[NSDictionary class]]) {
            hooks = obj[@"hooks"];
            networkRules = obj[@"networkRules"];
        }

        for (NSDictionary *h in hooks) {
            @try { apply_single_hook(h); } @catch (__unused NSException *e) {}
        }

        // 启用网络正则替换
        if (networkRules) {
            @try { enable_network_hook(networkRules); } @catch (__unused NSException *e) {}
        }
    }
}

#pragma mark - 网络响应拦截（正则替换）
static NSArray *g_networkRules = nil;
static IMP g_orig_dataTask = NULL;

// 对响应数据应用正则替换
static NSData *apply_regex_rules(NSData *data, NSURLRequest *req) {
    NSString *url = req.URL.absoluteString;
    NSString *body = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!body) return data;

    BOOL modified = NO;
    for (NSDictionary *group in g_networkRules) {
        NSString *domain = group[@"domain"];
        if (domain && [url containsString:domain]) {
            for (NSDictionary *rule in group[@"rules"]) {
                NSString *key = rule[@"key"];
                NSString *value = rule[@"value"];
                if (key && value) {
                    NSRegularExpression *re = [NSRegularExpression
                        regularExpressionWithPattern:key options:0 error:nil];
                    if (re) {
                        body = [re stringByReplacingMatchesInString:body
                            options:0 range:NSMakeRange(0, body.length)
                            withTemplate:value];
                        modified = YES;
                    }
                }
            }
        }
    }
    return modified ? [body dataUsingEncoding:NSUTF8StringEncoding] : data;
}

static id goat_dataTask_hook(id self, SEL _cmd, NSURLRequest *req, id completion) {
    id wrapped = ^(NSData *data, NSURLResponse *resp, NSError *err) {
        if (data && !err && g_networkRules) {
            @try { data = apply_regex_rules(data, req); } @catch (__unused NSException *e) {}
        }
        typedef void (^cb_t)(NSData *, NSURLResponse *, NSError *);
        ((cb_t)completion)(data, resp, err);
    };
    typedef id (*orig_fn)(id, SEL, id, id);
    return ((orig_fn)g_orig_dataTask)(self, _cmd, req, wrapped);
}

static void enable_network_hook(NSArray *rules) {
    if (!rules || rules.count == 0) return;
    g_networkRules = rules;
    Class cls = NSClassFromString(@"NSURLSession");
    if (!cls) return;
    SEL sel = @selector(dataTaskWithRequest:completionHandler:);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    g_orig_dataTask = method_getImplementation(m);
    method_setImplementation(m, (IMP)goat_dataTask_hook);
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
