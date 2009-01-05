//
//  ASIHTTPRequest.m
//
//  Created by Ben Copsey on 04/10/2007.
//  Copyright 2007-2008 All-Seeing Interactive. All rights reserved.
//
//  A guide to the main features is available at:
//  http://allseeing-i.com/ASIHTTPRequest
//
//  Portions are based on the ImageClient example from Apple:
//  See: http://developer.apple.com/samplecode/ImageClient/listing37.html

#import "ASIHTTPRequest.h"
#import "NSHTTPCookieAdditions.h"

// We use our own custom run loop mode as CoreAnimation seems to want to hijack our threads otherwise
static CFStringRef ASIHTTPRequestRunMode = CFSTR("ASIHTTPRequest");

static NSString *NetworkRequestErrorDomain = @"com.Your-Company.Your-Product.NetworkError.";

static const CFOptionFlags kNetworkEvents = kCFStreamEventOpenCompleted | kCFStreamEventHasBytesAvailable | kCFStreamEventEndEncountered | kCFStreamEventErrorOccurred;

static CFHTTPAuthenticationRef sessionAuthentication = NULL;
static NSMutableDictionary *sessionCredentials = nil;
static NSMutableArray *sessionCookies = nil;


static void ReadStreamClientCallBack(CFReadStreamRef readStream, CFStreamEventType type, void *clientCallBackInfo) {
    [((ASIHTTPRequest*)clientCallBackInfo) handleNetworkEvent: type];
}

// This lock prevents the operation from being cancelled while it is trying to update the progress, and vice versa
static NSRecursiveLock *progressLock;

static NSError *ASIRequestCancelledError;
static NSError *ASIRequestTimedOutError;
static NSError *ASIAuthenticationError;
static NSError *ASIUnableToCreateRequestError;

@implementation ASIHTTPRequest



#pragma mark init / dealloc

+ (void)initialize
{
	if (self == [ASIHTTPRequest class]) {
		progressLock = [[NSRecursiveLock alloc] init];
		ASIRequestTimedOutError = [[NSError errorWithDomain:NetworkRequestErrorDomain code:ASIRequestTimedOutErrorType userInfo:[NSDictionary dictionaryWithObjectsAndKeys:@"The request timed out",NSLocalizedDescriptionKey,nil]] retain];	
		ASIAuthenticationError = [[NSError errorWithDomain:NetworkRequestErrorDomain code:ASIAuthenticationErrorType userInfo:[NSDictionary dictionaryWithObjectsAndKeys:@"Authentication needed",NSLocalizedDescriptionKey,nil]] retain];
		ASIRequestCancelledError = [[NSError errorWithDomain:NetworkRequestErrorDomain code:ASIRequestCancelledErrorType userInfo:[NSDictionary dictionaryWithObjectsAndKeys:@"The request was cancelled",NSLocalizedDescriptionKey,nil]] retain];
		ASIUnableToCreateRequestError = [[NSError errorWithDomain:NetworkRequestErrorDomain code:ASIUnableToCreateRequestErrorType userInfo:[NSDictionary dictionaryWithObjectsAndKeys:@"Unable to create request (bad url?)",NSLocalizedDescriptionKey,nil]] retain];
	}
	[super initialize];
}

- (id)initWithURL:(NSURL *)newURL
{
	self = [super init];
	[self setRequestMethod:@"GET"];
	lastBytesSent = 0;
	showAccurateProgress = YES;
	shouldResetProgressIndicators = YES;
	updatedProgress = NO;
	[self setMainRequest:nil];
	[self setPassword:nil];
	[self setUsername:nil];
	[self setRequestHeaders:nil];
	authenticationRealm = nil;
	outputStream = nil;
	requestAuthentication = NULL;
	haveBuiltPostBody = NO;
	request = NULL;
	[self setUploadBufferSize:0];
	[self setResponseHeaders:nil];
	[self setTimeOutSeconds:10];
	[self setUseKeychainPersistance:NO];
	[self setUseSessionPersistance:YES];
	[self setUseCookiePersistance:YES];
	[self setRequestCookies:[[[NSMutableArray alloc] init] autorelease]];
	[self setDidFinishSelector:@selector(requestFinished:)];
	[self setDidFailSelector:@selector(requestFailed:)];
	[self setDelegate:nil];
	url = [newURL retain];
	cancelledLock = [[NSLock alloc] init];
	return self;
}

- (void)dealloc
{
	if (requestAuthentication) {
		CFRelease(requestAuthentication);
	}
	if (request) {
		CFRelease(request);
	}
	[self cancelLoad];
	[mainRequest release];
	[postBody release];
	[requestCredentials release];
	[error release];
	[requestHeaders release];
	[requestCookies release];
	[downloadDestinationPath release];
	[outputStream release];
	[username release];
	[password release];
	[domain release];
	[authenticationRealm release];
	[url release];
	[authenticationLock release];
	[lastActivityTime release];
	[responseCookies release];
	[receivedData release];
	[responseHeaders release];
	[requestMethod release];
	[cancelledLock release];
	[super dealloc];
}


#pragma mark setup request

- (void)addRequestHeader:(NSString *)header value:(NSString *)value
{
	if (!requestHeaders) {
		[self setRequestHeaders:[NSMutableDictionary dictionaryWithCapacity:1]];
	}
	[requestHeaders setObject:value forKey:header];
}

