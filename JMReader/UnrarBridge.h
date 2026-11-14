#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Thin Objective-C++ bridge over the vendored UnRAR library (RARLAB,
/// see Unrar/acknow.txt). Extraction only; archives with passwords are
/// reported as errors, there is no password UI.
@interface UnrarBridge : NSObject

/// Extracts every entry of the RAR archive at `archivePath` into
/// `destDir` (created by the library as needed). Returns the relative
/// paths of the extracted FILES (directories excluded), or nil and an
/// error describing the failure code.
+ (nullable NSArray<NSString *> *)extractArchiveAtPath:(NSString *)archivePath
                                           toDirectory:(NSString *)destDir
                                                 error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
