#import <Foundation/Foundation.h>
#import "LCMachOUtils.h"
#import "utils.h"
@import UIKit;

typedef NS_ENUM(NSInteger, Store){
    SideStore = 0,
    AltStore = 1,
    ADP = 2,
    Unknown = -1
};

@interface UIDevice(private)
@property(readonly) NSString* buildVersion;
@end

@interface LCUtils : NSObject

+ (NSData *)certificateData;
+ (NSProgress *)signAppBundleWithZSign:(NSURL *)path completionHandler:(void (^)(BOOL success, NSError *error))completionHandler;
+ (Store)store;

@end