-(void)setPostBody:(NSData *)body
{
	postBody = [body retain];
	postLength = [postBody length];
	[self addRequestHeader:@"Content-Length" value:[NSString stringWithFormat:@"%llu",postLength]];
	if (postBody && postLength > 0 && ![requestMethod isEqualToString:@"POST"] && ![requestMethod isEqualToString:@"PUT"]) {
		[self setRequestMethod:@"POST"];
	}
}

// Subclasses should override this method if they need to create POST content for this request
// This function will be called either just before a request starts, or when postLength is needed, whichever comes first
// postLength must be set by the time this function is complete - calling setPostBody: will do this for you
- (void)buildPostBody
{
	haveBuiltPostBody = YES;
}

#pragma mark get information about this request

- (BOOL)isFinished 
{
	return complete;
}


- (void)cancel
{
	[self failWithError:ASIRequestCancelledError];
	[self cancelLoad];
	complete = YES;
	[super cancel];
}


// Call this method to get the recieved data as an NSString. Don't use for Binary data!
- (NSString *)dataString
{
	if (!receivedData) {
		return nil;
	}
	return [[[NSString alloc] initWithBytes:[receivedData bytes] length:[receivedData length] encoding:NSUTF8StringEncoding] autorelease];
}


#pragma mark request logic

// Create the request
- (void)main
{
	
	[pool release];
	pool = [[NSAutoreleasePool alloc] init];
	
	complete = NO;
	
	if (!url) {
		[self failWithError:ASIUnableToCreateRequestError];
		return;		
	}
	
    // Create a new HTTP request.
	request = CFHTTPMessageCreateRequest(kCFAllocatorDefault, (CFStringRef)requestMethod, (CFURLRef)url, kCFHTTPVersion1_1);
    if (!request) {
		[self failWithError:ASIUnableToCreateRequestError];
		return;
    }
	
	// If we've already talked to this server and have valid credentials, let's apply them to the request
	if (useSessionPersistance && sessionCredentials && sessionAuthentication) {
		if (!CFHTTPMessageApplyCredentialDictionary(request, sessionAuthentication, (CFMutableDictionaryRef)sessionCredentials, NULL)) {
			[ASIHTTPRequest setSessionAuthentication:NULL];
			[ASIHTTPRequest setSessionCredentials:nil];
		}
	}
	
	// Add cookies from the persistant (mac os global) store
	if (useCookiePersistance) {
		NSArray *cookies = [[NSHTTPCookieStorage sharedHTTPCookieStorage] cookiesForURL:url];
		if (cookies) {
			[requestCookies addObjectsFromArray:cookies];
		}
	}
	
	// Apply request cookies
	NSArray *cookies;
	if ([self mainRequest]) {
		cookies = [[self mainRequest] requestCookies];
	} else {
		cookies = [self requestCookies];
	}
	if ([cookies count] > 0) {
		NSHTTPCookie *cookie;
		NSString *cookieHeader = nil;
		for (cookie in cookies) {
			if (!cookieHeader) {
				cookieHeader = [NSString stringWithFormat: @"%@=%@",[cookie name],[cookie encodedValue]];
			} else {
				cookieHeader = [NSString stringWithFormat: @"%@; %@=%@",cookieHeader,[cookie name],[cookie encodedValue]];
			}
		}
		if (cookieHeader) {
			[self addRequestHeader:@"Cookie" value:cookieHeader];
		}
	}
	
	
	if (!haveBuiltPostBody) {
		[self buildPostBody];
	}
	
	// Add custom headers
	NSDictionary *headers;
	
	//Add headers from the main request if this is a HEAD request generated by an ASINetwork Queue
	if ([self mainRequest]) {
		headers = [mainRequest requestHeaders];
	} else {
		headers = [self requestHeaders];
	}	
	NSString *header;
	for (header in headers) {
		CFHTTPMessageSetHeaderFieldValue(request, (CFStringRef)header, (CFStringRef)[requestHeaders objectForKey:header]);
	}
	
	
	// If this is a post request and we have data to send, add it to the request
	if ([self postBody]) {
		CFHTTPMessageSetBody(request, (CFDataRef)postBody);
	}
	
	[self loadRequest];
	
}


