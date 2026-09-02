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
// — all 8 GUIDs and every vtable slot order declared here match exactly.
//
// UNVERIFIED: never compiled or run (no Windows machine available this
// session). Only the methods this backend's `selectFamilyByName` calls are
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

/// Slots 0..2 (IUnknown), 3 `GetFontFamilyCount` (placeholder, unused —
/// `FindFamilyName` gives the index directly), 4 `GetFontFamily`, 5
/// `FindFamilyName`. `GetFontFromFontFace` (slot 6) omitted.
pub const IDWriteFontCollectionVtbl = extern struct {
    QueryInterface: *const fn (*IDWriteFontCollection, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*IDWriteFontCollection) callconv(.winapi) u32,
    Release: *const fn (*IDWriteFontCollection) callconv(.winapi) u32,
    GetFontFamilyCount: *const anyopaque,
    GetFontFamily: *const fn (*IDWriteFontCollection, index: UINT32, *?*IDWriteFontFamily) callconv(.winapi) HRESULT,
    FindFamilyName: *const fn (*IDWriteFontCollection, familyName: [*:0]const WCHAR, index: *UINT32, exists: *BOOL) callconv(.winapi) HRESULT,
};
pub const IDWriteFontCollection = extern struct { vtable: *const IDWriteFontCollectionVtbl };

/// `IDWriteFontFamily` inherits `IDWriteFontList`'s vtable prefix (slots
/// 0..2 IUnknown, 3 `GetFontCollection` placeholder, 4 `GetFontCount`, 5
/// `GetFont`) and only adds family-specific methods after it
/// (`GetFamilyNames`, `GetFirstMatchingFont`, `GetMatchingFonts`) — none of
/// which this backend needs, so the shared `IDWriteFontList` prefix is all
/// that's declared.
pub const IDWriteFontFamilyVtbl = extern struct {
    QueryInterface: *const fn (*IDWriteFontFamily, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*IDWriteFontFamily) callconv(.winapi) u32,
    Release: *const fn (*IDWriteFontFamily) callconv(.winapi) u32,
    GetFontCollection: *const anyopaque,
    GetFontCount: *const fn (*IDWriteFontFamily) callconv(.winapi) UINT32,
    GetFont: *const fn (*IDWriteFontFamily, index: UINT32, *?*IDWriteFont) callconv(.winapi) HRESULT,
};
pub const IDWriteFontFamily = extern struct { vtable: *const IDWriteFontFamilyVtbl };

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
