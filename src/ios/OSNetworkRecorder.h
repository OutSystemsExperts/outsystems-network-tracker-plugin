//
//  Derived from:
//  FLEXNetworkRecorder.h
//  FLEX
//
//  Copyright (c) 2014-2016, Flipboard
//  All rights reserved.
//
//
//
//  OSNetworkRecorder.h
//  NetworkTracker
//
//  Created by João Gonçalves on 17/11/16.
//

#import <Foundation/Foundation.h>
#import "OSNetworkTransaction.h"


@protocol OSNetworkRecorderOutputWriter <NSObject>

- (void) writeNetworkTransaction: (OSNetworkTransaction* ) transaction responseBody:(NSData*) responseBody sessionId:(NSNumber*) sessionId;

@end

@interface OSNetworkRecorder : NSObject

+(instancetype) sharedInstance;

-(void) registerWriter:(id <OSNetworkRecorderOutputWriter>) writer;


-(void) newSession;

-(NSNumber*) currentSession;

- (NSString*) filename;

// Recording network activity

/// Call when app is about to send HTTP request.
- (void)recordRequestWillBeSentWithRequestID:(NSString *)requestID request:(NSURLRequest *)request redirectResponse:(NSURLResponse *)redirectResponse;

/// Call when HTTP response is available.
- (void)recordResponseReceivedWithRequestID:(NSString *)requestID response:(NSURLResponse *)response;

/// Call when data chunk is received over the network.
- (void)recordDataReceivedWithRequestID:(NSString *)requestID dataLength:(int64_t)dataLength;

/// Call when HTTP request has finished loading.
- (void)recordLoadingFinishedWithRequestID:(NSString *)requestID responseBody:(NSData *)responseBody;

/// Call when HTTP request has failed to load.
- (void)recordLoadingFailedWithRequestID:(NSString *)requestID error:(NSError *)error;

/// Call to set the request mechanism anytime after recordRequestWillBeSent... has been called.
/// This string can be set to anything useful about the API used to make the request.
- (void)recordMechanism:(NSString *)mechanism forRequestID:(NSString *)requestID;


@end
