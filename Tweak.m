// AMFix: makes a re-signed Alight Motion report its original bundle ID.
// Build with the included GitHub Actions workflow (needs fishhook.c/.h, fetched there).

#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <objc/runtime.h>
#include "fishhook.h"

static NSString *const kOrigID = @"com.alightcreative.motion";

#pragma mark - Logging (written to Documents/amfix.log, visible in the Files app)

static void AMLog(NSString *fmt, ...) {
    static __thread BOOL busy = NO;
    if (busy) return;
    busy = YES;
    va_list args;
    va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);

    static NSString *path;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        path = [docs stringByAppendingPathComponent:@"amfix.log"];
    });
    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], msg];
    NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!h) {
        [line writeToFile:path atomically:NO encoding:NSUTF8StringEncoding error:nil];
    } else {
        [h seekToEndOfFile];
        [h writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [h closeFile];
    }
    busy = NO;
}

#pragma mark - Objective-C hooks (NSBundle)

static IMP orig_bundleIdentifier, orig_objectForInfoDictionaryKey, orig_infoDictionary;

static NSString *new_bundleIdentifier(id self, SEL _cmd) {
    if (self == NSBundle.mainBundle) return kOrigID;
    return ((NSString *(*)(id, SEL))orig_bundleIdentifier)(self, _cmd);
}

static id new_objectForInfoDictionaryKey(id self, SEL _cmd, NSString *key) {
    if (self == NSBundle.mainBundle && [key isEqualToString:@"CFBundleIdentifier"]) return kOrigID;
    return ((id (*)(id, SEL, NSString *))orig_objectForInfoDictionaryKey)(self, _cmd, key);
}

static NSDictionary *new_infoDictionary(id self, SEL _cmd) {
    NSDictionary *d = ((NSDictionary *(*)(id, SEL))orig_infoDictionary)(self, _cmd);
    if (self == NSBundle.mainBundle && d) {
        static NSDictionary *patched;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            NSMutableDictionary *m = [d mutableCopy];
            m[@"CFBundleIdentifier"] = kOrigID;
            patched = [m copy];
        });
        return patched;
    }
    return d;
}

#pragma mark - C hooks (CoreFoundation)

static CFStringRef (*orig_CFBundleGetIdentifier)(CFBundleRef);
static CFStringRef my_CFBundleGetIdentifier(CFBundleRef b) {
    if (b == CFBundleGetMainBundle()) return (__bridge CFStringRef)kOrigID;
    return orig_CFBundleGetIdentifier(b);
}

static CFTypeRef (*orig_CFBundleGetValueForInfoDictionaryKey)(CFBundleRef, CFStringRef);
static CFTypeRef my_CFBundleGetValueForInfoDictionaryKey(CFBundleRef b, CFStringRef key) {
    if (b == CFBundleGetMainBundle() && key && CFEqual(key, CFSTR("CFBundleIdentifier")))
        return (__bridge CFStringRef)kOrigID;
    return orig_CFBundleGetValueForInfoDictionaryKey(b, key);
}

#pragma mark - Keychain hooks (drop hard-coded access groups that don't exist on a re-signed app)

static CFDictionaryRef AMStrip(CFDictionaryRef d) {
    if (!d) return NULL;
    CFMutableDictionaryRef m = CFDictionaryCreateMutableCopy(NULL, 0, d);
    CFDictionaryRemoveValue(m, kSecAttrAccessGroup);
    return m; // caller releases
}

static void AMCheck(const char *fn, OSStatus s) {
    if (s != errSecSuccess && s != errSecItemNotFound && s != errSecDuplicateItem)
        AMLog(@"%s failed: OSStatus %d", fn, (int)s);
}

static OSStatus (*orig_SecItemAdd)(CFDictionaryRef, CFTypeRef *);
static OSStatus my_SecItemAdd(CFDictionaryRef a, CFTypeRef *r) {
    CFDictionaryRef c = AMStrip(a);
    OSStatus s = orig_SecItemAdd(c, r);
    if (c) CFRelease(c);
    AMCheck("SecItemAdd", s);
    return s;
}

static OSStatus (*orig_SecItemCopyMatching)(CFDictionaryRef, CFTypeRef *);
static OSStatus my_SecItemCopyMatching(CFDictionaryRef q, CFTypeRef *r) {
    CFDictionaryRef c = AMStrip(q);
    OSStatus s = orig_SecItemCopyMatching(c, r);
    if (c) CFRelease(c);
    AMCheck("SecItemCopyMatching", s);
    return s;
}

static OSStatus (*orig_SecItemUpdate)(CFDictionaryRef, CFDictionaryRef);
static OSStatus my_SecItemUpdate(CFDictionaryRef q, CFDictionaryRef u) {
    CFDictionaryRef cq = AMStrip(q);
    CFDictionaryRef cu = AMStrip(u);
    OSStatus s = orig_SecItemUpdate(cq, cu);
    if (cq) CFRelease(cq);
    if (cu) CFRelease(cu);
    AMCheck("SecItemUpdate", s);
    return s;
}

static OSStatus (*orig_SecItemDelete)(CFDictionaryRef);
static OSStatus my_SecItemDelete(CFDictionaryRef q) {
    CFDictionaryRef c = AMStrip(q);
    OSStatus s = orig_SecItemDelete(c);
    if (c) CFRelease(c);
    AMCheck("SecItemDelete", s);
    return s;
}

#pragma mark - Entry point

static void swizzle(Class c, SEL sel, IMP imp, IMP *orig) {
    Method m = class_getInstanceMethod(c, sel);
    if (m) *orig = method_setImplementation(m, imp);
}

__attribute__((constructor)) static void AMFixInit(void) {
    swizzle(NSBundle.class, @selector(bundleIdentifier), (IMP)new_bundleIdentifier, &orig_bundleIdentifier);
    swizzle(NSBundle.class, @selector(objectForInfoDictionaryKey:), (IMP)new_objectForInfoDictionaryKey, &orig_objectForInfoDictionaryKey);
    swizzle(NSBundle.class, @selector(infoDictionary), (IMP)new_infoDictionary, &orig_infoDictionary);

    struct rebinding rebs[] = {
        {"CFBundleGetIdentifier", my_CFBundleGetIdentifier, (void *)&orig_CFBundleGetIdentifier},
        {"CFBundleGetValueForInfoDictionaryKey", my_CFBundleGetValueForInfoDictionaryKey, (void *)&orig_CFBundleGetValueForInfoDictionaryKey},
        {"SecItemAdd", my_SecItemAdd, (void *)&orig_SecItemAdd},
        {"SecItemCopyMatching", my_SecItemCopyMatching, (void *)&orig_SecItemCopyMatching},
        {"SecItemUpdate", my_SecItemUpdate, (void *)&orig_SecItemUpdate},
        {"SecItemDelete", my_SecItemDelete, (void *)&orig_SecItemDelete},
    };
    rebind_symbols(rebs, sizeof(rebs) / sizeof(rebs[0]));

    AMLog(@"AMFix loaded. Real bundle ID: %@", ((NSString *(*)(id, SEL))orig_bundleIdentifier)(NSBundle.mainBundle, @selector(bundleIdentifier)));
}