// Start the request
- (void)loadRequest
{

	[cancelledLock lock];
	
	if ([self isCancelled]) {
		[cancelledLock unlock];
		return;
	}
	
	[authenticationLock release];
	authenticationLock = [[NSConditionLock alloc] initWithCondition:1];
	
	complete = NO;
	totalBytesRead = 0;
	lastBytesRead = 0;
	
	// If we're retrying a request after an authentication failure, let's remove any progress we made
	if (lastBytesSent > 0 && uploadProgressDelegate) {
		[self removeUploadProgressSoFar];
	}
	
	lastBytesSent = 0;
	if (shouldResetProgressIndicators) {
		contentLength = 0;
	}
	[self setResponseHeaders:nil];
    [self setReceivedData:[[[NSMutableData alloc] init] autorelease]];
    
    // Create the stream for the request.
    readStream = CFReadStreamCreateForStreamedHTTPRequest(kCFAllocatorDefault, request,readStream);
    if (!readStream) {
		[cancelledLock unlock];
		[self failWithError:[NSError errorWithDomain:NetworkRequestErrorDomain code:ASIInternalErrorWhileBuildingRequestType userInfo:[NSDictionary dictionaryWithObjectsAndKeys:@"Unable to create read stream",NSLocalizedDescriptionKey,nil]]];
        return;
    }
    
    // Set the client
	CFStreamClientContext ctxt = {0, self, NULL, NULL, NULL};
    if (!CFReadStreamSetClient(readStream, kNetworkEvents, ReadStreamClientCallBack, &ctxt)) {
        CFRelease(readStream);
        readStream = NULL;
		[cancelledLock unlock];
		[self failWithError:[NSError errorWithDomain:NetworkRequestErrorDomain code:ASIInternalErrorWhileBuildingRequestType userInfo:[NSDictionary dictionaryWithObjectsAndKeys:@"Unable to setup read stream",NSLocalizedDescriptionKey,nil]]];
        return;
    }
    
    // Schedule the stream
    CFReadStreamScheduleWithRunLoop(readStream, CFRunLoopGetCurrent(), ASIHTTPRequestRunMode);
    
    // Start the HTTP connection
    if (!CFReadStreamOpen(readStream)) {
        CFReadStreamSetClient(readStream, 0, NULL, NULL);
        CFReadStreamUnscheduleFromRunLoop(readStream, CFRunLoopGetCurrent(), ASIHTTPRequestRunMode);
        CFRelease(readStream);
        readStream = NULL;
		[cancelledLock unlock];
		[self failWithError:[NSError errorWithDomain:NetworkRequestErrorDomain code:ASIInternalErrorWhileBuildingRequestType userInfo:[NSDictionary dictionaryWithObjectsAndKeys:@"Unable to start HTTP connection",NSLocalizedDescriptionKey,nil]]];
        return;
    }
	[cancelledLock unlock];
	
	
	if (uploadProgressDelegate && shouldResetProgressIndicators) {
		double amount = 1;
		if (showAccurateProgress) {
			amount = postLength;
		}
		[self resetUploadProgress:amount];
	}
	
	
	
	// Record when the request started, so we can timeout if nothing happens
	[self setLastActivityTime:[NSDate date]];
	
	// Wait for the request to finish
	while (!complete) {
		
		// This may take a while, so we'll release the pool each cycle to stop a giant backlog of autoreleased objects building up
		[pool release];
		pool = [[NSAutoreleasePool alloc] init];
		
		NSDate *now = [NSDate date];
		
		// See if we need to timeout
		if (lastActivityTime && timeOutSeconds > 0 && [now timeIntervalSinceDate:lastActivityTime] > timeOutSeconds) {
			
			// Prevent timeouts before 128KB has been sent when the size of data to upload is greater than 128KB
			// This is to workaround the fact that kCFStreamPropertyHTTPRequestBytesWrittenCount is the amount written to the buffer, not the amount actually sent
			// This workaround prevents erroneous timeouts in low bandwidth situations (eg iPhone)
			if (contentLength <= uploadBufferSize || (uploadBufferSize > 0 && lastBytesSent > uploadBufferSize)) {
				[self failWithError:ASIRequestTimedOutError];
				[self cancelLoad];
				complete = YES;
				break;
			}
		}
		
		// See if our NSOperationQueue told us to cancel
		if ([self isCancelled]) {
			break;
		}
		
		[self updateProgressIndicators];
		
		// This thread should wait for 1/4 second for the stream to do something. We'll stop early if it does.
		CFRunLoopRunInMode(ASIHTTPRequestRunMode,0.25,YES);
	}
	
	[pool release];
	pool = nil;
}

// Cancel loading and clean up
- (void)cancelLoad
{
	[cancelledLock lock];
    if (readStream) {
        CFReadStreamClose(readStream);
        CFReadStreamSetClient(readStream, kCFStreamEventNone, NULL, NULL);
        CFReadStreamUnscheduleFromRunLoop(readStream, CFRunLoopGetCurrent(), ASIHTTPRequestRunMode);
        CFRelease(readStream);
        readStream = NULL;
    }
	
    if (receivedData) {
		[self setReceivedData:nil];
	
	// If we were downloading to a file, let's remove it
	} else if (downloadDestinationPath) {
		[outputStream close];
		[[NSFileManager defaultManager] removeItemAtPath:downloadDestinationPath error:NULL];
	}
	
	[self setResponseHeaders:nil];
	[cancelledLock unlock];
}



#pragma mark upload/download progress


- (void)updateProgressIndicators
{
	
	//Only update progress if this isn't a HEAD request used to preset the content-length
	if (!mainRequest) {
		if (showAccurateProgress || (complete && !updatedProgress)) {
			[self updateUploadProgress];
			[self updateDownloadProgress];
		}
	}
	
}


- (void)setUploadProgressDelegate:(id)newDelegate
{
	uploadProgressDelegate = newDelegate;
	
	// If the uploadProgressDelegate is an NSProgressIndicator, we set it's MaxValue to 1.0 so we can treat it similarly to UIProgressViews
	SEL selector = @selector(setMaxValue:);
	if ([uploadProgressDelegate respondsToSelector:selector]) {
		double max = 1.0;
		NSMethodSignature *signature = [[uploadProgressDelegate class] instanceMethodSignatureForSelector:selector];
		NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
		[invocation setTarget:uploadProgressDelegate];
		[invocation setSelector:selector];
		[invocation setArgument:&max atIndex:2];
		[invocation invoke];
		
	}	
}

