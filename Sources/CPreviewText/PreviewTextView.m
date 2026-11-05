#import "PreviewTextView.h"
#import "PreviewTextError.h"
#import <os/log.h>
#import <math.h>

NSTextStorage *STCreatePreviewTextStorage(NSAttributedString *document) {
    @try {
        return [[NSTextStorage alloc] initWithAttributedString:document];
    } @catch (NSException *exception) {
        STPreviewError(@"text storage creation", exception);
        return nil;
    }
}

@implementation STPreviewTextView {
    NSError *_renderingError;
}

- (NSError *)renderingError { return _renderingError; }

- (void)retireWithError:(NSError *)error {
    if (_renderingError) return;
    _renderingError = error;
    void (^handler)(NSError *) = self.renderingFailed;
    self.renderingFailed = nil;
    __weak STPreviewTextView *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (weakSelf && handler) handler(error);
    });
}

- (void)retireAfterException:(NSException *)exception operation:(NSString *)operation {
    [self retireWithError:STPreviewError(operation, exception)];
}

- (BOOL)useTextStorage:(NSTextStorage *)storage allowingNonContiguousLayout:(BOOL)allows {
    if (_renderingError) return NO;
    @try {
        // Idle-time layout runs outside view callbacks and their exception boundaries.
        self.layoutManager.backgroundLayoutEnabled = NO;
        if (_renderingError) return NO;
        // Turn lazy layout on before installation; turn it off only after the old storage has gone.
        if (allows) self.layoutManager.allowsNonContiguousLayout = YES;
        if (_renderingError) return NO;
        [self.layoutManager replaceTextStorage:storage];
        if (_renderingError) return NO;
        if (!allows) self.layoutManager.allowsNonContiguousLayout = NO;
        return _renderingError == nil;
    } @catch (NSException *exception) {
        [self retireAfterException:exception operation:@"text storage installation"];
        return NO;
    }
}

- (void)layout {
    if (_renderingError) return;
    @try {
        [super layout];
    } @catch (NSException *exception) {
        [self retireAfterException:exception operation:@"layout"];
    }
}

- (BOOL)applyWrapping:(BOOL)wraps {
    if (_renderingError) return NO;
    @try {
        self.horizontallyResizable = !wraps;
        self.textContainer.widthTracksTextView = wraps;
        self.textContainer.containerSize = NSMakeSize(wraps ? self.frame.size.width : CGFLOAT_MAX, CGFLOAT_MAX);
        return _renderingError == nil;
    } @catch (NSException *exception) {
        [self retireAfterException:exception operation:@"line wrapping"];
        return NO;
    }
}

- (void)setFrameSize:(NSSize)size {
    if (_renderingError) return;
    if (!isfinite(size.width) || !isfinite(size.height) || size.width < 0 || size.height < 0) {
        [self retireWithError:STPreviewError(@"view dimensions", nil)];
        return;
    }
    @try {
        [super setFrameSize:size];
    } @catch (NSException *exception) {
        [self retireAfterException:exception operation:@"view resizing"];
    }
}

- (void)drawRect:(NSRect)rect {
    if (_renderingError) return;
    @try {
        [super drawRect:rect];
    } @catch (NSException *exception) {
        [self retireAfterException:exception operation:@"drawing"];
    }
}

- (void)setNeedsDisplayInRect:(NSRect)rect {
    if (_renderingError) return;
    @try {
        [super setNeedsDisplayInRect:rect];
    } @catch (NSException *exception) {
        [self retireAfterException:exception operation:@"display invalidation"];
    }
}

- (void)setNeedsDisplayInRect:(NSRect)rect avoidAdditionalLayout:(BOOL)avoidLayout {
    // Removing a document also invalidates it; a retired view must never reenter its failed layout manager.
    if (_renderingError) return;
    @try {
        [super setNeedsDisplayInRect:rect avoidAdditionalLayout:avoidLayout];
    } @catch (NSException *exception) {
        [self retireAfterException:exception operation:@"text display invalidation"];
    }
}

- (void)sizeToFit {
    if (_renderingError) return;
    @try {
        [super sizeToFit];
    } @catch (NSException *exception) {
        [self retireAfterException:exception operation:@"text sizing"];
    }
}

- (BOOL)containsRange:(NSRange)range {
    NSUInteger length = self.textStorage.length;
    return range.location <= length && range.length <= length - range.location;
}

- (BOOL)resizeAttachments:(NSArray<NSTextAttachment *> *)attachments width:(CGFloat)width {
    if (_renderingError) return NO;
    @try {
        if (!isfinite(width) || width <= 0) {
            [self retireWithError:STPreviewError(@"attachment dimensions", nil)];
            return NO;
        }
        for (NSTextAttachment *attachment in attachments) {
            NSSize size = attachment.image.size;
            if (!isfinite(size.width) || !isfinite(size.height) || size.width <= 0 || size.height <= 0) continue;
            CGFloat fitted = MIN(size.width, MAX(1, width - 20));
            attachment.bounds = NSMakeRect(0, 0, fitted, size.height * fitted / size.width);
        }
        [self.layoutManager invalidateLayoutForCharacterRange:NSMakeRange(0, self.textStorage.length) actualCharacterRange:nil];
        return _renderingError == nil;
    } @catch (NSException *exception) {
        [self retireAfterException:exception operation:@"attachment resizing"];
        return NO;
    }
}

