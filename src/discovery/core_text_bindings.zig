// Hand-edited output of:
// zig translate-c src/discovery/core_text_shim.h
// on core_text_shim.h, which hand-declares only the CoreFoundation/CoreText
// symbols the discovery backend needs (see that file for why: the real
// CoreText.h umbrella header pulls in CoreGraphics.h, which uses Blocks and
// array-nullability syntax translate-c can't parse).
//
// Trimmed vs. raw translate-c output: dropped compiler builtin macros
// (__GNUC__, __SIZEOF_INT__, etc.) that translate-c always emits alongside
// real declarations — noise, not part of this binding's surface.
//
// Regenerate with the command above, then reapply this trim by hand.

pub const Boolean = u8;
pub const UInt8 = u8;
pub const CFIndex = c_long;
pub const CFTypeID = c_ulong;
pub const CFOptionFlags = c_ulong;
pub const CFTypeRef = ?*const anyopaque;

pub const CFAllocator = opaque {};
pub const CFAllocatorRef = ?*const CFAllocator;
pub const CFString = opaque {};
pub const CFStringRef = ?*const CFString;
pub const CFURL = opaque {};
pub const CFURLRef = ?*const CFURL;
pub const CFDictionary = opaque {};
pub const CFDictionaryRef = ?*const CFDictionary;
pub const CFArray = opaque {};
pub const CFArrayRef = ?*const CFArray;
pub const CFNumber = opaque {};
pub const CFNumberRef = ?*const CFNumber;

pub const CFStringEncoding = c_uint;
pub const kCFStringEncodingUTF8: CFStringEncoding = 0x08000100;

pub const CFNumberType = c_long;
pub const kCFNumberSInt32Type: CFNumberType = 3;
pub const kCFNumberDoubleType: CFNumberType = 13;

pub extern const kCFAllocatorDefault: CFAllocatorRef;

pub extern fn CFRetain(cf: CFTypeRef) CFTypeRef;
pub extern fn CFRelease(cf: CFTypeRef) void;

pub extern fn CFStringCreateWithBytes(alloc: CFAllocatorRef, bytes: [*c]const UInt8, numBytes: CFIndex, encoding: CFStringEncoding, isExternalRepresentation: Boolean) CFStringRef;
pub extern fn CFStringGetCString(theString: CFStringRef, buffer: [*c]u8, bufferSize: CFIndex, encoding: CFStringEncoding) Boolean;
pub extern fn CFStringGetLength(theString: CFStringRef) CFIndex;

pub const CFRange = extern struct {
    location: CFIndex,
    length: CFIndex,
};

pub extern fn CFURLGetFileSystemRepresentation(url: CFURLRef, resolveAgainstBase: Boolean, buffer: [*c]UInt8, maxBufLen: CFIndex) Boolean;

pub const CFDictionaryKeyCallBacks = ?*const anyopaque;
pub const CFDictionaryValueCallBacks = ?*const anyopaque;
pub extern const kCFTypeDictionaryKeyCallBacks: CFDictionaryKeyCallBacks;
pub extern const kCFTypeDictionaryValueCallBacks: CFDictionaryValueCallBacks;
pub extern fn CFDictionaryCreate(allocator: CFAllocatorRef, keys: [*c]?*const anyopaque, values: [*c]?*const anyopaque, numValues: CFIndex, keyCallBacks: [*c]const CFDictionaryKeyCallBacks, valueCallBacks: [*c]const CFDictionaryValueCallBacks) CFDictionaryRef;
pub extern fn CFDictionaryGetValue(theDict: CFDictionaryRef, key: ?*const anyopaque) ?*const anyopaque;

pub const CFArrayCallBacks = ?*const anyopaque;
pub extern const kCFTypeArrayCallBacks: CFArrayCallBacks;
pub extern fn CFArrayCreate(allocator: CFAllocatorRef, values: [*c]?*const anyopaque, numValues: CFIndex, callBacks: [*c]const CFArrayCallBacks) CFArrayRef;
pub extern fn CFArrayGetCount(theArray: CFArrayRef) CFIndex;
pub extern fn CFArrayGetValueAtIndex(theArray: CFArrayRef, idx: CFIndex) ?*const anyopaque;

