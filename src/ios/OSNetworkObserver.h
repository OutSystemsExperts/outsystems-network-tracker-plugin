//
//  Derived from:
//  FLEXNetworkObserver.h
//  FLEX
//
//  Copyright (c) 2014-2016, Flipboard
//  All rights reserved.
//
//
//  OSNetworkObserver.h
//  NetworkTracker
//
//  Created by João Gonçalves on 16/11/16.
//
//

#import <Foundation/Foundation.h>

@interface OSNetworkObserver : NSObject

+(void) setEnabled:(BOOL)enabled;
+(BOOL) isEnabled;

@end
