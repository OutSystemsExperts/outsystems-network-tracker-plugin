//
//  OSNetowrkTransactionDatabaseWriter.h
//  NetworkTracker
//
//  Created by João Gonçalves on 18/11/16.
//
//

#import <Foundation/Foundation.h>
#import "OSNetworkRecorder.h"

@interface OSNetworkTransactionDatabaseWriter : NSObject <OSNetworkRecorderOutputWriter>

-(void) newSession;

@end
