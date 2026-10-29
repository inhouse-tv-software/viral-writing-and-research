//
//  ApplicationDelegate.m
//  Beat
//
//  Copyright © 2019 Lauri-Matti Parppei. All rights reserved.
//  Copyright © 2016 Hendrik Noeller. All rights reserved.
//	Released under GPL license



#import <os/log.h>
#import <BeatParsing/BeatParsing.h>
#import <StoreKit/StoreKit.h>
#import <BeatCore/NSString+VersionNumber.h>
#import <BeatThemes/BeatThemes.h>
#import <BeatPlugins/BeatPlugins.h>
#import <BeatFileExport/BeatFileExport.h>

#import "BeatAppDelegate.h"
#import "BeatAppDelegate+DarkMode.h"
#import "BeatAppDelegate+Backups.h"
#import "BeatAppDelegate+AdditionalViews.h"

#import "BeatNotifications.h"

#ifndef QUICKLOOK
#import "Beat-Swift.h"
#endif

#import "BeatTest.h"

#define APPNAME @"Beat"

@interface BeatAppDelegate () <BeatThemeDelegate> {
	bool awoken;
}

@property (nonatomic) BeatNotifications *notifications;

// Some outlets for classes added in IB
@property (nonatomic) IBOutlet BeatPluginMenuManager *pluginMenuManager;
@property (nonatomic) IBOutlet BeatWebResources *resources;
@property (nonatomic) IBOutlet BeatSpellCheckingUtils *spellCheckingUtils;

@property (nonatomic) IBOutlet BeatTemplateMenuProvider *templateMenuProvider;

@property (nonatomic) BeatTest *tests;

@property (nonatomic) IBOutlet NSMenuItem *checkForUpdatesItem;

@end

@implementation BeatAppDelegate

#define DEVELOPMENT NO

#pragma mark - Help

+(void)load {
	[super load];
}

- (instancetype) init {
	self = [super init];
	
	// Use these to reset any user defaults (for debugging purposes)
	//[NSUserDefaults.standardUserDefaults removePersistentDomainForName:NSBundle.mainBundle.bundleIdentifier];
	//[NSUserDefaults.standardUserDefaults removeObjectForKey:@"AppleLanguages"];
	
	[self checkDarkMode];
	NSWindow.allowsAutomaticWindowTabbing = true;
	
	return self;
}

- (void)awakeFromNib
{
	if (awoken) return;
	
	NSLog(@"(beat) %@ / %@ - %@ distribution",
		  NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"],
		  NSBundle.mainBundle.infoDictionary[@"CFBundleVersion"],
		  BeatAppDelegate.distribution);
	
	// Setup (or remove) auto-update system and menu items
	[self setupUpdates];
	
	// Show welcome screen
	[self showLaunchScreen];
	
	// Populate plugin menu
	[self.pluginMenuManager setup];
	// Populate style menu
	[self.styleMenuManager setup];
	
	awoken = true;
}

+ (NSString*)distribution
{
#ifdef ADHOC
	return @"Ad Hoc";
#endif
#ifdef APPSTORE
	return @"App Store";
#endif
#ifdef ORGANIZATION
	return @"Academic";
#endif
}

- (void)applicationWillFinishLaunching:(NSNotification *)notification
{
	if (@available(macOS 10.14, *)) {
		UNUserNotificationCenter *center = UNUserNotificationCenter.currentNotificationCenter;
		[center requestAuthorizationWithOptions:UNAuthorizationOptionBadge | UNAuthorizationOptionAlert completionHandler:^(BOOL granted, NSError * _Nullable error) {
		}];
	}
}

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification
{
	[self setupDocumentOpenListener];

	// Show launch screen
	[self showLaunchScreen];
	
	// Add to launch count
	NSInteger timesLaunched = [NSUserDefaults.standardUserDefaults integerForKey:@"LaunchCount"] + 1;
	[NSUserDefaults.standardUserDefaults setInteger:timesLaunched forKey:@"LaunchCount"];
}

- (void)applicationWillTerminate:(NSNotification *)notification
{
#ifdef ADHOC
	//[BeatDonationPlea nag];
#endif
}


#pragma mark - Window management

- (BOOL)applicationShouldOpenUntitledFile:(NSApplication *)sender
{
	return NO;
}

/*
- (BOOL)applicationShouldHandleReopen:(NSApplication *)theApplication hasVisibleWindows:(BOOL)flag
{
	return !flag;
}
*/

#pragma mark - Updates

- (void)setupUpdates
{
	// Viral doesn't use Beat's update feed, so remove update related menu items
	[_checkForUpdatesItem.menu removeItem:_checkForUpdatesItem];
	_checkForUpdatesItem = nil;
}




#pragma mark - Handoff
/*
- (BOOL)application:(NSApplication *)application continueUserActivity:(NSUserActivity *)userActivity restorationHandler:(void (^)(NSArray<id<NSUserActivityRestoring>> * _Nonnull))restorationHandler
{
	return false;
}
*/


#pragma mark - Generic methods for opening a plain-text file

- (id)newDocumentWithContents:(NSString*)string
{
	NSURL *tempURL = [BeatPaths urlForTemporaryFileWithPrefix:@"fountain"];
	NSError *error;
	
	[string writeToURL:tempURL atomically:NO encoding:NSUTF8StringEncoding error:&error];
	id document = [NSDocumentController.sharedDocumentController duplicateDocumentWithContentsOfURL:tempURL copying:YES displayName:@"Untitled" error:nil];
	
	return document;
}

- (IBAction)newDocument:(id)sender
{
	[NSDocumentController.sharedDocumentController newDocument:sender];
}


#pragma mark - Create a file with rich text contents (attributed string)

/*
/// Unfortunately this requires some additional hacking.
- (id)newDocumentWithAttributedString:(NSAttributedString*)string
{
	NSURL* tempURL = [self URLForTemporaryFileWithPrefix:@"fountain"];
	
	NSMutableAttributedString* result = string.mutableCopy;
	[string enumerateAttributesInRange:NSMakeRange(0, string.length) options:0 usingBlock:^(NSDictionary<NSAttributedStringKey,id> * _Nonnull attrs, NSRange range, BOOL * _Nonnull stop) {
		// First append the string
		NSString* s = [string.string substringWithRange:range];
		[result appendAttributedString:[NSAttributedString.alloc initWithString:s]];
		
		// Then append all Beat-related attributes
		for (NSString* key in attrs.allKeys) {
			if ([key rangeOfString:@"Beat"].location != 0) continue;
			id value = attrs[key];
			
			if (value != nil) [result addAttribute:key value:value range:range];
		}
	}];
	
	BeatDocumentSettings* docSettings = BeatDocumentSettings.new;
	[docSettings set:DocSettingRevisions as:<#(nonnull id)#>
}
*/


#pragma mark - Menu delegation

-(void)menuWillOpen:(NSMenu *)menu
{
	if (menu == _backupMenu) {
		[self addBackupMenuItemsTo:menu];
	}
}


#pragma mark - Show notifications

- (void)showNotification:(NSString*)title body:(NSString*)body identifier:(NSString*)identifier oneTime:(BOOL)showOnce interval:(CGFloat)interval
{
	if (!_notifications) _notifications = BeatNotifications.new;
	[_notifications showNotification:title body:body identifier:identifier oneTime:showOnce interval:interval];
}


#pragma mark - Supporting methods

/// This is here just to conform to theme manager delegate. Themes should be a part of the BeatCore framework, just saying.
- (NSURL*)appDataPath:(NSString*)subPath {
	return [BeatPaths appDataPath:subPath];
}


@end