- (void)setDownloadProgressDelegate:(id)newDelegate
{
	downloadProgressDelegate = newDelegate;
	
	// If the downloadProgressDelegate is an NSProgressIndicator, we set it's MaxValue to 1.0 so we can treat it similarly to UIProgressViews
	SEL selector = @selector(setMaxValue:);
	if ([downloadProgressDelegate respondsToSelector:selector]) {
		double max = 1.0;
		NSMethodSignature *signature = [[downloadProgressDelegate class] instanceMethodSignatureForSelector:selector];
		NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
		[invocation setSelector:@selector(setMaxValue:)];
		[invocation setArgument:&max atIndex:2];
		[invocation invokeWithTarget:downloadProgressDelegate];
	}	
}


- (void)resetUploadProgress:(unsigned long long)value
{
	[progressLock lock];
	//We're using a progress queue or compatible controller to handle progress
	if ([uploadProgressDelegate respondsToSelector:@selector(incrementUploadSizeBy:)]) {
		SEL selector = @selector(incrementUploadSizeBy:);
		NSMethodSignature *signature = [[uploadProgressDelegate class] instanceMethodSignatureForSelector:selector];
		NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
		[invocation setTarget:uploadProgressDelegate];
		[invocation setSelector:selector];
		[invocation setArgument:&value atIndex:2];
		[invocation invoke];
	} else {
		[ASIHTTPRequest setProgress:0 forProgressIndicator:uploadProgressDelegate];
	}
	[progressLock unlock];
}		

- (void)updateUploadProgress
{
	[cancelledLock lock];
	if ([self isCancelled]) {
		return;
	}
	unsigned long long byteCount = [[(NSNumber *)CFReadStreamCopyProperty (readStream, kCFStreamPropertyHTTPRequestBytesWrittenCount) autorelease] unsignedLongLongValue];
	
	// If this is the first time we've written to the buffer, byteCount will be the size of the buffer (currently seems to be 128KB on both Mac and iPhone)
	// We will remove this from any progress display, as kCFStreamPropertyHTTPRequestBytesWrittenCount does not tell us how much data has actually be written
	if (byteCount > 0 && uploadBufferSize == 0 && byteCount != postLength) {
		[self setUploadBufferSize:byteCount];
		SEL selector = @selector(setUploadBufferSize:);
		if ([uploadProgressDelegate respondsToSelector:selector]) {
			NSMethodSignature *signature = nil;
			signature = [[uploadProgressDelegate class] instanceMethodSignatureForSelector:selector];
			NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
			[invocation setTarget:uploadProgressDelegate];
			[invocation setSelector:selector];
			[invocation setArgument:&byteCount atIndex:2];
			[invocation invoke];
		}
	}
	

	
	[cancelledLock unlock];
	if (byteCount > lastBytesSent) {
		[self setLastActivityTime:[NSDate date]];		
	}
	
	if (uploadProgressDelegate) {
		
		// We're using a progress queue or compatible controller to handle progress
		if ([uploadProgressDelegate respondsToSelector:@selector(incrementUploadProgressBy:)]) {
			unsigned long long value = 0;
			if (showAccurateProgress) {
				if (byteCount == postLength) {
					value = byteCount+uploadBufferSize;
				} else if (lastBytesSent > 0) {
					value = ((byteCount-uploadBufferSize)-(lastBytesSent-uploadBufferSize));
				} else {
					value = 0;
				}
			} else {
				value = 1;
				updatedProgress = YES;
			}
			SEL selector = @selector(incrementUploadProgressBy:);
			NSMethodSignature *signature = nil;
			signature = [[uploadProgressDelegate class] instanceMethodSignatureForSelector:selector];
			NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
			[invocation setTarget:uploadProgressDelegate];
			[invocation setSelector:selector];
			[invocation setArgument:&value atIndex:2];
			[invocation invoke];
			
			// We aren't using a queue, we should just set progress of the indicator
		} else {
			[ASIHTTPRequest setProgress:(double)(1.0*(byteCount-uploadBufferSize)/(postLength-uploadBufferSize)) forProgressIndicator:uploadProgressDelegate];
		}
		
	}
	lastBytesSent = byteCount;
	
}


- (void)resetDownloadProgress:(unsigned long long)value
{
	[progressLock lock];	
	// We're using a progress queue or compatible controller to handle progress
	if ([downloadProgressDelegate respondsToSelector:@selector(incrementDownloadSizeBy:)]) {
		SEL selector = @selector(incrementDownloadSizeBy:);
		NSMethodSignature *signature = [[downloadProgressDelegate class] instanceMethodSignatureForSelector:selector];
		NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
		[invocation setTarget:downloadProgressDelegate];
		[invocation setSelector:selector];
		[invocation setArgument:&value atIndex:2];
		[invocation invoke];
		
	} else {
		[ASIHTTPRequest setProgress:0 forProgressIndicator:downloadProgressDelegate];
	}
	[progressLock unlock];
}	

