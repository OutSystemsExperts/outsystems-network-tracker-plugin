//
//  Derived from:
//  OSNetworkTransaction.h
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

@interface OSNetworkTransaction : NSObject

@property (nonatomic, copy) NSString *requestID;

@property (nonatomic, strong) NSURLRequest *request;
@property (nonatomic, strong) NSURLResponse *response;
@property (nonatomic, copy) NSString *requestMechanism;
@property (nonatomic, strong) NSError *error;

@property (nonatomic, strong) NSDate *startTime;
@property (nonatomic, assign) NSTimeInterval latency;
@property (nonatomic, assign) NSTimeInterval duration;

@property (nonatomic, assign) int64_t receivedDataLength;

@end
