//
//  BranchAdvance.swift
//  SwiftGit2 — mantua additions
//
//  Force-advance a local branch reference to a given OID. Needed for
//  fast-forward merges where the caller wants HEAD to stay attached to the
//  branch (the stock `checkout(_:OID,strategy:)` detaches HEAD via
//  git_repository_set_head_detached).
//

import Foundation
import Clibgit2

extension Repository {
    /// True when HEAD is detached (i.e. not pointing at a branch).
    public func isHEADDetached() -> Bool {
        return git_repository_head_detached(self.pointer) == 1
    }

    /// Force-create or advance `refs/heads/<branchName>` to `oid`. Used to
    /// reattach HEAD to a branch after a fast-forward.
    ///
    /// - Returns: success or a libgit2 NSError on failure.
    public func setBranchTarget(branchName: String, oid: OID) -> Result<(), NSError> {
        let longName = branchName.hasPrefix("refs/heads/")
            ? branchName
            : "refs/heads/\(branchName)"
        var oidCopy = oid.oid
        var newRef: OpaquePointer? = nil
        let result = longName.withCString { name in
            git_reference_create(&newRef, self.pointer, name, &oidCopy, /*force*/ 1, "fast-forward")
        }
        if let p = newRef { git_reference_free(p) }
        guard result == GIT_OK.rawValue else {
            return .failure(NSError(gitError: result, pointOfFailure: "git_reference_create"))
        }
        return .success(())
    }
}