- (void)updateDownloadProgress
{
	unsigned long long bytesReadSoFar = totalBytesRead;
	
	// We won't update download progress until we've examined the headers, since we might need to authenticate
	if (responseHeaders) {
		
		if (bytesReadSoFar > lastBytesRead) {
			[self setLastActivityTime:[NSDate date]];
		}
		
		if (downloadProgressDelegate) {
			
			
			// We're using a progress queue or compatible controller to handle progress
			if ([downloadProgressDelegate respondsToSelector:@selector(incrementDownloadProgressBy:)]) {
				
				NSAutoreleasePool *thePool = [[NSAutoreleasePool alloc] init];
				
				unsigned long long value = 0;
				if (showAccurateProgress) {
					value = bytesReadSoFar-lastBytesRead;
				} else {
					value = 1;
					updatedProgress = YES;
				}
				
				
				
				SEL selector = @selector(incrementDownloadProgressBy:);
				NSMethodSignature *signature = [[downloadProgressDelegate class] instanceMethodSignatureForSelector:selector];
				NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
				[invocation setTarget:downloadProgressDelegate];
				[invocation setSelector:selector];
				[invocation setArgument:&value atIndex:2];
				[invocation invoke];
				
				[thePool release];
				
				// We aren't using a queue, we should just set progress of the indicator to 0
			} else if (contentLength > 0)  {
				[ASIHTTPRequest setProgress:(double)(1.0*bytesReadSoFar/contentLength) forProgressIndicator:downloadProgressDelegate];
			}
		}
		
		lastBytesRead = bytesReadSoFar;
	}
	
}

-(void)removeUploadProgressSoFar
{
	
	// We're using a progress queue or compatible controller to handle progress
	if ([uploadProgressDelegate respondsToSelector:@selector(decrementUploadProgressBy:)]) {
		unsigned long long value = 0-lastBytesSent;
		SEL selector = @selector(decrementUploadProgressBy:);
		NSMethodSignature *signature = [[uploadProgressDelegate class] instanceMethodSignatureForSelector:selector];
		NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
		[invocation setTarget:uploadProgressDelegate];
		[invocation setSelector:selector];
		[invocation setArgument:&value atIndex:2];
		[invocation invoke];
		
		// We aren't using a queue, we should just set progress of the indicator to 0
	} else {
		[ASIHTTPRequest setProgress:0 forProgressIndicator:uploadProgressDelegate];
	}
}


+ (void)setProgress:(double)progress forProgressIndicator:(id)indicator
{

	SEL selector;
	[progressLock lock];
	
	// Cocoa Touch: UIProgressView
	if ([indicator respondsToSelector:@selector(setProgress:)]) {
		selector = @selector(setProgress:);
		NSMethodSignature *signature = [[indicator class] instanceMethodSignatureForSelector:selector];
		NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
		[invocation setSelector:selector];
		float progressFloat = (float)progress; // UIProgressView wants a float for the progress parameter
		[invocation setArgument:&progressFloat atIndex:2];

		// If we're running in the main thread, update the progress straight away. Otherwise, it's not that urgent
		[invocation performSelectorOnMainThread:@selector(invokeWithTarget:) withObject:indicator waitUntilDone:[NSThread isMainThread]];

		
	// Cocoa: NSProgressIndicator
	} else if ([indicator respondsToSelector:@selector(setDoubleValue:)]) {
		selector = @selector(setDoubleValue:);
		NSMethodSignature *signature = [[indicator class] instanceMethodSignatureForSelector:selector];
		NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
		[invocation setSelector:selector];
		[invocation setArgument:&progress atIndex:2];
		
		// If we're running in the main thread, update the progress straight away. Otherwise, it's not that urgent
		[invocation performSelectorOnMainThread:@selector(invokeWithTarget:) withObject:indicator waitUntilDone:[NSThread isMainThread]];
		
	}
	[progressLock unlock];
}


#pragma mark handling request complete / failure

// Subclasses can override this method to process the result in the same thread
// If not overidden, it will call the didFinishSelector on the delegate, if one has been setup
- (void)requestFinished
{
	if (didFinishSelector && ![self isCancelled] && [delegate respondsToSelector:didFinishSelector]) {
		[delegate performSelectorOnMainThread:didFinishSelector withObject:self waitUntilDone:[NSThread isMainThread]];		
	}
}



// Subclasses can override this method to perform error handling in the same thread
// If not overidden, it will call the didFailSelector on the delegate (by default requestFailed:)`
- (void)failWithError:(NSError *)theError
{
	complete = YES;
	if (!error) {
		
		// If this is a HEAD request created by an ASINetworkQueue, make the main request fail
		if ([self mainRequest]) {
			ASIHTTPRequest *mRequest = [self mainRequest];
			[mRequest setError:theError];
			if ([mRequest didFailSelector] && ![self isCancelled] && [[mRequest delegate] respondsToSelector:[mRequest didFailSelector]]) {
				[[mRequest delegate] performSelectorOnMainThread:[mRequest didFailSelector] withObject:mRequest waitUntilDone:[NSThread isMainThread]];	
			}
		
		} else {
			[self setError:theError];
			if (didFailSelector && ![self isCancelled] && [delegate respondsToSelector:didFailSelector]) {
				[delegate performSelectorOnMainThread:didFailSelector withObject:self waitUntilDone:[NSThread isMainThread]];	
			}
		}

	}
}


#pragma mark http authentication

