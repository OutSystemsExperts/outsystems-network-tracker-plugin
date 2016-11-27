//
//  OSNetworkHARExporter.h
//  OutSystems
//
//  Created by João Gonçalves on 25/11/16.
//
//

#import <Foundation/Foundation.h>

@interface OSNetworkHARExporter : NSObject

+ (instancetype) sharedInstance;

- (BOOL) exportHARForSession: (NSNumber*) sessionId dbFilePath: (NSString*) dbFilePath;

@end
