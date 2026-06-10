import XCTest
@testable import Persistence
import CoreModel

/// Tests for ProjectRepository: CRUD round-trip, list() ordering, upsert semantics.
///
/// WHY these tests matter:
///   - ProjectRepository.list() is called on every workspace-list rebuild; if it
///     returns projects in wrong order (updated_at DESC) the sidebar is scrambled.
///   - Upsert must update mutable fields (name, path, favorite) without duplicating
///     or stomping the created_at timestamp, which is the source of truth for
///     project-creation time in the sidebar.
final class ProjectRepositoryTests: XCTestCase {

    // MARK: - Helpers

    private func makeDB() throws -> SQLiteDB {
        let db = try SQLiteDB(path: ":memory:")
        try Schema.migrate(db)
        return db
    }

    private func makeProject(
        name: String = "proj",
        path: String = "/tmp/proj",
        favorite: Bool = false,
        createdAt: Date = Date(timeIntervalSince1970: 1_000),
        updatedAt: Date = Date(timeIntervalSince1970: 1_000)
    ) -> ProjectRepository.Project {
        ProjectRepository.Project(
            id: ProjectID(UUID()),
            name: name,
            path: path,
            favorite: favorite,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    // MARK: - CRUD round-trip

    /// WHY: all fields written via upsert must be retrievable via list() so
    /// a project rename or path-change is reflected immediately to the sidebar.
    func test_upsert_andList_roundTripsAllFields() throws {
        let db = try makeDB()
        let repo = ProjectRepository(db: db)
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        let updated = Date(timeIntervalSince1970: 1_700_001_000)
        let p = ProjectRepository.Project(
            id: ProjectID(UUID()),
            name: "MyProject",
            path: "/Users/alice/myproject",
            favorite: true,
            createdAt: created,
            updatedAt: updated
        )

        try repo.upsert(p)

        let listed = try repo.list()
        XCTAssertEqual(listed.count, 1)
        let r = listed[0]
        XCTAssertEqual(r.id, p.id, "id must survive upsert")
        XCTAssertEqual(r.name, "MyProject", "name must round-trip so the sidebar shows the correct project label")
        XCTAssertEqual(r.path, "/Users/alice/myproject", "path must round-trip so the app opens the correct directory")
        XCTAssertTrue(r.favorite, "favorite flag must round-trip so favorites are not lost on restart")
        XCTAssertEqual(r.createdAt.timeIntervalSince1970, created.timeIntervalSince1970, accuracy: 1,
            "createdAt must round-trip so project age is stable across restarts")
        XCTAssertEqual(r.updatedAt.timeIntervalSince1970, updated.timeIntervalSince1970, accuracy: 1,
            "updatedAt must round-trip so list() ordering is stable")
    }

    // MARK: - list() ordering (updated_at DESC)

    /// WHY: the sidebar shows most-recently-updated projects first. If list()
    /// returns oldest-first, the user sees stale projects at the top after working
    /// on a new one.
    func test_list_returnsMostRecentlyUpdatedFirst() throws {
        let db = try makeDB()
        let repo = ProjectRepository(db: db)

        let older = makeProject(name: "older", updatedAt: Date(timeIntervalSince1970: 1_000))
        let newer = makeProject(name: "newer", updatedAt: Date(timeIntervalSince1970: 9_000))
        let middle = makeProject(name: "middle", updatedAt: Date(timeIntervalSince1970: 5_000))

        try repo.upsert(older)
        try repo.upsert(newer)
        try repo.upsert(middle)

        let listed = try repo.list()
        XCTAssertEqual(listed.map(\.name), ["newer", "middle", "older"],
            "list() must order by updated_at DESC so the sidebar surfaces the most-recently-active project at the top")
    }

    // MARK: - upsert updates mutable fields only

    /// WHY: upsert uses ON CONFLICT(id) DO UPDATE. If it accidentally overwrites
    /// created_at, the project-creation date shown in the sidebar drifts over time.
    /// Only name, path, favorite, and updated_at are mutable.
    func test_upsert_updatesNameAndPathButPreservesCreatedAt() throws {
        let db = try makeDB()
        let repo = ProjectRepository(db: db)

        let originalCreatedAt = Date(timeIntervalSince1970: 1_000)
        var p = makeProject(name: "old-name", path: "/old", favorite: false, createdAt: originalCreatedAt, updatedAt: Date(timeIntervalSince1970: 1_000))
        try repo.upsert(p)

        p.name = "new-name"
        p.path = "/new"
        p.favorite = true
        p.updatedAt = Date(timeIntervalSince1970: 9_000)
        try repo.upsert(p)

        let listed = try repo.list()
        XCTAssertEqual(listed.count, 1, "upsert must not insert a duplicate row")
        let r = listed[0]
        XCTAssertEqual(r.name, "new-name", "upsert must update name")
        XCTAssertEqual(r.path, "/new", "upsert must update path")
        XCTAssertTrue(r.favorite, "upsert must update favorite")
        XCTAssertEqual(r.createdAt.timeIntervalSince1970, originalCreatedAt.timeIntervalSince1970, accuracy: 1,
            "upsert must NOT overwrite created_at; overwriting it drifts the project-age display in the sidebar")
    }

    // MARK: - empty table

    func test_list_emptyTable_returnsEmptyArray() throws {
        let db = try makeDB()
        let repo = ProjectRepository(db: db)

        let listed = try repo.list()
        XCTAssertTrue(listed.isEmpty,
            "list() on an empty table must return an empty array, not nil or an error")
    }

    // MARK: - multiple projects isolation

    /// WHY: upsert by id must not touch other projects. A scoping bug would
    /// cause a rename of project A to rename project B as well.
    func test_upsert_isolatesAcrossProjects() throws {
        let db = try makeDB()
        let repo = ProjectRepository(db: db)

        var pA = makeProject(name: "A", updatedAt: Date(timeIntervalSince1970: 1_000))
        let pB = makeProject(name: "B", updatedAt: Date(timeIntervalSince1970: 2_000))
        try repo.upsert(pA)
        try repo.upsert(pB)

        pA.name = "A-renamed"
        pA.updatedAt = Date(timeIntervalSince1970: 3_000)
        try repo.upsert(pA)

        let listed = try repo.list()
        let names = Set(listed.map(\.name))
        XCTAssertTrue(names.contains("A-renamed"), "renamed project A must reflect the update")
        XCTAssertTrue(names.contains("B"), "project B must be unaffected by the rename of project A")
        XCTAssertEqual(listed.count, 2, "upsert must not insert a third row when updating project A")
    }
}
