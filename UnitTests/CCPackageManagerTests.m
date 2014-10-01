//
//  CCPackageManagerTests.m
//  cocos2d-tests-ios
//
//  Created by Nicky Weber on 23.09.14.
//  Copyright (c) 2014 Cocos2d. All rights reserved.
//

#import <XCTest/XCTest.h>
#import "CCPackageManager.h"
#import "CCPackage.h"
#import "CCFileUtils.h"
#import "CCPackage_private.h"
#import "CCPackageConstants.h"
#import "CCPackageManagerDelegate.h"
#import "CCUnitTestAssertions.h"
#import "CCDirector.h"
#import "AppDelegate.h"
#import "CCPackageCocos2dEnabler.h"
#import "CCPackageManager_private.h"


static NSString *const PACKAGE_BASE_URL = @"http://manager.test";

@interface CCPackageManagerTestURLProtocol : NSURLProtocol @end

@implementation CCPackageManagerTestURLProtocol

+ (BOOL)canInitWithRequest:(NSURLRequest*)theRequest
{
    return [theRequest.URL.scheme caseInsensitiveCompare:@"http"] == NSOrderedSame;
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)theRequest
{
    return theRequest;
}

- (void)startLoading
{
    NSData *data;
    NSHTTPURLResponse *response;
    if ([self.request.URL.absoluteString rangeOfString:PACKAGE_BASE_URL].location != NSNotFound)
    {
        NSString *pathToPackage = [[NSBundle mainBundle] pathForResource:@"Resources-shared/Packages/testpackage-iOS-phonehd.zip" ofType:nil];
        data = [NSData dataWithContentsOfFile:pathToPackage];

        response = [[NSHTTPURLResponse alloc] initWithURL:self.request.URL
                                                              statusCode:200
                                                             HTTPVersion:@"HTTP/1.1"
                                                            headerFields:nil];
    }
    else
    {
        response = [[NSHTTPURLResponse alloc] initWithURL:self.request.URL
                                                              statusCode:404
                                                             HTTPVersion:@"HTTP/1.1"
                                                            headerFields:nil];
    }

    id<NSURLProtocolClient> client = [self client];
    [client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    [client URLProtocol:self didLoadData:data];
    [client URLProtocolDidFinishLoading:self];
}

- (void)stopLoading
{
    // Nothing to do
}

@end


@interface CCPackageManagerTests : XCTestCase <CCPackageManagerDelegate>

@property (nonatomic, strong) CCPackageManager *packageManager;
@property (nonatomic) BOOL managerReturnedSuccessfully;
@property (nonatomic) BOOL managerReturnedFailed;
@property (nonatomic, copy) NSString *customFolderName;
@property (nonatomic, strong) NSError *managerReturnedWithError;
@property (nonatomic, strong) NSMutableSet *cleanPathsArrayOnTearDown;

@end


@implementation CCPackageManagerTests

- (void)setUp
{
    [super setUp];

    [(AppController *)[UIApplication sharedApplication].delegate configureCocos2d];
    [[CCDirector sharedDirector] stopAnimation];

    self.packageManager = [[CCPackageManager alloc] init];
    _packageManager.delegate = self;

    self.managerReturnedSuccessfully = NO;
    self.managerReturnedFailed = NO;
    self.managerReturnedWithError = nil;
    self.customFolderName = nil;

    // A set of paths to be removed on tear down
    self.cleanPathsArrayOnTearDown = [NSMutableSet set];
    [_cleanPathsArrayOnTearDown addObject:[NSTemporaryDirectory() stringByAppendingPathComponent:PACKAGE_REL_UNZIP_FOLDER]];
    [_cleanPathsArrayOnTearDown addObject:[NSTemporaryDirectory() stringByAppendingPathComponent:PACKAGE_REL_DOWNLOAD_FOLDER]];
    [_cleanPathsArrayOnTearDown addObject:_packageManager.installedPackagesPath];

    // Important for the standard identifier of packages which most often determined internally instead
    // of provided by the user. In this case resolution will default to phonehd.
    [CCFileUtils sharedFileUtils].searchResolutionsOrder = [@[CCFileUtilsSuffixiPhoneHD] mutableCopy];

    [[NSUserDefaults standardUserDefaults] setObject:nil forKey:PACKAGE_STORAGE_USERDEFAULTS_KEY];

    [NSURLProtocol registerClass:[CCPackageManagerTestURLProtocol class]];
}

- (void)tearDown
{
    [NSURLProtocol unregisterClass:[CCPackageManagerTestURLProtocol class]];

    NSFileManager *fileManager = [NSFileManager defaultManager];
    for (NSString *path in _cleanPathsArrayOnTearDown)
    {
        [fileManager removeItemAtPath:path error:nil];
    }

    [super tearDown];
}


#pragma mark - Tests

- (void)testPackageWithName
{
    [CCFileUtils sharedFileUtils].searchResolutionsOrder = [@[CCFileUtilsSuffixiPadHD] mutableCopy];

    CCPackage *aPackage = [[CCPackage alloc] initWithName:@"foo"
                                               resolution:@"tablethd" // See note above
                                                       os:@"iOS"
                                                remoteURL:[NSURL URLWithString:@"http://foo.fake"]];

    [_packageManager addPackage:aPackage];

    CCPackage *result = [_packageManager packageWithName:@"foo"];

    XCTAssertEqual(aPackage, result);
}

- (void)testSavePackages
{
    CCPackage *package1 = [[CCPackage alloc] initWithName:@"DLC1"
                                               resolution:@"phonehd"
                                                       os:@"iOS"
                                                remoteURL:[NSURL URLWithString:@"http://foo.fake"]];
    package1.installURL = [NSURL fileURLWithPath:@"/packages/DLC1-iOS-phonehd"];
    package1.status = CCPackageStatusInitial;


    CCPackage *package2 = [[CCPackage alloc] initWithName:@"DLC2"
                                               resolution:@"tablethd"
                                                       os:@"iOS"
                                                remoteURL:[NSURL URLWithString:@"http://baa.fake"]];
    package2.installURL = [NSURL fileURLWithPath:@"/packages/DLC2-iOS-tablethd"];
    package2.status = CCPackageStatusInitial;

    [_packageManager addPackage:package1];
    [_packageManager addPackage:package2];

    [_packageManager savePackages];

    NSArray *packages = [[NSUserDefaults standardUserDefaults] objectForKey:PACKAGE_STORAGE_USERDEFAULTS_KEY];

    XCTAssertEqual(packages.count, 2);
    // Note: Persistency of CCPackage is tested in CCPackageTests
}

- (void)testDownloadWithNameAndBaseURLAndUnzipOnCustomQueue
{
    _packageManager.baseURL = [NSURL URLWithString:PACKAGE_BASE_URL];

    CCPackage *package = [_packageManager downloadPackageWithName:@"testpackage" enableAfterDownload:YES];

    dispatch_queue_t queue = dispatch_queue_create("testqueue", DISPATCH_QUEUE_CONCURRENT);
    _packageManager.unzippingQueue = queue;

    [self waitForDelegateToReturn];

    XCTAssertNotNil(package);
    XCTAssertTrue(_managerReturnedSuccessfully);
    XCTAssertEqual(package.status, CCPackageStatusInstalledEnabled);
}

- (void)testDownloadWithCustomFolderNameInPackage
{
    // The installer used by the package manager will look into the unzipped contents and expect a folder
    // named after the standard identifier: Foo-iOS-phonehd.
    // Since the testpackage-iOS-phonehd is downloaded the delegate is used to correct this.

    [CCFileUtils sharedFileUtils].searchResolutionsOrder = [@[CCFileUtilsSuffixiPhoneHD] mutableCopy];

    _packageManager.baseURL = [NSURL URLWithString:PACKAGE_BASE_URL];

    self.customFolderName = @"testpackage-iOS-phonehd";

    CCPackage *package = [_packageManager downloadPackageWithName:@"Foo" enableAfterDownload:YES];

    [self waitForDelegateToReturn];

    XCTAssertNotNil(package);
    XCTAssertTrue(_managerReturnedSuccessfully);
}

- (void)testCannotDetermineFolderNameWhenUnzipping
{
    // Like in testDownloadWithCustomFolderNameInPackage but this time we expect an error and a failing delegate method

    _packageManager.baseURL = [NSURL URLWithString:PACKAGE_BASE_URL];

    CCPackage *package = [_packageManager downloadPackageWithName:@"Foo" enableAfterDownload:YES];

    [self waitForDelegateToReturn];

    XCTAssertNotNil(package);
    XCTAssertTrue(_managerReturnedFailed);
    XCTAssertEqual(_managerReturnedWithError.code, PACKAGE_ERROR_INSTALL_PACKAGE_FOLDER_NAME_NOT_FOUND);
}

- (void)testDownloadWithoutBaseURLShouldFail
{
    CCPackage *package = [_packageManager downloadPackageWithName:@"testpackage" enableAfterDownload:YES];

    [self waitForDelegateToReturn];

    XCTAssertNil(package);
    XCTAssertTrue(_managerReturnedFailed);
    XCTAssertEqual(_managerReturnedWithError.code, PACKAGE_ERROR_MANAGER_NO_BASE_URL_SET);
}

- (void)testSetInstallPath
{
    // Test: set a non existing path
    NSFileManager *fileManager = [NSFileManager defaultManager];

    NSString *customInstallPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"FooBar"];
    [_cleanPathsArrayOnTearDown addObject:customInstallPath];

    _packageManager.installedPackagesPath = customInstallPath;

    XCTAssertTrue([fileManager fileExistsAtPath:customInstallPath]);
    CCAssertEqualStrings(customInstallPath, _packageManager.installedPackagesPath);


    // Test2: set an existing path
    NSString *customInstallPath2 = [NSTemporaryDirectory() stringByAppendingPathComponent:@"FooBar2"];
    [_cleanPathsArrayOnTearDown addObject:customInstallPath2];

    [fileManager createDirectoryAtPath:customInstallPath2 withIntermediateDirectories:YES attributes:nil error:nil];

    _packageManager.installedPackagesPath = customInstallPath2;
    XCTAssertTrue([fileManager fileExistsAtPath:customInstallPath]);
    CCAssertEqualStrings(customInstallPath2, _packageManager.installedPackagesPath);
}

