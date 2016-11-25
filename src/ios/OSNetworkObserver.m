//
//  Derived from:
//  FLEXNetworkObserver.m
//  FLEX
//
//  Copyright (c) 2014-2016, Flipboard
//  All rights reserved.
//
//
//  OSNetworkObserver.m
//  NetworkTracker
//
//  Created by João Gonçalves on 16/11/16.
//
//

#import "OSNetworkObserver.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <dispatch/queue.h>
#import "RSSwizzle.h"
#import "OSNetworkRecorder.h"

static NSString *const kOSNetworkObserverEnabledDefaultsKey = @"com.outsystems.OSNetworkObserver.enableOnLaunch";

typedef void (^NSURLSessionAsyncCompletion)(id fileURLOrData, NSURLResponse *response, NSError *error);

@interface OSInternalRequestState : NSObject

@property (nonatomic, copy) NSURLRequest *request;
@property (nonatomic, strong) NSMutableData *dataAccumulator;

@end

@implementation OSInternalRequestState

@end

#pragma mark NSURLConnectionHelpers

@interface OSNetworkObserver (NSURLConnectionHelpers)

- (void)connection:(NSURLConnection *)connection willSendRequest:(NSURLRequest *)request redirectResponse:(NSURLResponse *)response delegate:(id <NSURLConnectionDelegate>)delegate;
- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)response delegate:(id <NSURLConnectionDelegate>)delegate;
- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data delegate:(id <NSURLConnectionDelegate>)delegate;
- (void)connectionDidFinishLoading:(NSURLConnection *)connection delegate:(id <NSURLConnectionDelegate>)delegate;
- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error delegate:(id <NSURLConnectionDelegate>)delegate;
- (void)connectionWillCancel:(NSURLConnection *)connection;

@end

#pragma mark NSURLSessionTaskHelpers

@interface OSNetworkObserver (NSURLSessionTaskHelpers)

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest *))completionHandler delegate:(id <NSURLSessionDelegate>)delegate;
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition disposition))completionHandler delegate:(id <NSURLSessionDelegate>)delegate;
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:(NSData *)data delegate:(id <NSURLSessionDelegate>)delegate;
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask
didBecomeDownloadTask:(NSURLSessionDownloadTask *)downloadTask delegate:(id <NSURLSessionDelegate>)delegate;
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error delegate:(id <NSURLSessionDelegate>)delegate;
- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask didWriteData:(int64_t)bytesWritten totalBytesWritten:(int64_t)totalBytesWritten totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite delegate:(id <NSURLSessionDelegate>)delegate;
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionDownloadTask *)downloadTask didFinishDownloadingToURL:(NSURL *)location data:(NSData *)data delegate:(id <NSURLSessionDelegate>)delegate;
- (void)URLSessionTaskWillResume:(NSURLSessionTask *)task;

@end

@interface OSNetworkObserver()

@property (nonatomic, strong) NSMutableDictionary *requestStatesForRequestIDs;
@property (nonatomic, strong) dispatch_queue_t queue;

@end

@implementation OSNetworkObserver

#pragma mark Public Methods

+(void)setEnabled:(BOOL)enabled {
    BOOL previouslyEnabled = [self isEnabled];
    
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:kOSNetworkObserverEnabledDefaultsKey];
    
    if(enabled) {
        [self injectIntoAllNSURLConnectionDelegateClasses];
    }
    
    if (previouslyEnabled != enabled) {
        [[NSNotificationCenter defaultCenter] postNotificationName:kOSNetworkObserverEnabledDefaultsKey object:self];
    }
    
}

+ (BOOL)isEnabled
{
    return [[[NSUserDefaults standardUserDefaults] objectForKey:kOSNetworkObserverEnabledDefaultsKey] boolValue];
}

+ (void)load
{
    // We don't want to do the swizzling from +load because not all the classes may be loaded at this point.
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([self isEnabled]) {
            [self injectIntoAllNSURLConnectionDelegateClasses];
        }
    });
}

#pragma mark Statics

+ (instancetype)sharedObserver
{
    static OSNetworkObserver *sharedObserver = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedObserver = [[[self class] alloc] init];
    });
    return sharedObserver;
}

+ (NSString *)nextRequestID
{
    return [[NSUUID UUID] UUIDString];
}

#pragma mark Delegate Injection Convenience Methods

