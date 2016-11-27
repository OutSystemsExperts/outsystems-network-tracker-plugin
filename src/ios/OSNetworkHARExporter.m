//
//  OSNetworkHARExporter.m
//  OutSystems
//
//  Created by João Gonçalves on 25/11/16.
//
//

#import "OSNetworkHARExporter.h"
#import "FMDB.h"

@implementation OSNetworkHARExporter

- (instancetype)init
{
    self = [super init];
    if (self) {
        
    }
    return self;
}

+(instancetype)sharedInstance {
    static OSNetworkHARExporter *sharedInstace = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstace = [[[self class] alloc] init];
    });
    return sharedInstace;
}

- (NSString*) filePath: (NSNumber*) session {
    NSString *documentsPath = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    NSString *filePath = [documentsPath stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.har", session]];
    return filePath;
}

- (BOOL) exportHARForSession: (NSNumber*) sessionId dbFilePath: (NSString*) dbFilePath {
    
    FMDatabaseQueue *dbQueue = [FMDatabaseQueue databaseQueueWithPath: dbFilePath];
    
    __block BOOL returnValue = NO;
    
    [dbQueue inDatabase:^(FMDatabase *db) {
        FMResultSet *result = [db executeQuery:@"SELECT * FROM traces WHERE traces.appSessionId = ?", sessionId];
        
        NSMutableDictionary *root = [[NSMutableDictionary alloc] init];
        
        // log
        NSMutableDictionary *log = [[NSMutableDictionary alloc] init];
        [log setObject:@"1.2" forKey:@"version"];
        
        // creator
        NSDictionary *creator = @{@"name": @"OutSystems Network Tracer Plugin", @"version": @"0.1"};
        [log setObject:creator forKey:@"creator"];
        
        // entries
        NSMutableArray* entriesArray = [[NSMutableArray alloc] init];
        
        while([result next]) {
            NSMutableDictionary *entry = [[NSMutableDictionary alloc] init];
            
            // startedDateTime
            
            NSDate* startedDatetime = [result dateForColumn:@"startTime"];
            [entry setObject:[self getISO8601FromDate:startedDatetime] forKey:@"startedDateTime"];
            
            // time
            
            double duration = [result doubleForColumn:@"duration"];
            duration = duration * 1000; // HAR expects value in milliseconds
            [entry setObject:[NSNumber numberWithDouble:duration] forKey:@"time"];
            
            // request
            NSMutableDictionary *request = [[NSMutableDictionary alloc] init];
            
            // request - method
            NSString *method = [result stringForColumn:@"requestMethod"];
            [request setObject:method forKey:@"method"];
            
            // request - url
            NSString *requestUrl = [result stringForColumn:@"requestUrl"];
            [request setObject:requestUrl forKey:@"url"];
            
            // request - httpVersion
            NSString *requestHttpVersion = [result stringForColumn:@"requestHttpVersion"];
            [request setObject:requestHttpVersion forKey:@"httpVersion"];
            
            // request - cookies
            NSString *requestCookies = [result stringForColumn:@"requestCookies"];
            NSArray *cookiesArray = [self getNSArrayFromJSONString:requestCookies];
            [request setObject:cookiesArray forKey:@"cookies"];
            
            // request - headers
            NSString *requestHeaders = [result stringForColumn:@"requestHeaders"];
            NSArray *requestHeadersArray = [self getNSArrayFromJSONString:requestHeaders];
            [request setObject:requestHeadersArray forKey:@"headers"];
            
            // request - queryString
            NSString *requestQueryString = [result stringForColumn:@"requestQueryString"];
            NSArray *requestQueryStringArray = [self getNSArrayFromJSONString:requestQueryString];
            [request setObject:requestQueryStringArray forKey:@"queryString"];
            
            // request - postData
            NSString *requestPostData = [result stringForColumn:@"requestPostData"];
            NSArray *requestPostDataArray = [self getNSArrayFromJSONString:requestPostData];
            if([requestPostData length] > 0) {
                [request setObject:requestPostDataArray forKey:@"postData"];
            }
            // request - headerSize
            long requestHeaderSize = [result longForColumn:@"requestHeadersSize"];
            [request setObject:@(requestHeaderSize) forKey:@"headersSize"];
            
            // request - bodySize
            long requestBodySize = [result longForColumn:@"requestBodySize"];
            [request setObject:@(requestBodySize) forKey:@"bodySize"];
            
            
            [entry setObject:request forKey:@"request"];
            
            // response
            NSMutableDictionary *response = [[NSMutableDictionary alloc] init];
            
            // response - status
            int responseStatus = [result intForColumn:@"responseStatus"];
            [response setObject:@(responseStatus) forKey:@"status"];
            
            // response - statusText
            NSString* responseStatusText = [result stringForColumn:@"responseStatusText"];
            [response setObject:responseStatusText forKey:@"statusText"];
            
            // response - httpVersion
            NSString* responseHttpVersion = [result stringForColumn:@"responseHttpVersion"];
            [response setObject:responseHttpVersion forKey:@"httpVersion"];
            
            // response - cookies
            NSString* responseCookies = [result stringForColumn:@"responseCookies"];
            NSArray *responseCookiesArray = [self getNSArrayFromJSONString:responseCookies];
            [response setObject:responseCookiesArray forKey:@"cookies"];
            
            // response - headers
            NSString* responseHeaders = [result stringForColumn:@"responseHeaders"];
            NSArray *responseHeadersArray = [self getNSArrayFromJSONString:responseHeaders];
            [response setObject:responseHeadersArray forKey:@"headers"];
            
            // response - content
            NSString* responseContent = [result stringForColumn:@"responseContent"];
            NSDictionary *responseContentDictionary = [self getNSDictionaryFromJSONString:responseContent];
            [response setObject:responseContentDictionary forKey:@"content"];
            
            // response - redirectURL
            NSString* responseRedirectURL = [result stringForColumn:@"responseRedirectURL"];
            [response setObject:responseRedirectURL forKey:@"redirectURL"];
            
            // response - headersSize
            int responseHeaderSize = [result intForColumn:@"responseHeaderSize"];
            [response setObject:@(responseHeaderSize) forKey:@"headersSize"];
            
            // response - bodySize
            int responseBodySize = [result intForColumn:@"responseBodySize"];
            [response setObject:@(responseBodySize) forKey:@"bodySize"];
            
            [entry setObject:response forKey:@"response"];
            
            // cache
            NSMutableDictionary *cache = [[NSMutableDictionary alloc] init];
            
            // cache - beforeRequest
            
            
            // cache - afterRequest
            
            
            [entry setObject:cache forKey:@"cache"];
            
            // timings
//            send [number] - Time required to send HTTP request to the server.
//            wait [number] - Waiting for a response from the server.
//            receive [number] - Time required to read entire response from the server (or cache).
            
            NSMutableDictionary *timings = [[NSMutableDictionary alloc] init];
            // timings - send
//            long send = [result longForColumn:@"duration"];
//            send = send * 1000; // HAR expects value in milliseconds
            [timings setObject:[NSNumber numberWithDouble:0] forKey:@"send"]; // Harcoded 0, perhaps implement this?
            
            // timings - wait
            double wait = [result doubleForColumn:@"latency"];
            wait = wait * 1000; // HAR expects value in milliseconds
            [timings setObject:[NSNumber numberWithDouble:wait] forKey:@"wait"];
            
            // timings - receive
            double receive = [result doubleForColumn:@"duration"];
            receive = receive * 1000; // HAR expects value in milliseconds
            [timings setObject:[NSNumber numberWithDouble:receive] forKey:@"receive"];
            
            [entry setObject:timings forKey:@"timings"];
            // serverIPAddress
            // connection
            [entriesArray addObject:entry];
        }
        
        [log setObject:entriesArray forKey:@"entries"];
        
        [root setObject:log forKey:@"log"];
        
        
        NSError *error;
        NSData* jsonData = [NSJSONSerialization dataWithJSONObject:root options:NSJSONWritingPrettyPrinted error:&error];
        NSString* jsonString = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
        
        
        
        if(error) {
            returnValue = NO;
        } else {
            returnValue = YES;
            [jsonString writeToFile:[self filePath:sessionId]  atomically:YES encoding:NSUTF8StringEncoding error:&error];
            
        }
        
        
        [db close];
        
    }];
    
    return NO;
}

-(NSString *) getISO8601FromDate: (NSDate*) date {
    NSDateFormatter *dateFormatter = [[NSDateFormatter alloc] init];
    NSLocale *enUSPOSIXLocale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    [dateFormatter setLocale:enUSPOSIXLocale];
    [dateFormatter setDateFormat:@"yyyy-MM-dd'T'HH:mm:ssZZZZZ"];
    
    return [dateFormatter stringFromDate:date];
    
}

- (NSArray*) getNSArrayFromJSONString:(NSString*) jsonString {
    NSData *jsonData = [jsonString dataUsingEncoding:NSUTF8StringEncoding];
    NSError *error;
    NSArray* array = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:&error];
    if(error) {
        return [[NSArray alloc] init];
    } else {
        return array;
    }
}

- (NSDictionary*) getNSDictionaryFromJSONString:(NSString*) jsonString {
    NSData *jsonData = [jsonString dataUsingEncoding:NSUTF8StringEncoding];
    NSError *error;
    NSDictionary* dictionary = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:&error];
    if(error) {
        return [[NSDictionary alloc] init];
    } else {
        return dictionary;
    }
}


@end
