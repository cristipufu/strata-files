#import "PreviewTextFailures.h"

@implementation STFailingPreviewLayoutManager

- (void)failAt:(STPreviewFailurePoint)point {
    if (self.failurePoint != point) return;
    _failures++;
    [NSException raise:NSInternalInconsistencyException format:@"Controlled preview layout failure"];
}

- (void)removeTemporaryAttribute:(NSAttributedStringKey)name forCharacterRange:(NSRange)range {
    [self failAt:STPreviewFailureHighlighting];
    [super removeTemporaryAttribute:name forCharacterRange:range];
}

- (NSRange)glyphRangeForBoundingRect:(NSRect)rect inTextContainer:(NSTextContainer *)container {
    _glyphQueries++;
    [self failAt:STPreviewFailureRuler];
    return [super glyphRangeForBoundingRect:rect inTextContainer:container];
}

- (NSRect)boundingRectForGlyphRange:(NSRange)range inTextContainer:(NSTextContainer *)container {
    [self failAt:STPreviewFailureCentering];
    return [super boundingRectForGlyphRange:range inTextContainer:container];
}

- (void)invalidateLayoutForCharacterRange:(NSRange)range actualCharacterRange:(NSRangePointer)actual {
    [self failAt:STPreviewFailureInvalidation];
    [super invalidateLayoutForCharacterRange:range actualCharacterRange:actual];
}

@end

@implementation STFailingPreviewTableCell
- (void)setValue:(CGFloat)value type:(NSTextBlockValueType)type forDimension:(NSTextBlockDimension)dimension {
    if (self.failsFitting) [NSException raise:NSInternalInconsistencyException format:@"Controlled table fitting failure"];
    [super setValue:value type:type forDimension:dimension];
}
@end

@implementation STFailingPreviewTextContainer
- (void)setContainerSize:(NSSize)size {
    if (self.failsSizing) [NSException raise:NSInternalInconsistencyException format:@"Controlled container sizing failure"];
    [super setContainerSize:size];
}
@end

@implementation STFailingPreviewStorage {
    NSMutableAttributedString *_contents;
}
- (instancetype)init {
    if ((self = [super init])) _contents = [[NSMutableAttributedString alloc] initWithString:@"Diagram source\n"];
    return self;
}
- (NSString *)string { return _contents.string; }
- (NSDictionary *)attributesAtIndex:(NSUInteger)index effectiveRange:(NSRangePointer)range {
    return [_contents attributesAtIndex:index effectiveRange:range];
}
- (void)replaceCharactersInRange:(NSRange)range withString:(NSString *)string {
    if (self.failsEditing) [NSException raise:NSInternalInconsistencyException format:@"Controlled storage editing failure"];
    [_contents replaceCharactersInRange:range withString:string];
    [self edited:NSTextStorageEditedCharacters range:range changeInLength:(NSInteger)string.length - (NSInteger)range.length];
}
- (void)setAttributes:(NSDictionary *)attributes range:(NSRange)range {
    [_contents setAttributes:attributes range:range];
    [self edited:NSTextStorageEditedAttributes range:range changeInLength:0];
}
@end

@interface STFailingMarkdownString : NSString
@end
@implementation STFailingMarkdownString
- (NSUInteger)length { [NSException raise:NSInternalInconsistencyException format:@"Controlled Markdown parsing failure"]; return 0; }
- (unichar)characterAtIndex:(NSUInteger)index { return 'x'; }
@end

NSError *STTestInlineMarkdownFailure(void) {
    NSError *error = nil;
    [STPreviewTextBuilder inlineMarkdown:[STFailingMarkdownString new] baseURL:[NSURL fileURLWithPath:@"/"] error:&error];
    return error;
}
