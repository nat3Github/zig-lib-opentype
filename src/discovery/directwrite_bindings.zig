// Hand-written DirectWrite COM bindings (dwrite.h subset).
//
// NOT run through `zig translate-c`, unlike core_text_bindings.zig: dwrite.h
// is a C++-style COM header (RIDL-macro interface declarations) that
// translate-c cannot parse into usable Zig, and this checkout has no Windows
// SDK to run it against anyway. Instead this mirrors the layout
// translate-c-plus-hand-edit would produce: one `extern struct { vtable:
// *const XVtbl }` per COM interface, with vtable fields in the exact
// declaration order from the real header so member-function offsets match
// the ABI.
//
// GUIDs and vtable method order verified against the `winapi` crate's
// `src/um/dwrite.rs` (a direct transcription of the Windows SDK header),
// not hand-guessed — a wrong GUID or misordered vtable slot fails
// QueryInterface or calls the wrong function silently. Cross-checked a
// second time against zigwin32 (github.com/marlersoft/zigwin32,
// win32metadata-generated, vendor/zigwin32/win32/graphics/direct_write.zig)
// — the GUIDs and vtable slot orders declared here match exactly.
//
// UNVERIFIED: cross-compiles for x86_64-windows but has never been run (no
// Windows machine available). Only the methods this backend calls are
// declared; interface methods that come *before* a needed one in the real
// vtable are kept as opaque placeholder fields (never called, but required
// to preserve the offsets of the methods after them) — methods declared
// *after* the last one this backend needs are omitted entirely.

const std = @import("std");

pub const WCHAR = u16;
pub const BOOL = i32;
pub const UINT32 = u32;
pub const HRESULT = i32;

pub const S_OK: HRESULT = 0;
pub const E_NOINTERFACE: HRESULT = @bitCast(@as(u32, 0x80004002));

pub const GUID = extern struct {
    data1: u32,
    data2: u16,
    data3: u16,
    data4: [8]u8,
};

pub const IID_IDWriteFactory = GUID{ .data1 = 0xb859ee5a, .data2 = 0xd838, .data3 = 0x4b5b, .data4 = .{ 0xa2, 0xe8, 0x1a, 0xdc, 0x7d, 0x93, 0xdb, 0x48 } };
pub const IID_IDWriteFontCollection = GUID{ .data1 = 0xa84cee02, .data2 = 0x3eea, .data3 = 0x4eee, .data4 = .{ 0xa8, 0x27, 0x87, 0xc1, 0xa0, 0x2a, 0x0f, 0xcc } };
pub const IID_IDWriteFontFamily = GUID{ .data1 = 0xda20d8ef, .data2 = 0x812a, .data3 = 0x4c43, .data4 = .{ 0x98, 0x02, 0x62, 0xec, 0x4a, 0xbd, 0x7a, 0xdd } };
pub const IID_IDWriteFont = GUID{ .data1 = 0xacd16696, .data2 = 0x8c14, .data3 = 0x4f5d, .data4 = .{ 0x87, 0x7e, 0xfe, 0x3f, 0xc1, 0xd3, 0x27, 0x37 } };
pub const IID_IDWriteFontFace = GUID{ .data1 = 0x5f49804d, .data2 = 0x7024, .data3 = 0x4d43, .data4 = .{ 0xbf, 0xa9, 0xd2, 0x59, 0x84, 0xf5, 0x38, 0x49 } };
pub const IID_IDWriteFontFile = GUID{ .data1 = 0x739d886a, .data2 = 0xcef5, .data3 = 0x47dc, .data4 = .{ 0x87, 0x69, 0x1a, 0x8b, 0x41, 0xbe, 0xbb, 0xb0 } };
pub const IID_IDWriteFontFileLoader = GUID{ .data1 = 0x727cad4e, .data2 = 0xd6af, .data3 = 0x4c9e, .data4 = .{ 0x8a, 0x08, 0xd6, 0x95, 0xb1, 0x1c, 0xaa, 0x49 } };
pub const IID_IDWriteLocalFontFileLoader = GUID{ .data1 = 0xb2d9f3ec, .data2 = 0xc9fe, .data3 = 0x4a11, .data4 = .{ 0xa2, 0xec, 0xd8, 0x62, 0x08, 0xf7, 0xc0, 0xa2 } };

// DWRITE_FACTORY_TYPE
pub const DWRITE_FACTORY_TYPE_SHARED: u32 = 0;

