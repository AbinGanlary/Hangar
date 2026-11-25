//
//  XPCServer.h
//  LiveContainer
//
//  Created by s s on 2025/7/20.
//

#import <Foundation/Foundation.h>
#import <UserNotifications/UserNotifications.h>

__attribute__((swift_attr("@Sendable")))
@protocol RefreshServer
- (void)updateProgress:(double)value;
- (void)finish:(NSString*)error;
- (void)onConnection:(NSXPCConnection*)connection;
- (void)finishedLaunching;
- (void)addNotificationRequest:(UNNotificationRequest*)request;
- (void)removePendingNotificationRequestsWithIdentifiers:(NSArray<NSString*>*)identifiers;
// Hangar: the background sign-in asks the host for a 2FA code. Reply with the code, @"sms", or nil to cancel.
- (void)hangarRequestCodeWithPrompt:(NSString* _Nonnull)prompt error:(NSString* _Nullable)error canUseSMS:(BOOL)canUseSMS reply:(void (^ _Nonnull)(NSString* _Nullable code))reply;
@end

@protocol RefreshClient
- (void)refreshAllAppsWithIdentifier:(NSString*)identifier mangledTypeName:(NSString *)mangledTypeName;
// Hangar: sign in / out with Hangar's own screen (HangarAuthBridge in Hangar's SideStore build). Ends with -finish:.
- (void)hangarSignInWithAppleID:(NSString* _Nonnull)appleID password:(NSString* _Nonnull)password;
- (void)hangarSignOut;
// Hangar: @"deactivate" or @"activate" a native app (HangarAppsBridge). Ends with -finish:.
- (void)hangarAppAction:(NSString* _Nonnull)action bundleID:(NSString* _Nonnull)bundleID;
@end

@interface LiveProcessSideStoreHandler : NSObject
@property (class, readonly, strong) LiveProcessSideStoreHandler* shared;
@property NSXPCConnection* connection;
@property NSObject<RefreshServer>* server;

@end

NSXPCListener* startAnonymousListener(NSObject<RefreshServer>* reporter);
NSData* bookmarkForURL(NSURL* url);

void installSideStoreHooks(void);
void installSideStoreNotificationHooks(void);

@interface SideStoreClient : NSObject<RefreshClient>
@property (class, readonly) SideStoreClient* shared;
- (void) relaunchLC;
@end
