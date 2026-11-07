// AMFix no-op: hooks nothing. Only writes one line to Documents/amfix.log.
// Purpose: find out whether merely injecting an extra dylib makes the app crash.

#import <Foundation/Foundation.h>

__attribute__((constructor)) static void AMFixNoopInit(void) {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *path = [docs stringByAppendingPathComponent:@"amfix-noop.log"];
    NSString *line = [NSString stringWithFormat:@"%@ noop dylib loaded\n", [NSDate date]];
    NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!h) {
        [line writeToFile:path atomically:NO encoding:NSUTF8StringEncoding error:nil];
    } else {
        [h seekToEndOfFile];
        [h writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [h closeFile];
    }
}
