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
    'responseHeaderSize' INTEGER, \
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
    
    
//    NSString* queryInsert = [NSString stringWithFormat:@"INSERT INTO traces VALUES (%@, %ld, %lf, %lf, %lf, %@, %@, %@, %@, %@, %@, %@, %ld, %ld, %ld, %@, %@, %@, %@, %ld, %ld, %@ )",
//                             ];
    
    FMDatabaseQueue *dbQueue = [FMDatabaseQueue databaseQueueWithPath: [self filename]];
    [dbQueue inDatabase:^(FMDatabase *db) {
        
        NSString* insertStmt = @" \
        INSERT INTO traces ( \
        id, \
        appSessionId, \
        startTime, \
        duration, \
        latency, \
        requestMethod, \
        requestUrl, \
        requestHttpVersion, \
        requestCookies, \
        requestHeaders, \
        requestQueryString, \
        requestPostData, \
        requestHeadersSize, \
        requestBodySize, \
        responseStatus, \
        responseStatusText, \
        responseHttpVersion, \
        responseCookies, \
        responseHeaders, \
        responseRedirectURL, \
        responseHeaderSize, \
        responseBodySize, \
        responseContent \
        ) \
        VALUES ( ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ? );";
        
        BOOL inserted = [db executeUpdate:insertStmt,
                         [transaction requestID],
                         [NSNumber numberWithLong: [self sessionId]],
                         [NSNumber numberWithDouble: [[transaction startTime] timeIntervalSince1970]],
                         [NSNumber numberWithDouble: [transaction duration]],
                         [NSNumber numberWithDouble: [transaction latency]],
                         [transaction.request HTTPMethod],
                         [[transaction.request URL] absoluteString],
                         kCFHTTPVersion1_1,
                         [self getHTTPRequestCookiesForTransaction:transaction],
                         [self getHeadersString:[transaction.request allHTTPHeaderFields]],
                         [self getURLQueryOnTransaction:transaction],
                         [self getHTTPRequestPostDataOnTransaction:transaction],
                         [NSNumber numberWithDouble: [self getHeadersSizeOnTransaction:transaction]],
                         [NSNumber numberWithDouble: [self getBodySizeForTransaction:transaction]],
                         [NSNumber numberWithDouble: [self getHTTPResponseStatusCodeForTransaction:transaction]],
                         [self getHTTPResponseStatusTextForTransaction:transaction],
                         kCFHTTPVersion1_1,
                         [self getHTTPResponseCookiesForTransaction:transaction],
                         [self getHeadersString:[(NSHTTPURLResponse*) transaction.response allHeaderFields]],
                         @"",
                         [NSNumber numberWithDouble: [self getHTTPResponseHeadersSizeForTransaction:transaction]],
                         [NSNumber numberWithDouble: [self getHTTPResponseBodySizeForTransaction:transaction withResponseData:responseBody]],
                         [self getHTTPResponseContentForTransaction:transaction responseBody:responseBody]];
        
//        BOOL inserted = [db executeUpdate:@"INSERT INTO traces (id, appSessionId) VALUES (?, ?)",
//                         [transaction requestID],
//                         [NSNumber numberWithLong: [self sessionId]]];
        if(!inserted)
            NSLog(@"error = %@", [db lastErrorMessage]);
        
    }];
    
    
}

-(NSString*) getURLQueryOnTransaction:(OSNetworkTransaction*) transaction {
    if([[transaction.request URL] query]){
        return [[transaction.request URL] query];
    }else {
        return @"";
    }
}


