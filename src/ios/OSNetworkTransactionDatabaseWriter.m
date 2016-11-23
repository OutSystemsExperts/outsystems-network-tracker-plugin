//
//  OSNetowrkTransactionDatabaseWriter.m
//  NetworkTracker
//
//  Created by João Gonçalves on 18/11/16.
//
//

#import "OSNetworkTransactionDatabaseWriter.h"
#include "sqlite3.h"
#import "FMDB.h"

@interface OSNetworkTransactionDatabaseWriter()

/*
 *   Identifies a running session.
 *   A running session is the time of execution since the application goes into foreground and ends when entering on background.
 */
@property time_t sessionId;

@end

@implementation OSNetworkTransactionDatabaseWriter

- (instancetype)init
{
    self = [super init];
    if (self) {
        [self createTable];
    }
    return self;
}

-(void) newSession{
    self.sessionId = [[NSDate date] timeIntervalSince1970];
}

- (NSString*) filename {
    NSString *documentsPath = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    NSString *filePath = [documentsPath stringByAppendingPathComponent:@"os_network_trace.db"];
    return filePath;
}

- (void) createTable {
    
    NSString *createSqlStmnt = @" \
    CREATE TABLE IF NOT EXISTS 'traces' ( \
    'id'	TEXT, \
    'appSessionId'	INTEGER, \
    'startTime'	INTEGER, \
    'duration'	INTEGER, \
    'latency'	INTEGER, \
    'requestMethod'	TEXT, \
    'requestUrl'	TEXT, \
    'requestHttpVersion'	TEXT, \
    'requestCookies'	TEXT, \
    'requestHeaders'	TEXT, \
    'requestQueryString'	TEXT, \
    'requestPostData'	TEXT, \
    'requestHeadersSize'	INTEGER, \
    'requestBodySize'	INTEGER, \
    'responseStatus'	INTEGER, \
    'responseStatusText'	TEXT, \
    'responseHttpVersion'	TEXT, \
    'responseCookies'	TEXT, \
    'responseHeaders'	TEXT, \
    'responseRedirectURL'	TEXT, \
    'responseHeaderSize' INTEGER \
    'responseBodySize'	INTEGER, \
    'responseContent'	TEXT, \
    PRIMARY KEY(id) \
    ); \
    ";
    
    FMDatabaseQueue *dbQueue = [FMDatabaseQueue databaseQueueWithPath: [self filename]];
    [dbQueue inDatabase:^(FMDatabase *db) {
        [db executeUpdate:createSqlStmnt];
        
    }];
    [dbQueue close];
}

- (void) writeNetworkTransaction: (OSNetworkTransaction* ) transaction responseBody:(NSData*) responseBody {
    // NSLog(@"\n\nWrite transaction\n%@\n\n", transaction);
    
    
    NSString* queryInsert = [NSString stringWithFormat:@"INSERT INTO traces values (%@, %ld, %lf, %lf, %lf, %@, %@, %@, %@, %@, %@, %ld, %ld, %ld, %@, %@, %@, %@, %ld, %ld )",
                             [transaction requestID],
                             self.sessionId,
                             [[transaction startTime] timeIntervalSince1970],
                             [transaction duration],
                             [transaction latency],
                             [transaction.request HTTPMethod],
                             [[transaction.request URL] absoluteString],
                             kCFHTTPVersion1_1,
                             [self getHeadersString:[transaction.request allHTTPHeaderFields]],
                             [self getURLQueryOnTransaction:transaction],
                             [self getHTTPRequestPostDataOnTransaction:transaction],
                             [self getHeadersSizeOnTransaction:transaction],
                             [self getBodySizeForTransaction:transaction],
                             [self getHTTPResponseStatusCodeForTransaction:transaction],
                             [self getHTTPResponseStatusTextForTransaction:transaction],
                             [self getHTTPResponseCookiesForTransaction:transaction],
                             [self getHeadersString:[(NSHTTPURLResponse*) transaction.response allHeaderFields]],
                             @"",
                             [self getHTTPResponseHeadersSizeForTransaction:transaction],
                             [self getHTTPResponseBodySizeForTransaction:transaction withResponseData:responseBody]];
    
    NSLog(@"\n\nWrite transaction\n%@\n\n", queryInsert);
    
    
}

