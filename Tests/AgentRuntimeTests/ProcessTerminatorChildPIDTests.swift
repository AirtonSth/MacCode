import XCTest
import Darwin
@testable import AgentRuntime

// Verifies that ProcessTerminator.terminateTree uses the injected ChildPIDProvider
// so termination ordering and escalation are unit-testable without spawning real
// processes.
//
// WHY these tests exist (Rule 8):
// - terminateTree sends SIGTERM to every node in the tree (children first, root
//   last) then escalates survivors to SIGKILL after the grace window.  A wrong
//   traversal order silences children before parents can handle them gracefully.
// - Prior to the seam, directChildPIDs called proc_listchildpids unconditionally,
//   making it impossible to assert ordering or escalation behaviour in tests that
//   have no control over the live process table.

final class ProcessTerminatorChildPIDTests: XCTestCase {

    // MARK: - Fake provider

    /// Test double: returns a pre-wired parent -> [children] tree so tests
    /// control the traversal without touching the OS process table.
    private struct FakeChildPIDProvider: ProcessTerminator.ChildPIDProviding {
        /// Maps each pid to its direct children (empty list = leaf node).
        let tree: [Int32: [Int32]]

        func directChildren(of pid: Int32) -> [Int32] {
            tree[pid] ?? []
        }
    }

    func test_unreapedDescendants_dropsRootAndDeadPids() {
        // WHY: Graphify's Python resource_tracker can outlive the CLI root.
        // Timeout must recapture the tree and kill only still-alive children.
        let leftover = ProcessTerminator.unreapedDescendants(
            root: 10,
            tree: [11, 10, 12, 0, -1],
            isAlive: { pid in pid == 11 || pid == 10 }
        )
        XCTAssertEqual(leftover, [11])
    }

    // Restore the real provider after each test so other suites are unaffected.
    override func tearDown() {
        super.tearDown()
        ProcessTerminator.childPIDProvider = ProcessTerminator.LibprocChildPIDProvider()
    }

    // MARK: - Ordering (via processTreePIDs + terminationPlan)

    // terminateTree visits leaves before their parent; this is enforced by
    // processTreePIDs returning children first, root last.
    // WHY: signalling a parent before its children can leave orphaned zombie
    // processes when the parent is the only one that would reap them, and prevents
    // the parent from propagating the signal (e.g. via a process group) to leaves
    // that are still running.
    func testProviderSuppliedTreeOrdersChildrenBeforeRoot() {
        // Tree: root=500, children=[501, 502], each child is a leaf.
        let fake = FakeChildPIDProvider(tree: [500: [501, 502]])
        ProcessTerminator.childPIDProvider = fake

        // processTreePIDs returns children-first, root-last.
        let pids = ProcessTerminator.processTreePIDs(root: 500)
        XCTAssertEqual(pids.last, 500, "root must appear last so it is signalled after its children")
        XCTAssertTrue(pids.contains(501) && pids.contains(502),
                      "provider-supplied children must appear in the tree")

        // Build the SIGTERM plan from the provider-ordered pids.
        let plan = ProcessTerminator.terminationPlan(
            pids: pids,
            isAlive: { _ in true },
            graceElapsed: false
        )
        // Phase 1: every pid gets SIGTERM, leaves before root.
        XCTAssertEqual(plan, [
            ProcessTerminationStep(pid: 501, signal: SIGTERM),
            ProcessTerminationStep(pid: 502, signal: SIGTERM),
            ProcessTerminationStep(pid: 500, signal: SIGTERM)
        ], "phase-1 plan must cover all nodes from the provider-supplied tree, children before root")
    }

    // A provider that returns no children yields a tree containing only the root.
    // WHY: a leaf process (no children) must still be signalled -- the tree must
    // not silently drop the root when the provider returns an empty list.
    func testLeafProcessProducesRootOnlyTree() {
        let fake = FakeChildPIDProvider(tree: [:])   // no children for any pid
        ProcessTerminator.childPIDProvider = fake

        let pids = ProcessTerminator.processTreePIDs(root: 500)
        XCTAssertEqual(pids, [500],
                       "leaf process tree must contain only the root when the provider returns no children")

        let plan = ProcessTerminator.terminationPlan(
            pids: pids,
            isAlive: { _ in true },
            graceElapsed: false
        )
        XCTAssertEqual(plan, [ProcessTerminationStep(pid: 500, signal: SIGTERM)],
                       "leaf process must receive SIGTERM")
    }

