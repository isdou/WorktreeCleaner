import CryptoKit
import Foundation

extension WorktreeScanner {
    /// Captures the last locally observed origin tip. Scanning never contacts the remote for this option.
    public static func originDeletionTarget(for localBranch: String, in worktreePath: String) async -> OriginDeletionTarget? {
        guard let origin = await originBranch(for: localBranch, in: worktreePath) else { return nil }
        let tip = await ShellRunner.git(["for-each-ref", "--format=%(refname)%00%(symref)%00%(objectname)", origin.trackingRef], in: worktreePath)
        guard tip.succeeded,
              let fields = tip.stdout.split(separator: "\n").map({ $0.components(separatedBy: "\0") }).first(where: { $0.first == origin.trackingRef }),
              fields.count == 3, fields[1].isEmpty else { return nil }
        let oid = fields[2]
        var target = OriginDeletionTarget(branch: origin.branch, expectedOID: oid, endpointID: origin.endpointID)
        target.trackingRef = origin.trackingRef
        return target
    }

    private struct OriginBranch {
        let branch: String
        let trackingRef: String
        let endpoint: String

        var endpointID: String {
            SHA256.hash(data: Data(endpoint.utf8)).map { String(format: "%02x", $0) }.joined()
        }
    }

    private static func originBranch(for localBranch: String, in worktreePath: String) async -> OriginBranch? {
        guard !localBranch.isEmpty, !WorktreeItem.protectedBranchNames.contains(localBranch.lowercased()) else { return nil }
        let localRef = "refs/heads/\(localBranch)"
        let format = "%(refname)%00%(upstream)%00%(upstream:remotename)%00%(upstream:remoteref)"
        async let upstreamResult = ShellRunner.git(["for-each-ref", "--format=\(format)", localRef], in: worktreePath)
        async let endpointResult = ShellRunner.git(["remote", "get-url", "--push", "--all", "origin"], in: worktreePath)
        async let defaultResult = ShellRunner.git(["symbolic-ref", "--quiet", "refs/remotes/origin/HEAD"], in: worktreePath)
        let (upstream, endpoints, defaultRef) = await (upstreamResult, endpointResult, defaultResult)
        let fields = upstream.stdout.split(separator: "\n").map { $0.components(separatedBy: "\0") }
            .first { $0.first == localRef }
        let urls = endpoints.stdout.split(separator: "\n", omittingEmptySubsequences: false).dropLast()
        guard upstream.succeeded, let fields, fields.count == 4, endpoints.succeeded,
              urls.count == 1, let url = urls.first, !url.isEmpty, !url.hasPrefix("-") else { return nil }

        let branch: String
        let trackingRef: String
        if fields[2] == "origin", fields[3].hasPrefix("refs/heads/"), !fields[1].isEmpty {
            branch = String(fields[3].dropFirst("refs/heads/".count))
            trackingRef = fields[1]
        } else {
            guard fields.dropFirst().allSatisfy(\.isEmpty) else { return nil }
            // An upstream outside the fetch refspec may have no %(upstream). Do not guess its name.
            let configured = await ShellRunner.git(["config", "--get-all", "branch.\(localBranch).merge"], in: worktreePath)
            guard configured.exitCode == 1 else { return nil }
            branch = localBranch
            trackingRef = "refs/remotes/origin/\(localBranch)"
            // A name under refs/remotes/origin/ is only evidence for the same branch when the
            // fetch mapping proves that relationship. Skip excluded, overlapping or custom maps.
            let fetch = await ShellRunner.git(["config", "--get-all", "remote.origin.fetch"], in: worktreePath)
            let specs = fetch.stdout.split(separator: "\n")
            guard fetch.succeeded, specs.count == 1, let spec = specs.first else { return nil }
            let mapping = spec.hasPrefix("+") ? String(spec.dropFirst()) : String(spec)
            guard mapping == "refs/heads/*:refs/remotes/origin/*" || mapping == "\(localRef):\(trackingRef)" else { return nil }
        }
        let cachedDefault = defaultRef.stdout.trimmingCharacters(in: .newlines)
        guard branch != "HEAD", !WorktreeItem.protectedBranchNames.contains(branch.lowercased()),
              cachedDefault != trackingRef, cachedDefault != "refs/remotes/origin/\(localBranch)" else { return nil }
        // An explicit URL pins both operations to the same destination. Resolve relative local paths
        // to avoid reinterpreting one as a configured remote name when passing it to git push.
        let endpoint = effectiveEndpoint(String(url), in: worktreePath)
        return OriginBranch(branch: branch, trackingRef: trackingRef, endpoint: endpoint)
    }