-(NSString*) getURLQueryOnTransaction:(OSNetworkTransaction*) transaction {
    if([[transaction.request URL] query]){
        return [[transaction.request URL] query];
    }else {
        return @"";
    }
}

-(NSString*) getHeadersString:(NSDictionary<NSString *, NSString *>*) allHTTPHeaderFields{
    NSMutableString* headersString = [NSMutableString stringWithCapacity:10];
    for (NSString* headerKey in allHTTPHeaderFields) {
        [headersString appendFormat:@"%@: %@\n", headerKey, [allHTTPHeaderFields objectForKey:headerKey]];
    }
    return [headersString copy];
}

-(long) getHeadersSizeOnTransaction:(OSNetworkTransaction*) transaction {
    //    if(transaction.request) {
    //        return [[transaction.request HTTPBody] length];
    //    } else {
    //        return -1;
    //    }
    return -1; // TODO(jppg) implement a proper way of calculating headers size
}

-(long) getBodySizeForTransaction:(OSNetworkTransaction*) transaction {
    if([[transaction request] HTTPBody]) {
        return [[transaction.request HTTPBody] length];
    } else {
        return -1;
    }
}

/*
 *  "postData": {
 *      "mimeType": "multipart/form-data",
 *      "params": [],
 *      "text" : "plain posted data",
 *      "comment": ""
 *      }
 *
 */

-(NSString*) getHTTPRequestPostDataOnTransaction:(OSNetworkTransaction*) transaction {
    
    NSURLRequest* request = transaction.request;
    
    NSString* postMimeType = [[request allHTTPHeaderFields] objectForKey:@"Content-Type"];
    
    if([transaction.request HTTPBody]) {
        return [[transaction.request HTTPBody] base64EncodedStringWithOptions:0];
    } else {
        return @"";
    }
}

-(long) getHTTPResponseStatusCodeForTransaction:(OSNetworkTransaction*) transaction {
    NSHTTPURLResponse* response = (NSHTTPURLResponse*) transaction.response;
    if([transaction.response respondsToSelector:@selector(statusCode)]) {
        return [response statusCode];
    }
    
    return -1;
}


-(NSString*) getHTTPResponseStatusTextForTransaction: (OSNetworkTransaction*) transaction {
    NSHTTPURLResponse* response = (NSHTTPURLResponse*) transaction.response;
    if([transaction.response respondsToSelector:@selector(statusCode)]) {
        return [NSHTTPURLResponse localizedStringForStatusCode:response.statusCode];
        
    }
    else {
        return @"";
    }
    
}

-(NSString*) getHTTPResponseCookiesForTransaction: (OSNetworkTransaction*) transaction {
    NSHTTPURLResponse* response = (NSHTTPURLResponse*) transaction.response;
    if([transaction.response respondsToSelector:@selector(statusCode)]) {
        NSArray* cookies = [[NSArray alloc] init];
        cookies = [NSHTTPCookie cookiesWithResponseHeaderFields:[response allHeaderFields] forURL:[response URL]];
        return @"";
    }
    
    return @"";
}

-(long) getHTTPResponseHeadersSizeForTransaction: (OSNetworkTransaction*) transaction {
    // TODO(jppg) implement proper header size calculation
    return -1;
}

-(long) getHTTPResponseBodySizeForTransaction:(OSNetworkTransaction*) transaction withResponseData:(NSData*) responseData {
    if(responseData) {
        return responseData.length;
    } else {
        return -1;
    }
}

/*
 
 "content": {
    "size": 33,
    "compression": 0,
    "mimeType": "text/html; charset=utf-8",
    "text": "\n",
    "comment": ""
 }
 
 */
-(NSString*) getHTTPResponseContentForTransaction: (OSNetworkTransaction*) transaction responseBody:(NSData*) responseBody {
    NSMutableDictionary* responseContent = [[NSMutableDictionary alloc] init];
    
    long bodySize = responseBody ? [responseBody length] : 0;
    [responseContent setObject:[NSNumber numberWithLong:bodySize] forKey:@"size"];
    
}
@end
