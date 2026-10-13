@import CommonCrypto;
@import MachO;

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "LCAppInfo.h"
#import "LCUtils.h"
#import "../../LiveContainer/LCSharedUtils.h"

uint32_t dyld_get_sdk_version(const struct mach_header* mh);

@implementation LCAppInfo

- (instancetype)initWithBundlePath:(NSString*)bundlePath {
    self = [super init];
	if(self) {
        _bundlePath = bundlePath;
        _infoPlist = [NSMutableDictionary dictionaryWithContentsOfFile:[NSString stringWithFormat:@"%@/Info.plist", bundlePath]];
        _info = [NSMutableDictionary dictionaryWithContentsOfFile:[NSString stringWithFormat:@"%@/LCAppInfo.plist", bundlePath]];
        if(!_info) {
            _info = [[NSMutableDictionary alloc] init];
        }
        if(!_infoPlist) {
            _infoPlist = [[NSMutableDictionary alloc] init];
        }
        
        // fix bundle id and execName if crash when signing
        if (_infoPlist[@"LCBundleIdentifier"]) {
            _infoPlist[@"CFBundleExecutable"] = _infoPlist[@"LCBundleExecutable"];
            _infoPlist[@"CFBundleIdentifier"] = _infoPlist[@"LCBundleIdentifier"];
            [_infoPlist removeObjectForKey:@"LCBundleExecutable"];
            [_infoPlist removeObjectForKey:@"LCBundleIdentifier"];
            [_infoPlist writeBinToFile:[NSString stringWithFormat:@"%@/Info.plist", bundlePath] atomically:YES];
        }

    }
    return self;
}

- (NSString*)bundleIdentifier {
    NSString* ans = _infoPlist[@"CFBundleIdentifier"];
    if(ans) {
        return ans;
    } else {
        return @"Unknown";
    }
}

- (NSString*)dataUUID {
    return _info[@"LCDataUUID"];
}

- (void)setDataUUID:(NSString *)uuid {
    _info[@"LCDataUUID"] = uuid;
    [self save];
}

- (NSString*)bundlePath {
    return _bundlePath;
}

- (void)save {
    [_info writeBinToFile:[NSString stringWithFormat:@"%@/LCAppInfo.plist", _bundlePath] atomically:YES];
}

