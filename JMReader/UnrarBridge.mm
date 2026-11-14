#import "UnrarBridge.h"

#include "Unrar/rar.hpp"
#include "Unrar/dll.hpp"

#include <cstring>
#include <string>

static int CALLBACK JMUnrarCallback(UINT msg, LPARAM userData, LPARAM p1, LPARAM p2) {
    // No volume/password interaction in the app: let the library surface
    // missing volumes and missing passwords as process errors.
    return 0;
}

static NSError *JMUnrarError(int code, NSString *message) {
    return [NSError errorWithDomain:@"UnrarBridge" code:code
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

@implementation UnrarBridge

+ (NSArray<NSString *> *)extractArchiveAtPath:(NSString *)archivePath
                                  toDirectory:(NSString *)destDir
                                        error:(NSError **)error {
    RAROpenArchiveDataEx openData;
    memset(&openData, 0, sizeof(openData));
    openData.ArcName = (char *)archivePath.UTF8String;
    openData.OpenMode = RAR_OM_EXTRACT;
    openData.Callback = JMUnrarCallback;
    HANDLE handle = RAROpenArchiveEx(&openData);
    if (handle == NULL) {
        if (error) *error = JMUnrarError(openData.OpenResult, @"无法打开这个 RAR 文件");
        return nil;
    }

    NSData *destData = [destDir dataUsingEncoding:NSUTF32LittleEndianStringEncoding];
    std::wstring destW((const wchar_t *)destData.bytes,
                       destData.length / sizeof(wchar_t));

    NSMutableArray<NSString *> *files = [NSMutableArray array];
    RARHeaderDataEx header;
    memset(&header, 0, sizeof(header));
    int readResult = 0;
    while ((readResult = RARReadHeaderEx(handle, &header)) == 0) {
        const bool isDirectory = (header.Flags & RHDF_DIRECTORY) != 0;
        const int processResult =
            RARProcessFileW(handle, RAR_EXTRACT, (wchar_t *)destW.c_str(), NULL);
        if (processResult != 0) {
            RARCloseArchive(handle);
            if (error) {
                NSString *message = (processResult == ERAR_MISSING_PASSWORD ||
                                     processResult == ERAR_BAD_PASSWORD)
                    ? @"这个 RAR 有密码，暂时不支持"
                    : [NSString stringWithFormat:@"解压 RAR 失败（错误 %d）", processResult];
                *error = JMUnrarError(processResult, message);
            }
            return nil;
        }
        if (!isDirectory) {
            NSString *name = [[NSString alloc]
                initWithBytes:header.FileNameW
                       length:wcslen(header.FileNameW) * sizeof(wchar_t)
                     encoding:NSUTF32LittleEndianStringEncoding];
            if (name.length > 0) [files addObject:name];
        }
        memset(&header, 0, sizeof(header));
    }
    RARCloseArchive(handle);
    if (readResult != ERAR_END_ARCHIVE) {
        if (error) *error = JMUnrarError(readResult, @"读取 RAR 目录失败");
        return nil;
    }
    return files;
}

@end
