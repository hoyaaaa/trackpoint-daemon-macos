#import <Foundation/Foundation.h>
#import "../updates.h"
static NSDictionary *release(NSString *tag) {
    return @{@"tag_name":tag,@"draft":@NO,@"prerelease":@NO,@"body":@"Changes",@"html_url":@"https://untrusted.example/"};
}
int main(void) {
    @autoreleasepool {
        for (NSString *invalid in @[@"",@"2.3",@"2.3.0-beta",@"v2.3.0",@"02.3.0",@"2.3.0\n",@"-1.2.3",@"9999999999.0.0"])
            assert(!version_parts(invalid));
        assert(!version_parts((id)@1));
        NSString *error=nil;
        NSDictionary *update=available_release(release(@"v2.10.0"),@"2.9.9",&error);
        assert(update && !error);
        assert([update[@"url"] isEqual:@"https://github.com/hoyaaaa/trackpoint-daemon-macos/releases/tag/v2.10.0"]);
        assert([update[@"notes"] isEqual:@"Changes"]);
        assert(!available_release(release(@"v2.3.0"),@"2.3.0",&error) && !error);
        assert(!available_release(release(@"v2.2.99"),@"2.3.0",&error) && !error);
        assert(available_release(release(@"v3.0.0"),@"2.99.99",&error));
        assert(available_release(release(@"v2.3.1"),@"2.3.0",&error));
        for (id invalid in @[@[],[NSNull null],@{},@{@"tag_name":@3},release(@"v2.3.0-rc1")]) {
            assert(!available_release(invalid,@"2.3.0",&error) && error);
        }
        for (NSString *flag in @[@"draft",@"prerelease"]) {
            NSMutableDictionary *draft=[release(@"v3.0.0") mutableCopy]; draft[flag]=@YES;
            assert(!available_release(draft,@"2.3.0",&error) && error);
        }
        NSMutableDictionary *missing=[release(@"v3.0.0") mutableCopy]; [missing removeObjectForKey:@"draft"];
        assert(!available_release(missing,@"2.3.0",&error) && error);
        assert(!available_release(release(@"v3.0.0"),@"broken",&error) && error);
        missing=[release(@"v3.0.0") mutableCopy]; missing[@"body"]=@4;
        assert([available_release(missing,@"2.3.0",&error)[@"notes"] isEqual:@""]);
        puts("release version/comparison tests: ok");
    }
}