- (void)testDownloadOfPackageWithDifferentInstallPath
{
    NSString *customInstallPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"PackagesInstall"];

    NSFileManager *fileManager = [NSFileManager defaultManager];
    [fileManager removeItemAtPath:customInstallPath error:nil];
    [_cleanPathsArrayOnTearDown addObject:customInstallPath];

    _packageManager.installedPackagesPath = customInstallPath;

    CCPackage *package = [self testPackage];

    [_packageManager downloadPackage:package enableAfterDownload:NO];

    [self waitForDelegateToReturn];

    XCTAssertNotNil(package);
    XCTAssertTrue(_managerReturnedSuccessfully);
    XCTAssertEqual(package.status, CCPackageStatusInstalledDisabled);
}

- (void)testEnablePackage
{
    CCPackage *package = [self testPackage];

    NSString *pathToPackage = [[[NSBundle mainBundle] bundlePath] stringByAppendingPathComponent:@"Resources-shared/Packages/testpackage-iOS-phonehd_unzipped"];
    package.installURL = [[NSURL fileURLWithPath:pathToPackage] URLByAppendingPathComponent:@"testpackage-iOS-phonehd"];
    package.status = CCPackageStatusInstalledDisabled;

    NSError *error;
    BOOL success = [_packageManager enablePackage:package error:&error];

    XCTAssertTrue(success);
    XCTAssertNil(error);
    XCTAssertNotNil([_packageManager packageWithName:@"testpackage"]);
    XCTAssertEqual(package.status, CCPackageStatusInstalledEnabled);
}