- (void)patchExecAndSignIfNeedWithCompletionHandler:(void(^)(bool success, NSString* errorInfo))completetionHandler progressHandler:(void(^)(NSProgress* progress))progressHandler forceSign:(BOOL)forceSign {
    [NSUserDefaults.standardUserDefaults setObject:@(YES) forKey:@"SigningInProgress"];
    NSString *appPath = self.bundlePath;
    NSString *infoPath = [NSString stringWithFormat:@"%@/Info.plist", appPath];
    NSMutableDictionary *info = _info;
    NSMutableDictionary *infoPlist = _infoPlist;
    if (!info) {
        [NSUserDefaults.standardUserDefaults removeObjectForKey:@"SigningInProgress"];
        completetionHandler(NO, @"Info.plist not found");
        return;
    }
    NSFileManager* fm = NSFileManager.defaultManager;
    NSString *execPath = [NSString stringWithFormat:@"%@/%@", appPath, _infoPlist[@"CFBundleExecutable"]];
    
    // Update patch
    int currentPatchRev = 7;
    bool needPatch = [info[@"LCPatchRevision"] intValue] < currentPatchRev;
    if (needPatch || forceSign) {
        // copy-delete-move to avoid EXC_BAD_ACCESS (SIGKILL - CODESIGNING)
        NSString *backupPath = [NSString stringWithFormat:@"%@/%@_LiveContainerPatchBackUp", appPath, _infoPlist[@"CFBundleExecutable"]];
        NSError *err;
        [fm copyItemAtPath:execPath toPath:backupPath error:&err];
        [fm removeItemAtPath:execPath error:&err];
        [fm moveItemAtPath:backupPath toPath:execPath error:&err];
    }
    
    bool is32bit = false;
    if (needPatch) {
        __block bool has64bitSlice = NO;
        __block bool isEncrypted = false;
        NSString *error = LCParseMachO(execPath.UTF8String, false, ^(const char *path, struct mach_header_64 *header, int fd, void* filePtr) {
            if(header->cputype == CPU_TYPE_ARM64) {
                has64bitSlice |= YES;
                int patchResult = LCPatchExecSlice(path, header, ![info[@"dontInjectTweakLoader"] boolValue]);
                if(patchResult & PATCH_EXEC_RESULT_NO_SPACE_FOR_TWEAKLOADER) {
                    info[@"LCTweakLoaderCantInject"] = @YES;
                    info[@"dontInjectTweakLoader"] = @YES;
                }
            }
            isEncrypted |= LCIsMachOEncrypted(header);
        });
        is32bit = !has64bitSlice;
        LCPatchAppBundleFixupARM64eSlice([NSURL fileURLWithPath:appPath]);
        if (isEncrypted) {
            error = @"The app you tried to install is encrypted. Please provide decrypted app.";
        }
        if (error) {
            [NSUserDefaults.standardUserDefaults removeObjectForKey:@"SigningInProgress"];
            completetionHandler(NO, error);
            return;
        }
        info[@"LCPatchRevision"] = @(currentPatchRev);
        forceSign = true;
        
        [self save];
    }
    if(is32bit) {
        [NSUserDefaults.standardUserDefaults removeObjectForKey:@"SigningInProgress"];
        completetionHandler(NO, @"32-bit app is NOT supported!");
        return;
    }

    if (!LCSharedUtils.certificatePassword) {
        [NSUserDefaults.standardUserDefaults removeObjectForKey:@"SigningInProgress"];
        completetionHandler(YES, nil);
        return;
    }

    // check if iOS think this app's signature is valid, if so, we can skip any further signature check
    NSString* executablePath = [appPath stringByAppendingPathComponent:infoPlist[@"CFBundleExecutable"]];
    if(!forceSign) {
        bool signatureValid = checkCodeSignature(executablePath.UTF8String);
        
        if(signatureValid) {
            [NSUserDefaults.standardUserDefaults removeObjectForKey:@"SigningInProgress"];
            completetionHandler(YES, nil);
            return;
        }
    }
    
    if (!LCUtils.certificateData) {
        [NSUserDefaults.standardUserDefaults removeObjectForKey:@"SigningInProgress"];
        completetionHandler(NO, @"lc.signer.noCertificateFoundErr");
        return;
    }
    
    if(forceSign) {
        // remove ZSign cache since hash is changed after upgrading patch
        NSString* cachePath = [appPath stringByAppendingPathComponent:@"zsign_cache.json"];
        if([fm fileExistsAtPath:cachePath]) {
            NSError* err;
            [fm removeItemAtPath:cachePath error:&err];
        }
    }
    
    // Sign app if JIT-less is set up
        NSURL *appPathURL = [NSURL fileURLWithPath:appPath];
            // We need to temporarily fake bundle ID and main executable to sign properly
            NSString *tmpExecPath = [appPath stringByAppendingPathComponent:@"LiveContainer.tmp"];
            if (!info[@"LCBundleIdentifier"]) {
                // Don't let main executable get entitlements
                [fm copyItemAtPath:NSBundle.mainBundle.executablePath toPath:tmpExecPath error:nil];

                infoPlist[@"LCBundleExecutable"] = infoPlist[@"CFBundleExecutable"];
                infoPlist[@"LCBundleIdentifier"] = infoPlist[@"CFBundleIdentifier"];
                infoPlist[@"CFBundleExecutable"] = tmpExecPath.lastPathComponent;
                infoPlist[@"CFBundleIdentifier"] = NSBundle.mainBundle.bundleIdentifier;
                [infoPlist writeBinToFile:infoPath atomically:YES];
            }
            infoPlist[@"CFBundleExecutable"] = infoPlist[@"LCBundleExecutable"];
            infoPlist[@"CFBundleIdentifier"] = infoPlist[@"LCBundleIdentifier"];
            [infoPlist removeObjectForKey:@"LCBundleExecutable"];
            [infoPlist removeObjectForKey:@"LCBundleIdentifier"];
            
            void (^signCompletionHandler)(BOOL success, NSError *error)  = ^(BOOL success, NSError *_Nullable error) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    
                    // Remove fake main executable
                    [fm removeItemAtPath:tmpExecPath error:nil];
                    
                    // Save sign ID and restore bundle ID
                    [self save];
                    [infoPlist writeBinToFile:infoPath atomically:YES];
                    [NSUserDefaults.standardUserDefaults removeObjectForKey:@"SigningInProgress"];
                    if(!success) {
                        completetionHandler(NO, error.localizedDescription);
                    } else {
                        bool signatureValid = checkCodeSignature(executablePath.UTF8String);
                        if(signatureValid) {
                            completetionHandler(YES, [error localizedDescription]);
                        } else {
                            completetionHandler(NO, @"lc.signer.latestCertificateInvalidErr");
                        }
                    }
                    
                });
            };
            
            __block NSProgress *progress = [LCUtils signAppBundleWithZSign:appPathURL completionHandler:signCompletionHandler];

            if (progress) {
                progressHandler(progress);
            }

}

- (NSArray<NSDictionary*>* )containerInfo {
    return _info[@"LCContainers"];
}

- (void)setContainerInfo:(NSArray<NSDictionary *> *)containerInfo {
    _info[@"LCContainers"] = containerInfo;
    [self save];
}
- (bool)spoofSDKVersion {
    if(!_info[@"spoofSDKVersion"]) {
        return false;
    } else {
        return [_info[@"spoofSDKVersion"] unsignedIntValue] != 0;
    }
}

- (void)setSpoofSDKVersion:(bool)doSpoof {
    if(!doSpoof) {
        _info[@"spoofSDKVersion"] = 0;
    } else {
        NSString *execPath = [NSString stringWithFormat:@"%@/%@", _bundlePath, _infoPlist[@"CFBundleExecutable"]];
        __block uint32_t sdkVersion = 0;
        LCParseMachO(execPath.UTF8String, true, ^(const char *path, struct mach_header_64 *header, int fd, void *filePtr) {
            sdkVersion = dyld_get_sdk_version((const struct mach_header *)header);
        });
        NSLog(@"[LC] sdkversion = %8x", sdkVersion);
        _info[@"spoofSDKVersion"] = [NSNumber numberWithUnsignedInt:sdkVersion];
    }
    [self save];
}

@end