//  "headers": [
//            {
//                "name": "Accept-Encoding",
//                "value": "gzip,deflate",
//                "comment": ""
//            },
//            {
//                "name": "Accept-Language",
//                "value": "en-us,en;q=0.5",
//                "comment": ""
//  }]
-(NSString*) getHeadersString:(NSDictionary<NSString *, NSString *>*) allHTTPHeaderFields {
    
    if([allHTTPHeaderFields count] == 0) {
        return @"[]";
    }
    
    NSMutableArray* headers = [[NSMutableArray alloc] init];
    for (NSString* headerKey in allHTTPHeaderFields) {
        NSDictionary *headersDict = @{@"name":headerKey, @"value": [allHTTPHeaderFields objectForKey:headerKey] };
        [headers addObject:headersDict];
    }
    
    NSError *error;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:headers options:0 error: &error];
    if(error) {
        return @"[]";
    } else {
        return [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
    }
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
    if([transaction.request HTTPBody]) {
        NSString* postMimeType = [[request allHTTPHeaderFields] objectForKey:@"Content-Type"];
        if(!postMimeType) {
            postMimeType = [[request allHTTPHeaderFields] objectForKey:@"content-type"];
        }
        
        NSMutableString *text = [[NSMutableString alloc] init];
        [text appendString:[[NSString alloc] initWithData:[transaction.request HTTPBody] encoding:NSUTF8StringEncoding]] ;
        
        // TODO(jppg) add support for:
        // - application/x-www-form-urlencoded
        // - multipart/form-data
        
        NSMutableDictionary *postData = [[NSMutableDictionary alloc] init];
        [postData setObject:postMimeType forKey:@"mimeType"];
        [postData setObject:text forKey:@"text"];
        [postData setObject:@"[]" forKey:@"params"];
        
        NSError *error;
        NSData *jsonPostData = [NSJSONSerialization dataWithJSONObject:postData options:0 error:&error];
        if(error) {
            return @"{}";
        } else {
            return [[NSString alloc] initWithData:jsonPostData encoding:NSUTF8StringEncoding];
        }
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


//"cookies": [
//            {
//                "name": "TestCookie",
//                "value": "Cookie Value",
//                "path": "/",
//                "domain": "www.janodvarko.cz",
//                "expires": "2009-07-24T19:20:30.123+02:00",
//                "httpOnly": false,
//                "secure": false,
//                "comment": ""
//            }
//            ]
-(NSString*) getHTTPRequestCookiesForTransaction: (OSNetworkTransaction*) transaction {
    NSURLRequest *request = transaction.request;
    return [self getCookiesOnHeaders:request.allHTTPHeaderFields URL:request.URL];
}


-(NSString*) getHTTPResponseCookiesForTransaction: (OSNetworkTransaction*) transaction {
    NSHTTPURLResponse* response = (NSHTTPURLResponse*) transaction.response;
    if([transaction.response respondsToSelector:@selector(statusCode)]) {
        return [self getCookiesOnHeaders:[response allHeaderFields] URL:response.URL];
    }
    return @"";
}

-(NSString*) getCookiesOnHeaders: (NSDictionary*) httpHeaders URL:(NSURL*) url {
    NSArray* cookies = [[NSArray alloc] init];
    cookies = [NSHTTPCookie cookiesWithResponseHeaderFields:httpHeaders forURL:url];
    
    if([cookies count] == 0) {
        return @"[]";
    }
    
    NSDateFormatter *dateFormatter = [[NSDateFormatter alloc] init];
    NSLocale *enUSPOSIXLocale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    [dateFormatter setLocale:enUSPOSIXLocale];
    [dateFormatter setDateFormat:@"yyyy-MM-dd'T'HH:mm:ssZZZZZ"];
    
    NSMutableArray* cookiesObj = [[NSMutableArray alloc] init];
    
    for (NSHTTPCookie* cookie in cookies) {
        
        NSMutableDictionary *cookieDto = [[NSMutableDictionary alloc] init];
        
        [cookieDto setObject:[cookie name] forKey:@"name"];
        [cookieDto setObject:[cookie value] forKey:@"value"];
        
        if([cookie path]) {
            [cookieDto setObject:[cookie path] forKey:@"path"];
        }
        
        if([cookie domain]) {
            [cookieDto setObject:[cookie domain] forKey:@"domain"];
        }
        
        if([cookie expiresDate]) {
            [cookieDto setObject:[dateFormatter stringFromDate:[cookie expiresDate]] forKey:@"expires"];
        }
        
        [cookieDto setObject:[cookie isHTTPOnly] ? @"true" : @"false" forKey:@"httpOnly"];
        [cookieDto setObject:[cookie isSecure] ? @"true" : @"false" forKey:@"secure"];
        
        [cookiesObj addObject:cookieDto];
    }
    
    
    NSError *error;
    NSData* jsonData = [NSJSONSerialization dataWithJSONObject:cookiesObj options:0 error:&error];
    if(error) {
        return @"[]";
    } else {
        return [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
    }
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
 "encoding": "base64",
 "comment": ""
 }
 
 */
-(NSString*) getHTTPResponseContentForTransaction: (OSNetworkTransaction*) transaction responseBody:(NSData*) responseBody {
    if(responseBody) {
        
        NSMutableDictionary* responseContent = [[NSMutableDictionary alloc] init];
        
        long bodySize = responseBody ? [responseBody length] : 0;
        [responseContent setObject:[NSNumber numberWithLong:bodySize] forKey:@"size"];
        [responseContent setObject:[NSNumber numberWithInt:0] forKey:@"compression"];
        [responseContent setObject:[transaction.response MIMEType] forKey:@"mimeType"];
        
        
        NSString* responseEncodingName = [(NSHTTPURLResponse*) transaction.response textEncodingName];
        
        
        if(!responseEncodingName) {
            if([[[transaction.response MIMEType] lowercaseString] containsString:@"text"] ||
               [[[transaction.response MIMEType] lowercaseString] containsString:@"application/json"] ||
               [[[transaction.response MIMEType] lowercaseString] containsString:@"application/javascript"]) {
                
                responseEncodingName = @"utf-8";
                
            }
        }
        
        NSStringEncoding encodingType = [NSString defaultCStringEncoding];
        if(responseEncodingName){
            encodingType = CFStringConvertEncodingToNSStringEncoding(CFStringConvertIANACharSetNameToEncoding((__bridge CFStringRef)responseEncodingName));
        }
        
        if(responseEncodingName) {
            NSString* textualResponse = [[NSString alloc] initWithData:responseBody encoding:encodingType];
            [responseContent setObject:textualResponse forKey:@"text"];
        } else {
            [responseContent setObject:[responseBody base64EncodedStringWithOptions:0] forKey:@"text"];
            [responseContent setObject:@"base64" forKey:@"encoding"];
        }
        
        
        return [responseContent description];
        
    }
    return @"";
}
@end