- (void)testEnableNonDisabledPackage
{
    CCPackage *package = [self testPackageWithStatus:CCPackageStatusDownloaded];

    NSError *error;
    BOOL success = [_packageManager enablePackage:package error:&error];

    XCTAssertFalse(success);
    XCTAssertEqual(error.code, PACKAGE_ERROR_MANAGER_CANNOT_ENABLE_NON_DISABLED_PACKAGE);
    XCTAssertNotNil([_packageManager packageWithName:@"testpackage"]);
    XCTAssertEqual(package.status, CCPackageStatusDownloaded);
}

- (void)testDisablePackage
{
    CCPackage *package = [self testPackageWithStatus:CCPackageStatusInstalledEnabled];

    NSError *error;
    BOOL success = [_packageManager disablePackage:package error:&error];

    XCTAssertTrue(success);
    XCTAssertNil(error);
    XCTAssertNotNil([_packageManager packageWithName:@"testpackage"]);
    XCTAssertEqual(package.status, CCPackageStatusInstalledDisabled);
}

- (void)testDisableNonEnabledPackage
{
    CCPackage *package = [self testPackageWithStatus:CCPackageStatusUnzipped];

    NSError *error;
    BOOL success = [_packageManager disablePackage:package error:&error];

    XCTAssertFalse(success);
    XCTAssertEqual(error.code, PACKAGE_ERROR_MANAGER_CANNOT_DISABLE_NON_ENABLED_PACKAGE);
    XCTAssertNotNil([_packageManager packageWithName:@"testpackage"]);
    XCTAssertEqual(package.status, CCPackageStatusUnzipped);
}

