#import "NativeReaders.h"
#import "NativeReadError.h"

@implementation STXMLReader
+ (BOOL)parse:(NSXMLParser *)parser error:(NSError **)error {
    @try {
        BOOL success = [parser parse];
        if (!success && error) *error = parser.parserError ?: [NSError errorWithDomain:@"StrataNativeRead" code:2 userInfo:nil];
        return success;
    } @catch (NSException *exception) {
        if (error) *error = STNativeReadFailure(@"XML parsing", exception);
        return NO;
    }
}
@end
