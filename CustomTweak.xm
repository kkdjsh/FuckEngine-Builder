#import <Foundation/Foundation.h>
#import <objc/runtime.h>

__attribute__((constructor))
static void Entry(void) {
    @autoreleasepool {
        Class cls = objc_getClass("VCSettingsConfig");
        if (!cls) return;
        
        Method m = class_getInstanceMethod(cls, @selector(shouldShowAds));
        if (m) {
            IMP newImp = imp_implementationWithBlock(^(id _self) { return NO; });
            method_setImplementation(m, newImp);
        }
        
        Method m2 = class_getInstanceMethod(cls, @selector(haveVideoCompressEverPayment));
        if (m2) {
            IMP newImp2 = imp_implementationWithBlock(^(id _self) { return YES; });
            method_setImplementation(m2, newImp2);
        }
    }
}