// DWRITE_FONT_WEIGHT: plain UINT32/int, 1..999, CSS-compatible (100 == Thin
// ... 900 == Black), no translation table needed unlike CoreText's
// normalized axis.
pub const DWRITE_FONT_WEIGHT = u32;
// DWRITE_FONT_STRETCH: 1..9, index-for-index the same as this codebase's
// discovery.Stretch enumerators (UltraCondensed..UltraExpanded).
pub const DWRITE_FONT_STRETCH = u32;
// DWRITE_FONT_STYLE: Normal = 0, Oblique = 1, Italic = 2.
pub const DWRITE_FONT_STYLE = u32;
pub const DWRITE_FONT_STYLE_NORMAL: DWRITE_FONT_STYLE = 0;
pub const DWRITE_FONT_STYLE_OBLIQUE: DWRITE_FONT_STYLE = 1;
pub const DWRITE_FONT_STYLE_ITALIC: DWRITE_FONT_STYLE = 2;

pub extern "dwrite" fn DWriteCreateFactory(
    factoryType: u32,
    iid: *const GUID,
    factory: *?*IDWriteFactory,
) callconv(.winapi) HRESULT;

/// Vtable slots 0..2 (IUnknown) + slot 3 (`GetSystemFontCollection`), the
/// only `IDWriteFactory` method this backend calls — everything after it in
/// the real vtable (CreateCustomFontCollection, CreateFontFace, text-layout
/// methods, ...) is omitted.
pub const IDWriteFactoryVtbl = extern struct {
    QueryInterface: *const fn (*IDWriteFactory, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*IDWriteFactory) callconv(.winapi) u32,
    Release: *const fn (*IDWriteFactory) callconv(.winapi) u32,
    GetSystemFontCollection: *const fn (*IDWriteFactory, *?*IDWriteFontCollection, checkForUpdates: BOOL) callconv(.winapi) HRESULT,
};
pub const IDWriteFactory = extern struct { vtable: *const IDWriteFactoryVtbl };

/// Slots 0..2 (IUnknown), 3 `GetFontFamilyCount` (used by
/// `availableFamilies`; `FindFamilyName` gives the index directly for
/// lookups by name), 4 `GetFontFamily`, 5 `FindFamilyName`.
/// `GetFontFromFontFace` (slot 6) omitted.
pub const IDWriteFontCollectionVtbl = extern struct {
    QueryInterface: *const fn (*IDWriteFontCollection, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*IDWriteFontCollection) callconv(.winapi) u32,
    Release: *const fn (*IDWriteFontCollection) callconv(.winapi) u32,
    GetFontFamilyCount: *const fn (*IDWriteFontCollection) callconv(.winapi) UINT32,
    GetFontFamily: *const fn (*IDWriteFontCollection, index: UINT32, *?*IDWriteFontFamily) callconv(.winapi) HRESULT,
    FindFamilyName: *const fn (*IDWriteFontCollection, familyName: [*:0]const WCHAR, index: *UINT32, exists: *BOOL) callconv(.winapi) HRESULT,
};
pub const IDWriteFontCollection = extern struct { vtable: *const IDWriteFontCollectionVtbl };

/// `IDWriteFontFamily` inherits `IDWriteFontList`'s vtable prefix (slots
/// 0..2 IUnknown, 3 `GetFontCollection` placeholder, 4 `GetFontCount`, 5
/// `GetFont`) then adds 6 `GetFamilyNames`. `GetFirstMatchingFont` (7) and
/// `GetMatchingFonts` (8) are omitted.
pub const IDWriteFontFamilyVtbl = extern struct {
    QueryInterface: *const fn (*IDWriteFontFamily, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*IDWriteFontFamily) callconv(.winapi) u32,
    Release: *const fn (*IDWriteFontFamily) callconv(.winapi) u32,
    GetFontCollection: *const anyopaque,
    GetFontCount: *const fn (*IDWriteFontFamily) callconv(.winapi) UINT32,
    GetFont: *const fn (*IDWriteFontFamily, index: UINT32, *?*IDWriteFont) callconv(.winapi) HRESULT,
    GetFamilyNames: *const fn (*IDWriteFontFamily, *?*IDWriteLocalizedStrings) callconv(.winapi) HRESULT,
};
pub const IDWriteFontFamily = extern struct { vtable: *const IDWriteFontFamilyVtbl };

