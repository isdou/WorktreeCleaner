import Foundation
import Testing
@testable import WorktreeCleanerCore

@Suite("Origin branch removal", .serialized)
struct OriginBranchRemovalTests {
    @Test("Local and origin deletion choices are independent", arguments: [false, true], [false, true])
    func deletionChoices(deleteLocal: Bool, deleteOrigin: Bool) async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        let (item, target) = try await fixture.scan()
        #expect(target.branch == fixture.publishedBranch)

        try await WorktreeScanner.removeWorktree(
            item, moveToTrash: false, deleteLocalBranch: deleteLocal,
            originDeletionTarget: deleteOrigin ? target : nil
        ).get()

        #expect(!fixture.worktreeExists)
        #expect(try await fixture.hasBranch(fixture.localBranch, in: fixture.repo) == !deleteLocal)
        #expect(try await fixture.hasBranch(fixture.publishedBranch, in: fixture.origin) == !deleteOrigin)
        let trackingRef = "refs/remotes/origin/\(fixture.publishedBranch)"
        let tracking = try await fixture.git(["for-each-ref", "--format=%(refname)", trackingRef], in: fixture.repo)
        #expect((tracking == trackingRef) == !deleteOrigin)
        // A same-named remote branch is unrelated when the actual upstream has a different name.
        #expect(try await fixture.hasBranch(fixture.localBranch, in: fixture.origin))
    }

    @Test("A new remote commit or a denied deletion keeps the worktree and branch", arguments: [false, true])
    func remoteRefusal(denyDeletion: Bool) async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        let (item, target) = try await fixture.scan()
        if denyDeletion {
            try await fixture.git(["config", "receive.denyDeletes", "true"], in: fixture.origin)
        } else {
            try await fixture.git(["commit", "--allow-empty", "-m", "Concurrent change"], in: fixture.repo)
            // Write directly to the remote URL so the reviewed tracking ref stays unchanged.
            try await fixture.git(["push", fixture.origin, "HEAD:refs/heads/\(fixture.publishedBranch)"], in: fixture.repo)
        }
        let remoteTip = try await fixture.git(["rev-parse", "refs/heads/\(fixture.publishedBranch)"], in: fixture.origin)
        let result = await WorktreeScanner.removeWorktree(
            item, moveToTrash: false, deleteLocalBranch: true, originDeletionTarget: target)
        #expect(throws: (any Error).self) { try result.get() }
        #expect(fixture.worktreeExists)
        #expect(try await fixture.hasBranch(fixture.localBranch, in: fixture.repo))
        #expect(try await fixture.git(["rev-parse", "refs/heads/\(fixture.publishedBranch)"], in: fixture.origin) == remoteTip)
    }

    @Test("A branch already removed by the Git host allows local cleanup to finish")
    func alreadyDeleted() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        let (item, target) = try await fixture.scan()
        try await fixture.git(["update-ref", "-d", "refs/heads/\(target.branch)"], in: fixture.origin)
        try await WorktreeScanner.removeWorktree(item, moveToTrash: false, originDeletionTarget: target).get()
        #expect(!fixture.worktreeExists)
        #expect(try await fixture.hasBranch(fixture.localBranch, in: fixture.repo))
    }

    @Test("The lease rejects a remote update made after the final check")
    func updateDuringPush() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        let (item, target) = try await fixture.scan()
        try await fixture.git(["commit", "--allow-empty", "-m", "Teammate update"], in: fixture.repo)
        let newTip = try await fixture.git(["rev-parse", "HEAD"], in: fixture.repo)
        try await fixture.git(["push", "origin", "HEAD:refs/heads/test/other-work"], in: fixture.repo)

        // The receive hook changes the ref after ls-remote, before receive-pack updates the ref.
        let hook = URL(fileURLWithPath: fixture.origin).appendingPathComponent("hooks/pre-receive")
        try """
        #!/bin/sh
        unset GIT_QUARANTINE_PATH
        git update-ref refs/heads/\(target.branch) \(newTip) \(target.expectedOID)
        """.write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        try await fixture.git(["config", "core.hooksPath", hook.deletingLastPathComponent().path], in: fixture.origin)

        let result = await WorktreeScanner.removeWorktree(item, moveToTrash: false, originDeletionTarget: target)
        #expect(throws: (any Error).self) { try result.get() }
        #expect(fixture.worktreeExists)
        #expect(try await fixture.git(["rev-parse", "refs/heads/\(target.branch)"], in: fixture.origin) == newTip)
    }

    @Test("Deleting both branches preserves a requested backup of uncommitted work")
    func keepBackupCommit() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        let file = URL(fileURLWithPath: fixture.worktree).appendingPathComponent("notes.txt")
        try "work in progress".write(to: file, atomically: true, encoding: .utf8)
        let (item, target) = try await fixture.scan(untrackedCount: 1)
        try await WorktreeScanner.removeWorktree(
            item, backupCommitFirst: true, moveToTrash: false, deleteLocalBranch: true,
            originDeletionTarget: target).get()
        let backup = try await fixture.git(["for-each-ref", "--format=%(refname)", "refs/heads/backup/"], in: fixture.repo)
        #expect(try await fixture.git(["show", "\(backup):notes.txt"], in: fixture.repo) == "work in progress")
        #expect(try await !fixture.hasBranch(fixture.localBranch, in: fixture.repo))
    }

    @Test("A custom fetch mapping cannot be mistaken for an untracked branch's matching origin ref")
    func customFetchMapping() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        try await fixture.git(["branch", "--unset-upstream", fixture.localBranch], in: fixture.worktree)
        try await fixture.git(["config", "remote.origin.fetch", "+refs/heads/team/*:refs/remotes/origin/*"], in: fixture.repo)
        #expect(await WorktreeScanner.originDeletionTarget(for: fixture.localBranch, in: fixture.worktree) == nil)
    }

    @Test("The live origin default branch cannot be deleted, including nonstandard names")
    func defaultBranchChanged() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        let (item, target) = try await fixture.scan()
        try await fixture.git(["symbolic-ref", "HEAD", "refs/heads/\(target.branch)"], in: fixture.origin)
        try await fixture.git(["config", "receive.denyDeleteCurrent", "ignore"], in: fixture.origin)
        let result = await WorktreeScanner.removeWorktree(item, moveToTrash: false, originDeletionTarget: target)
        #expect(throws: (any Error).self) { try result.get() }
        #expect(fixture.worktreeExists)
        #expect(try await fixture.hasBranch(target.branch, in: fixture.origin))
    }

    @Test("An origin destination change invalidates the approved target")
    func changedPushDestination() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        let (item, target) = try await fixture.scan()
        let other = fixture.root.appendingPathComponent("other.git").path
        try await fixture.git(["clone", "--bare", fixture.origin, other], in: fixture.repo)
        try await fixture.git(["remote", "set-url", "--push", "origin", other], in: fixture.repo)
        let result = await WorktreeScanner.removeWorktree(item, moveToTrash: false, originDeletionTarget: target)
        #expect(throws: (any Error).self) { try result.get() }
        #expect(fixture.worktreeExists)
        #expect(try await fixture.hasBranch(target.branch, in: fixture.origin))
        #expect(try await fixture.hasBranch(target.branch, in: other))
    }

    @Test("A process that entered the worktree after the scan blocks remote deletion")
    func worktreeBecameActive() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        let (item, target) = try await fixture.scan()
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sleep")
        task.arguments = ["60"]
        task.currentDirectoryURL = URL(fileURLWithPath: fixture.worktree)
        try task.run()
        defer { if task.isRunning { task.terminate() } }
        let result = await WorktreeScanner.removeWorktree(
            item, moveToTrash: false, originDeletionTarget: target, force: true)
        #expect(throws: (any Error).self) { try result.get() }
        #expect(fixture.worktreeExists)
        #expect(try await fixture.hasBranch(target.branch, in: fixture.origin))
    }

    @Test("A same-name origin branch is eligible without an upstream, but another remote's upstream is not")
    func upstreamMapping() async throws {
        let fixture = try await Fixture()
        defer { fixture.cleanUp() }
        try await fixture.git(["branch", "--unset-upstream", fixture.localBranch], in: fixture.worktree)
        let (_, target) = try await fixture.scan()
        #expect(target.branch == fixture.localBranch)
        try await fixture.git(["remote", "add", "other", fixture.origin], in: fixture.repo)
        try await fixture.git(["fetch", "other"], in: fixture.repo)
        try await fixture.git(["branch", "-u", "other/\(fixture.localBranch)", fixture.localBranch], in: fixture.repo)
        #expect(await WorktreeScanner.originDeletionTarget(for: fixture.localBranch, in: fixture.worktree) == nil)
    }
}

