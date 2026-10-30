//
//  BeatDocumentBaseController+Fonts.m
//  BeatCore
//
//  Created by Lauri-Matti Parppei on 17.6.2026.
//

#import "BeatDocumentBaseController+Fonts.h"
#import <BeatCore/BeatCore-Swift.h>
#import <BeatCore/BeatFontSet.h>

@implementation BeatDocumentBaseController (Fonts)

#pragma mark - Fonts

/// Returns fonts for this document window. Make sure that fonts are loaded before styles.
- (BeatFontSet*)fonts
{
    if (self.__fonts == nil) return BeatFontManager.shared.defaultFonts;
    else return self.__fonts;
}

- (void)setFonts:(BeatFontSet *)fonts
{
    self.__fonts = fonts;
}

- (NSInteger)fontStyle
{
    return [BeatUserDefaults.sharedDefaults getInteger:BeatSettingFontStyle];
}

/// Returns current default font point size
- (CGFloat)fontSize
{
    return BeatFontManager.shared.defaultFonts.regular.pointSize;
}

- (BeatFontType)fontType
{
    return [BeatFontSet fontTypeWithStyle:self.fontStyle variableWidth:self.editorStyles.variableFont];
}

- (void)loadFonts
{
    [self loadFontsWithScale:1.0];
}

- (void)loadFontsWithScale:(CGFloat)scale
{
    // Viral: a font picked from the fonts on this Mac wins over the built-in screenplay fonts
    NSString* custom = BeatFontManager.customFontName;
    if (custom != nil) {
        BeatFontSet* set = [BeatFontManager.shared customFontsWithName:custom scale:scale];
        if (set != nil) { self.fonts = set; return; }
    }
    self.fonts = [BeatFontManager.shared fontsWith:self.fontType scale:scale];
}

/// Reloads fonts and reformats whole document if needed.
/// @warning Can take a lot of time. Use with care.
- (void)reloadFonts
{
    NSString* oldFontName = self.fonts.name.copy;
    [self loadFonts];
    
    // If the font changed, let's reformat the whole document.
    if (![oldFontName isEqualToString:self.fonts.name]) [self.formatting formatAllLines];
}

- (CGFloat)fontScale
{
#if TARGET_OS_IOS
    if (is_Mobile) {
        CGFloat zoom = (CGFloat)[BeatUserDefaults.sharedDefaults getInteger:BeatSettingPhoneFontSize];
        return ((zoom + 4) / 10 ) + 1.0;
    }
#endif
    return 1.0;
}

@end