/// Slots 0..2 IUnknown, 3 `GetCount`, 4 `FindLocaleName` (placeholder), 5
/// `GetLocaleNameLength` (placeholder), 6 `GetLocaleName` (placeholder), 7
/// `GetStringLength`, 8 `GetString`.
pub const IDWriteLocalizedStringsVtbl = extern struct {
    QueryInterface: *const fn (*IDWriteLocalizedStrings, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*IDWriteLocalizedStrings) callconv(.winapi) u32,
    Release: *const fn (*IDWriteLocalizedStrings) callconv(.winapi) u32,
    GetCount: *const fn (*IDWriteLocalizedStrings) callconv(.winapi) UINT32,
    FindLocaleName: *const anyopaque,
    GetLocaleNameLength: *const anyopaque,
    GetLocaleName: *const anyopaque,
    GetStringLength: *const fn (*IDWriteLocalizedStrings, index: UINT32, length: *UINT32) callconv(.winapi) HRESULT,
    GetString: *const fn (*IDWriteLocalizedStrings, index: UINT32, stringBuffer: [*]WCHAR, size: UINT32) callconv(.winapi) HRESULT,
};
pub const IDWriteLocalizedStrings = extern struct { vtable: *const IDWriteLocalizedStringsVtbl };

/// Slots 0..2 IUnknown, 3 `GetFontFamily` (placeholder), 4 `GetWeight`, 5
/// `GetStretch`, 6 `GetStyle`, 7 `IsSymbolFont` (placeholder), 8
/// `GetFaceNames` (placeholder), 9 `GetInformationalStrings` (placeholder),
/// 10 `GetSimulations` (placeholder), 11 `GetMetrics` (placeholder), 12
/// `HasCharacter` (placeholder), 13 `CreateFontFace`. Nothing after
/// `CreateFontFace` is declared.
pub const IDWriteFontVtbl = extern struct {
    QueryInterface: *const fn (*IDWriteFont, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*IDWriteFont) callconv(.winapi) u32,
    Release: *const fn (*IDWriteFont) callconv(.winapi) u32,
    GetFontFamily: *const anyopaque,
    GetWeight: *const fn (*IDWriteFont) callconv(.winapi) DWRITE_FONT_WEIGHT,
    GetStretch: *const fn (*IDWriteFont) callconv(.winapi) DWRITE_FONT_STRETCH,
    GetStyle: *const fn (*IDWriteFont) callconv(.winapi) DWRITE_FONT_STYLE,
    IsSymbolFont: *const anyopaque,
    GetFaceNames: *const anyopaque,
    GetInformationalStrings: *const anyopaque,
    GetSimulations: *const anyopaque,
    GetMetrics: *const anyopaque,
    HasCharacter: *const anyopaque,
    CreateFontFace: *const fn (*IDWriteFont, *?*IDWriteFontFace) callconv(.winapi) HRESULT,
};
pub const IDWriteFont = extern struct { vtable: *const IDWriteFontVtbl };

/// Slots 0..2 IUnknown, 3 `GetType` (placeholder), 4 `GetFiles`, 5
/// `GetIndex`. Everything after `GetIndex` (GetSimulations, IsSymbolFont,
/// GetMetrics, outline/rasterization methods, ...) omitted.
pub const IDWriteFontFaceVtbl = extern struct {
    QueryInterface: *const fn (*IDWriteFontFace, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*IDWriteFontFace) callconv(.winapi) u32,
    Release: *const fn (*IDWriteFontFace) callconv(.winapi) u32,
    GetType: *const anyopaque,
    GetFiles: *const fn (*IDWriteFontFace, numberOfFiles: *UINT32, fontFiles: ?[*]?*IDWriteFontFile) callconv(.winapi) HRESULT,
    GetIndex: *const fn (*IDWriteFontFace) callconv(.winapi) UINT32,
};
pub const IDWriteFontFace = extern struct { vtable: *const IDWriteFontFaceVtbl };

