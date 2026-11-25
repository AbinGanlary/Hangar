//
//  XPCClient.m
//  AltStore
//
//  Created by s s on 2025/7/20.
//  Copyright © 2025 SideStore. All rights reserved.
//
#include "XPCServer.h"
#include "../LiveContainer/utils.h"
#include "../LiveContainer/LCSharedUtils.h"
@import UIKit;
#import <objc/message.h>

@interface SideStoreClient(Swift)
- (void)performRefreshForRealWithIdentifier:(NSString*)identifier
                            mangledTypeName:(NSString*)mangledTypeName
                                     server:(id <RefreshServer> _Nonnull)server;

@end

static LiveProcessSideStoreHandler* handler = nil;
void installSideStoreHooks(void);

@implementation SideStoreClient

+ (SideStoreClient*)shared {
    static SideStoreClient* sharedClient = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedClient = [SideStoreClient new];
    });

    return sharedClient;
}

+ (void)load {
    if(!NSUserDefaults.isSideStore) return;
    
    installSideStoreHooks();
    
    if(!NSUserDefaults.isLiveProcess) return;
    
    handler = [PrivClass(LiveProcessSideStoreHandler) shared];
    installSideStoreNotificationHooks();
    handler.connection.exportedInterface = [NSXPCInterface interfaceWithProtocol:@protocol(RefreshClient)];
    handler.connection.exportedObject = SideStoreClient.shared;

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(appDidFinishLaunching:)
                                                 name:UIApplicationDidFinishLaunchingNotification
                                               object:nil];
}

// Implement the callback method
+ (void)appDidFinishLaunching:(NSNotification *)notification {
    NSDictionary *launchOptions = notification.userInfo;
    [handler.server finishedLaunching];
}

- (void) relaunchLC {
    [LCSharedUtils launchToGuestAppWithClassicMode:0];
}

- (void)refreshAllAppsWithIdentifier:(NSString*)identifier mangledTypeName:(NSString *)mangledTypeName {
    if(!handler) {
        return;
    }
    [self performRefreshForRealWithIdentifier:identifier mangledTypeName:mangledTypeName server:handler.server];
}

// Hangar: forward to HangarAuthBridge (Hangar's SideStore build) and report back over XPC.
- (void)hangarSignInWithAppleID:(NSString*)appleID password:(NSString*)password {
    if(!handler) return;
    NSObject<RefreshServer>* server = handler.server;
    Class bridge = NSClassFromString(@"HangarAuthBridge");
    SEL sel = NSSelectorFromString(@"signInWithAppleID:password:codeProvider:completion:");
    if(!bridge || ![bridge respondsToSelector:sel]) {
        [server finish:@"This installer build can't sign in from Hangar. Update Hangar."];
        return;
    }
    void (^codeProvider)(NSString*, NSString*, BOOL, void (^)(NSString*)) = ^(NSString* prompt, NSString* error, BOOL canUseSMS, void (^reply)(NSString*)) {
        [server hangarRequestCodeWithPrompt:prompt error:error canUseSMS:canUseSMS reply:reply];
    };
    void (^completion)(NSString*) = ^(NSString* error) {
        [server finish:error];
    };
    ((void (*)(id, SEL, NSString*, NSString*, id, id))objc_msgSend)(bridge, sel, appleID, password, codeProvider, completion);
}

- (void)hangarSignOut {
    if(!handler) return;
    NSObject<RefreshServer>* server = handler.server;
    Class bridge = NSClassFromString(@"HangarAuthBridge");
    SEL sel = NSSelectorFromString(@"signOutWithCompletion:");
    if(!bridge || ![bridge respondsToSelector:sel]) {
        [server finish:@"This installer build can't sign out from Hangar. Update Hangar."];
        return;
    }
    void (^completion)(NSString*) = ^(NSString* error) {
        [server finish:error];
    };
    ((void (*)(id, SEL, id))objc_msgSend)(bridge, sel, completion);
}

@end
