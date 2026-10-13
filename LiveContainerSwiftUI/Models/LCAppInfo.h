#import <Foundation/Foundation.h>
#import "LCUtils.h"

@interface LCAppInfo : NSObject {
    NSMutableDictionary* _info;
    NSMutableDictionary* _infoPlist;
    NSString* _bundlePath;
}
@property NSString* relativeBundlePath;
@property NSString* dataUUID;
@property NSArray<NSDictionary*>* containerInfo;
@property bool spoofSDKVersion;
- (NSString*)bundlePath;
- (NSString*)bundleIdentifier;
- (instancetype)initWithBundlePath:(NSString*)bundlePath;
- (void)save;
- (void)patchExecAndSignIfNeedWithCompletionHandler:(void(^)(bool success, NSString* errorInfo))completetionHandler progressHandler:(void(^)(NSProgress* progress))progressHandler  forceSign:(BOOL)forceSign;
@end
