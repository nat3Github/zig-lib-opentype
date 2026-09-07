/*
 * Narrow, hand-written declarations for the CoreFoundation/CoreText symbols
 * the discovery backend needs. Deliberately does NOT #include the real
 * CoreFoundation.h/CoreText.h umbrella headers: CoreText.h pulls in
 * CoreGraphics.h, which uses Blocks and array-nullability syntax that
 * `zig translate-c` cannot parse. Every declaration here is copied from the
 * real SDK headers (macOS SDK, CoreFoundation.framework /
 * CoreText.framework) trimmed to only what this backend calls.
 *
 * Run `zig translate-c src/discovery/core_text_shim.h -- -isysroot $(xcrun
 * --show-sdk-path)` to regenerate core_text_bindings.zig, then re-apply any
 * hand edits (see comments in that file).
 */
#ifndef CORE_TEXT_SHIM_H
#define CORE_TEXT_SHIM_H

#include <stdint.h>

typedef unsigned char Boolean;
typedef unsigned char UInt8;
typedef signed long CFIndex;
typedef unsigned long CFTypeID;
typedef unsigned long CFOptionFlags;

typedef const void *CFTypeRef;
typedef const struct __CFAllocator *CFAllocatorRef;
typedef const struct __CFString *CFStringRef;
typedef const struct __CFURL *CFURLRef;
typedef const struct __CFDictionary *CFDictionaryRef;
typedef const struct __CFArray *CFArrayRef;
typedef const struct __CFNumber *CFNumberRef;

typedef unsigned int CFStringEncoding;
enum { kCFStringEncodingUTF8 = 0x08000100 };

typedef long CFNumberType;
enum {
    kCFNumberSInt32Type = 3,
    kCFNumberDoubleType = 13,
};

extern const CFAllocatorRef kCFAllocatorDefault;

CFTypeRef CFRetain(CFTypeRef cf);
void CFRelease(CFTypeRef cf);

CFStringRef CFStringCreateWithBytes(CFAllocatorRef alloc, const UInt8 *bytes, CFIndex numBytes, CFStringEncoding encoding, Boolean isExternalRepresentation);
Boolean CFStringGetCString(CFStringRef theString, char *buffer, CFIndex bufferSize, CFStringEncoding encoding);

Boolean CFURLGetFileSystemRepresentation(CFURLRef url, Boolean resolveAgainstBase, UInt8 *buffer, CFIndex maxBufLen);

typedef struct {
    CFIndex location;
    CFIndex length;
} CFRange;

typedef const void *CFDictionaryKeyCallBacks;
typedef const void *CFDictionaryValueCallBacks;
extern const CFDictionaryKeyCallBacks kCFTypeDictionaryKeyCallBacks;
extern const CFDictionaryValueCallBacks kCFTypeDictionaryValueCallBacks;
CFDictionaryRef CFDictionaryCreate(CFAllocatorRef allocator, const void **keys, const void **values, CFIndex numValues, const CFDictionaryKeyCallBacks *keyCallBacks, const CFDictionaryValueCallBacks *valueCallBacks);
const void *CFDictionaryGetValue(CFDictionaryRef theDict, const void *key);

typedef const void *CFArrayCallBacks;
extern const CFArrayCallBacks kCFTypeArrayCallBacks;
CFArrayRef CFArrayCreate(CFAllocatorRef allocator, const void **values, CFIndex numValues, const CFArrayCallBacks *callBacks);
CFIndex CFArrayGetCount(CFArrayRef theArray);
const void *CFArrayGetValueAtIndex(CFArrayRef theArray, CFIndex idx);

Boolean CFNumberGetValue(CFNumberRef number, CFNumberType theType, void *valuePtr);

typedef const struct __CTFontDescriptor *CTFontDescriptorRef;
typedef const struct __CTFontCollection *CTFontCollectionRef;
typedef const struct __CTFont *CTFontRef;

extern const CFStringRef kCTFontURLAttribute;
extern const CFStringRef kCTFontNameAttribute;
extern const CFStringRef kCTFontFamilyNameAttribute;
extern const CFStringRef kCTFontTraitsAttribute;

extern const CFStringRef kCTFontSymbolicTrait;
extern const CFStringRef kCTFontWeightTrait;
extern const CFStringRef kCTFontWidthTrait;
extern const CFStringRef kCTFontSlantTrait;

CTFontDescriptorRef CTFontDescriptorCreateWithAttributes(CFDictionaryRef attributes);
CFTypeRef CTFontDescriptorCopyAttribute(CTFontDescriptorRef descriptor, CFStringRef attribute);

CTFontCollectionRef CTFontCollectionCreateWithFontDescriptors(CFArrayRef queryDescriptors, CFDictionaryRef options);
CFArrayRef CTFontCollectionCreateMatchingFontDescriptors(CTFontCollectionRef collection);

CFArrayRef CTFontManagerCopyAvailableFontFamilyNames(void);

CTFontRef CTFontCreateWithFontDescriptor(CTFontDescriptorRef descriptor, double size, const void *matrix);
CTFontRef CTFontCreateWithName(CFStringRef name, double size, const void *matrix);
CTFontRef CTFontCreateForString(CTFontRef currentFont, CFStringRef string, CFRange range);
CTFontDescriptorRef CTFontCopyFontDescriptor(CTFontRef font);

typedef uint32_t CTFontTableOptions;
CFArrayRef CTFontCopyAvailableTables(CTFontRef font, CTFontTableOptions options);

#endif
