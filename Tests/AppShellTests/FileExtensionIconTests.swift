import XCTest
@testable import AppShell

/// Tests for the pure `fileIcon(for:)` helper in FilesSurface.
///
/// WHY these tests matter:
///  - Distinct per-extension icons are a product feature (P3): users scan the sidebar faster
///    when .swift / .js / .ts / .json / .yml / .md / .png each show a different glyph.
///    A regression that collapses two distinct types to the same symbol breaks that affordance.
///  - Case-insensitive matching is required because macOS file systems are case-insensitive
///    by default; `.Swift` and `.SWIFT` must produce the same icon as `.swift`.
///  - Unknown extensions must produce the generic "doc" sentinel, not crash or return nil.
final class FileExtensionIconTests: XCTestCase {

    // MARK: - Known extensions produce distinct symbols

    func test_swift_returnsSwiftSymbol() {
        XCTAssertEqual(fileIcon(for: "main.swift"), "swift",
            ".swift files must use the dedicated Swift SF Symbol")
    }

    func test_js_returnsCurlybraces() {
        XCTAssertEqual(fileIcon(for: "app.js"), "curlybraces",
            ".js files must use curlybraces to distinguish from TypeScript")
    }

    func test_ts_returnsCurlybracessquare() {
        XCTAssertEqual(fileIcon(for: "app.ts"), "curlybraces.square",
            ".ts files must use curlybraces.square to distinguish from JavaScript")
    }

    func test_json_returnsEllipsisCurlybraces() {
        XCTAssertEqual(fileIcon(for: "package.json"), "ellipsis.curlybraces",
            ".json files must have their own distinct icon")
    }

    func test_yml_returnsGearshape() {
        XCTAssertEqual(fileIcon(for: "config.yml"), "gearshape",
            ".yml files must use gearshape to reflect config/data nature")
    }

    func test_yaml_returnsGearshape() {
        XCTAssertEqual(fileIcon(for: "docker-compose.yaml"), "gearshape",
            ".yaml is an alias for .yml and must produce the same icon")
    }

    func test_md_returnsDocRichtext() {
        XCTAssertEqual(fileIcon(for: "README.md"), "doc.richtext",
            ".md files must use doc.richtext matching the kind=markdown fallback")
    }

    func test_markdown_returnsDocRichtext() {
        XCTAssertEqual(fileIcon(for: "guide.markdown"), "doc.richtext",
            ".markdown must produce the same icon as .md")
    }

    func test_png_returnsPhoto() {
        XCTAssertEqual(fileIcon(for: "logo.png"), "photo",
            ".png image files must use the photo symbol")
    }

    func test_jpg_returnsPhoto() {
        XCTAssertEqual(fileIcon(for: "photo.jpg"), "photo",
            ".jpg must use the photo symbol same as .png")
    }

    // MARK: - Distinct symbols: no two common types share the same icon

    func test_swiftAndJs_areDistinct() {
        let swiftIcon = fileIcon(for: "main.swift")
        let jsIcon = fileIcon(for: "app.js")
        XCTAssertNotEqual(swiftIcon, jsIcon,
            ".swift and .js must map to distinct icons so users can tell them apart in the sidebar")
    }

    func test_jsAndTs_areDistinct() {
        let jsIcon = fileIcon(for: "app.js")
        let tsIcon = fileIcon(for: "app.ts")
        XCTAssertNotEqual(jsIcon, tsIcon,
            ".js and .ts must map to distinct icons")
    }

    func test_tsAndJson_areDistinct() {
        let tsIcon = fileIcon(for: "app.ts")
        let jsonIcon = fileIcon(for: "config.json")
        XCTAssertNotEqual(tsIcon, jsonIcon,
            ".ts and .json must map to distinct icons")
    }

    func test_jsonAndYml_areDistinct() {
        let jsonIcon = fileIcon(for: "config.json")
        let ymlIcon = fileIcon(for: "config.yml")
        XCTAssertNotEqual(jsonIcon, ymlIcon,
            ".json and .yml must map to distinct icons")
    }

    func test_ymlAndMd_areDistinct() {
        let ymlIcon = fileIcon(for: "config.yml")
        let mdIcon = fileIcon(for: "README.md")
        XCTAssertNotEqual(ymlIcon, mdIcon,
            ".yml and .md must map to distinct icons")
    }

