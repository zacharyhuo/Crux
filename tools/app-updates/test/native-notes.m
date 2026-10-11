// Test-only adapter to the pinned Sparkle standard UI. Never linked into Crux.
#import <AppKit/AppKit.h>
#import <Sparkle/Sparkle.h>

@interface SPUUserUpdateState (AcceptanceOnly)
- (instancetype)initWithStage:(SPUUserUpdateStage)stage userInitiated:(BOOL)userInitiated;
@end

@interface QuietNotesDelegate : NSObject <SPUStandardUserDriverDelegate>
@end
@implementation QuietNotesDelegate
- (BOOL)supportsGentleScheduledUpdateReminders { return YES; }
- (BOOL)standardUserDriverShouldHandleShowingScheduledUpdate:(SUAppcastItem *)item andInImmediateFocus:(BOOL)focus { return NO; }
- (void)standardUserDriverWillHandleShowingUpdate:(BOOL)handle forUpdate:(SUAppcastItem *)item state:(SPUUserUpdateState *)state {}
@end

static NSTextView *findNotes(NSView *view) {
    if ([view isKindOfClass:NSTextView.class] && [((NSTextView *)view).string containsString:@"中文更新"]) return (NSTextView *)view;
    for (NSView *child in view.subviews) { NSTextView *notes = findNotes(child); if (notes) return notes; }
    return nil;
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc != 4) return 2;
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
        NSBundle *bundle = [NSBundle bundleWithPath:@(argv[1])];
        if (![bundle.bundleIdentifier hasPrefix:@"com.zacharyhuo.Crux.Beta.UpdateAcceptance."]) return 3;
        NSDictionary *dictionary = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:@(argv[2])] options:0 error:nil];
        // The deprecated constructor is intentionally confined to this UI-only
        // fixture, not update selection/security (which the real CLI tests).
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        SUAppcastItem *item = [[SUAppcastItem alloc] initWithDictionary:dictionary];
#pragma clang diagnostic pop
        if (!item || ![item.itemDescriptionFormat isEqualToString:@"markdown"]) return 4;
        QuietNotesDelegate *delegate = [QuietNotesDelegate new];
        SPUStandardUserDriver *driver = [[SPUStandardUserDriver alloc] initWithHostBundle:bundle delegate:delegate];
        SPUUserUpdateState *state = [[SPUUserUpdateState alloc] initWithStage:SPUUserUpdateStageNotDownloaded userInitiated:NO];
        [driver showUpdateFoundWithAppcastItem:item state:state reply:^(SPUUserUpdateChoice choice) {}];
        // Test-only inspection of the pinned UI: load its window without
        // ordering it onscreen, activating the app, or synthesizing any input.
        NSWindowController *alert = [driver valueForKey:@"activeUpdateAlert"];
        NSWindow *window = alert.window;
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:10];
        NSTextView *notes;
        while (!(notes = findNotes(window.contentView)) && deadline.timeIntervalSinceNow > 0) {
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
        }
        if (!notes || window.visible || NSApp.active) return 5;
        NSString *text = notes.string;
        if (![text containsString:@"修复问题"] || ![text containsString:@"let value = 1"] || [text containsString:@"```"] || [text containsString:@"## 中文更新"]) return 6;
        __block NSUInteger links = 0;
        [notes.textStorage enumerateAttribute:NSLinkAttributeName inRange:NSMakeRange(0, text.length) options:0 usingBlock:^(id value, NSRange range, BOOL *stop) { if (value) links++; }];
        if (links == 0) return 7;
        [window.contentView layoutSubtreeIfNeeded];
        NSBitmapImageRep *image = [window.contentView bitmapImageRepForCachingDisplayInRect:window.contentView.bounds];
        [window.contentView cacheDisplayInRect:window.contentView.bounds toBitmapImageRep:image];
        if (![[image representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:@(argv[3]) atomically:YES]) return 8;
        NSDictionary *receipt = @{ @"standardSparkleNotesRendered": @YES, @"markdownSyntaxRemoved": @YES, @"links": @(links), @"windowShown": @NO, @"activated": @NO, @"text": text };
        NSData *data = [NSJSONSerialization dataWithJSONObject:receipt options:NSJSONWritingPrettyPrinted error:nil];
        puts([[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding].UTF8String);
        [window close];
        return 0;
    }
}
