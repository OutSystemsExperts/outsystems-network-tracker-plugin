//
//  Derived from:
//  OSNetworkTransaction.m
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

#import "OSNetworkTransaction.h"

@implementation OSNetworkTransaction

-(NSString*) description {
    NSString *description = [super description];
    
    description = [description stringByAppendingFormat:@" id = %@;", self.requestID];
    description = [description stringByAppendingFormat:@" url = %@;", self.request.URL];
    description = [description stringByAppendingFormat:@" duration = %f;", self.duration];
    description = [description stringByAppendingFormat:@" receivedDataLength = %lld", self.receivedDataLength];
    
    return description;
}

@end
