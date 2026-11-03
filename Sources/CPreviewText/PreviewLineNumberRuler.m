#import "PreviewTextView.h"
#import "PreviewTextError.h"
#import <math.h>

@implementation STPreviewLineLabel
- (instancetype)initWithNumber:(NSInteger)number baseline:(CGFloat)baseline {
    if ((self = [super init])) {
        _number = number;
        _baseline = baseline;
    }
    return self;
}
@end

@implementation STPreviewLineNumberRuler {
    __weak STPreviewTextView *_textView;
    NSArray<NSNumber *> *_lineStarts;
    NSNumber *_highlightedLine;
    NSFont *_font;
}

- (instancetype)initWithTextView:(STPreviewTextView *)textView lineStarts:(NSArray<NSNumber *> *)lineStarts
                highlightedLine:(NSNumber *)highlightedLine {
    @try {
        if ((self = [super initWithScrollView:textView.enclosingScrollView orientation:NSVerticalRuler])) {
            _textView = textView;
            _lineStarts = [lineStarts copy];
            _highlightedLine = highlightedLine;
            _font = [NSFont monospacedDigitSystemFontOfSize:10 weight:NSFontWeightRegular];
            self.clientView = textView;
            self.clipsToBounds = YES;
            NSUInteger digits = MAX(2, @(lineStarts.count).stringValue.length);
            self.ruleThickness = ceil(digits * [@"8" sizeWithAttributes:@{ NSFontAttributeName: _font }].width) + 16;
            self.reservedThicknessForMarkers = 0;
            self.reservedThicknessForAccessoryView = 0;
        }
    } @catch (NSException *exception) {
        [textView retireWithError:STPreviewError(@"line number setup", exception)];
        return nil;
    }
    return self;
}

- (BOOL)isFlipped { return YES; }

- (void)drawRect:(NSRect)rect { [self drawHashMarksAndLabelsInRect:rect]; }

- (void)drawHashMarksAndLabelsInRect:(NSRect)rect {
    STPreviewTextView *textView = _textView;
    if (!textView || textView.renderingError) return;
    @try {
        NSDictionary *normal = @{ NSFontAttributeName: _font, NSForegroundColorAttributeName: NSColor.tertiaryLabelColor };
        NSDictionary *marked = @{ NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:10 weight:NSFontWeightBold],
            NSForegroundColorAttributeName: NSColor.systemRedColor };
        NSArray<STPreviewLineLabel *> *labels = [self labelsInRect:textView.visibleRect];
        if (textView.renderingError) return;
        for (STPreviewLineLabel *label in labels) {
            NSAttributedString *text = [[NSAttributedString alloc] initWithString:@(label.number).stringValue
                attributes:label.number == _highlightedLine.integerValue ? marked : normal];
            [text drawAtPoint:NSMakePoint(self.bounds.size.width - 8 - text.size.width, label.baseline - _font.ascender)];
        }
    } @catch (NSException *exception) {
        [textView retireWithError:STPreviewError(@"line number drawing", exception)];
    }
}

- (NSArray<STPreviewLineLabel *> *)labelsInRect:(NSRect)visibleRect {
    STPreviewTextView *textView = _textView;
    if (!textView || textView.renderingError || !_lineStarts.count) return @[];
    @try {
        NSLayoutManager *manager = textView.layoutManager;
        NSTextContainer *container = textView.textContainer;
        if (!manager || !container || !manager.numberOfGlyphs) return @[];
        NSPoint origin = textView.textContainerOrigin;
        NSRect visible = NSOffsetRect(visibleRect, -origin.x, -origin.y);
        NSRange glyphs = [manager glyphRangeForBoundingRect:visible inTextContainer:container];
        NSMutableArray<STPreviewLineLabel *> *labels = [NSMutableArray new];
        [manager enumerateLineFragmentsForGlyphRange:glyphs usingBlock:^(NSRect fragment, NSRect used,
                NSTextContainer *textContainer, NSRange range, BOOL *stop) {
            if (!range.length) return;
            NSUInteger character = [manager characterIndexForGlyphAtIndex:range.location];
            NSUInteger line = [self lineIndexContaining:character];
            if (character != self->_lineStarts[line].unsignedIntegerValue) return;
            CGFloat baseline = [manager locationForGlyphAtIndex:range.location].y;
            CGFloat y = [self convertPoint:NSMakePoint(0, NSMinY(fragment) + origin.y + baseline) fromView:textView].y;
            [labels addObject:[[STPreviewLineLabel alloc] initWithNumber:line + 1 baseline:y]];
        }];
        return labels;
    } @catch (NSException *exception) {
        [textView retireWithError:STPreviewError(@"line number layout", exception)];
        return @[];
    }
}

- (NSUInteger)lineIndexContaining:(NSUInteger)character {
    NSUInteger low = 0, high = _lineStarts.count - 1;
    while (low < high) {
        NSUInteger mid = low + (high - low + 1) / 2;
        if (_lineStarts[mid].unsignedIntegerValue <= character) low = mid;
        else high = mid - 1;
    }
    return low;
}

@end