- (void)testDeleteInstalledPackage
{
    CCPackage *package = [self testPackageWithStatus:CCPackageStatusInstalledEnabled];
    [_packageManager.packages addObject:package];

    NSError *error;
    BOOL success = [_packageManager deletePackage:package error:&error];

    XCTAssertTrue(success);

    BOOL isInSearchPath = NO;
    for (NSString *aSearchPath in [CCFileUtils sharedFileUtils].searchPath)
    {
        if ([aSearchPath isEqualToString:package.installURL.path])
        {
            isInSearchPath = YES;
        }
    }

    XCTAssertFalse(isInSearchPath);

    NSFileManager *fileManager = [NSFileManager defaultManager];
    XCTAssertFalse([fileManager fileExistsAtPath:package.installURL.path]);
    XCTAssertNil([_packageManager packageWithName:@"testpackage"]);
}

- (void)testDeleteUnzippingPackage
{
    CCPackage *package = [self testPackage];
    package.status = CCPackageStatusUnzipping;
    [_packageManager.packages addObject:package];

    NSError *error;
    BOOL success = [_packageManager deletePackage:package error:&error];

    XCTAssertFalse(success);
    XCTAssertEqual(error.code, PACKAGE_ERROR_MANAGER_CANNOT_DELETE_UNZIPPING_PACKAGE);
    XCTAssertNotNil([_packageManager packageWithName:@"testpackage"]);
}

- (void)testDeleteDownloadingPackage
{

}

/*
- (void)testCancelDownload
{
    XCTFail(@"Not implemented yet.");
}

- (void)testLoadPackages
{
    XCTFail(@"Not implemented yet.");
}
*/

- (void)testAllOtherDownloadRelatedMethods
{
/* - (void)resumeAllDownloads;
 * - (void)pauseAllDownloads;
 * - (void)pauseDownloadOfPackage:(CCPackage *)package;
 * - (void)resumeDownloadOfPackage:(CCPackage *)package;
 *
 * These should be already tests in the CCPackageDownloadManagerTests class as CCPackageManager is just delegating the class to that class.
 */
}


#pragma mark - CCPackageManagerDelegate

- (void)packageInstallationFinished:(CCPackage *)package
{
    self.managerReturnedSuccessfully = YES;
}

- (void)packageInstallationFailed:(CCPackage *)package error:(NSError *)error
{
    self.managerReturnedFailed = YES;
    self.managerReturnedWithError = error;
}

- (void)packageDownloadFinished:(CCPackage *)package
{
    // Nothing to do at the moment
}

- (void)packageDownloadFailed:(CCPackage *)package error:(NSError *)error
{
    self.managerReturnedFailed = YES;
    self.managerReturnedWithError = error;
}

- (void)packageUnzippingFinished:(CCPackage *)package
{
    // Nothing to do at the moment
}

- (void)packageUnzippingFailed:(CCPackage *)package error:(NSError *)error
{
    self.managerReturnedFailed = YES;
    self.managerReturnedWithError = error;
}

- (NSString *)customFolderName:(CCPackage *)package packageContents:(NSArray *)packageContents
{
    return _customFolderName;
}




#pragma mark - Fixtures

- (CCPackage *)testPackage
{
    return [self testPackageWithStatus:CCPackageStatusInitial];
}

- (CCPackage *)testPackageWithStatus:(CCPackageStatus)status
{
    CCPackage *package = [[CCPackage alloc] initWithName:@"testpackage"
                                              resolution:@"phonehd"
                                                      os:@"iOS"
                                               remoteURL:[[NSURL URLWithString:PACKAGE_BASE_URL]
                                                                 URLByAppendingPathComponent:@"testpackage-iOS-phonehd.zip"]];
    package.status = status;

    if (status == CCPackageStatusInstalledDisabled
        || status == CCPackageStatusInstalledEnabled)
    {
        NSString *pathToPackage = [[[NSBundle mainBundle] bundlePath] stringByAppendingPathComponent:@"Resources-shared/Packages/testpackage-iOS-phonehd_unzipped/testpackage-iOS-phonehd"];

        NSFileManager *fileManager = [NSFileManager defaultManager];

        package.installURL = [NSURL fileURLWithPath:[_packageManager.installedPackagesPath stringByAppendingPathComponent:@"testpackage-iOS-phonehd"]];

        [fileManager copyItemAtPath:pathToPackage toPath:package.installURL.path error:nil];
    }

    if (status == CCPackageStatusInstalledEnabled)
    {
        CCPackageCocos2dEnabler *packageEnabler = [[CCPackageCocos2dEnabler alloc] init];
        [packageEnabler enablePackages:@[package]];
    }

    return package;
}

#pragma mark - Helper

- (void)waitForDelegateToReturn
{
    while (!_managerReturnedFailed
           && !_managerReturnedSuccessfully)
    {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate distantFuture]];
    }
}

@end