/// Slots 0..2 IUnknown, 3 `GetReferenceKey`, 4 `GetLoader`. `Analyze` (slot
/// 5) omitted.
pub const IDWriteFontFileVtbl = extern struct {
    QueryInterface: *const fn (*IDWriteFontFile, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*IDWriteFontFile) callconv(.winapi) u32,
    Release: *const fn (*IDWriteFontFile) callconv(.winapi) u32,
    GetReferenceKey: *const fn (*IDWriteFontFile, key: *?*const anyopaque, keySize: *UINT32) callconv(.winapi) HRESULT,
    GetLoader: *const fn (*IDWriteFontFile, loader: *?*IDWriteFontFileLoader) callconv(.winapi) HRESULT,
};
pub const IDWriteFontFile = extern struct { vtable: *const IDWriteFontFileVtbl };

/// Base `IDWriteFontFileLoader` — only used as a QueryInterface target to
/// reach `IDWriteLocalFontFileLoader`, so nothing beyond IUnknown is
/// declared (`CreateStreamFromKey`, slot 3, is never called on this type).
pub const IDWriteFontFileLoaderVtbl = extern struct {
    QueryInterface: *const fn (*IDWriteFontFileLoader, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*IDWriteFontFileLoader) callconv(.winapi) u32,
    Release: *const fn (*IDWriteFontFileLoader) callconv(.winapi) u32,
};
pub const IDWriteFontFileLoader = extern struct { vtable: *const IDWriteFontFileLoaderVtbl };

/// `IDWriteLocalFontFileLoader` inherits `IDWriteFontFileLoader`'s vtable
/// (slots 0..2 IUnknown, 3 `CreateStreamFromKey` placeholder) then adds 4
/// `GetFilePathLengthFromKey`, 5 `GetFilePathFromKey`. `GetLastWriteTimeFromKey`
/// (slot 6) omitted.
pub const IDWriteLocalFontFileLoaderVtbl = extern struct {
    QueryInterface: *const fn (*IDWriteLocalFontFileLoader, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*IDWriteLocalFontFileLoader) callconv(.winapi) u32,
    Release: *const fn (*IDWriteLocalFontFileLoader) callconv(.winapi) u32,
    CreateStreamFromKey: *const anyopaque,
    GetFilePathLengthFromKey: *const fn (*IDWriteLocalFontFileLoader, key: ?*const anyopaque, keySize: UINT32, length: *UINT32) callconv(.winapi) HRESULT,
    GetFilePathFromKey: *const fn (*IDWriteLocalFontFileLoader, key: ?*const anyopaque, keySize: UINT32, filePath: [*]WCHAR, filePathSize: UINT32) callconv(.winapi) HRESULT,
};
pub const IDWriteLocalFontFileLoader = extern struct { vtable: *const IDWriteLocalFontFileLoaderVtbl };

pub const FLOAT = f32;

pub const IID_IUnknown = GUID{ .data1 = 0x00000000, .data2 = 0x0000, .data3 = 0x0000, .data4 = .{ 0xc0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46 } };
pub const IID_IDWriteTextAnalysisSource = GUID{ .data1 = 0x688e1a58, .data2 = 0x5094, .data3 = 0x47c8, .data4 = .{ 0xad, 0xc8, 0xfb, 0xce, 0xa6, 0x0a, 0xe9, 0x2b } };
pub const IID_IDWriteFactory2 = GUID{ .data1 = 0x0439fc60, .data2 = 0xca44, .data3 = 0x4994, .data4 = .{ 0x8d, 0xee, 0x3a, 0x9a, 0xf7, 0xb7, 0x32, 0xec } };
pub const IID_IDWriteFontFallback = GUID{ .data1 = 0xefa008f9, .data2 = 0xf7a1, .data3 = 0x48bf, .data4 = .{ 0xb0, 0x5c, 0xf2, 0x24, 0x71, 0x3c, 0xc0, 0xff } };

pub const DWRITE_FONT_WEIGHT_NORMAL: DWRITE_FONT_WEIGHT = 400;
pub const DWRITE_FONT_STRETCH_NORMAL: DWRITE_FONT_STRETCH = 5;

// DWRITE_READING_DIRECTION: LeftToRight = 0.
pub const DWRITE_READING_DIRECTION = u32;
pub const DWRITE_READING_DIRECTION_LEFT_TO_RIGHT: DWRITE_READING_DIRECTION = 0;