- (BOOL)readResponseHeadersReturningAuthenticationFailure
{
	BOOL isAuthenticationChallenge = NO;
	CFHTTPMessageRef headers = (CFHTTPMessageRef)CFReadStreamCopyProperty(readStream, kCFStreamPropertyHTTPResponseHeader);
	if (CFHTTPMessageIsHeaderComplete(headers)) {
		responseHeaders = (NSDictionary *)CFHTTPMessageCopyAllHeaderFields(headers);
		responseStatusCode = CFHTTPMessageGetResponseStatusCode(headers);
		
		// Is the server response a challenge for credentials?
		isAuthenticationChallenge = (responseStatusCode == 401);
		
		// We won't reset the download progress delegate if we got an authentication challenge
		if (!isAuthenticationChallenge) {
			
			// See if we got a Content-length header
			NSString *cLength = [responseHeaders valueForKey:@"Content-Length"];
			if (cLength) {
				contentLength = CFStringGetIntValue((CFStringRef)cLength);
				if (mainRequest) {
					[mainRequest setContentLength:contentLength];
				}
				if (downloadProgressDelegate && showAccurateProgress && shouldResetProgressIndicators) {
					[self resetDownloadProgress:contentLength];
				}
			}
			
			// Handle cookies
			NSArray *cookies = [NSHTTPCookie cookiesWithResponseHeaderFields:responseHeaders forURL:url];
			[self setResponseCookies:cookies];
			
			if (useCookiePersistance) {
				
				// Store cookies in global persistent store
				[[NSHTTPCookieStorage sharedHTTPCookieStorage] setCookies:cookies forURL:url mainDocumentURL:nil];
				
				// We also keep any cookies in the sessionCookies array, so that we have a reference to them if we need to remove them later
				if (!sessionCookies) {
					[ASIHTTPRequest setSessionCookies:[[[NSMutableArray alloc] init] autorelease]];
					NSHTTPCookie *cookie;
					for (cookie in cookies) {
						[[ASIHTTPRequest sessionCookies] addObject:cookie];
					}
				}
			}
			
		}
		
	}
	CFRelease(headers);
	return isAuthenticationChallenge;
}


- (void)saveCredentialsToKeychain:(NSMutableDictionary *)newCredentials
{
	NSURLCredential *authenticationCredentials = [NSURLCredential credentialWithUser:[newCredentials objectForKey:(NSString *)kCFHTTPAuthenticationUsername]
																			password:[newCredentials objectForKey:(NSString *)kCFHTTPAuthenticationPassword]
																		 persistence:NSURLCredentialPersistencePermanent];
	
	if (authenticationCredentials) {
		[ASIHTTPRequest saveCredentials:authenticationCredentials forHost:[url host] port:[[url port] intValue] protocol:[url scheme] realm:authenticationRealm];
	}	
}

- (BOOL)applyCredentials:(NSMutableDictionary *)newCredentials
{
	
	if (newCredentials && requestAuthentication && request) {
		// Apply whatever credentials we've built up to the old request
		if (CFHTTPMessageApplyCredentialDictionary(request, requestAuthentication, (CFMutableDictionaryRef)newCredentials, NULL)) {
			
			//If we have credentials and they're ok, let's save them to the keychain
			if (useKeychainPersistance) {
				[self saveCredentialsToKeychain:newCredentials];
			}
			if (useSessionPersistance) {
				
				[ASIHTTPRequest setSessionAuthentication:requestAuthentication];
				[ASIHTTPRequest setSessionCredentials:newCredentials];
			}
			[self setRequestCredentials:newCredentials];
			return TRUE;
		}
	}
	return FALSE;
}

- (NSMutableDictionary *)findCredentials
{
	NSMutableDictionary *newCredentials = [[[NSMutableDictionary alloc] init] autorelease];
	
	// Is an account domain needed? (used currently for NTLM only)
	if (CFHTTPAuthenticationRequiresAccountDomain(requestAuthentication)) {
		[newCredentials setObject:domain forKey:(NSString *)kCFHTTPAuthenticationAccountDomain];
	}
	
	// Get the authentication realm
	[authenticationRealm release];
	authenticationRealm = nil;
	if (!CFHTTPAuthenticationRequiresAccountDomain(requestAuthentication)) {
		authenticationRealm = (NSString *)CFHTTPAuthenticationCopyRealm(requestAuthentication);
	}
	
	// First, let's look at the url to see if the username and password were included
	NSString *user = [url user];
	NSString *pass = [url password];
	
	// If the username and password weren't in the url
	if (!user || !pass) {
		
		// If this is a HEAD request generated by an ASINetworkQueue, we'll try to use the details from the main request
		if ([self mainRequest] && [[self mainRequest] username] && [[self mainRequest] password]) {
			user = [[self mainRequest] username];
			pass = [[self mainRequest] password];
			
		// Let's try to use the ones set in this object
		} else if (username && password) {
			user = username;
			pass = password;
		}		
		
	}
	

	
	// Ok, that didn't work, let's try the keychain
	if ((!user || !pass) && useKeychainPersistance) {
		NSURLCredential *authenticationCredentials = [ASIHTTPRequest savedCredentialsForHost:[url host] port:443 protocol:[url scheme] realm:authenticationRealm];
		if (authenticationCredentials) {
			user = [authenticationCredentials user];
			pass = [authenticationCredentials password];
		}
		
	}
	
	// If we have a username and password, let's apply them to the request and continue
	if (user && pass) {
		
		[newCredentials setObject:user forKey:(NSString *)kCFHTTPAuthenticationUsername];
		[newCredentials setObject:pass forKey:(NSString *)kCFHTTPAuthenticationPassword];
		return newCredentials;
	}
	return nil;
}

// Called by delegate to resume loading once authentication info has been populated
- (void)retryWithAuthentication
{
	[authenticationLock lockWhenCondition:1];
	[authenticationLock unlockWithCondition:2];
}

