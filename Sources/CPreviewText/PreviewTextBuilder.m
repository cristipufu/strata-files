#import "PreviewTextView.h"
#import "PreviewTextError.h"
#import <math.h>

@implementation STPreviewTextBuilder

+ (NSAttributedString *)inlineMarkdown:(NSString *)markdown baseURL:(NSURL *)baseURL error:(NSError **)error {
    @try {
        NSAttributedStringMarkdownParsingOptions *options = [NSAttributedStringMarkdownParsingOptions new];
        options.allowsExtendedAttributes = NO;
        options.interpretedSyntax = NSAttributedStringMarkdownInterpretedSyntaxInlineOnlyPreservingWhitespace;
        options.failurePolicy = NSAttributedStringMarkdownParsingFailureReturnPartiallyParsedIfPossible;
        // A syntax error can show as source. A native exception abandons this document instead.
        NSAttributedString *parsed = [[NSAttributedString alloc] initWithMarkdownString:markdown options:options
            baseURL:baseURL error:nil];
        return parsed ?: [[NSAttributedString alloc] initWithString:markdown];
    } @catch (NSException *exception) {
        if (error) *error = STPreviewError(@"inline Markdown", exception);
        return nil;
    }
}

+ (NSNumber *)widthOfString:(NSAttributedString *)string error:(NSError **)error {
    @try {
        CGFloat width = string.size.width;
        if (isfinite(width) && width >= 0) return @(width);
        if (error) *error = STPreviewError(@"text measurement", nil);
    } @catch (NSException *exception) {
        if (error) *error = STPreviewError(@"text measurement", exception);
    }
    return nil;
}

+ (NSNumber *)wordCountInString:(NSString *)string error:(NSError **)error {
    @try {
        __block NSUInteger count = 0;
        [string enumerateSubstringsInRange:NSMakeRange(0, string.length)
            options:NSStringEnumerationByWords | NSStringEnumerationSubstringNotRequired
            usingBlock:^(NSString *part, NSRange range, NSRange enclosing, BOOL *stop) { count++; }];
        return @(count);
    } @catch (NSException *exception) {
        if (error) *error = STPreviewError(@"word counting", exception);
        return nil;
    }
}

+ (BOOL)fitTable:(NSTextTable *)table cells:(NSArray<NSTextTableBlock *> *)cells
         widths:(NSArray<NSNumber *> *)widths available:(CGFloat)available error:(NSError **)error {
    @try {
        BOOL valid = isfinite(available) && available > 0;
        for (NSNumber *width in widths) valid &= isfinite(width.doubleValue) && width.doubleValue > 0;
        for (NSTextTableBlock *cell in cells) valid &= cell.startingColumn >= 0 && cell.startingColumn < widths.count;
        if (!valid) {
            if (error) *error = STPreviewError(@"table dimensions", nil);
            return NO;
        }
        [table setValue:available type:NSTextBlockAbsoluteValueType forDimension:NSTextBlockWidth];
        for (NSTextTableBlock *cell in cells) {
            [cell setValue:MAX(1, widths[cell.startingColumn].doubleValue - 18)
                     type:NSTextBlockAbsoluteValueType forDimension:NSTextBlockWidth];
        }
        return YES;
    } @catch (NSException *exception) {
        if (error) *error = STPreviewError(@"table fitting", exception);
        return NO;
    }
}

@end