pub extern fn CFNumberGetValue(number: CFNumberRef, theType: CFNumberType, valuePtr: ?*anyopaque) Boolean;

pub const CTFontDescriptor = opaque {};
pub const CTFontDescriptorRef = ?*const CTFontDescriptor;
pub const CTFontCollection = opaque {};
pub const CTFontCollectionRef = ?*const CTFontCollection;
pub const CTFont = opaque {};
pub const CTFontRef = ?*const CTFont;

pub extern const kCTFontURLAttribute: CFStringRef;
pub extern const kCTFontNameAttribute: CFStringRef;
pub extern const kCTFontFamilyNameAttribute: CFStringRef;
pub extern const kCTFontTraitsAttribute: CFStringRef;
pub extern const kCTFontVariationAxesAttribute: CFStringRef;
pub extern const kCTFontVariationAxisIdentifierKey: CFStringRef;
pub extern const kCTFontVariationAxisMinimumValueKey: CFStringRef;
pub extern const kCTFontVariationAxisMaximumValueKey: CFStringRef;

pub extern const kCTFontSymbolicTrait: CFStringRef;
pub extern const kCTFontWeightTrait: CFStringRef;
pub extern const kCTFontWidthTrait: CFStringRef;
pub extern const kCTFontSlantTrait: CFStringRef;

pub extern fn CTFontDescriptorCreateWithAttributes(attributes: CFDictionaryRef) CTFontDescriptorRef;
pub extern fn CTFontDescriptorCopyAttribute(descriptor: CTFontDescriptorRef, attribute: CFStringRef) CFTypeRef;

pub extern fn CTFontCollectionCreateWithFontDescriptors(queryDescriptors: CFArrayRef, options: CFDictionaryRef) CTFontCollectionRef;
pub extern fn CTFontCollectionCreateMatchingFontDescriptors(collection: CTFontCollectionRef) CFArrayRef;

// Used by `availableFamilies` — the system's own "every installed family"
// list, the same one Font Book and every Cocoa font picker shows.
pub extern fn CTFontManagerCopyAvailableFontFamilyNames() CFArrayRef;

// Used by `selectFallbackForCodepoint`'s CoreText cascade-list lookup, not
// the family-listing path above.
pub extern fn CTFontCreateWithFontDescriptor(descriptor: CTFontDescriptorRef, size: f64, matrix: ?*const anyopaque) CTFontRef;
pub extern fn CTFontCreateWithName(name: CFStringRef, size: f64, matrix: ?*const anyopaque) CTFontRef;
pub const CTFontUIFontType = u32;
pub const kCTFontUIFontSystem: CTFontUIFontType = 2;
pub extern fn CTFontCreateUIFontForLanguage(uiType: CTFontUIFontType, size: f64, language: CFStringRef) CTFontRef;
pub extern fn CTFontCreateForString(currentFont: CTFontRef, string: CFStringRef, range: CFRange) CTFontRef;
// macOS 10.15+ / iOS 13+.
pub extern fn CTFontCreateForStringWithLanguage(currentFont: CTFontRef, string: CFStringRef, range: CFRange, language: CFStringRef) CTFontRef;
pub extern fn CTFontCopyFontDescriptor(font: CTFontRef) CTFontDescriptorRef;

// CTFontTableOptions is `uint32_t`, not CFOptionFlags (`c_ulong`, 8 bytes on
// arm64/x86_64) -- binding it as the wrong width breaks the ABI on Apple
// Silicon.
pub const CTFontTableOptions = u32;
pub extern fn CTFontCopyAvailableTables(font: CTFontRef, options: CTFontTableOptions) CFArrayRef;

// CTFontSymbolicTraits bit (CTFontTraits.h) — enum constant, no extern
// symbol to bind, so declared directly rather than round-tripped through
// translate-c.
pub const kCTFontTraitItalic: u32 = 1 << 0;