- (void)attemptToApplyCredentialsAndResume
{
	
	// Read authentication data
	if (!requestAuthentication) {
		CFHTTPMessageRef responseHeader = (CFHTTPMessageRef) CFReadStreamCopyProperty(readStream,kCFStreamPropertyHTTPResponseHeader);
		requestAuthentication = CFHTTPAuthenticationCreateFromResponse(NULL, responseHeader);
		CFRelease(responseHeader);
	}	
	
	if (!requestAuthentication) {
		[self failWithError:[NSError errorWithDomain:NetworkRequestErrorDomain code:ASIInternalErrorWhileApplyingCredentialsType userInfo:[NSDictionary dictionaryWithObjectsAndKeys:@"Failed to get authentication object from response headers",NSLocalizedDescriptionKey,nil]]];
		return;
	}
	
	// See if authentication is valid
	CFStreamError err;		
	if (!CFHTTPAuthenticationIsValid(requestAuthentication, &err)) {
		
		CFRelease(requestAuthentication);
		requestAuthentication = NULL;
		
		// check for bad credentials, so we can give the delegate a chance to replace them
		if (err.domain == kCFStreamErrorDomainHTTP && (err.error == kCFStreamErrorHTTPAuthenticationBadUserName || err.error == kCFStreamErrorHTTPAuthenticationBadPassword)) {
			
			[self setRequestCredentials:nil];
			
			ignoreError = YES;	
			[self setLastActivityTime:nil];
			if ([delegate respondsToSelector:@selector(authorizationNeededForRequest:)]) {
				[delegate performSelectorOnMainThread:@selector(authorizationNeededForRequest:) withObject:self waitUntilDone:[NSThread isMainThread]];
				[authenticationLock lockWhenCondition:2];
				[authenticationLock unlock];
				
				// Hopefully, the delegate gave us some credentials, let's apply them and reload
				[self attemptToApplyCredentialsAndResume];
				return;
			}
		}
		[self failWithError:ASIAuthenticationError];
		return;
	}
	
	[self cancelLoad];
	
	if (requestCredentials) {
		if ([self applyCredentials:requestCredentials]) {
			[self loadRequest];
		} else {
			[self failWithError:[NSError errorWithDomain:NetworkRequestErrorDomain code:ASIInternalErrorWhileApplyingCredentialsType userInfo:[NSDictionary dictionaryWithObjectsAndKeys:@"Failed to apply credentials to request",NSLocalizedDescriptionKey,nil]]];
		}
		
		// Are a user name & password needed?
	}  else if (CFHTTPAuthenticationRequiresUserNameAndPassword(requestAuthentication)) {
		
		NSMutableDictionary *newCredentials = [self findCredentials];
		
		//If we have some credentials to use let's apply them to the request and continue
		if (newCredentials) {
			
			if ([self applyCredentials:newCredentials]) {
				[self loadRequest];
			} else {
				[self failWithError:[NSError errorWithDomain:NetworkRequestErrorDomain code:ASIInternalErrorWhileApplyingCredentialsType userInfo:[NSDictionary dictionaryWithObjectsAndKeys:@"Failed to apply credentials to request",NSLocalizedDescriptionKey,nil]]];
			}
			return;
		}
		
		// We've got no credentials, let's ask the delegate to sort this out
		ignoreError = YES;	
		if ([delegate respondsToSelector:@selector(authorizationNeededForRequest:)]) {
			[delegate performSelectorOnMainThread:@selector(authorizationNeededForRequest:) withObject:self waitUntilDone:[NSThread isMainThread]];
			[authenticationLock lockWhenCondition:2];
			[authenticationLock unlock];
			[self attemptToApplyCredentialsAndResume];
			return;
		}
		
		// The delegate isn't interested, we'll have to give up
		[self failWithError:ASIAuthenticationError];
		return;
	}
	
}

#pragma mark stream status handlers


- (void)handleNetworkEvent:(CFStreamEventType)type
{
    // Dispatch the stream events.
    switch (type) {
        case kCFStreamEventHasBytesAvailable:
            [self handleBytesAvailable];
            break;
            
        case kCFStreamEventEndEncountered:
            [self handleStreamComplete];
            break;
            
        case kCFStreamEventErrorOccurred:
            [self handleStreamError];
            break;
            
        default:
            break;
    }
}


- (void)handleBytesAvailable
{
	
	if (!responseHeaders) {
		if ([self readResponseHeadersReturningAuthenticationFailure]) {
			[self attemptToApplyCredentialsAndResume];
			return;
		}
	}
	
    UInt8 buffer[2048];
    CFIndex bytesRead = CFReadStreamRead(readStream, buffer, sizeof(buffer));
	
	
    // Less than zero is an error
    if (bytesRead < 0) {
        [self handleStreamError];
		
		// If zero bytes were read, wait for the EOF to come.
    } else if (bytesRead) {
		
		totalBytesRead += bytesRead;
		
		// Are we downloading to a file?
		if (downloadDestinationPath) {
			if (!outputStream) {
				outputStream = [[NSOutputStream alloc] initToFileAtPath:downloadDestinationPath append:NO];
				[outputStream open];
			}
			[outputStream write:buffer maxLength:bytesRead];
			
			//Otherwise, let's add the data to our in-memory store
		} else {
			[receivedData appendBytes:buffer length:bytesRead];
		}
    }
	
	
}


