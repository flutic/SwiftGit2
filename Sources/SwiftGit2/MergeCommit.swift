//
//  MergeCommit.swift
//  SwiftGit2 — mantua additions
//
//  A merge commit has two parents. `commit(message:signature:)` uses HEAD
//  alone and the index-to-tree step is internal, so a caller that has just
//  merged cleanly has no way to record it.

import Foundation
import Clibgit2

extension Repository {
    /// Write the current index out as a tree object.
    public func writeTreeFromIndex() -> Result<OID, NSError> {
        return unsafeIndex().flatMap { index in
            defer { git_index_free(index) }
            var treeOID = git_oid()
            let result = git_index_write_tree(&treeOID, index)
            guard result == GIT_OK.rawValue else {
                return .failure(NSError(gitError: result, pointOfFailure: "git_index_write_tree"))
            }
            return .success(OID(treeOID))
        }
    }

    /// Commit the merged index with both parents: HEAD and the commit merged in.
    public func commitMerge(theirs: OID, message: String,
                            signature: Signature) -> Result<Commit, NSError> {
        return writeTreeFromIndex().flatMap { treeOID in
            var headOID = git_oid()
            let headResult = git_reference_name_to_id(&headOID, self.pointer, "HEAD")
            guard headResult == GIT_OK.rawValue else {
                return .failure(NSError(gitError: headResult, pointOfFailure: "git_reference_name_to_id"))
            }
            return commit(OID(headOID)).flatMap { ours in
                commit(theirs).flatMap { theirCommit in
                    commit(tree: treeOID, parents: [ours, theirCommit],
                           message: message, signature: signature)
                }
            }
        }
    }
}
