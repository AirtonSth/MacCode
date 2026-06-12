import XCTest
@testable import SocketServer
import CoreModel

// Tests for the fs.list RPC handler (Dispatcher.fsList).
// Verifies output shape, dirs-first sort, hidden-file inclusion, and error paths.
// The handler uses FileManager.contentsOfDirectory(at:includingPropertiesForKeys:)
// with .isDirectoryKey prefetched to avoid a per-child stat.
@MainActor
final class FsListDispatcherTests: XCTestCase {
    // MARK: - helpers

    private func dispatch(_ path: String) async -> JSONRPCResponse {
        let d = JSONRPCDispatcher(router: FakeRouter())
        return await d.dispatch(JSONRPCRequest(
            jsonrpc: "2.0", id: .number(1),
            method: "fs.list",
            params: ["path": .string(path)]
        ))
    }

    private func entries(in result: JSONValue) -> [JSONValue] {
        guard case .object(let o) = result,
              case .array(let arr) = o["entries"] else { return [] }
        return arr
    }

    // MARK: - tests

    func test_lists_real_tmp_directory_without_error() async throws {
        // /private/tmp always exists on macOS; verifies the happy path does not error.
        let resp = await dispatch("/private/tmp")
        XCTAssertNil(resp.error, "fs.list /private/tmp must not error")
        XCTAssertNotNil(resp.result)
    }

    func test_output_shape_contains_path_parentPath_entries() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let resp = await dispatch(tmp.path)
        XCTAssertNil(resp.error)
        guard case .object(let o) = resp.result else { XCTFail("expected object result"); return }
        XCTAssertNotNil(o["path"],       "result must include 'path'")
        XCTAssertNotNil(o["parentPath"], "result must include 'parentPath'")
        XCTAssertNotNil(o["entries"],    "result must include 'entries'")
    }

    func test_each_entry_has_name_path_type_keys() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Create one file and one subdirectory.
        let fileURL = tmp.appendingPathComponent("alpha.txt")
        let dirURL  = tmp.appendingPathComponent("beta_dir")
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: false)

        let resp = await dispatch(tmp.path)
        XCTAssertNil(resp.error)
        let arr = entries(in: resp.result!)
        XCTAssertEqual(arr.count, 2)
        for entry in arr {
            guard case .object(let e) = entry else { XCTFail("entry is not object"); continue }
            XCTAssertNotNil(e["name"], "entry missing 'name'")
            XCTAssertNotNil(e["path"], "entry missing 'path'")
            XCTAssertNotNil(e["type"], "entry missing 'type'")
        }
    }

    func test_directories_sort_before_files() async throws {
        // Invariant: regardless of lexicographic order, dirs must come first.
        // Use names where "z_file" < "a_dir" lexicographically to prove it is not
        // a simple alpha sort.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        FileManager.default.createFile(atPath: tmp.appendingPathComponent("a_file.txt").path, contents: nil)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("z_dir"), withIntermediateDirectories: false)

        let resp = await dispatch(tmp.path)
        XCTAssertNil(resp.error)
        let arr = entries(in: resp.result!)
        guard arr.count == 2,
              case .object(let first) = arr[0],
              case .string(let firstType) = first["type"] else {
            XCTFail("expected exactly 2 entries"); return
        }
        XCTAssertEqual(firstType, "directory",
                       "directory must sort before file even when its name is lexicographically last")
    }

    func test_hidden_files_are_included() async throws {
        // contentsOfDirectory(at:options:[]) with no .skipsHiddenFiles option includes
        // hidden entries. Verify the entry appears so callers can render dot-files.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        FileManager.default.createFile(atPath: tmp.appendingPathComponent(".hidden").path, contents: nil)
        FileManager.default.createFile(atPath: tmp.appendingPathComponent("visible.txt").path, contents: nil)

        let resp = await dispatch(tmp.path)
        XCTAssertNil(resp.error)
        let names = entries(in: resp.result!).compactMap { entry -> String? in
            guard case .object(let e) = entry, case .string(let n) = e["name"] else { return nil }
            return n
        }
        XCTAssertTrue(names.contains(".hidden"),
                      "hidden files must be included in the listing")
    }

    func test_type_field_is_file_for_regular_file() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        FileManager.default.createFile(atPath: tmp.appendingPathComponent("plain.txt").path, contents: nil)

        let resp = await dispatch(tmp.path)
        XCTAssertNil(resp.error)
        let arr = entries(in: resp.result!)
        guard let entry = arr.first, case .object(let e) = entry,
              case .string(let t) = e["type"] else {
            XCTFail("expected one file entry"); return
        }
        XCTAssertEqual(t, "file")
    }

    func test_type_field_is_directory_for_subdirectory() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("subdir"), withIntermediateDirectories: false)

        let resp = await dispatch(tmp.path)
        XCTAssertNil(resp.error)
        let arr = entries(in: resp.result!)
        guard let entry = arr.first, case .object(let e) = entry,
              case .string(let t) = e["type"] else {
            XCTFail("expected one directory entry"); return
        }
        XCTAssertEqual(t, "directory")
    }

    func test_non_existent_path_returns_error_code_minus32602() async throws {
        let resp = await dispatch("/nonexistent/path/\(UUID().uuidString)")
        XCTAssertNotNil(resp.error, "missing path must return an error")
        XCTAssertEqual(resp.error?.code, -32602)
    }

    func test_file_path_returns_not_a_directory_error() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".txt")
        FileManager.default.createFile(atPath: tmp.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let resp = await dispatch(tmp.path)
        XCTAssertNotNil(resp.error, "passing a file path must return an error")
        XCTAssertEqual(resp.error?.code, -32602)
    }
}