    private static func effectiveEndpoint(_ url: String, in worktreePath: String) -> String {
        if url.contains(":") || url.hasPrefix("/") { return url }
        return URL(fileURLWithPath: worktreePath, isDirectory: true)
            .appendingPathComponent(url).standardizedFileURL.path
    }

    private static func clearConfirmedTrackingRef(_ approved: OriginDeletionTarget, origin: OriginBranch, in path: String) async {
        // A distinct fetch repository may still contain the branch, even after deletion at the push URL.
        let fetch = await ShellRunner.git(["remote", "get-url", "origin"], in: path)
        let fetchURL = fetch.stdout.trimmingCharacters(in: .newlines)
        guard fetch.succeeded, !fetchURL.isEmpty, effectiveEndpoint(fetchURL, in: path) == origin.endpoint,
              origin.trackingRef == "refs/remotes/origin/\(origin.branch)", origin.branch != "HEAD" else { return }
        let symbolic = await ShellRunner.git(["symbolic-ref", "--quiet", origin.trackingRef], in: path)
        guard symbolic.exitCode == 1 else { return }
        // Do not follow symbolic refs or overwrite a newer fetch. A missing or changed ref needs no cleanup.
        _ = await ShellRunner.git(["update-ref", "--no-deref", "-d", origin.trackingRef, approved.expectedOID], in: path)
    }

    /// Returns false when the approved branch is already gone. A failure leaves the worktree untouched.
    static func deleteOriginBranch(_ approved: OriginDeletionTarget, for item: WorktreeItem) async throws -> Bool {
        guard item.originDeletionTarget == approved, let origin = await originBranch(for: item.branch, in: item.path),
              origin.branch == approved.branch, origin.endpointID == approved.endpointID, origin.trackingRef == approved.trackingRef else {
            throw CleanerError(message: "The origin destination or tracked branch changed. Refresh and review it again.")
        }
        let remoteRef = "refs/heads/\(origin.branch)"
        let advertised = await ShellRunner.git(["ls-remote", "--symref", "--", origin.endpoint, "HEAD", remoteRef], in: item.path, timeout: 30)
        guard advertised.succeeded else {
            throw CleanerError(message: "Could not verify the origin branch and default branch. The worktree was kept.")
        }
        let refs = advertised.stdout.split(separator: "\n").map { $0.split(separator: "\t", maxSplits: 1) }
        let head = refs.first(where: { $0.count == 2 && $0[1] == "HEAD" && $0[0].hasPrefix("ref: refs/heads/") })?.first
        guard head != "ref: \(remoteRef)", head != "ref: refs/heads/\(item.branch)" else {
            throw CleanerError(message: "The origin default branch is protected. The worktree was kept.")
        }
        guard let tip = refs.first(where: { $0.count == 2 && $0[1] == remoteRef })?.first else {
            await clearConfirmedTrackingRef(approved, origin: origin, in: item.path)
            return false
        }
        guard head != nil else {
            throw CleanerError(message: "Could not verify the origin default branch. The worktree was kept.")
        }
        guard tip == approved.expectedOID else {
            throw CleanerError(message: "origin/\(origin.branch) changed since the scan. The worktree was kept. Run git fetch origin, review the new commits, then refresh.")
        }
        let result = await ShellRunner.git([
            "push", "--porcelain", "--no-follow-tags", "--recurse-submodules=no",
            "--force-with-lease=\(remoteRef):\(approved.expectedOID)", "--", origin.endpoint, ":\(remoteRef)"
        ], in: item.path, timeout: 45)
        guard result.succeeded else {
            throw CleanerError(message: "Deletion of origin/\(origin.branch) was not confirmed. The worktree was kept. Check your access and branch protection, run git fetch origin, then review the branch and refresh.")
        }
        await clearConfirmedTrackingRef(approved, origin: origin, in: item.path)
        return true
    }
}
