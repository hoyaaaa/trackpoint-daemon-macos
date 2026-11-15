/* GitHub stable releases are the only update authority. Release metadata never supplies executable commands. */
static NSArray<NSNumber *> *version_parts(NSString *value) {
    if (![value isKindOfClass:NSString.class]) return nil;
    NSRegularExpression *pattern = [NSRegularExpression regularExpressionWithPattern:
        @"\\A(0|[1-9][0-9]{0,8})\\.(0|[1-9][0-9]{0,8})\\.(0|[1-9][0-9]{0,8})\\z" options:0 error:NULL];
    if ([pattern numberOfMatchesInString:value options:0 range:NSMakeRange(0,value.length)] != 1) return nil;
    NSArray *parts = [value componentsSeparatedByString:@"."];
    return @[@([parts[0] integerValue]), @([parts[1] integerValue]), @([parts[2] integerValue])];
}
static NSDictionary *available_release(id payload, NSString *current, NSString **error) {
    if (error) *error = nil;
    if (![payload isKindOfClass:NSDictionary.class] || !version_parts(current)) {
        if (error) *error = @"Invalid release information.";
        return nil;
    }
    NSDictionary *release = payload;
    NSString *tag = release[@"tag_name"];
    if (![tag isKindOfClass:NSString.class] || ![tag hasPrefix:@"v"] ||
        !version_parts([tag substringFromIndex:1]) ||
        ![release[@"draft"] isKindOfClass:NSNumber.class] ||
        ![release[@"prerelease"] isKindOfClass:NSNumber.class] ||
        [release[@"draft"] boolValue] || [release[@"prerelease"] boolValue]) {
        if (error) *error = @"The server did not return a stable release.";
        return nil;
    }
    NSString *version = [tag substringFromIndex:1];
    NSArray *remote = version_parts(version), *local = version_parts(current);
    for (NSUInteger i=0; i<3; i++) {
        NSComparisonResult comparison = [remote[i] compare:local[i]];
        if (comparison == NSOrderedAscending) return nil;
        if (comparison == NSOrderedDescending)
            return @{@"version":version, @"url":[@"https://github.com/hoyaaaa/trackpoint-daemon-macos/releases/tag/" stringByAppendingString:tag],
                @"notes":[release[@"body"] isKindOfClass:NSString.class] ? release[@"body"] : @""};
    }
    return nil;
}