    // MARK: - Escalation with provider-supplied tree

    // After the grace window, survivors in a provider-supplied tree are escalated
    // to SIGKILL; dead nodes are skipped.
    // WHY: if the escalation phase ignores the liveness probe for provider-returned
    // pids, a recycled pid (same number, different process) could be killed by
    // mistake -- a correctness hazard documented in ProcessTerminationPlanTests.
    func testEscalationSkipsDeadNodesInProviderTree() {
        let fake = FakeChildPIDProvider(tree: [500: [501, 502]])
        ProcessTerminator.childPIDProvider = fake

        // pid 501 died during the grace window; 502 and 500 are still alive.
        let pids: [Int32] = [501, 502, 500]
        let survivors: Set<Int32> = [502, 500]

        let plan = ProcessTerminator.terminationPlan(
            pids: pids,
            isAlive: { survivors.contains($0) },
            graceElapsed: true
        )

        XCTAssertEqual(plan, [
            ProcessTerminationStep(pid: 502, signal: SIGKILL),
            ProcessTerminationStep(pid: 500, signal: SIGKILL)
        ], "phase-2 must escalate only live pids; dead pid 501 must be skipped")
    }

    // MARK: - Provider is used (wiring verification)

    // Verifies that childPIDProvider is actually consulted by processTreePIDs,
    // not bypassed.
    // WHY: if the seam were declared but never used, processTreePIDs would still
    // call the hard-coded libproc path and the provider swap would have no effect --
    // a pid not in the OS process table would yield [] from libproc, and a tree with
    // injected children would return only the root.  The test detects this by
    // injecting a provider that returns children for a pid that doesn't exist in the
    // OS process table (99999), then asserting the tree includes those children.
    func testProcessTreePIDs_usesInjectedProviderNotLibproc() {
        // Use pid 99999 which almost certainly doesn't exist in the OS process
        // table; libproc would return [] for it, but the fake provider returns [99998].
        let unrealPID: Int32 = 99999
        let fake = FakeChildPIDProvider(tree: [unrealPID: [99998]])
        ProcessTerminator.childPIDProvider = fake

        let tree = ProcessTerminator.processTreePIDs(root: unrealPID)

        // If the provider is wired correctly: tree == [99998, 99999] (child first, root last).
        // If libproc were used instead: tree == [99999] (no children for a non-existent pid).
        XCTAssertEqual(tree, [99998, unrealPID],
                       "processTreePIDs must use the injected provider, not libproc; " +
                       "a non-existent OS pid with an injected child must yield [child, root]")
    }

    // Swapping the provider mid-test changes the returned tree (confirms the provider
    // is read on each call, not cached at process startup).
    // WHY: if childPIDProvider were read once and stored, swapping it at test-setup
    // time would have no effect on subsequent calls, leaving all tests sharing the
    // same (now stale) provider reference.
    func testSwappingProviderChangesTraversalResult() {
        // Provider A: root 900 has children [901, 902].
        let providerA = FakeChildPIDProvider(tree: [900: [901, 902]])
        ProcessTerminator.childPIDProvider = providerA

        let treeA = ProcessTerminator.processTreePIDs(root: 900)
        XCTAssertEqual(treeA, [901, 902, 900],
                       "with provider A the tree must contain both children before the root")

        // Provider B: root 900 is a leaf (no children).
        let providerB = FakeChildPIDProvider(tree: [:])
        ProcessTerminator.childPIDProvider = providerB

        let treeB = ProcessTerminator.processTreePIDs(root: 900)
        XCTAssertEqual(treeB, [900],
                       "after swapping to a leaf-only provider the tree must shrink to just the root")
    }
}