/// `IDWriteFactory2` reached by `QueryInterface` on `IDWriteFactory` (same
/// object, DirectWrite 1.2 / Windows 8.1+). Its vtable is `IDWriteFactory`'s
/// 24 slots plus `IDWriteFactory1`'s 2, then `GetSystemFontFallback` at
/// slot 26 — everything before it is an unused placeholder that only exists
/// to keep that offset right.
pub const IDWriteFactory2Vtbl = extern struct {
    QueryInterface: *const fn (*IDWriteFactory2, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*IDWriteFactory2) callconv(.winapi) u32,
    Release: *const fn (*IDWriteFactory2) callconv(.winapi) u32,
    GetSystemFontCollection: *const anyopaque,
    CreateCustomFontCollection: *const anyopaque,
    RegisterFontCollectionLoader: *const anyopaque,
    UnregisterFontCollectionLoader: *const anyopaque,
    CreateFontFileReference: *const anyopaque,
    CreateCustomFontFileReference: *const anyopaque,
    CreateFontFace: *const anyopaque,
    CreateRenderingParams: *const anyopaque,
    CreateMonitorRenderingParams: *const anyopaque,
    CreateCustomRenderingParams: *const anyopaque,
    RegisterFontFileLoader: *const anyopaque,
    UnregisterFontFileLoader: *const anyopaque,
    CreateTextFormat: *const anyopaque,
    CreateTypography: *const anyopaque,
    GetGdiInterop: *const anyopaque,
    CreateTextLayout: *const anyopaque,
    CreateGdiCompatibleTextLayout: *const anyopaque,
    CreateEllipsisTrimmingSign: *const anyopaque,
    CreateTextAnalyzer: *const anyopaque,
    CreateNumberSubstitution: *const anyopaque,
    CreateGlyphRunAnalysis: *const anyopaque,
    GetEudcFontCollection: *const anyopaque,
    CreateCustomRenderingParams1: *const anyopaque,
    GetSystemFontFallback: *const fn (*IDWriteFactory2, *?*IDWriteFontFallback) callconv(.winapi) HRESULT,
};
pub const IDWriteFactory2 = extern struct { vtable: *const IDWriteFactory2Vtbl };

/// Slots 0..2 IUnknown, 3 `MapCharacters` — the whole interface.
pub const IDWriteFontFallbackVtbl = extern struct {
    QueryInterface: *const fn (*IDWriteFontFallback, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*IDWriteFontFallback) callconv(.winapi) u32,
    Release: *const fn (*IDWriteFontFallback) callconv(.winapi) u32,
    MapCharacters: *const fn (
        *IDWriteFontFallback,
        analysisSource: *IDWriteTextAnalysisSource,
        textPosition: UINT32,
        textLength: UINT32,
        baseFontCollection: ?*IDWriteFontCollection,
        baseFamilyName: ?[*:0]const WCHAR,
        baseWeight: DWRITE_FONT_WEIGHT,
        baseStyle: DWRITE_FONT_STYLE,
        baseStretch: DWRITE_FONT_STRETCH,
        mappedLength: *UINT32,
        mappedFont: *?*IDWriteFont,
        scale: *FLOAT,
    ) callconv(.winapi) HRESULT,
};
pub const IDWriteFontFallback = extern struct { vtable: *const IDWriteFontFallbackVtbl };

/// `IDWriteTextAnalysisSource` is the one COM interface here *this* code
/// implements rather than calls: `MapCharacters` reads its text through it.
/// `TextAnalysisSource` below is a stack-allocated instance with a static
/// vtable — DirectWrite only borrows it for the duration of the call, so
/// AddRef/Release are no-ops rather than real refcounting.
pub const IDWriteTextAnalysisSourceVtbl = extern struct {
    QueryInterface: *const fn (*IDWriteTextAnalysisSource, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*IDWriteTextAnalysisSource) callconv(.winapi) u32,
    Release: *const fn (*IDWriteTextAnalysisSource) callconv(.winapi) u32,
    GetTextAtPosition: *const fn (*IDWriteTextAnalysisSource, textPosition: UINT32, textString: *?[*]const WCHAR, textLength: *UINT32) callconv(.winapi) HRESULT,
    GetTextBeforePosition: *const fn (*IDWriteTextAnalysisSource, textPosition: UINT32, textString: *?[*]const WCHAR, textLength: *UINT32) callconv(.winapi) HRESULT,
    GetParagraphReadingDirection: *const fn (*IDWriteTextAnalysisSource) callconv(.winapi) DWRITE_READING_DIRECTION,
    GetLocaleName: *const fn (*IDWriteTextAnalysisSource, textPosition: UINT32, textLength: *UINT32, localeName: *?[*:0]const WCHAR) callconv(.winapi) HRESULT,
    GetNumberSubstitution: *const fn (*IDWriteTextAnalysisSource, textPosition: UINT32, textLength: *UINT32, numberSubstitution: *?*anyopaque) callconv(.winapi) HRESULT,
};
pub const IDWriteTextAnalysisSource = extern struct { vtable: *const IDWriteTextAnalysisSourceVtbl };

