// AMFix lite: only spoofs the main bundle ID via two NSBundle methods.
// No keychain hooks, no fishhook, no infoDictionary replacement.
// Logs which library asks for the ID so we can see who reads it.
// Replace the contents of Tweak.m with this file; the workflow stays the same.

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <dlfcn.h>

static NSString *const kOrigID = @"com.alightcreative.motion";
static IMP orig_bundleIdentifier, orig_objectForInfoDictionaryKey;
static int logCount = 0;

static void AMLog(NSString *line) {
    static NSString *path;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        path = [docs stringByAppendingPathComponent:@"amfix.log"];
    });
    NSString *out = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], line];
    NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!h) {
        [out writeToFile:path atomically:NO encoding:NSUTF8StringEncoding error:nil];
    } else {
        [h seekToEndOfFile];
        [h writeData:[out dataUsingEncoding:NSUTF8StringEncoding]];
        [h closeFile];
    }
}

static void logCaller(const char *what, void *ret) {
    static __thread BOOL busy = NO;
    if (busy || logCount >= 40) return;
    busy = YES;
    logCount++;
    Dl_info info;
    const char *img = (dladdr(ret, &info) && info.dli_fname) ? info.dli_fname : "?";
    const char *slash = strrchr(img, '/');
    AMLog([NSString stringWithFormat:@"%s read by %s", what, slash ? slash + 1 : img]);
    busy = NO;
}

static NSString *new_bundleIdentifier(id self, SEL _cmd) {
    if (self == NSBundle.mainBundle) {
        logCaller("bundleIdentifier", __builtin_return_address(0));
        return kOrigID;
    }
    return ((NSString *(*)(id, SEL))orig_bundleIdentifier)(self, _cmd);
}

static id new_objectForInfoDictionaryKey(id self, SEL _cmd, NSString *key) {
    if (self == NSBundle.mainBundle && [key isEqualToString:@"CFBundleIdentifier"]) {
        logCaller("objectForInfoDictionaryKey:CFBundleIdentifier", __builtin_return_address(0));
        return kOrigID;
    }
    return ((id (*)(id, SEL, NSString *))orig_objectForInfoDictionaryKey)(self, _cmd, key);
}

static IMP orig_bundleWithIdentifier;
static NSBundle *new_bundleWithIdentifier(id self, SEL _cmd, NSString *ident) {
    if ([ident isEqualToString:kOrigID]) {
        logCaller("bundleWithIdentifier:", __builtin_return_address(0));
        return NSBundle.mainBundle;
    }
    return ((NSBundle *(*)(id, SEL, NSString *))orig_bundleWithIdentifier)(self, _cmd, ident);
}

__attribute__((constructor)) static void AMFixLiteInit(void) {
    Method m3 = class_getClassMethod(NSBundle.class, @selector(bundleWithIdentifier:));
    if (m3) orig_bundleWithIdentifier = method_setImplementation(m3, (IMP)new_bundleWithIdentifier);

    Method m1 = class_getInstanceMethod(NSBundle.class, @selector(bundleIdentifier));
    if (m1) orig_bundleIdentifier = method_setImplementation(m1, (IMP)new_bundleIdentifier);
    Method m2 = class_getInstanceMethod(NSBundle.class, @selector(objectForInfoDictionaryKey:));
    if (m2) orig_objectForInfoDictionaryKey = method_setImplementation(m2, (IMP)new_objectForInfoDictionaryKey);

    NSString *real = orig_bundleIdentifier
        ? ((NSString *(*)(id, SEL))orig_bundleIdentifier)(NSBundle.mainBundle, @selector(bundleIdentifier))
        : @"?";
    AMLog([NSString stringWithFormat:@"AMFix lite loaded. Real bundle ID: %@", real]);
}