private struct Fixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("wtc-origin-\(UUID().uuidString)")
    let localBranch = "feature/local"
    let publishedBranch = "team/published"
    var repo: String { root.appendingPathComponent("repo").path }
    var origin: String { root.appendingPathComponent("origin.git").path }
    var worktree: String { root.appendingPathComponent("feature").path }
    var worktreeExists: Bool { FileManager.default.fileExists(atPath: worktree) }

    init() async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        do {
            try await git(["init", "--bare", "-b", "trunk", origin], in: root.path)
            try await git(["init", "-b", "trunk", repo], in: root.path)
            try await git(["config", "user.email", "fixture@example.invalid"], in: repo)
            try await git(["config", "user.name", "Test"], in: repo)
            try await git(["config", "commit.gpgsign", "false"], in: repo)
            try await git(["config", "core.hooksPath", "/dev/null"], in: repo)
            try await git(["commit", "--allow-empty", "-m", "Initial"], in: repo)
            try await git(["remote", "add", "origin", origin], in: repo)
            try await git(["push", "-u", "origin", "trunk"], in: repo)
            try await git(["remote", "set-head", "origin", "trunk"], in: repo)
            try await git(["worktree", "add", "-b", localBranch, worktree], in: repo)
            try await git(["push", "origin", "HEAD:refs/heads/\(localBranch)"], in: worktree)
            try await git(["push", "-u", "origin", "HEAD:refs/heads/\(publishedBranch)"], in: worktree)
        } catch {
            cleanUp()
            throw error
        }
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    func git(_ arguments: [String], in directory: String) async throws -> String {
        let result = await ShellRunner.git(arguments, in: directory)
        guard result.succeeded else {
            throw NSError(domain: "GitFixture", code: Int(result.exitCode),
                          userInfo: [NSLocalizedDescriptionKey: "git \(arguments): \(result.stderr)"])
        }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func hasBranch(_ branch: String, in directory: String) async throws -> Bool {
        let refs = try await git(["for-each-ref", "--format=%(refname)", "refs/heads/\(branch)"], in: directory)
        return refs.split(separator: "\n").contains("refs/heads/\(branch)")
    }

    func scan(untrackedCount: Int = 0) async throws -> (WorktreeItem, OriginDeletionTarget) {
        let target = try #require(await WorktreeScanner.originDeletionTarget(for: localBranch, in: worktree))
        let head = try await git(["rev-parse", "HEAD"], in: worktree)
        var item = WorktreeItem(
            id: worktree, path: worktree, kind: .linkedWorktree, mainRepoPath: repo, mainRepoName: "repo",
            branch: localBranch, headCommit: head, headSubject: "", lastModified: nil, isDetached: false,
            isLocked: false, directoryExists: true, source: .local, remoteName: "origin", modifiedCount: 0,
            untrackedCount: untrackedCount, aheadCount: 0, hasUpstream: true, isMergedToDefault: true,
            isSquashMerged: false, prInfo: nil, changedFiles: [], unpushedCommits: [], activeProcesses: [],
            preciousIgnoredFiles: [], orphanFileCount: 0, featureSummary: nil, diskSizeBytes: nil)
        item.originDeletionTarget = target
        return (item, target)
    }
}