- (BOOL)replaceCharactersInRange:(NSRange)range withAttributedString:(NSAttributedString *)replacement {
    if (_renderingError) return NO;
    @try {
        if (![self containsRange:range]) {
            [self retireWithError:STPreviewError(@"replacement range", nil)];
            return NO;
        }
        [self.textStorage replaceCharactersInRange:range withAttributedString:replacement];
        return _renderingError == nil;
    } @catch (NSException *exception) {
        [self retireAfterException:exception operation:@"document replacement"];
        return NO;
    }
}

- (BOOL)replaceRanges:(NSArray<NSValue *> *)ranges withStrings:(NSArray<NSAttributedString *> *)strings {
    if (_renderingError) return NO;
    @try {
        if (ranges.count != strings.count) {
            [self retireWithError:STPreviewError(@"replacement batch", nil)];
            return NO;
        }
        NSUInteger previous = self.textStorage.length;
        for (NSValue *value in ranges) {
            NSRange range = value.rangeValue;
            if (![self containsRange:range] || range.location > previous || range.length > previous - range.location) {
                [self retireWithError:STPreviewError(@"replacement ranges", nil)];
                return NO;
            }
            previous = range.location;
        }
        [self.textStorage beginEditing];
        for (NSUInteger index = 0; index < ranges.count; index++) {
            [self.textStorage replaceCharactersInRange:ranges[index].rangeValue withAttributedString:strings[index]];
            if (_renderingError) return NO;
        }
        [self.textStorage endEditing];
        return _renderingError == nil;
    } @catch (NSException *exception) {
        [self retireAfterException:exception operation:@"document replacement batch"];
        return NO;
    }
}

- (BOOL)writeSelectionToPasteboard:(NSPasteboard *)pasteboard types:(NSArray<NSPasteboardType> *)types {
    if (_renderingError) return NO;
    @try {
        return [super writeSelectionToPasteboard:pasteboard types:types];
    } @catch (NSException *exception) {
        [self retireAfterException:exception operation:@"selection copying"];
        return NO;
    }
}

- (BOOL)writePlainText:(NSString *)text toPasteboard:(NSPasteboard *)pasteboard {
    if (_renderingError) return NO;
    @try {
        [pasteboard declareTypes:@[NSPasteboardTypeString] owner:nil];
        return [pasteboard setString:text forType:NSPasteboardTypeString];
    } @catch (NSException *exception) {
        [self retireAfterException:exception operation:@"equation copying"];
        return NO;
    }
}

- (BOOL)highlightRanges:(NSArray<NSValue *> *)ranges clearingRange:(NSRange)whole {
    if (_renderingError) return NO;
    @try {
        BOOL valid = [self containsRange:whole];
        for (NSValue *value in ranges) valid &= [self containsRange:value.rangeValue];
        if (!valid) {
            [self retireWithError:STPreviewError(@"highlight ranges", nil)];
            return NO;
        }
        NSLayoutManager *manager = self.layoutManager;
        [manager removeTemporaryAttribute:NSBackgroundColorAttributeName forCharacterRange:whole];
        [manager removeTemporaryAttribute:NSForegroundColorAttributeName forCharacterRange:whole];
        for (NSValue *value in ranges) {
            [manager addTemporaryAttributes:@{ NSBackgroundColorAttributeName: NSColor.selectedTextBackgroundColor,
                NSForegroundColorAttributeName: NSColor.selectedTextColor } forCharacterRange:value.rangeValue];
        }
        return _renderingError == nil;
    } @catch (NSException *exception) {
        [self retireAfterException:exception operation:@"Find highlighting"];
        return NO;
    }
}

- (void)setSelectedRange:(NSRange)range {
    if (_renderingError) return;
    @try {
        [super setSelectedRange:range];
    } @catch (NSException *exception) {
        [self retireAfterException:exception operation:@"text selection"];
    }
}

- (void)scrollRangeToVisible:(NSRange)range {
    if (_renderingError) return;
    @try {
        [super scrollRangeToVisible:range];
    } @catch (NSException *exception) {
        [self retireAfterException:exception operation:@"Find scrolling"];
    }
}

- (BOOL)revealRange:(NSRange)range {
    if (_renderingError) return NO;
    @try {
        if (![self containsRange:range]) {
            [self retireWithError:STPreviewError(@"Find selection range", nil)];
            return NO;
        }
        [self setSelectedRange:range];
        [self scrollRangeToVisible:range];
        return _renderingError == nil;
    } @catch (NSException *exception) {
        [self retireAfterException:exception operation:@"Find selection"];
        return NO;
    }
}

- (void)centerCharacterAtIndex:(NSUInteger)index {
    if (_renderingError) return;
    @try {
        if (![self containsRange:NSMakeRange(index, 0)]) return;
        NSLayoutManager *manager = self.layoutManager;
        NSTextContainer *container = self.textContainer;
        if (!manager || !container) return;
        NSRange glyphs = [manager glyphRangeForCharacterRange:NSMakeRange(index, 0) actualCharacterRange:nil];
        NSRect rect = [manager boundingRectForGlyphRange:glyphs inTextContainer:container];
        NSClipView *clip = self.enclosingScrollView.contentView;
        NSRect target = clip.bounds;
        target.origin = NSMakePoint(-clip.contentInsets.left, NSMidY(rect) + self.textContainerOrigin.y - target.size.height / 2);
        [clip scrollToPoint:[clip constrainBoundsRect:target].origin];
        [self.enclosingScrollView reflectScrolledClipView:clip];
    } @catch (NSException *exception) {
        [self retireAfterException:exception operation:@"error line positioning"];
    }
}

@end
