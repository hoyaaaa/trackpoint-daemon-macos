#import <Cocoa/Cocoa.h>
#import "../updates.h"
#import "../upgrade.h"
static NSDictionary *release(NSString *tag) {
    return @{@"tag_name":tag,@"draft":@NO,@"prerelease":@NO,@"body":@"Changes",@"html_url":@"https://untrusted.example/"};
}
static void test_rendered_notes(void) {
    NSAttributedString *notes=render_release_notes(@"### Fixed\n- **Better** scrolling across\n  wrapped source lines.\n- Use `brew`.\n\n1. First\n2. Second\n   - Nested\n\n[Website](https://example.com) ![Image](https://example.com/image.png)");
    assert([notes.string hasPrefix:@"Fixed\n•\tBetter scrolling across wrapped source lines."]);
    assert([notes.string containsString:@"•\tUse brew."]);
    assert([notes.string containsString:@"1.\tFirst\n2.\tSecond\n•\tNested"]);
    NSFont *heading=[notes attribute:NSFontAttributeName atIndex:0 effectiveRange:NULL];
    assert(heading.pointSize>13 && (heading.fontDescriptor.symbolicTraits & NSFontDescriptorTraitBold));
    NSRange bold=[notes.string rangeOfString:@"Better"];
    NSFont *boldFont=[notes attribute:NSFontAttributeName atIndex:bold.location effectiveRange:NULL];
    assert(boldFont.fontDescriptor.symbolicTraits & NSFontDescriptorTraitBold);
    NSParagraphStyle *bullet=[notes attribute:NSParagraphStyleAttributeName atIndex:bold.location effectiveRange:NULL];
    NSRange nested=[notes.string rangeOfString:@"Nested"];
    NSParagraphStyle *nestedStyle=[notes attribute:NSParagraphStyleAttributeName atIndex:nested.location effectiveRange:NULL];
    assert(bullet.headIndent>bullet.firstLineHeadIndent && nestedStyle.firstLineHeadIndent>bullet.firstLineHeadIndent);
    NSRange code=[notes.string rangeOfString:@"brew"];
    NSFont *codeFont=[notes attribute:NSFontAttributeName atIndex:code.location effectiveRange:NULL];
    assert(codeFont.fontDescriptor.symbolicTraits & NSFontDescriptorTraitMonoSpace);
    for (NSUInteger i=0;i<notes.length;i++) {
        assert(![notes attribute:NSLinkAttributeName atIndex:i effectiveRange:NULL]);
        assert(![notes attribute:NSAttachmentAttributeName atIndex:i effectiveRange:NULL]);
    }
    assert([render_release_notes(@"\n ").string isEqual:@"No release notes were provided."]);
    assert([render_release_notes(@"# One\n\n## Two\n\nText").string isEqual:@"One\nTwo\nText"]);
    assert([render_release_notes(@"```\n# literal\n- literal\n```").string containsString:@"# literal\n- literal"]);
    NSScrollView *view=release_notes_view(@"## Title\n- Item");
    NSTextView *text=(NSTextView *)view.documentView;
    assert(!text.editable && [text.string isEqual:@"Title\n•\tItem"]);
    NSTextView *log=(NSTextView *)plain_text_view(@"### Keep raw\n- log entry").documentView;
    assert([log.string isEqual:@"### Keep raw\n- log entry"]);
}
int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        test_rendered_notes();
        for (NSString *invalid in @[@"",@"2.3",@"2.3.0-beta",@"v2.3.0",@"02.3.0",@"2.3.0\n",@"-1.2.3",@"9999999999.0.0"])
            assert(!version_parts(invalid));
        assert(!version_parts((id)@1));
        assert([homebrew_installation(@"/opt/homebrew/Cellar/trackpointd/9.0.0/TrackPointD.app")[@"prefix"] isEqual:@"/opt/homebrew"]);
        assert([homebrew_installation(@"/usr/local/Cellar/trackpointd/9.0.0/TrackPointD.app")[@"brew"] isEqual:@"/usr/local/bin/brew"]);
        for (NSString *path in @[@"/Applications/TrackPointD.app",@"/opt/homebrew/Cellar/other/9.0.0/TrackPointD.app",@"/opt/homebrew/Cellar/trackpointd/9.0.0/Other.app",@"/opt/homebrew/Cellar/trackpointd/9.0.0/TrackPointD.app/Extra",@"/opt/homebrew/Cellar/trackpointd/HEAD/TrackPointD.app"])
            assert(!homebrew_installation(path));
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
