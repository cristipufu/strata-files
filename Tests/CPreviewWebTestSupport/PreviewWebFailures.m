#import "PreviewWebFailures.h"

@implementation STFailingWebSchemeTask {
    NSMutableArray<NSString *> *_events;
}
- (instancetype)init {
    if ((self = [super init])) _events = [NSMutableArray array];
    return self;
}
- (NSURLRequest *)request { return [NSURLRequest requestWithURL:[NSURL URLWithString:@"strata-html://fixture/document.pdf"]]; }
- (NSArray<NSString *> *)events { return [_events copy]; }
- (void)record:(NSString *)event point:(STWebFailurePoint)point {
    [_events addObject:event];
    if (self.eventOccurred) self.eventOccurred();
    if (self.failurePoint == point) @throw [NSException exceptionWithName:@"StrataFixtureWebFailure" reason:event userInfo:nil];
}
- (void)didReceiveResponse:(NSURLResponse *)response { [self record:@"response" point:STWebFailureResponse]; }
- (void)didReceiveData:(NSData *)data { [self record:@"data" point:STWebFailureData]; }
- (void)didFinish { [self record:@"finish" point:STWebFailureCompletion]; }
- (void)didFailWithError:(NSError *)error { [self record:@"failure" point:STWebFailureFailure]; }
@end
