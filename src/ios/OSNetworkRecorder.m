//
//  Derived from:
//  FLEXNetworkRecorder.m
//  FLEX
//
//  Copyright (c) 2014-2016, Flipboard
//  All rights reserved.
//
//
//
//  OSNetworkRecorder.m
//  NetworkTracker
//
//  Created by João Gonçalves on 17/11/16.
//

#import "OSNetworkRecorder.h"
#import <objc/runtime.h>
#import "RSSwizzle.h"
#import "AppDelegate.h"
#import "OSNetworkHARExporter.h"

@interface OSNetworkRecorder ()

@property (nonatomic, strong) NSCache *responseCache;
@property (nonatomic, strong) NSMutableArray *orderedTransactions;
@property (nonatomic, strong) NSMutableDictionary *networkTransactionsForRequestIdentifiers;
@property (nonatomic, strong) dispatch_queue_t queue;
@property (nonatomic, strong) id<OSNetworkRecorderOutputWriter> outputWriter;

/*
 *   Identifies a running session.
 *   A running session is the time of execution since the application goes into foreground and ends when entering on background.
 */
@property time_t sessionId;
@end

@implementation OSNetworkRecorder

- (instancetype)init
{
    self = [super init];
    if (self) {
        self.orderedTransactions = [NSMutableArray array];
        self.networkTransactionsForRequestIdentifiers = [NSMutableDictionary dictionary];
        [self swizzleAppDelegate];
        // Serial queue used because we use mutable objects that are not thread safe
        self.queue = dispatch_queue_create("com.outsystems.OSNetworkRecorder", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

+(instancetype)sharedInstance {
    static OSNetworkRecorder *sharedInstace = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstace = [[[self class] alloc] init];
    });
    return sharedInstace;
}

-(void) newSession{
    self.sessionId = [[NSDate date] timeIntervalSince1970];
}

-(NSNumber*) currentSession {
    return [NSNumber numberWithLong: self.sessionId];
}

- (NSString*) filename {
    NSString *documentsPath = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    NSString *filePath = [documentsPath stringByAppendingPathComponent:@"os_network_trace.db"];
    return filePath;
}


-(void) registerWriter:(id <OSNetworkRecorderOutputWriter>) writer {
    self.outputWriter = writer;
}

// Recording network activity

/// Call when app is about to send HTTP request.
- (void)recordRequestWillBeSentWithRequestID:(NSString *)requestID request:(NSURLRequest *)request redirectResponse:(NSURLResponse *)redirectResponse{
    
    NSDate *startDate = [NSDate date];
    
    if (redirectResponse) {
        [self recordResponseReceivedWithRequestID:requestID response:redirectResponse];
        [self recordLoadingFinishedWithRequestID:requestID responseBody:nil];
    }
    
    dispatch_async(self.queue, ^{
        OSNetworkTransaction *transaction = [[OSNetworkTransaction alloc] init];
        transaction.requestID = requestID;
        transaction.request = request;
        transaction.startTime = startDate;
        
        [self.orderedTransactions insertObject:transaction atIndex:0];
        [self.networkTransactionsForRequestIdentifiers setObject:transaction forKey:requestID];
        
    });
    
}


/// Call when HTTP response is available.
- (void)recordResponseReceivedWithRequestID:(NSString *)requestID response:(NSURLResponse *)response {
    NSDate *responseDate = [NSDate date];
    
    dispatch_async(self.queue, ^{
        OSNetworkTransaction *transaction = self.networkTransactionsForRequestIdentifiers[requestID];
        if (!transaction) {
            return;
        }
        transaction.response = response;
        transaction.latency = -[transaction.startTime timeIntervalSinceDate:responseDate];
        
    });
}

/// Call when data chunk is received over the network.
- (void)recordDataReceivedWithRequestID:(NSString *)requestID dataLength:(int64_t)dataLength {
    dispatch_async(self.queue, ^{
        OSNetworkTransaction *transaction = self.networkTransactionsForRequestIdentifiers[requestID];
        if (!transaction) {
            return;
        }
        transaction.receivedDataLength += dataLength;
        
    });
}

/// Call when HTTP request has finished loading.
- (void)recordLoadingFinishedWithRequestID:(NSString *)requestID responseBody:(NSData *)responseBody {
    NSDate *finishedDate = [NSDate date];
    
    dispatch_async(self.queue, ^{
        OSNetworkTransaction *transaction = self.networkTransactionsForRequestIdentifiers[requestID];
        if (!transaction) {
            return;
        }
        transaction.duration = -[transaction.startTime timeIntervalSinceDate:finishedDate];
        
        if(self.outputWriter) {
            [self.outputWriter writeNetworkTransaction:transaction responseBody:responseBody sessionId:[self currentSession]];
        }
        
    });
}

/// Call when HTTP request has failed to load.
- (void)recordLoadingFailedWithRequestID:(NSString *)requestID error:(NSError *)error {
    dispatch_async(self.queue, ^{
        OSNetworkTransaction *transaction = self.networkTransactionsForRequestIdentifiers[requestID];
        if (!transaction) {
            return;
        }
    });
}

/// Call to set the request mechanism anytime after recordRequestWillBeSent... has been called.
/// This string can be set to anything useful about the API used to make the request.
- (void)recordMechanism:(NSString *)mechanism forRequestID:(NSString *)requestID {
    
}


-(void)swizzleAppDelegate {
    SEL selector = @selector(applicationDidEnterBackground:);
    Class cls = [AppDelegate class];
    
    typedef void (^UIApplicationBlockApplicationDidEnterBckg)(id <UIApplicationDelegate> slf, UIApplication *application);
    UIApplicationBlockApplicationDidEnterBckg swizzleddBlock = ^(id <UIApplicationDelegate> slf, UIApplication *application) {
        NSLog(@"AppDelegate went to background");
        
        __block UIBackgroundTaskIdentifier task = [application beginBackgroundTaskWithExpirationHandler:^{
            if(task != UIBackgroundTaskInvalid) {
                [application endBackgroundTask:task];
                task = UIBackgroundTaskInvalid;
            }
            
        }];
        
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{

            [[OSNetworkHARExporter sharedInstance] exportHARForSession: [self currentSession] dbFilePath: [[OSNetworkRecorder sharedInstance] filename] ];
            
            if(task != UIBackgroundTaskInvalid) {
                [application endBackgroundTask:task];
                task = UIBackgroundTaskInvalid;
            }
        });
    };
    
    [RSSwizzle swizzleInstanceMethod:selector inClass:cls newImpFactory:^id(RSSwizzleInfo *swizzleInfo) {
        return ^void(__unsafe_unretained id self, UIApplication* application){
            
            swizzleddBlock(self, application);
            
            void (*originalIMP)(__unsafe_unretained id, SEL, UIApplication*);
            originalIMP = (__typeof(originalIMP))[swizzleInfo getOriginalImplementation];
            originalIMP(self, selector, application);
        };
        
    } mode:RSSwizzleModeAlways key:nil];
}

@end
