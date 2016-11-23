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



@interface OSNetworkRecorder ()

@property (nonatomic, strong) NSCache *responseCache;
@property (nonatomic, strong) NSMutableArray *orderedTransactions;
@property (nonatomic, strong) NSMutableDictionary *networkTransactionsForRequestIdentifiers;
@property (nonatomic, strong) dispatch_queue_t queue;
@property (nonatomic, strong) id<OSNetworkRecorderOutputWriter> outputWriter;

@end

@implementation OSNetworkRecorder

- (instancetype)init
{
    self = [super init];
    if (self) {
        self.orderedTransactions = [NSMutableArray array];
        self.networkTransactionsForRequestIdentifiers = [NSMutableDictionary dictionary];
        
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
            [self.outputWriter writeNetworkTransaction:transaction responseBody:responseBody];
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

@end