    func test_mdAndPng_areDistinct() {
        let mdIcon = fileIcon(for: "README.md")
        let pngIcon = fileIcon(for: "logo.png")
        XCTAssertNotEqual(mdIcon, pngIcon,
            ".md and .png must map to distinct icons")
    }

    // MARK: - Unknown extension falls back to generic doc

    func test_unknownExtension_returnsDoc() {
        XCTAssertEqual(fileIcon(for: "archive.xyzzy"), "doc",
            "unrecognised extension must return the generic doc sentinel, not crash")
    }

    func test_noExtension_returnsDoc() {
        XCTAssertEqual(fileIcon(for: "Makefile"), "doc",
            "a filename with no extension must return the generic doc sentinel")
    }

    func test_emptyString_returnsDoc() {
        XCTAssertEqual(fileIcon(for: ""), "doc",
            "empty filename must return the generic doc sentinel without crashing")
    }

    // MARK: - Case-insensitive extension matching

    func test_uppercaseSwiftExtension_returnsSwiftSymbol() {
        XCTAssertEqual(fileIcon(for: "Main.SWIFT"), "swift",
            "extension matching must be case-insensitive: .SWIFT == .swift")
    }

    func test_mixedCaseJsExtension_returnsCurlybraces() {
        XCTAssertEqual(fileIcon(for: "app.Js"), "curlybraces",
            "extension matching must be case-insensitive: .Js == .js")
    }

    func test_uppercasePngExtension_returnsPhoto() {
        XCTAssertEqual(fileIcon(for: "Banner.PNG"), "photo",
            "extension matching must be case-insensitive: .PNG == .png")
    }

    func test_uppercaseMdExtension_returnsDocRichtext() {
        XCTAssertEqual(fileIcon(for: "README.MD"), "doc.richtext",
            "extension matching must be case-insensitive: .MD == .md")
    }

    func test_uppercaseYmlExtension_returnsGearshape() {
        XCTAssertEqual(fileIcon(for: "config.YML"), "gearshape",
            "extension matching must be case-insensitive: .YML == .yml")
    }

    // MARK: - Additional common extensions

    func test_jsx_returnsCurlybraces() {
        XCTAssertEqual(fileIcon(for: "Component.jsx"), "curlybraces",
            ".jsx React files must share the JS icon")
    }

    func test_tsx_returnsCurlybracessquare() {
        XCTAssertEqual(fileIcon(for: "Component.tsx"), "curlybraces.square",
            ".tsx React/TypeScript files must share the TS icon")
    }

    func test_sh_returnsTerminal() {
        XCTAssertEqual(fileIcon(for: "build.sh"), "terminal",
            ".sh shell scripts must use the terminal symbol")
    }

    func test_py_returnsCodeSymbol() {
        XCTAssertEqual(fileIcon(for: "main.py"), "chevron.left.forwardslash.chevron.right",
            ".py Python files must use the generic code symbol")
    }

    func test_svg_returnsPaintpalette() {
        XCTAssertEqual(fileIcon(for: "icon.svg"), "paintpalette",
            ".svg vector graphics must use paintpalette to differ from raster photos")
    }
}

final class AppCommandRouterFileTypeLabelTests: XCTestCase {
    func test_fileTypeLabel_preservesNSStringPathExtensionForLeadingDotBasenames() {
        // WHY: local/SSH listings used NSString.pathExtension. A leading-dot
        // basename (`.png`, `foo/.png`) has no extension and must stay "File",
        // not "PNG File". photo.PNG and ordinary multi-dot names keep the
        // prior case-insensitive last-extension label.
        XCTAssertEqual(
            AppCommandRouter.fileTypeLabel(for: ".png"),
            "File",
            ".png is a leading-dot basename with no extension"
        )
        XCTAssertEqual(
            AppCommandRouter.fileTypeLabel(for: "foo/.png"),
            "File",
            "foo/.png is a leading-dot basename with no extension"
        )
        XCTAssertEqual(
            AppCommandRouter.fileTypeLabel(for: "photo.PNG"),
            "PNG File",
            "photo.PNG must keep case-insensitive PNG File labeling"
        )
        XCTAssertEqual(
            AppCommandRouter.fileTypeLabel(for: "archive.tar.gz"),
            "GZ File",
            "ordinary multi-dot names must still use the last extension"
        )
    }
}