- (void)handleStreamComplete
{
	
	
	//Try to read the headers (if this is a HEAD request handleBytesAvailable available may not be called)
	if (!responseHeaders) {
		if ([self readResponseHeadersReturningAuthenticationFailure]) {
			[self attemptToApplyCredentialsAndResume];
			return;
		}
	}
	[progressLock lock];	
	complete = YES;
	[self updateProgressIndicators];	
	
    if (readStream) {
        CFReadStreamClose(readStream);
        CFReadStreamSetClient(readStream, kCFStreamEventNone, NULL, NULL);
        CFReadStreamUnscheduleFromRunLoop(readStream, CFRunLoopGetCurrent(), ASIHTTPRequestRunMode);
        CFRelease(readStream);
        readStream = NULL;
    }
	
	// Close the output stream as we're done writing to the file
	if (downloadDestinationPath) {
		[outputStream close];
	}
	[progressLock unlock];
	[self requestFinished];
	
}


- (void)handleStreamError
{
	NSError *underlyingError = [(NSError *)CFReadStreamCopyError(readStream) autorelease];
	
	[self cancelLoad];
	
	if (!error) { // We may already have handled this error
		
		[self failWithError:[NSError errorWithDomain:NetworkRequestErrorDomain code:ASIConnectionFailureErrorType userInfo:[NSDictionary dictionaryWithObjectsAndKeys:@"A connection failure occurred",NSLocalizedDescriptionKey,underlyingError,NSUnderlyingErrorKey,nil]]];
	}
}

#pragma mark managing the session

+ (void)setSessionCredentials:(NSMutableDictionary *)newCredentials
{
	[sessionCredentials release];
	sessionCredentials = [newCredentials retain];
}

+ (void)setSessionAuthentication:(CFHTTPAuthenticationRef)newAuthentication
{
	if (sessionAuthentication) {
		CFRelease(sessionAuthentication);
	}
	sessionAuthentication = newAuthentication;
	if (newAuthentication) {
		CFRetain(sessionAuthentication);
	}
}

#pragma mark keychain storage

+ (void)saveCredentials:(NSURLCredential *)credentials forHost:(NSString *)host port:(int)port protocol:(NSString *)protocol realm:(NSString *)realm
{
	NSURLProtectionSpace *protectionSpace = [[[NSURLProtectionSpace alloc] initWithHost:host
																				   port:port
																			   protocol:protocol
																				  realm:realm
																   authenticationMethod:NSURLAuthenticationMethodDefault] autorelease];
	
	
	NSURLCredentialStorage *storage = [NSURLCredentialStorage sharedCredentialStorage];
	[storage setDefaultCredential:credentials forProtectionSpace:protectionSpace];
}

+ (NSURLCredential *)savedCredentialsForHost:(NSString *)host port:(int)port protocol:(NSString *)protocol realm:(NSString *)realm
{
	NSURLProtectionSpace *protectionSpace = [[[NSURLProtectionSpace alloc] initWithHost:host
																				   port:port
																			   protocol:protocol
																				  realm:realm
																   authenticationMethod:NSURLAuthenticationMethodDefault] autorelease];
	
	
	NSURLCredentialStorage *storage = [NSURLCredentialStorage sharedCredentialStorage];
	return [storage defaultCredentialForProtectionSpace:protectionSpace];
}

+ (void)removeCredentialsForHost:(NSString *)host port:(int)port protocol:(NSString *)protocol realm:(NSString *)realm
{
	NSURLProtectionSpace *protectionSpace = [[[NSURLProtectionSpace alloc] initWithHost:host
																				   port:port
																			   protocol:protocol
																				  realm:realm
																   authenticationMethod:NSURLAuthenticationMethodDefault] autorelease];
	
	
	NSURLCredentialStorage *storage = [NSURLCredentialStorage sharedCredentialStorage];
	[storage removeCredential:[storage defaultCredentialForProtectionSpace:protectionSpace] forProtectionSpace:protectionSpace];
	
}


+ (NSMutableArray *)sessionCookies
{
	return sessionCookies;
}

+ (void)setSessionCookies:(NSMutableArray *)newSessionCookies
{
	// Remove existing cookies from the persistent store
	NSHTTPCookie *cookie;
	for (cookie in newSessionCookies) {
		[[NSHTTPCookieStorage sharedHTTPCookieStorage] deleteCookie:cookie];
	}
	[sessionCookies release];
	sessionCookies = [newSessionCookies retain];
}

// Dump all session data (authentication and cookies)
+ (void)clearSession
{
	[ASIHTTPRequest setSessionAuthentication:NULL];
	[ASIHTTPRequest setSessionCredentials:nil];
	[ASIHTTPRequest setSessionCookies:nil];
}


@synthesize username;
@synthesize password;
@synthesize domain;
@synthesize url;
@synthesize delegate;
@synthesize uploadProgressDelegate;
@synthesize downloadProgressDelegate;
@synthesize useKeychainPersistance;
@synthesize useSessionPersistance;
@synthesize useCookiePersistance;
@synthesize downloadDestinationPath;
@synthesize didFinishSelector;
@synthesize didFailSelector;
@synthesize authenticationRealm;
@synthesize error;
@synthesize complete;
@synthesize requestHeaders;
@synthesize responseHeaders;
@synthesize responseCookies;
@synthesize requestCookies;
@synthesize requestCredentials;
@synthesize responseStatusCode;
@synthesize receivedData;
@synthesize lastActivityTime;
@synthesize timeOutSeconds;
@synthesize requestMethod;
@synthesize postBody;
@synthesize contentLength;
@synthesize postLength;
@synthesize shouldResetProgressIndicators;
@synthesize mainRequest;
@synthesize totalBytesRead;
@synthesize showAccurateProgress;
@synthesize totalBytesRead;
@synthesize uploadBufferSize;
@end