/// All swizzled delegate methods should make use of this guard.
/// This will prevent duplicated sniffing when the original implementation calls up to a superclass implementation which we've also swizzled.
/// The superclass implementation (and implementations in classes above that) will be executed without inteference if called from the original implementation.
+ (void)sniffWithoutDuplicationForObject:(NSObject *)object
                                selector:(SEL)selector
                           sniffingBlock:(void (^)(void))sniffingBlock
             originalImplementationBlock:(void (^)(void))originalImplementationBlock
{
    // If we don't have an object to detect nested calls on, just run the original implmentation and bail.
    // This case can happen if someone besides the URL loading system calls the delegate methods directly.
    // See https://github.com/Flipboard/FLEX/issues/61 for an example.
    if (!object) {
        originalImplementationBlock();
        return;
    }
    
    const void *key = selector;
    
    // Don't run the sniffing block if we're inside a nested call
    if (!objc_getAssociatedObject(object, key)) {
        sniffingBlock();
    }
    
    // Mark that we're calling through to the original so we can detect nested calls
    objc_setAssociatedObject(object, key, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    originalImplementationBlock();
    objc_setAssociatedObject(object, key, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

+ (SEL)swizzledSelectorForSelector:(SEL)selector
{
    return NSSelectorFromString([NSString stringWithFormat:@"_os_swizzle_%x_%@", arc4random(), NSStringFromSelector(selector)]);
}

+ (void)replaceImplementationOfKnownSelector:(SEL)originalSelector
                                     onClass:(Class)class
                                   withBlock:(id)block
                            swizzledSelector:(SEL)swizzledSelector
{
    // This method is only intended for swizzling methods that are know to exist on the class.
    // Bail if that isn't the case.
    Method originalMethod = class_getInstanceMethod(class, originalSelector);
    if (!originalMethod) {
        return;
    }
    
    IMP implementation = imp_implementationWithBlock(block);
    class_addMethod(class, swizzledSelector, implementation, method_getTypeEncoding(originalMethod));
    Method newMethod = class_getInstanceMethod(class, swizzledSelector);
    method_exchangeImplementations(originalMethod, newMethod);
}

+ (void)replaceImplementationOfSelector:(SEL)selector
                           withSelector:(SEL)swizzledSelector
                               forClass:(Class)cls
                  withMethodDescription:(struct objc_method_description)methodDescription
                    implementationBlock:(id)implementationBlock
                         undefinedBlock:(id)undefinedBlock
{
    if ([self instanceRespondsButDoesNotImplementSelector:selector class:cls]) {
        return;
    }
    
    IMP implementation = imp_implementationWithBlock((id)([cls instancesRespondToSelector:selector] ? implementationBlock : undefinedBlock));
    
    Method oldMethod = class_getInstanceMethod(cls, selector);
    if (oldMethod) {
        class_addMethod(cls, swizzledSelector, implementation, methodDescription.types);
        
        Method newMethod = class_getInstanceMethod(cls, swizzledSelector);
        
        method_exchangeImplementations(oldMethod, newMethod);
    } else {
        class_addMethod(cls, selector, implementation, methodDescription.types);
    }
}

+ (BOOL)instanceRespondsButDoesNotImplementSelector:(SEL)selector
                                              class:(Class)cls
{
    if ([cls instancesRespondToSelector:selector]) {
        unsigned int numMethods = 0;
        Method *methods = class_copyMethodList(cls, &numMethods);
        
        BOOL implementsSelector = NO;
        for (int index = 0; index < numMethods; index++) {
            SEL methodSelector = method_getName(methods[index]);
            if (selector == methodSelector) {
                implementsSelector = YES;
                break;
            }
        }
        
        free(methods);
        
        if (!implementsSelector) {
            return YES;
        }
    }
    
    return NO;
}
#pragma mark - Delegate Injection

+ (void)injectIntoAllNSURLConnectionDelegateClasses
{
    // Only allow swizzling once.
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // Swizzle any classes that implement one of these selectors.
        const SEL selectors[] = {
            @selector(connectionDidFinishLoading:),
            @selector(connection:willSendRequest:redirectResponse:),
            @selector(connection:didReceiveResponse:),
            @selector(connection:didReceiveData:),
            @selector(connection:didFailWithError:),
            @selector(URLSession:task:willPerformHTTPRedirection:newRequest:completionHandler:),
            @selector(URLSession:dataTask:didReceiveData:),
            @selector(URLSession:dataTask:didReceiveResponse:completionHandler:),
            @selector(URLSession:task:didCompleteWithError:),
            @selector(URLSession:dataTask:didBecomeDownloadTask:),
            @selector(URLSession:downloadTask:didWriteData:totalBytesWritten:totalBytesExpectedToWrite:),
            @selector(URLSession:downloadTask:didFinishDownloadingToURL:)
        };
        
        const int numSelectors = sizeof(selectors) / sizeof(SEL);
        
        Class *classes = NULL;
        int numClasses = objc_getClassList(NULL, 0);
        
        if (numClasses > 0) {
            classes = (__unsafe_unretained Class *)malloc(sizeof(Class) * numClasses);
            numClasses = objc_getClassList(classes, numClasses);
            for (NSInteger classIndex = 0; classIndex < numClasses; ++classIndex) {
                Class class = classes[classIndex];
                
                if (class == [OSNetworkObserver class]) {
                    continue;
                }
                
                // iOS 10 adds support on UIWebView to intercep XHR requests but they end up on a different delegate
                // WebCoreResourceHandleAsOperationQueueDelegate
                // WebCoreResourceHandleAsDelegate
                // WebResourceLoaderQuickLookDelegate
                if(class == NSClassFromString(@"WebCoreResourceHandleAsDelegate")) {
                    unsigned int methodCount = 0;
                    Method *methods = class_copyMethodList(class, &methodCount);
                    for (unsigned int methodIndex = 0; methodIndex < methodCount; methodIndex++) {
                        SEL sel = method_getName(methods[methodIndex]);
                        SEL sel2 = @selector(connection:didReceiveData:lengthReceived:);
                        if(sel == sel2) {
                            [self injectIntoWebCoreDidReceiveData:class];
                        }
                    }
                }
                
                // Use the runtime API rather than the methods on NSObject to avoid sending messages to
                // classes we're not interested in swizzling. Otherwise we hit +initialize on all classes.
                // NOTE: calling class_getInstanceMethod() DOES send +initialize to the class. That's why we iterate through the method list.
                unsigned int methodCount = 0;
                Method *methods = class_copyMethodList(class, &methodCount);
                BOOL matchingSelectorFound = NO;
                for (unsigned int methodIndex = 0; methodIndex < methodCount; methodIndex++) {
                    for (int selectorIndex = 0; selectorIndex < numSelectors; ++selectorIndex) {
                        if (method_getName(methods[methodIndex]) == selectors[selectorIndex]) {
                            [self injectIntoDelegateClass:class];
                            matchingSelectorFound = YES;
                            break;
                        }
                    }
                    if (matchingSelectorFound) {
                        break;
                    }
                }
                free(methods);
            }
            
            free(classes);
        }
        
        [self injectIntoNSURLConnectionCancel];
        [self injectIntoNSURLSessionTaskResume];
        
        [self injectIntoNSURLConnectionAsynchronousClassMethod];
        [self injectIntoNSURLConnectionSynchronousClassMethod];
        
        [self injectIntoNSURLSessionAsyncDataAndDownloadTaskMethods];
        [self injectIntoNSURLSessionAsyncUploadTaskMethods];
    });
}

+ (void)injectIntoWebCoreDidReceiveData: (Class)cls {
    
    // From https://github.com/WebKit/webkit/blob/master/Source/WebCore/platform/network/mac/WebCoreResourceHandleAsDelegate.mm
    // - (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data lengthReceived:(long long)lengthReceived
    
    SEL selector = @selector(connection:didReceiveData:lengthReceived:);
    
    if([cls instancesRespondToSelector:selector]) {
        [RSSwizzle
         swizzleInstanceMethod:selector
         inClass:cls
         newImpFactory:^id(RSSwizzleInfo *swizzleInfo) {
             // This block will be used as the new implementation.
             return ^void (__unsafe_unretained id self, NSURLConnection *connection, NSData *data, long long lengthReceived){
                 // Call observer method
                 [[OSNetworkObserver sharedObserver] connection:connection didReceiveData:data delegate:self];
                 
                 // You MUST always cast implementation to the correct function pointer.
                 void* (*originalIMP)(__unsafe_unretained id, SEL, NSURLConnection *connection, NSData *data, long long lengthReceived);
                 originalIMP = (__typeof(originalIMP))[swizzleInfo getOriginalImplementation];
                 // Calling original implementation.
                 originalIMP(self,selector, connection, data, lengthReceived);
                 
                
             };
         }
         mode:RSSwizzleModeAlways
         key:nil];
    }
    
    /// - (void)connection:(NSURLConnection *)connection didReceiveDataArray:(NSArray *)dataArray
    SEL selector2 = @selector(connection:didReceiveDataArray:);
    
    if([cls instancesRespondToSelector:selector2]) {
        [RSSwizzle
         swizzleInstanceMethod:selector2
         inClass:cls
         newImpFactory:^id(RSSwizzleInfo *swizzleInfo) {
             // This block will be used as the new implementation.
             return ^void (__unsafe_unretained id self, NSURLConnection *connection, NSArray* dataArray){
                 
                 NSMutableData* mutableData = [[NSMutableData alloc] init];
                 if([dataArray count] > 0) {
                     [mutableData appendData:[dataArray objectAtIndex:0]];
                 }
                 // Call observer method
                 [[OSNetworkObserver sharedObserver] connection:connection didReceiveData:[mutableData copy] delegate:self];
                 
                 // You MUST always cast implementation to the correct function pointer.
                 void* (*originalIMP)(__unsafe_unretained id, SEL, NSURLConnection *connection, NSArray* dataArray);
                 originalIMP = (__typeof(originalIMP))[swizzleInfo getOriginalImplementation];
                 // Calling original implementation.
                 originalIMP(self,selector2, connection, dataArray);
             };
         }
         mode:RSSwizzleModeAlways
         key:nil];
    }
    
}

+ (void)injectIntoDelegateClass:(Class)cls
{
    // Connections
    [self injectWillSendRequestIntoDelegateClass:cls];
    [self injectDidReceiveDataIntoDelegateClass:cls];
    [self injectDidReceiveResponseIntoDelegateClass:cls];
    [self injectDidFinishLoadingIntoDelegateClass:cls];
    [self injectDidFailWithErrorIntoDelegateClass:cls];
    
    // Sessions
    [self injectTaskWillPerformHTTPRedirectionIntoDelegateClass:cls];
    [self injectTaskDidReceiveDataIntoDelegateClass:cls];
    [self injectTaskDidReceiveResponseIntoDelegateClass:cls];
    [self injectTaskDidCompleteWithErrorIntoDelegateClass:cls];
    [self injectRespondsToSelectorIntoDelegateClass:cls];
    
    // Data tasks
    [self injectDataTaskDidBecomeDownloadTaskIntoDelegateClass:cls];
    
    // Download tasks
    [self injectDownloadTaskDidWriteDataIntoDelegateClass:cls];
    [self injectDownloadTaskDidFinishDownloadingIntoDelegateClass:cls];
}

#pragma mark NSURLConnectionDataDelegate swizzle

+ (void)injectWillSendRequestIntoDelegateClass:(Class)cls
{
    //- (nullable NSURLRequest *)connection:(NSURLConnection *)connection willSendRequest:(NSURLRequest *)request redirectResponse:(nullable NSURLResponse *)response;
    
    SEL selector = @selector(connection:willSendRequest:redirectResponse:);
    
    if([cls instancesRespondToSelector:selector]) {
        [RSSwizzle
         swizzleInstanceMethod:selector
         inClass:cls
         newImpFactory:^id(RSSwizzleInfo *swizzleInfo) {
             // This block will be used as the new implementation.
             return ^NSURLRequest*(__unsafe_unretained id self, NSURLConnection *connection, NSURLRequest *request, NSURLResponse *response){
                 
                 // Call observer method
                 [[OSNetworkObserver sharedObserver] connection:connection willSendRequest:request redirectResponse:response delegate:self];
                 
                 // You MUST always cast implementation to the correct function pointer.
                 NSURLRequest* (*originalIMP)(__unsafe_unretained id, SEL, NSURLConnection *connection, NSURLRequest *request, NSURLResponse *response);
                 originalIMP = (__typeof(originalIMP))[swizzleInfo getOriginalImplementation];
                 // Calling original implementation.
                 NSURLRequest* res = originalIMP(self,selector, connection, request, response);
                 // Returning modified return value.
                 return res;
             };
         }
         mode:RSSwizzleModeAlways
         key:nil];
    }
}

+ (void)injectDidReceiveDataIntoDelegateClass:(Class)cls
{
    //     - (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data;
    
    SEL selector = @selector(connection:didReceiveData:);
    
    Protocol *protocol = @protocol(NSURLConnectionDataDelegate);
    if(!protocol) {
        protocol = @protocol(NSURLConnectionDelegate);
    }
    
    
    
    Method oldmethod = class_getInstanceMethod(cls, selector);
    
    if(!oldmethod) {
        
        struct objc_method_description methodDescription = protocol_getMethodDescription(protocol, selector, NO, YES);
        
        typedef void (^NSURLConnectionDidReceiveDataBlock)(id <NSURLConnectionDelegate> slf, NSURLConnection *connection, NSData *data);
        NSURLConnectionDidReceiveDataBlock undefinedBlock = ^(id <NSURLConnectionDelegate> slf, NSURLConnection *connection, NSData *data) {
            [[OSNetworkObserver sharedObserver] connection:connection didReceiveData:data delegate:slf];
        };
        
        IMP implementation = imp_implementationWithBlock((id) undefinedBlock);
        class_addMethod(cls, selector, implementation, methodDescription.types);
    } else {
        
        
        
        if([cls instancesRespondToSelector:selector]) {
            [RSSwizzle
             swizzleInstanceMethod:selector
             inClass:cls
             newImpFactory:^id(RSSwizzleInfo *swizzleInfo) {
                 // This block will be used as the new implementation.
                 return ^void(__unsafe_unretained id self, NSURLConnection *connection, NSData *data){
                     
                     // Call observer method
                     [[OSNetworkObserver sharedObserver] connection:connection didReceiveData:data delegate:self];
                     
                     // You MUST always cast implementation to the correct function pointer.
                     void (*originalIMP)(__unsafe_unretained id, SEL, NSURLConnection *connection, NSData *data);
                     originalIMP = (__typeof(originalIMP))[swizzleInfo getOriginalImplementation];
                     
                     // Calling original implementation.
                     originalIMP(self,selector, connection, data);
                     
                     
                 };
             }
             mode:RSSwizzleModeAlways
             key:nil];
        }
    }
    
}

+ (void)injectDidReceiveResponseIntoDelegateClass:(Class)cls
{
    SEL selector = @selector(connection:didReceiveResponse:);
    // - (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)response;
    
    if([cls instancesRespondToSelector:selector]) {
        [RSSwizzle
         swizzleInstanceMethod:selector
         inClass:cls
         newImpFactory:^id(RSSwizzleInfo *swizzleInfo) {
             // This block will be used as the new implementation.
             return ^void(__unsafe_unretained id self, NSURLConnection *connection, NSURLResponse *response){
                 
                 // Call observer method
                 [[OSNetworkObserver sharedObserver] connection:connection didReceiveResponse:response delegate:self];
                 
                 // You MUST always cast implementation to the correct function pointer.
                 void (*originalIMP)(__unsafe_unretained id, SEL, NSURLConnection *connection, NSURLResponse * response);
                 originalIMP = (__typeof(originalIMP))[swizzleInfo getOriginalImplementation];
                 
                 // Calling original implementation.
                 originalIMP(self,selector, connection, response);
                 
                 
             };
         }
         mode:RSSwizzleModeAlways
         key:nil];
    }
}

+ (void)injectDidFinishLoadingIntoDelegateClass:(Class)cls
{
    // - (void)connectionDidFinishLoading:(NSURLConnection *)connection;
    SEL selector = @selector(connectionDidFinishLoading:);
    
    if([cls instancesRespondToSelector:selector]) {
        [RSSwizzle
         swizzleInstanceMethod:selector
         inClass:cls
         newImpFactory:^id(RSSwizzleInfo *swizzleInfo) {
             // This block will be used as the new implementation.
             return ^void(__unsafe_unretained id self, NSURLConnection *connection){
                 
                 // Call observer method
                 [[OSNetworkObserver sharedObserver] connectionDidFinishLoading:connection delegate:self];
                 
                 // You MUST always cast implementation to the correct function pointer.
                 void (*originalIMP)(__unsafe_unretained id, SEL, NSURLConnection *connection);
                 originalIMP = (__typeof(originalIMP))[swizzleInfo getOriginalImplementation];
                 
                 // Calling original implementation.
                 originalIMP(self,selector, connection);
                 
                 
             };
         }
         mode:RSSwizzleModeAlways
         key:nil];
    }
}

#pragma mark NSURLConnectionDelegate swizzle


+ (void)injectDidFailWithErrorIntoDelegateClass:(Class)cls
{
    // - (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error;
    SEL selector = @selector(connection:didFailWithError:);
    
    if([cls instancesRespondToSelector:selector]) {
        [RSSwizzle
         swizzleInstanceMethod:selector
         inClass:cls
         newImpFactory:^id(RSSwizzleInfo *swizzleInfo) {
             // This block will be used as the new implementation.
             return ^void(__unsafe_unretained id self, NSURLConnection *connection, NSError *error){
                 
                 // Call observer method
                 [[OSNetworkObserver sharedObserver] connection:connection didFailWithError:error delegate:self];
                 
                 // You MUST always cast implementation to the correct function pointer.
                 void (*originalIMP)(__unsafe_unretained id, SEL, NSURLConnection *connection, NSError *error);
                 originalIMP = (__typeof(originalIMP))[swizzleInfo getOriginalImplementation];
                 
                 // Calling original implementation.
                 originalIMP(self,selector, connection, error);
                 
                 
             };
         }
         mode:RSSwizzleModeAlways
         key:nil];
    }
}

#pragma mark NSURLSessionTaskDelegate swizzle

+ (void)injectTaskWillPerformHTTPRedirectionIntoDelegateClass:(Class)cls
{
    //    - (void)URLSession:(NSURLSession *)session
    //task:(NSURLSessionTask *)task
    //willPerformHTTPRedirection:(NSHTTPURLResponse *)response
    //newRequest:(NSURLRequest *)request
    //completionHandler:(void (^)(NSURLRequest * _Nullable))completionHandler;
    
    SEL selector = @selector(URLSession:task:willPerformHTTPRedirection:newRequest:completionHandler:);
    
    if([cls instancesRespondToSelector:selector]) {
        [RSSwizzle
         swizzleInstanceMethod:selector
         inClass:cls
         newImpFactory:^id(RSSwizzleInfo *swizzleInfo) {
             // This block will be used as the new implementation.
             return ^void(id <NSURLSessionTaskDelegate> self, NSURLSession *session, NSURLSessionTask *task, NSHTTPURLResponse *response, NSURLRequest *newRequest, void(^completionHandler)(NSURLRequest *)){
                 
                 // Call observer method
                 [[OSNetworkObserver sharedObserver] URLSession:session task:task willPerformHTTPRedirection:response newRequest:newRequest completionHandler:completionHandler delegate:self];
                 
                 // You MUST always cast implementation to the correct function pointer.
                 void (*originalIMP)(__unsafe_unretained id, SEL, NSURLSession *session, NSURLSessionTask *task, NSHTTPURLResponse *response, NSURLRequest *newRequest, void(^completionHandler)(NSURLRequest *));
                 
                 originalIMP = (__typeof(originalIMP))[swizzleInfo getOriginalImplementation];
                 
                 // Calling original implementation.
                 originalIMP(self,selector, session, task, response, newRequest, completionHandler);
                 
                 
             };
         }
         mode:RSSwizzleModeAlways
         key:nil];
    }
}


+ (void)injectTaskDidReceiveDataIntoDelegateClass:(Class)cls
{
    //    - (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask
    //didReceiveData:(NSData *)data;
    
    SEL selector = @selector(URLSession:dataTask:didReceiveData:);
    
    if([cls instancesRespondToSelector:selector]) {
        [RSSwizzle
         swizzleInstanceMethod:selector
         inClass:cls
         newImpFactory:^id(RSSwizzleInfo *swizzleInfo) {
             // This block will be used as the new implementation.
             return ^void(id <NSURLSessionDataDelegate> self, NSURLSession *session, NSURLSessionDataTask *dataTask, NSData *data){
                 
                 // Call observer method
                 [[OSNetworkObserver sharedObserver] URLSession:session dataTask:dataTask didReceiveData:data delegate:self];
                 // You MUST always cast implementation to the correct function pointer.
                 void (*originalIMP)(__unsafe_unretained id, SEL, NSURLSession *session, NSURLSessionDataTask *dataTask, NSData *data);
                 
                 originalIMP = (__typeof(originalIMP))[swizzleInfo getOriginalImplementation];
                 
                 // Calling original implementation.
                 originalIMP(self,selector, session, dataTask, data);
             };
         }
         mode:RSSwizzleModeAlways
         key:nil];
    }
}


+ (void)injectTaskDidReceiveResponseIntoDelegateClass:(Class)cls
{
    
    //    - (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask
    //    didReceiveResponse:(NSURLResponse *)response
    //     completionHandler:(void (^)(NSURLSessionResponseDisposition disposition))completionHandler;
    SEL selector = @selector(URLSession:dataTask:didReceiveResponse:completionHandler:);
    
    if([cls instancesRespondToSelector:selector]) {
        [RSSwizzle
         swizzleInstanceMethod:selector
         inClass:cls
         newImpFactory:^id(RSSwizzleInfo *swizzleInfo) {
             // This block will be used as the new implementation.
             return ^void(id <NSURLSessionDelegate> self, NSURLSession *session, NSURLSessionDataTask *dataTask, NSURLResponse *response, void(^completionHandler)(NSURLSessionResponseDisposition disposition)){
                 
                 // Call observer method
                 [[OSNetworkObserver sharedObserver] URLSession:session dataTask:dataTask didReceiveResponse:response completionHandler:completionHandler delegate:self];
                 completionHandler(NSURLSessionResponseAllow);
                 // You MUST always cast implementation to the correct function pointer.
                 void (*originalIMP)(__unsafe_unretained id, SEL, NSURLSession *session, NSURLSessionDataTask *dataTask, NSURLResponse *response, void(^completionHandler)(NSURLSessionResponseDisposition disposition));
                 
                 originalIMP = (__typeof(originalIMP))[swizzleInfo getOriginalImplementation];
                 
                 // Calling original implementation.
                 originalIMP(self, selector, session, dataTask, response, completionHandler);
             };
         }
         mode:RSSwizzleModeAlways
         key:nil];
    }
}

+ (void)injectTaskDidCompleteWithErrorIntoDelegateClass:(Class)cls
{
    
    //    - (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
    //                                didCompleteWithError:(nullable NSError *)error;
    
    SEL selector = @selector(URLSession:task:didCompleteWithError:);
    
    if([cls instancesRespondToSelector:selector]) {
        [RSSwizzle
         swizzleInstanceMethod:selector
         inClass:cls
         newImpFactory:^id(RSSwizzleInfo *swizzleInfo) {
             // This block will be used as the new implementation.
             return ^void(id <NSURLSessionTaskDelegate> self, NSURLSession *session, NSURLSessionTask *task, NSError *error){
                 
                 // Call observer method
                 [[OSNetworkObserver sharedObserver] URLSession:session task:task didCompleteWithError:error delegate:self];
                 
                 // You MUST always cast implementation to the correct function pointer.
                 void (*originalIMP)(__unsafe_unretained id, SEL, NSURLSession *session, NSURLSessionTask *task, NSError *error);
                 
                 originalIMP = (__typeof(originalIMP))[swizzleInfo getOriginalImplementation];
                 
                 // Calling original implementation.
                 originalIMP(self, selector, session, task, error);
             };
         }
         mode:RSSwizzleModeAlways
         key:nil];
    }
    
}

// Used for overriding AFNetworking behavior
+ (void)injectRespondsToSelectorIntoDelegateClass:(Class)cls
{
    SEL selector = @selector(respondsToSelector:);
    
    if([cls instancesRespondToSelector:selector]) {
        [RSSwizzle
         swizzleInstanceMethod:selector
         inClass:cls
         newImpFactory:^id(RSSwizzleInfo *swizzleInfo) {
             // This block will be used as the new implementation.
             return ^BOOL(id <NSURLSessionTaskDelegate> self, SEL sel){
                 
                 // Call observer method
                 if (sel == @selector(URLSession:dataTask:didReceiveResponse:completionHandler:)) {
                     return YES;
                 }
                 
                 // You MUST always cast implementation to the correct function pointer.
                 BOOL (*originalIMP)(__unsafe_unretained id, SEL, SEL);
                 
                 originalIMP = (__typeof(originalIMP))[swizzleInfo getOriginalImplementation];
                 
                 // Calling original implementation.
                 return originalIMP(self, selector, sel);
             };
         }
         mode:RSSwizzleModeAlways
         key:nil];
    }
}

#pragma mark NSURLSessionDataDelegate swizzle

+ (void)injectDataTaskDidBecomeDownloadTaskIntoDelegateClass:(Class)cls
{
    SEL selector = @selector(URLSession:dataTask:didBecomeDownloadTask:);
    
    if([cls instancesRespondToSelector:selector]) {
        [RSSwizzle
         swizzleInstanceMethod:selector
         inClass:cls
         newImpFactory:^id(RSSwizzleInfo *swizzleInfo) {
             // This block will be used as the new implementation.
             return ^void(id <NSURLSessionDataDelegate> self, NSURLSession *session, NSURLSessionDataTask *dataTask, NSURLSessionDownloadTask *downloadTask){
                 
                 // Call observer method
                 [[OSNetworkObserver sharedObserver] URLSession:session dataTask:dataTask didBecomeDownloadTask:downloadTask delegate:self];
                 
                 // You MUST always cast implementation to the correct function pointer.
                 void (*originalIMP)(__unsafe_unretained id, SEL, NSURLSession *session, NSURLSessionDataTask *dataTask, NSURLSessionDownloadTask *downloadTask);
                 
                 originalIMP = (__typeof(originalIMP))[swizzleInfo getOriginalImplementation];
                 
                 // Calling original implementation.
                 originalIMP(self, selector, session, dataTask, downloadTask);
             };
         }
         mode:RSSwizzleModeAlways
         key:nil];
    }
}

+ (void)injectDownloadTaskDidWriteDataIntoDelegateClass:(Class)cls
{
    SEL selector = @selector(URLSession:downloadTask:didWriteData:totalBytesWritten:totalBytesExpectedToWrite:);
    
    if([cls instancesRespondToSelector:selector]) {
        [RSSwizzle
         swizzleInstanceMethod:selector
         inClass:cls
         newImpFactory:^id(RSSwizzleInfo *swizzleInfo) {
             // This block will be used as the new implementation.
             return ^void(id <NSURLSessionTaskDelegate> self, NSURLSession *session, NSURLSessionDownloadTask *task, int64_t bytesWritten, int64_t totalBytesWritten, int64_t totalBytesExpectedToWrite){
                 
                 // Call observer method
                 [[OSNetworkObserver sharedObserver] URLSession:session downloadTask:task didWriteData:bytesWritten totalBytesWritten:totalBytesWritten totalBytesExpectedToWrite:totalBytesExpectedToWrite delegate:self];
                 // You MUST always cast implementation to the correct function pointer.
                 void (*originalIMP)(__unsafe_unretained id, SEL, NSURLSession *session, NSURLSessionDownloadTask *task, int64_t bytesWritten, int64_t totalBytesWritten, int64_t totalBytesExpectedToWrite);
                 
                 originalIMP = (__typeof(originalIMP))[swizzleInfo getOriginalImplementation];
                 
                 // Calling original implementation.
                 originalIMP(self, selector, session, task, bytesWritten, totalBytesWritten, totalBytesExpectedToWrite);
             };
         }
         mode:RSSwizzleModeAlways
         key:nil];
    }
}


+ (void)injectDownloadTaskDidFinishDownloadingIntoDelegateClass:(Class)cls
{
    SEL selector = @selector(URLSession:downloadTask:didFinishDownloadingToURL:);
    
    if([cls instancesRespondToSelector:selector]) {
        [RSSwizzle
         swizzleInstanceMethod:selector
         inClass:cls
         newImpFactory:^id(RSSwizzleInfo *swizzleInfo) {
             // This block will be used as the new implementation.
             return ^void(id <NSURLSessionTaskDelegate> self, NSURLSession *session, NSURLSessionDownloadTask *task, NSURL *location){
                 
                 // Call observer method
                 NSData *data = [NSData dataWithContentsOfFile:location.relativePath];
                 [[OSNetworkObserver sharedObserver] URLSession:session task:task didFinishDownloadingToURL:location data:data delegate:self];
                 
                 // You MUST always cast implementation to the correct function pointer.
                 void (*originalIMP)(__unsafe_unretained id, SEL, NSURLSession *session, NSURLSessionDownloadTask *task, NSURL *location);
                 
                 originalIMP = (__typeof(originalIMP))[swizzleInfo getOriginalImplementation];
                 
                 // Calling original implementation.
                 originalIMP(self, selector, session, task, location);
             };
         }
         mode:RSSwizzleModeAlways
         key:nil];
    }
}


+ (void)injectIntoNSURLConnectionCancel
{
    Class class = [NSURLConnection class];
    SEL selector = @selector(cancel);
    
    [RSSwizzle swizzleInstanceMethod:selector inClass:class newImpFactory:^id(RSSwizzleInfo *swizzleInfo) {
        return ^void (NSURLConnection* self) {
            [[OSNetworkObserver sharedObserver] connectionWillCancel:self];
            
            void (*originalIMP)(__unsafe_unretained id, SEL);
            originalIMP = (__typeof(originalIMP))[swizzleInfo getOriginalImplementation];
            originalIMP(self, selector);
        };
    } mode:RSSwizzleModeAlways key:nil];
    
}

+ (void)injectIntoNSURLSessionTaskResume
{
    
    // In iOS 7 resume lives in __NSCFLocalSessionTask
    // In iOS 8 resume lives in NSURLSessionTask
    // In iOS 9 resume lives in __NSCFURLSessionTask
    Class class = Nil;
    if (![[NSProcessInfo processInfo] respondsToSelector:@selector(operatingSystemVersion)]) {
        class = NSClassFromString(@"__NSCFLocalSessionTask");
    } else if ([[NSProcessInfo processInfo] operatingSystemVersion].majorVersion < 9) {
        class = [NSURLSessionTask class];
    } else {
        class = NSClassFromString(@"__NSCFURLSessionTask");
    }
    SEL selector = @selector(resume);
    
    [RSSwizzle swizzleInstanceMethod:selector inClass:class newImpFactory:^id(RSSwizzleInfo *swizzleInfo) {
        return ^void (NSURLSessionTask* self) {
            
            [[OSNetworkObserver sharedObserver] URLSessionTaskWillResume:self];
            
            void (*originalIMP)(__unsafe_unretained id, SEL);
            originalIMP = (__typeof(originalIMP))[swizzleInfo getOriginalImplementation];
            originalIMP(self, selector);
        };
    } mode:RSSwizzleModeAlways key:nil];
    
}

+ (void)injectIntoNSURLConnectionAsynchronousClassMethod
{
    Class class = [NSURLConnection class];
    SEL selector = @selector(sendAsynchronousRequest:queue:completionHandler:);
    
    typedef void (^NSURLConnectionAsyncCompletion)(NSURLResponse* response, NSData* data, NSError* connectionError);
    
    [RSSwizzle swizzleClassMethod:selector inClass:class newImpFactory:^id(RSSwizzleInfo *swizzleInfo) {
        return ^void(__unsafe_unretained id self, NSURLRequest *request, NSOperationQueue *queue, NSURLConnectionAsyncCompletion completion){
            
            // You MUST always cast implementation to the correct function pointer.
            void (*originalIMP)(__unsafe_unretained id, SEL, NSURLRequest *request, NSOperationQueue *queue, NSURLConnectionAsyncCompletion completion);
            originalIMP = (__typeof(originalIMP))[swizzleInfo getOriginalImplementation];
            
            if ([OSNetworkObserver isEnabled]) {
                NSString *requestID = [OSNetworkObserver nextRequestID];
                [[OSNetworkRecorder sharedInstance] recordRequestWillBeSentWithRequestID:requestID request:request redirectResponse:nil];
                
                NSURLConnectionAsyncCompletion completionWrapper = ^(NSURLResponse *response, NSData *data, NSError *connectionError) {
                    [[OSNetworkRecorder sharedInstance] recordResponseReceivedWithRequestID:requestID response:response];
                    [[OSNetworkRecorder sharedInstance] recordDataReceivedWithRequestID:requestID dataLength:[data length]];
                    if (connectionError) {
                        [[OSNetworkRecorder sharedInstance] recordLoadingFailedWithRequestID:requestID error:connectionError];
                    } else {
                        [[OSNetworkRecorder sharedInstance] recordLoadingFinishedWithRequestID:requestID responseBody:data];
                    }
                    
                    // Call through to the original completion handler
                    if (completion) {
                        completion(response, data, connectionError);
                    }
                };
                // Calling original implementation.
                originalIMP(self, selector, request, queue, completionWrapper);
            } else {
                // Calling original implementation.
                originalIMP(self, selector, request, queue, completion);
            }
            
        };
    }];
    
}

+ (void)injectIntoNSURLConnectionSynchronousClassMethod
{
    Class class = [NSURLConnection class];
    SEL selector = @selector(sendSynchronousRequest:returningResponse:error:);
    
    [RSSwizzle swizzleClassMethod:selector inClass:class newImpFactory:^id(RSSwizzleInfo *swizzleInfo) {
        return ^ NSData* (__unsafe_unretained id self, NSURLRequest *request, NSURLResponse **response, NSError **error){
            
            // You MUST always cast implementation to the correct function pointer.
            NSData* (*originalIMP)(__unsafe_unretained id, SEL, NSURLRequest *request, NSURLResponse **response, NSError **error);
            originalIMP = (__typeof(originalIMP))[swizzleInfo getOriginalImplementation];
            
            NSData *data = nil;
            if ([OSNetworkObserver isEnabled]) {
                NSString *requestID = [OSNetworkObserver nextRequestID];
                [[OSNetworkRecorder sharedInstance] recordRequestWillBeSentWithRequestID:requestID request:request redirectResponse:nil];
                
                NSError *temporaryError = nil;
                NSURLResponse *temporaryResponse = nil;
                // Calling original implementation.
                data = originalIMP(self, selector, request, &temporaryResponse, &temporaryError);
                [[OSNetworkRecorder sharedInstance] recordResponseReceivedWithRequestID:requestID response:temporaryResponse];
                [[OSNetworkRecorder sharedInstance] recordDataReceivedWithRequestID:requestID dataLength:[data length]];
                if (temporaryError) {
                    [[OSNetworkRecorder sharedInstance] recordLoadingFailedWithRequestID:requestID error:temporaryError];
                } else {
                    [[OSNetworkRecorder sharedInstance] recordLoadingFinishedWithRequestID:requestID responseBody:data];
                }
                if (error) {
                    *error = temporaryError;
                }
                if (response) {
                    *response = temporaryResponse;
                }
            } else {
                data = originalIMP(self, selector, request, response, error);
            }
            return data;
        };
    }];
    
}


+ (void)injectIntoNSURLSessionAsyncDataAndDownloadTaskMethods
{
    Class class = [NSURLSession class];
    
    
    [self injectIntoNSURLSessionAsyncDataAndTaskMethoDataTaskWithRequestCompletionHandler:class];
    [self injectIntoNSURLSessionAsyncDataAndTaskMethoDataTaskWithURLCompletionHandler:class];
    [self injectIntoNSURLSessionAsyncDataAndTaskMethodDownloadTaskWithRequestCompletionHandler:class];
    [self injectIntoNSURLSessionAsyncDataAndTaskMethodDownloadTaskWithResumeDataCompletionHandler:class];
    [self injectIntoNSURLSessionAsyncDataAndTaskMethodDownloadTaskWithURLCompletionHandler:class];
    
}

+ (void)injectIntoNSURLSessionAsyncDataAndTaskMethoDataTaskWithURLCompletionHandler: (Class) class {
    SEL selector = @selector(dataTaskWithRequest:completionHandler:);
    //    - (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error))completionHandler;
    if ([OSNetworkObserver instanceRespondsButDoesNotImplementSelector:selector class:class]) {
        // iOS 7 does not implement these methods on NSURLSession. We actually want to
        // swizzle __NSCFURLSession, which we can get from the class of the shared session
        class = [[NSURLSession sharedSession] class];
    }
    
    [RSSwizzle swizzleInstanceMethod:selector inClass:class newImpFactory:^id(RSSwizzleInfo *swizzleInfo) {
        return ^NSURLSessionDataTask*(__unsafe_unretained id self, NSURLRequest* request, NSURLSessionAsyncCompletion completion){
            // You MUST always cast implementation to the correct function pointer.
            NSURLSessionDataTask* (*originalIMP)(__unsafe_unretained id, SEL, NSURLRequest* request, NSURLSessionAsyncCompletion completion);
            originalIMP = (__typeof(originalIMP))[swizzleInfo getOriginalImplementation];
            
            
            NSURLSessionDataTask *task = nil;
            // If completion block was not provided sender expect to receive delegated methods or does not
            // interested in callback at all. In this case we should just call original method implementation
            // with nil completion block.
            if ([OSNetworkObserver isEnabled] && completion) {
                NSString *requestID = [OSNetworkObserver nextRequestID];
                //                NSString *mechanism = [self mechansimFromClassMethod:selector onClass:class];
                NSURLSessionAsyncCompletion completionWrapper = [OSNetworkObserver asyncCompletionWrapperForRequestID:requestID completion:completion];
                //                task = ((id(*)(id, SEL, id, id))objc_msgSend)(self, selector, argument, completionWrapper);
                task = originalIMP(self, selector, request, completionWrapper);
                [OSNetworkObserver setRequestID:requestID forConnectionOrTask:task];
            } else {
                // Calling original implementation.
                task = originalIMP(self, selector, request, completion);
            }
            return task;
            
            
        };
    } mode:RSSwizzleModeAlways key:nil];
    
}

+ (void)injectIntoNSURLSessionAsyncDataAndTaskMethoDataTaskWithRequestCompletionHandler: (Class) class {
    SEL selector = @selector(dataTaskWithURL:completionHandler:);
    //    - (NSURLSessionDataTask *)dataTaskWithURL:(NSURL *)url completionHandler:(void (^)(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error))completionHandler;
    if ([OSNetworkObserver instanceRespondsButDoesNotImplementSelector:selector class:class]) {
        // iOS 7 does not implement these methods on NSURLSession. We actually want to
        // swizzle __NSCFURLSession, which we can get from the class of the shared session
        class = [[NSURLSession sharedSession] class];
    }
    
    [RSSwizzle swizzleInstanceMethod:selector inClass:class newImpFactory:^id(RSSwizzleInfo *swizzleInfo) {
        return ^NSURLSessionDataTask*(__unsafe_unretained id self, NSURL* url, NSURLSessionAsyncCompletion completion){
            // You MUST always cast implementation to the correct function pointer.
            NSURLSessionDataTask* (*originalIMP)(__unsafe_unretained id, SEL, NSURL* url, NSURLSessionAsyncCompletion completion);
            originalIMP = (__typeof(originalIMP))[swizzleInfo getOriginalImplementation];
            
            
            NSURLSessionDataTask *task = nil;
            // If completion block was not provided sender expect to receive delegated methods or does not
            // interested in callback at all. In this case we should just call original method implementation
            // with nil completion block.
            if ([OSNetworkObserver isEnabled] && completion) {
                NSString *requestID = [OSNetworkObserver nextRequestID];
                //                NSString *mechanism = [self mechansimFromClassMethod:selector onClass:class];
                NSURLSessionAsyncCompletion completionWrapper = [OSNetworkObserver asyncCompletionWrapperForRequestID:requestID completion:completion];
                //                task = ((id(*)(id, SEL, id, id))objc_msgSend)(self, selector, argument, completionWrapper);
                task = originalIMP(self, selector, url, completionWrapper);
                [OSNetworkObserver setRequestID:requestID forConnectionOrTask:task];
            } else {
                // Calling original implementation.
                task = originalIMP(self, selector, url, completion);
            }
            return task;
            
            
        };
    } mode:RSSwizzleModeAlways key:nil];
    
}

+ (void)injectIntoNSURLSessionAsyncDataAndTaskMethodDownloadTaskWithRequestCompletionHandler: (Class) class {
    
    SEL selector = @selector(downloadTaskWithRequest:completionHandler:);
    
    //    - (NSURLSessionDownloadTask *)downloadTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURL * _Nullable location, NSURLResponse * _Nullable response, NSError * _Nullable error))completionHandler;
    
    if ([OSNetworkObserver instanceRespondsButDoesNotImplementSelector:selector class:class]) {
        // iOS 7 does not implement these methods on NSURLSession. We actually want to
        // swizzle __NSCFURLSession, which we can get from the class of the shared session
        class = [[NSURLSession sharedSession] class];
    }
    
    [RSSwizzle swizzleInstanceMethod:selector inClass:class newImpFactory:^id(RSSwizzleInfo *swizzleInfo) {
        return ^NSURLSessionDownloadTask*(__unsafe_unretained id self, NSURLRequest* request, NSURLSessionAsyncCompletion completion){
            // You MUST always cast implementation to the correct function pointer.
            NSURLSessionDownloadTask* (*originalIMP)(__unsafe_unretained id, SEL, NSURLRequest *request, NSURLSessionAsyncCompletion completion);
            originalIMP = (__typeof(originalIMP))[swizzleInfo getOriginalImplementation];
            
            
            NSURLSessionDownloadTask *task = nil;
            // If completion block was not provided sender expect to receive delegated methods or does not
            // interested in callback at all. In this case we should just call original method implementation
            // with nil completion block.
            if ([OSNetworkObserver isEnabled] && completion) {
                NSString *requestID = [OSNetworkObserver nextRequestID];
                //                NSString *mechanism = [self mechansimFromClassMethod:selector onClass:class];
                NSURLSessionAsyncCompletion completionWrapper = [OSNetworkObserver asyncCompletionWrapperForRequestID:requestID completion:completion];
                
                task = originalIMP(self, selector, request, completionWrapper);
                [OSNetworkObserver setRequestID:requestID forConnectionOrTask:task];
            } else {
                // Calling original implementation.
                task = originalIMP(self, selector, request, completion);
            }
            return task;
            
            
        };
    } mode:RSSwizzleModeAlways key:nil];
    
}

+ (void)injectIntoNSURLSessionAsyncDataAndTaskMethodDownloadTaskWithResumeDataCompletionHandler: (Class) class {
    
    SEL selector = @selector(downloadTaskWithResumeData:completionHandler:);
    
    //    - (NSURLSessionDownloadTask *)downloadTaskWithResumeData:(NSData *)resumeData completionHandler:(void (^)(NSURL * _Nullable location, NSURLResponse * _Nullable response, NSError * _Nullable error))completionHandler;
    
    if ([OSNetworkObserver instanceRespondsButDoesNotImplementSelector:selector class:class]) {
        // iOS 7 does not implement these methods on NSURLSession. We actually want to
        // swizzle __NSCFURLSession, which we can get from the class of the shared session
        class = [[NSURLSession sharedSession] class];
    }
    
    [RSSwizzle swizzleInstanceMethod:selector inClass:class newImpFactory:^id(RSSwizzleInfo *swizzleInfo) {
        return ^NSURLSessionDownloadTask*(__unsafe_unretained id self, NSData *data, NSURLSessionAsyncCompletion completion){
            // You MUST always cast implementation to the correct function pointer.
            NSURLSessionDownloadTask* (*originalIMP)(__unsafe_unretained id, SEL, NSData *data, NSURLSessionAsyncCompletion completion);
            originalIMP = (__typeof(originalIMP))[swizzleInfo getOriginalImplementation];
            
            
            NSURLSessionDownloadTask *task = nil;
            // If completion block was not provided sender expect to receive delegated methods or does not
            // interested in callback at all. In this case we should just call original method implementation
            // with nil completion block.
            if ([OSNetworkObserver isEnabled] && completion) {
                NSString *requestID = [OSNetworkObserver nextRequestID];
                //                NSString *mechanism = [self mechansimFromClassMethod:selector onClass:class];
                NSURLSessionAsyncCompletion completionWrapper = [OSNetworkObserver asyncCompletionWrapperForRequestID:requestID completion:completion];
                
                task = originalIMP(self, selector, data, completionWrapper);
                [OSNetworkObserver setRequestID:requestID forConnectionOrTask:task];
            } else {
                // Calling original implementation.
                task = originalIMP(self, selector, data, completion);
            }
            return task;
            
            
        };
    } mode:RSSwizzleModeAlways key:nil];
    
}

+ (void)injectIntoNSURLSessionAsyncDataAndTaskMethodDownloadTaskWithURLCompletionHandler: (Class) class {
    
    SEL selector = @selector(downloadTaskWithURL:completionHandler:);
    
    //    - (NSURLSessionDownloadTask *)downloadTaskWithURL:(NSURL *)url completionHandler:(void (^)(NSURL * _Nullable location, NSURLResponse * _Nullable response, NSError * _Nullable error))completionHandler;
    
    if ([OSNetworkObserver instanceRespondsButDoesNotImplementSelector:selector class:class]) {
        // iOS 7 does not implement these methods on NSURLSession. We actually want to
        // swizzle __NSCFURLSession, which we can get from the class of the shared session
        class = [[NSURLSession sharedSession] class];
    }
    
    [RSSwizzle swizzleInstanceMethod:selector inClass:class newImpFactory:^id(RSSwizzleInfo *swizzleInfo) {
        return ^NSURLSessionDownloadTask*(__unsafe_unretained id self, NSURL *url, NSURLSessionAsyncCompletion completion){
            // You MUST always cast implementation to the correct function pointer.
            NSURLSessionDownloadTask* (*originalIMP)(__unsafe_unretained id, SEL, NSURL *url, NSURLSessionAsyncCompletion completion);
            originalIMP = (__typeof(originalIMP))[swizzleInfo getOriginalImplementation];
            
            
            NSURLSessionDownloadTask *task = nil;
            // If completion block was not provided sender expect to receive delegated methods or does not
            // interested in callback at all. In this case we should just call original method implementation
            // with nil completion block.
            if ([OSNetworkObserver isEnabled] && completion) {
                NSString *requestID = [OSNetworkObserver nextRequestID];
                //                NSString *mechanism = [self mechansimFromClassMethod:selector onClass:class];
                NSURLSessionAsyncCompletion completionWrapper = [OSNetworkObserver asyncCompletionWrapperForRequestID:requestID completion:completion];
                
                task = originalIMP(self, selector, url, completionWrapper);
                [OSNetworkObserver setRequestID:requestID forConnectionOrTask:task];
            } else {
                // Calling original implementation.
                task = originalIMP(self, selector, url, completion);
            }
            return task;
            
            
        };
    } mode:RSSwizzleModeAlways key:nil];
    
}



+ (void)injectIntoNSURLSessionAsyncUploadTaskMethods
{
    Class class = [NSURLSession class];
    
    [self injectIntoNSURLSessionAsyncUploadTaskMethodUploadTaskWithRequestFromDataCompletionHandler:class];
    [self injectIntoNSURLSessionAsyncUploadTaskMethodUploadTaskWithRequestFromFileCompletionHandler:class];
}

+ (void)injectIntoNSURLSessionAsyncUploadTaskMethodUploadTaskWithRequestFromDataCompletionHandler:(Class) class {
    SEL selector = @selector(uploadTaskWithRequest:fromData:completionHandler:);
    
    //    - (NSURLSessionUploadTask *)uploadTaskWithRequest:(NSURLRequest *)request
    //  fromData:(nullable NSData *)bodyData
    //  completionHandler:
    //  (void (^)(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error))completionHandler;
    
    if ([OSNetworkObserver instanceRespondsButDoesNotImplementSelector:selector class:class]) {
        // iOS 7 does not implement these methods on NSURLSession. We actually want to
        // swizzle __NSCFURLSession, which we can get from the class of the shared session
        class = [[NSURLSession sharedSession] class];
    }
    
    
    [RSSwizzle swizzleInstanceMethod:selector inClass:class newImpFactory:^id(RSSwizzleInfo *swizzleInfo) {
        return ^NSURLSessionUploadTask*(__unsafe_unretained id self, NSURLRequest* request, NSData* bodyData, NSURLSessionAsyncCompletion completion){
            // You MUST always cast implementation to the correct function pointer.
            NSURLSessionUploadTask* (*originalIMP)(__unsafe_unretained id, SEL, NSURLRequest* request, NSData* bodyData, NSURLSessionAsyncCompletion completion);
            originalIMP = (__typeof(originalIMP))[swizzleInfo getOriginalImplementation];
            
            
            NSURLSessionUploadTask *task = nil;
            // If completion block was not provided sender expect to receive delegated methods or does not
            // interested in callback at all. In this case we should just call original method implementation
            // with nil completion block.
            if ([OSNetworkObserver isEnabled] && completion) {
                NSString *requestID = [OSNetworkObserver nextRequestID];
                //                NSString *mechanism = [self mechansimFromClassMethod:selector onClass:class];
                NSURLSessionAsyncCompletion completionWrapper = [OSNetworkObserver asyncCompletionWrapperForRequestID:requestID completion:completion];
                
                task = originalIMP(self, selector, request, bodyData, completionWrapper);
                [OSNetworkObserver setRequestID:requestID forConnectionOrTask:task];
            } else {
                // Calling original implementation.
                task = originalIMP(self, selector, request, bodyData, completion);
            }
            return task;
            
            
        };
    } mode:RSSwizzleModeAlways key:nil];
    
}

+ (void)injectIntoNSURLSessionAsyncUploadTaskMethodUploadTaskWithRequestFromFileCompletionHandler:(Class) class {
    SEL selector = @selector(uploadTaskWithRequest:fromFile:completionHandler:);
    
    //- (NSURLSessionUploadTask *)uploadTaskWithRequest:(NSURLRequest *)request
    //  fromFile:(NSURL *)fileURL
    //  completionHandler:(void (^)(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error))completionHandler;
    
    if ([OSNetworkObserver instanceRespondsButDoesNotImplementSelector:selector class:class]) {
        // iOS 7 does not implement these methods on NSURLSession. We actually want to
        // swizzle __NSCFURLSession, which we can get from the class of the shared session
        class = [[NSURLSession sharedSession] class];
    }
    
    
    [RSSwizzle swizzleInstanceMethod:selector inClass:class newImpFactory:^id(RSSwizzleInfo *swizzleInfo) {
        return ^NSURLSessionUploadTask*(__unsafe_unretained id self, NSURLRequest *request, NSURL* url, NSURLSessionAsyncCompletion completion){
            // You MUST always cast implementation to the correct function pointer.
            NSURLSessionUploadTask* (*originalIMP)(__unsafe_unretained id, SEL, NSURLRequest *request, NSURL* url, NSURLSessionAsyncCompletion completion);
            originalIMP = (__typeof(originalIMP))[swizzleInfo getOriginalImplementation];
            
            
            NSURLSessionUploadTask *task = nil;
            // If completion block was not provided sender expect to receive delegated methods or does not
            // interested in callback at all. In this case we should just call original method implementation
            // with nil completion block.
            if ([OSNetworkObserver isEnabled] && completion) {
                NSString *requestID = [OSNetworkObserver nextRequestID];
                //                NSString *mechanism = [self mechansimFromClassMethod:selector onClass:class];
                NSURLSessionAsyncCompletion completionWrapper = [OSNetworkObserver asyncCompletionWrapperForRequestID:requestID completion:completion];
                
                task = originalIMP(self, selector, request, url, completionWrapper);
                [OSNetworkObserver setRequestID:requestID forConnectionOrTask:task];
            } else {
                // Calling original implementation.
                task = originalIMP(self, selector, request, url, completion);
            }
            return task;
            
            
        };
    } mode:RSSwizzleModeAlways key:nil];
    
}














+ (NSURLSessionAsyncCompletion)asyncCompletionWrapperForRequestID:(NSString *)requestID completion:(NSURLSessionAsyncCompletion)completion
{
    NSURLSessionAsyncCompletion completionWrapper = ^(id fileURLOrData, NSURLResponse *response, NSError *error) {
        
        [[OSNetworkRecorder sharedInstance] recordResponseReceivedWithRequestID:requestID response:response];
        NSData *data = nil;
        if ([fileURLOrData isKindOfClass:[NSURL class]]) {
            data = [NSData dataWithContentsOfURL:fileURLOrData];
        } else if ([fileURLOrData isKindOfClass:[NSData class]]) {
            data = fileURLOrData;
        }
        [[OSNetworkRecorder sharedInstance] recordDataReceivedWithRequestID:requestID dataLength:[data length]];
        if (error) {
            [[OSNetworkRecorder sharedInstance] recordLoadingFailedWithRequestID:requestID error:error];
        } else {
            [[OSNetworkRecorder sharedInstance] recordLoadingFinishedWithRequestID:requestID responseBody:data];
        }
        
        // Call through to the original completion handler
        if (completion) {
            completion(fileURLOrData, response, error);
        }
    };
    return completionWrapper;
}


static char const * const kOSRequestIDKey = "kOSRequestIDKey";

+ (NSString *)requestIDForConnectionOrTask:(id)connectionOrTask
{
    NSString *requestID = objc_getAssociatedObject(connectionOrTask, kOSRequestIDKey);
    if (!requestID) {
        requestID = [self nextRequestID];
        [self setRequestID:requestID forConnectionOrTask:connectionOrTask];
    }
    return requestID;
}

+ (void)setRequestID:(NSString *)requestID forConnectionOrTask:(id)connectionOrTask
{
    objc_setAssociatedObject(connectionOrTask, kOSRequestIDKey, requestID, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

#pragma mark - Initialization

- (id)init
{
    self = [super init];
    if (self) {
        self.requestStatesForRequestIDs = [[NSMutableDictionary alloc] init];
        self.queue = dispatch_queue_create("com.outsystems.OSNetworkObserver", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

#pragma mark - Private Methods

- (void)performBlock:(dispatch_block_t)block
{
    if ([[self class] isEnabled]) {
        dispatch_async(_queue, block);
    }
}

- (OSInternalRequestState *)requestStateForRequestID:(NSString *)requestID
{
    OSInternalRequestState *requestState = self.requestStatesForRequestIDs[requestID];
    if (!requestState) {
        requestState = [[OSInternalRequestState alloc] init];
        [self.requestStatesForRequestIDs setObject:requestState forKey:requestID];
    }
    return requestState;
}

- (void)removeRequestStateForRequestID:(NSString *)requestID
{
    [self.requestStatesForRequestIDs removeObjectForKey:requestID];
}

@end

#pragma mark Observer Helper methods

@implementation OSNetworkObserver (NSURLConnectionHelpers)

- (void)connection:(NSURLConnection *)connection willSendRequest:(NSURLRequest *)request redirectResponse:(NSURLResponse *)response delegate:(id<NSURLConnectionDelegate>)delegate
{
    [self performBlock:^{
        NSString *requestID = [[self class] requestIDForConnectionOrTask:connection];
        OSInternalRequestState *requestState = [self requestStateForRequestID:requestID];
        requestState.request = request;
        
        [[OSNetworkRecorder sharedInstance] recordRequestWillBeSentWithRequestID:requestID request:request redirectResponse:response];
        
    }];
}

- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)response delegate:(id<NSURLConnectionDelegate>)delegate
{
    [self performBlock:^{
        NSString *requestID = [[self class] requestIDForConnectionOrTask:connection];
        OSInternalRequestState *requestState = [self requestStateForRequestID:requestID];
        
        NSMutableData *dataAccumulator = nil;
        if (response.expectedContentLength < 0) {
            dataAccumulator = [[NSMutableData alloc] init];
        } else {
            dataAccumulator = [[NSMutableData alloc] initWithCapacity:(NSUInteger)response.expectedContentLength];
        }
        requestState.dataAccumulator = dataAccumulator;
        
        [[OSNetworkRecorder sharedInstance] recordResponseReceivedWithRequestID:requestID response:response];
    }];
}

- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data delegate:(id<NSURLConnectionDelegate>)delegate
{
    // Just to be safe since we're doing this async
    data = [data copy];
    [self performBlock:^{
        NSString *requestID = [[self class] requestIDForConnectionOrTask:connection];
        OSInternalRequestState *requestState = [self requestStateForRequestID:requestID];
        [requestState.dataAccumulator appendData:data];
        [[OSNetworkRecorder sharedInstance] recordDataReceivedWithRequestID:requestID dataLength:data.length];
    }];
}

- (void)connectionDidFinishLoading:(NSURLConnection *)connection delegate:(id<NSURLConnectionDelegate>)delegate
{
    [self performBlock:^{
        NSString *requestID = [[self class] requestIDForConnectionOrTask:connection];
        OSInternalRequestState *requestState = [self requestStateForRequestID:requestID];
        [[OSNetworkRecorder sharedInstance] recordLoadingFinishedWithRequestID:requestID responseBody:requestState.dataAccumulator];
        [self removeRequestStateForRequestID:requestID];
    }];
}

- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error delegate:(id<NSURLConnectionDelegate>)delegate
{
    [self performBlock:^{
        NSString *requestID = [[self class] requestIDForConnectionOrTask:connection];
        OSInternalRequestState *requestState = [self requestStateForRequestID:requestID];
        
        // Cancellations can occur prior to the willSendRequest:... NSURLConnection delegate call.
        // These are pretty common and clutter up the logs. Only record the failure if the recorder already knows about the request through willSendRequest:...
        if (requestState.request) {
            [[OSNetworkRecorder sharedInstance] recordLoadingFailedWithRequestID:requestID error:error];
        }
        
        [self removeRequestStateForRequestID:requestID];
    }];
}

- (void)connectionWillCancel:(NSURLConnection *)connection
{
    [self performBlock:^{
        // Mimic the behavior of NSURLSession which is to create an error on cancellation.
        NSDictionary *userInfo = @{ NSLocalizedDescriptionKey : @"cancelled" };
        NSError *error = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled userInfo:userInfo];
        [self connection:connection didFailWithError:error delegate:nil];
    }];
}

@end

@implementation OSNetworkObserver (NSURLSessionTaskHelpers)

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest *))completionHandler delegate:(id<NSURLSessionDelegate>)delegate
{
    [self performBlock:^{
        NSString *requestID = [[self class] requestIDForConnectionOrTask:task];
        [[OSNetworkRecorder sharedInstance] recordRequestWillBeSentWithRequestID:requestID request:request redirectResponse:response];
    }];
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition disposition))completionHandler delegate:(id<NSURLSessionDelegate>)delegate
{
    [self performBlock:^{
        NSString *requestID = [[self class] requestIDForConnectionOrTask:dataTask];
        OSInternalRequestState *requestState = [self requestStateForRequestID:requestID];
        
        NSMutableData *dataAccumulator = nil;
        if (response.expectedContentLength < 0) {
            dataAccumulator = [[NSMutableData alloc] init];
        } else {
            dataAccumulator = [[NSMutableData alloc] initWithCapacity:(NSUInteger)response.expectedContentLength];
        }
        requestState.dataAccumulator = dataAccumulator;
        [[OSNetworkRecorder sharedInstance] recordResponseReceivedWithRequestID:requestID response:response];
    }];
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didBecomeDownloadTask:(NSURLSessionDownloadTask *)downloadTask delegate:(id<NSURLSessionDelegate>)delegate
{
    [self performBlock:^{
        // By setting the request ID of the download task to match the data task,
        // it can pick up where the data task left off.
        NSString *requestID = [[self class] requestIDForConnectionOrTask:dataTask];
        [OSNetworkObserver setRequestID:requestID forConnectionOrTask:downloadTask];
    }];
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:(NSData *)data delegate:(id<NSURLSessionDelegate>)delegate
{
    // Just to be safe since we're doing this async
    data = [data copy];
    [self performBlock:^{
        NSString *requestID = [[self class] requestIDForConnectionOrTask:dataTask];
        OSInternalRequestState *requestState = [self requestStateForRequestID:requestID];
        
        [requestState.dataAccumulator appendData:data];
        
        [[OSNetworkRecorder sharedInstance] recordDataReceivedWithRequestID:requestID dataLength:data.length];
    }];
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error delegate:(id<NSURLSessionDelegate>)delegate
{
    [self performBlock:^{
        NSString *requestID = [[self class] requestIDForConnectionOrTask:task];
        OSInternalRequestState *requestState = [self requestStateForRequestID:requestID];
        if (error) {
            [[OSNetworkRecorder sharedInstance] recordLoadingFailedWithRequestID:requestID error:error];
        } else {
            [[OSNetworkRecorder sharedInstance] recordLoadingFinishedWithRequestID:requestID responseBody:requestState.dataAccumulator];
        }
        [self removeRequestStateForRequestID:requestID];
    }];
}

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask didWriteData:(int64_t)bytesWritten totalBytesWritten:(int64_t)totalBytesWritten totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite delegate:(id<NSURLSessionDelegate>)delegate
{
    [self performBlock:^{
        NSString *requestID = [[self class] requestIDForConnectionOrTask:downloadTask];
        OSInternalRequestState *requestState = [self requestStateForRequestID:requestID];
        
        if (!requestState.dataAccumulator) {
            NSUInteger unsignedBytesExpectedToWrite = totalBytesExpectedToWrite > 0 ? (NSUInteger)totalBytesExpectedToWrite : 0;
            requestState.dataAccumulator = [[NSMutableData alloc] initWithCapacity:unsignedBytesExpectedToWrite];
            [[OSNetworkRecorder sharedInstance] recordResponseReceivedWithRequestID:requestID response:downloadTask.response];
        }
        [[OSNetworkRecorder sharedInstance] recordDataReceivedWithRequestID:requestID dataLength:bytesWritten];
    }];
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionDownloadTask *)downloadTask didFinishDownloadingToURL:(NSURL *)location data:(NSData *)data delegate:(id<NSURLSessionDelegate>)delegate
{
    data = [data copy];
    [self performBlock:^{
        NSString *requestID = [[self class] requestIDForConnectionOrTask:downloadTask];
        OSInternalRequestState *requestState = [self requestStateForRequestID:requestID];
        [requestState.dataAccumulator appendData:data];
    }];
}

- (void)URLSessionTaskWillResume:(NSURLSessionTask *)task
{
    // Since resume can be called multiple times on the same task, only treat the first resume as
    // the equivalent to connection:willSendRequest:...
    [self performBlock:^{
        NSString *requestID = [[self class] requestIDForConnectionOrTask:task];
        OSInternalRequestState *requestState = [self requestStateForRequestID:requestID];
        if (!requestState.request) {
            requestState.request = task.currentRequest;
            
            [[OSNetworkRecorder sharedInstance] recordRequestWillBeSentWithRequestID:requestID request:task.currentRequest redirectResponse:nil];
        }
    }];
}

@end
