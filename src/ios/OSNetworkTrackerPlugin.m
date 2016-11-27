//
//  OSNetworkTrackerPlugin.m
//  NetworkTracker
//
//  Created by João Gonçalves on 16/11/16.
//
//

#import "OSNetworkTrackerPlugin.h"
#import <Cordova/CDVViewController.h>
#import "OSNetworkObserver.h"
#import "OSNetworkRecorder.h"
#import "OSNetworkTransactionDatabaseWriter.h"

@interface OSNetworkTrackerPlugin()

@property(nonatomic, strong) OSNetworkTransactionDatabaseWriter* databaseWrite;

@end

@implementation OSNetworkTrackerPlugin

- (void) pluginInitialize {
    NSLog(@"pluginInitialize");
    
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(onResume) name:UIApplicationWillEnterForegroundNotification object:nil];
    self.databaseWrite = [[OSNetworkTransactionDatabaseWriter alloc] init];
    
    [[OSNetworkRecorder sharedInstance] newSession];
    [[OSNetworkRecorder sharedInstance] registerWriter:self.databaseWrite];
    [OSNetworkObserver setEnabled:YES];
    
}

- (void) dumpLogFile {
    [OSNetworkRecorder sharedInstance];
}

-(void) onResume {
    [[OSNetworkRecorder sharedInstance] newSession];
    NSLog(@"onResume");
}

@end
