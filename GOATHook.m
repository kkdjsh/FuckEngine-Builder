//
//  GOATHook.m
//  健壮版 Hook 壳 dylib（TrollStore / 全能签注入用）
//
//  特性：
//  1. 正确处理所有返回类型：void / BOOL / int / long / float / double / id
//  2. 每条 hook 独立 @try/@catch，单条失败不影响其他
//  3. 类/方法不存在时跳过并打日志，不崩溃
//  4. 延迟启动，让宿主 App 先初始化完
//  5. 配置从 __DATA 自定义节段读取，生成器直接二进制替换
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
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

#pragma mark - 返回常量 IMP 工厂
static IMP make_return_constant_imp(Method method, id constant) {
    const char *ret_type = method_copyReturnType(method);
    char t = ret_type[0];
    free((void *)ret_type);

    switch (t) {
        case 'v':
            return imp_implementationWithBlock(^(id self, SEL _cmd) {});

        case 'B':
        case 'c': {
            BOOL v = [constant boolValue];
            return imp_implementationWithBlock(^BOOL(id self, SEL _cmd) { return v; });
        }
        case 'i': {
            int v = [constant intValue];
            return imp_implementationWithBlock(^int(id self, SEL _cmd) { return v; });
        }
        case 's': {
            short v = [constant shortValue];
            return imp_implementationWithBlock(^short(id self, SEL _cmd) { return v; });
        }
        case 'l': {
            long v = [constant longValue];
            return imp_implementationWithBlock(^long(id self, SEL _cmd) { return v; });
        }
        case 'q': {
            long long v = [constant longLongValue];
            return imp_implementationWithBlock(^long long(id self, SEL _cmd) { return v; });
        }
        case 'f': {
            float v = [constant floatValue];
            return imp_implementationWithBlock(^float(id self, SEL _cmd) { return v; });
        }
        case 'd': {
            double v = [constant doubleValue];
            return imp_implementationWithBlock(^double(id self, SEL _cmd) { return v; });
        }
        case '[': case '{': case '(':
            return imp_implementationWithBlock(^id(id self, SEL _cmd) { return nil; });

        default: {
            id val = constant;
            return imp_implementationWithBlock(^id(id self, SEL _cmd) { return val; });
        }
    }
}

#pragma mark - 单条 Hook 应用
static void apply_single_hook(NSDictionary *hook) {
    NSString *class_name  = hook[@"className"];
    NSString *method_name = hook[@"methodName"];
    BOOL is_class_method  = [hook[@"isClassMethod"] boolValue];
    NSString *hook_type   = hook[@"hookType"];
    id hook_value         = hook[@"hookValue"];
    BOOL enabled          = YES;
    if (hook[@"enabled"]) enabled = [hook[@"enabled"] boolValue];

    if (!enabled) return;
    if (!class_name || !method_name) return;

    Class cls = NSClassFromString(class_name);
    if (!cls) {
        NSLog(@"[GOATHook] class not found: %@", class_name);
        return;
    }

    SEL sel = NSSelectorFromString(method_name);
    Method m = is_class_method
        ? class_getClassMethod(cls, sel)
        : class_getInstanceMethod(cls, sel);

    if (!m) {
        NSLog(@"[GOATHook] method not found: %@.%@", class_name, method_name);
        return;
    }

    if (!hook_type || [hook_type isEqualToString:@"returnConstant"]) {
        IMP new_imp = make_return_constant_imp(m, hook_value);
        method_setImplementation(m, new_imp);
        NSLog(@"[GOATHook] OK: %@.%@", class_name, method_name);
    }
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
        if (!obj) {
            NSLog(@"[GOATHook] JSON parse error: %@", error);
            return;
        }

        NSArray *hooks = nil;
        if ([obj isKindOfClass:[NSArray class]]) {
            hooks = (NSArray *)obj;
        } else if ([obj isKindOfClass:[NSDictionary class]]) {
            hooks = obj[@"hooks"];
        }

        NSLog(@"[GOATHook] applying %lu hooks", (unsigned long)hooks.count);

        int ok = 0, fail = 0;
        for (NSDictionary *h in hooks) {
            @try {
                apply_single_hook(h);
                ok++;
            } @catch (NSException *e) {
                NSLog(@"[GOATHook] exception: %@", e.reason);
                fail++;
            }
        }
        NSLog(@"[GOATHook] done: %d ok, %d fail", ok, fail);

        // 弹窗显示结果（debug 用，3秒后自动消失）
        NSString *msg = [NSString stringWithFormat:@"GOATHook\n成功 %d / 共 %lu 条",
                         ok, (unsigned long)hooks.count];
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"GOATHook"
                                                                        message:msg
                                                                 preferredStyle:UIAlertControllerStyleAlert];
        UIViewController *top = [UIApplication sharedApplication].keyWindow.rootViewController;
        while (top.presentedViewController) top = top.presentedViewController;
        [top presentViewController:alert animated:YES completion:^{
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC),
                           dispatch_get_main_queue(), ^{
                [alert dismissViewControllerAnimated:YES completion:nil];
            });
        }];
    }
}

#pragma mark - 构造器
__attribute__((constructor))
static void GOATHookEntry(void) {
    @autoreleasepool {
        double delay = atof(g_delay);
        if (delay <= 0) delay = 0.5;

        NSLog(@"[GOATHook] loaded, delay=%.1fs", delay);

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            apply_all_hooks();
        });
    }
}
