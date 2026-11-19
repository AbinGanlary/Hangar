//
//  LabHUD.m
//  TweakLoader (combined-app fork)
//
//  Phase 1 test overlay. It runs inside every guest app when "Show overlay in apps" is
//  on in the Lab tab, and shows render FPS (counted from CAMetalLayer -nextDrawable), free and
//  used memory, connected controllers, and whether the app runs in the main process or in a
//  multitask helper. It also writes a one-line summary per app to the app group so the Lab
//  tab's "Copy report" can include it.
//
//  Uses only runtime lookups (no GameController / QuartzCore link), so it adds no link dependencies.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include <objc/runtime.h>
#include <objc/message.h>
#include <mach/mach.h>
#include <os/proc.h>
#include <stdatomic.h>
#import "../LiveContainer/utils.h"

static atomic_uint_fast32_t labDrawableCount = 0;
static id (*labOrigNextDrawable)(id, SEL) = NULL;

static id labHookNextDrawable(id self, SEL _cmd) {
    atomic_fetch_add(&labDrawableCount, 1);
    return labOrigNextDrawable(self, _cmd);
}

static uint64_t labFootprintMB(void) {
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) != KERN_SUCCESS) {
        return 0;
    }
    return info.phys_footprint / 1048576;
}

static NSUInteger labControllerCount(void) {
    Class gc = NSClassFromString(@"GCController");
    if (!gc) return 0;
    NSArray *controllers = ((NSArray *(*)(id, SEL))objc_msgSend)(gc, NSSelectorFromString(@"controllers"));
    return controllers.count;
}

static NSString *labAppName(void) {
    NSDictionary *info = NSBundle.mainBundle.infoDictionary;
    NSString *name = info[@"CFBundleDisplayName"] ?: info[@"CFBundleName"];
    return name ?: (NSUserDefaults.lcGuestAppId ?: @"app");
}

@interface LabHUDController : NSObject
@property (nonatomic, strong) UIWindow *window;
@property (nonatomic, strong) UILabel *label;
@property (nonatomic, assign) uint64_t minFreeMB;
@property (nonatomic, assign) uint64_t maxFootMB;
@property (nonatomic, assign) uint32_t maxFPS;
@property (nonatomic, assign) int ticks;
@end

@implementation LabHUDController

+ (instancetype)shared {
    static LabHUDController *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [LabHUDController new]; s.minFreeMB = UINT64_MAX; });
    return s;
}

- (UIWindowScene *)activeScene {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if ([scene isKindOfClass:UIWindowScene.class]) {
            return (UIWindowScene *)scene;
        }
    }
    return nil;
}

- (void)tryAttach:(int)attempt {
    UIWindowScene *scene = [self activeScene];
    if (!scene) {
        if (attempt < 20) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                [self tryAttach:attempt + 1];
            });
        }
        return;
    }
    UIWindow *window = [[UIWindow alloc] initWithWindowScene:scene];
    window.frame = CGRectMake(8, 54, 250, 58);
    window.windowLevel = UIWindowLevelStatusBar + 10;
    window.userInteractionEnabled = NO;
    window.backgroundColor = UIColor.clearColor;
    UIViewController *vc = [UIViewController new];
    vc.view.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
    vc.view.layer.cornerRadius = 10;
    vc.view.userInteractionEnabled = NO;
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectInset(vc.view.bounds, 8, 4)];
    label.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    label.numberOfLines = 3;
    label.font = [UIFont monospacedDigitSystemFontOfSize:11 weight:UIFontWeightSemibold];
    label.textColor = UIColor.whiteColor;
    [vc.view addSubview:label];
    window.rootViewController = vc;
    window.hidden = NO;
    self.window = window;
    self.label = label;

    [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *timer) {
        [self tick];
    }];
}

- (void)tick {
    uint32_t fps = (uint32_t)atomic_exchange(&labDrawableCount, 0);
    uint64_t freeMB = os_proc_available_memory() / 1048576;
    uint64_t footMB = labFootprintMB();
    NSUInteger pads = labControllerCount();
    if (freeMB < self.minFreeMB) self.minFreeMB = freeMB;
    if (footMB > self.maxFootMB) self.maxFootMB = footMB;
    if (fps > self.maxFPS) self.maxFPS = fps;
    NSString *mode = NSUserDefaults.isLiveProcess ? @"multitask" : @"main";

    self.label.text = [NSString stringWithFormat:@"%@ · %@\nFPS %@ · max %u · screen %ld\nused %llu MB · free %llu MB · pads %lu",
                       labAppName(), mode,
                       fps ? [NSString stringWithFormat:@"%u", fps] : @"–", self.maxFPS,
                       (long)UIScreen.mainScreen.maximumFramesPerSecond,
                       footMB, freeMB, (unsigned long)pads];
    // keep the overlay above windows the app adds later
    self.window.hidden = NO;

    self.ticks += 1;
    if (self.ticks % 5 == 0) {
        [self saveReportWithMode:mode pads:pads];
    }
}

- (void)saveReportWithMode:(NSString *)mode pads:(NSUInteger)pads {
    NSUserDefaults *shared = NSUserDefaults.lcSharedDefaults;
    if (!shared) return;
    NSString *name = labAppName();
    NSString *prefix = [NSString stringWithFormat:@"%@ [%@]", name, mode];
    NSString *line = [NSString stringWithFormat:@"%@ maxFPS=%u minFreeMB=%llu maxUsedMB=%llu pads=%lu",
                      prefix, self.maxFPS, self.minFreeMB, self.maxFootMB, (unsigned long)pads];
    NSMutableArray *lines = [[shared stringArrayForKey:@"LCLabHUDReports"] mutableCopy] ?: [NSMutableArray new];
    [lines filterUsingPredicate:[NSPredicate predicateWithFormat:@"NOT (SELF BEGINSWITH %@)", prefix]];
    [lines addObject:line];
    while (lines.count > 20) [lines removeObjectAtIndex:0];
    [shared setObject:lines forKey:@"LCLabHUDReports"];
}

@end

static void labInstallDrawableHook(void) {
    Class metalLayer = NSClassFromString(@"CAMetalLayer");
    if (!metalLayer) return;
    Method m = class_getInstanceMethod(metalLayer, @selector(nextDrawable));
    if (!m) return;
    labOrigNextDrawable = (id (*)(id, SEL))method_setImplementation(m, (IMP)labHookNextDrawable);
}

__attribute__((constructor))
static void LabHUDConstructor(void) {
    if (![NSUserDefaults.lcSharedDefaults boolForKey:@"LCLabHUD"]) {
        return;
    }
    labInstallDrawableHook();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        [[LabHUDController shared] tryAttach:0];
    });
}