/// Minimal `IDWriteTextAnalysisSource` over a single in-memory UTF-16 run.
/// Layout must start with the vtable pointer so a `*TextAnalysisSource` is
/// a valid `*IDWriteTextAnalysisSource`.
pub const TextAnalysisSource = extern struct {
    vtable: *const IDWriteTextAnalysisSourceVtbl = &vtable_impl,
    text: [*]const WCHAR,
    len: UINT32,
    locale: ?[*:0]const WCHAR = null,

    pub fn init(text: []const WCHAR) TextAnalysisSource {
        return .{ .text = text.ptr, .len = @intCast(text.len) };
    }

    pub fn asSource(self: *TextAnalysisSource) *IDWriteTextAnalysisSource {
        return @ptrCast(self);
    }

    const vtable_impl: IDWriteTextAnalysisSourceVtbl = .{
        .QueryInterface = queryInterface,
        .AddRef = addRef,
        .Release = release,
        .GetTextAtPosition = getTextAtPosition,
        .GetTextBeforePosition = getTextBeforePosition,
        .GetParagraphReadingDirection = getParagraphReadingDirection,
        .GetLocaleName = getLocaleName,
        .GetNumberSubstitution = getNumberSubstitution,
    };

    // Must refuse unknown IIDs: DirectWrite probes for IDWriteTextAnalysisSource1,
    // and claiming it makes DWrite call past the end of this 8-slot vtable.
    fn queryInterface(this: *IDWriteTextAnalysisSource, iid: *const GUID, out: *?*anyopaque) callconv(.winapi) HRESULT {
        if (std.meta.eql(iid.*, IID_IUnknown) or std.meta.eql(iid.*, IID_IDWriteTextAnalysisSource)) {
            out.* = this;
            return S_OK;
        }
        out.* = null;
        return E_NOINTERFACE;
    }

    fn addRef(this: *IDWriteTextAnalysisSource) callconv(.winapi) u32 {
        _ = this;
        return 1;
    }

    fn release(this: *IDWriteTextAnalysisSource) callconv(.winapi) u32 {
        _ = this;
        return 1;
    }

    fn getTextAtPosition(this: *IDWriteTextAnalysisSource, position: UINT32, string: *?[*]const WCHAR, length: *UINT32) callconv(.winapi) HRESULT {
        const self: *TextAnalysisSource = @ptrCast(this);
        if (position >= self.len) {
            string.* = null;
            length.* = 0;
        } else {
            string.* = self.text + position;
            length.* = self.len - position;
        }
        return S_OK;
    }

    fn getTextBeforePosition(this: *IDWriteTextAnalysisSource, position: UINT32, string: *?[*]const WCHAR, length: *UINT32) callconv(.winapi) HRESULT {
        const self: *TextAnalysisSource = @ptrCast(this);
        if (position == 0 or position > self.len) {
            string.* = null;
            length.* = 0;
        } else {
            string.* = self.text;
            length.* = position;
        }
        return S_OK;
    }

    fn getParagraphReadingDirection(this: *IDWriteTextAnalysisSource) callconv(.winapi) DWRITE_READING_DIRECTION {
        _ = this;
        return DWRITE_READING_DIRECTION_LEFT_TO_RIGHT;
    }

    fn getLocaleName(this: *IDWriteTextAnalysisSource, position: UINT32, length: *UINT32, locale: *?[*:0]const WCHAR) callconv(.winapi) HRESULT {
        const self: *TextAnalysisSource = @ptrCast(this);
        _ = position;
        // Null unless the caller chose one: a guessed locale would bias Han
        // unification the wrong way.
        locale.* = self.locale;
        length.* = self.len;
        return S_OK;
    }

    fn getNumberSubstitution(this: *IDWriteTextAnalysisSource, position: UINT32, length: *UINT32, substitution: *?*anyopaque) callconv(.winapi) HRESULT {
        const self: *TextAnalysisSource = @ptrCast(this);
        _ = position;
        substitution.* = null;
        length.* = self.len;
        return S_OK;
    }
};
