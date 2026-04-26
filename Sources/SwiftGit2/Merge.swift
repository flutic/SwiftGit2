//
//  Merge.swift
//  SwiftGit2 — mantua additions
//
//  Wraps `git_merge` for the common single-parent merge case (e.g. merging
//  origin/main into the current branch). Surfaces the resulting index
//  conflicts so the application can present a 3-way merge UI without dropping
//  to libgit2 C calls.
//

import Foundation
import Clibgit2

/// One unresolved conflict produced by a merge.
public struct MergeConflict {
    public let path: String
    /// Common ancestor blob OID, if any (nil for add/add conflicts).
    public let ancestorOID: OID?
    /// Our (HEAD-side) blob OID, if any (nil if we deleted).
    public let ourOID: OID?
    /// Their (incoming) blob OID, if any (nil if they deleted).
    public let theirOID: OID?
}

/// Outcome of a merge analysis + merge attempt.
public enum MergeAnalysis {
    /// Local HEAD already contains the target — nothing to do.
    case upToDate
    /// Target descends from HEAD — caller should fast-forward HEAD.
    case fastForward(targetOID: OID)
    /// Real merge happened. The repository's index reflects the merge state.
    /// If `conflicts` is non-empty the caller must resolve them and create a
    /// merge commit; otherwise the caller can write the tree and commit.
    case merged(conflicts: [MergeConflict])
}

extension Repository {

    /// Analyse + merge the given commit OID into the current HEAD branch.
    ///
    /// On `.merged(conflicts: [])` the index is clean and the caller should
    /// write a tree, create a merge commit with `[HEAD, theirs]` parents, and
    /// call `cleanupMerge()`. On `.merged(conflicts: non-empty)` the caller
    /// resolves each path, calls `removeConflict(path:)`, re-adds the resolved
    /// blob, then creates the merge commit.
    public func merge(theirs: OID) -> Result<MergeAnalysis, NSError> {
        // 1. Look up the their-side commit object via annotated commit
        //    (libgit2's merge API operates on annotated commits).
        var annotated: OpaquePointer? = nil
        var oid = theirs.oid
        let lookupResult = git_annotated_commit_lookup(&annotated, self.pointer, &oid)
        guard lookupResult == GIT_OK.rawValue, let annotatedPtr = annotated else {
            return .failure(NSError(gitError: lookupResult, pointOfFailure: "git_annotated_commit_lookup"))
        }
        defer { git_annotated_commit_free(annotatedPtr) }

        // 2. Analyse merge + run merge if needed. The single annotated commit
        //    pointer needs to be passed as `git_annotated_commit **`; we hold
        //    it in a mutable variable and bridge via `withUnsafeMutablePointer`.
        var analysis = git_merge_analysis_t(rawValue: 0)
        var preference = git_merge_preference_t(rawValue: 0)
        var headPtr: OpaquePointer? = annotatedPtr

        let analyseResult: Int32 = withUnsafeMutablePointer(to: &headPtr) { headRef -> Int32 in
            return git_merge_analysis(&analysis, &preference, self.pointer, headRef, 1)
        }
        guard analyseResult == GIT_OK.rawValue else {
            return .failure(NSError(gitError: analyseResult, pointOfFailure: "git_merge_analysis"))
        }

        if analysis.rawValue & GIT_MERGE_ANALYSIS_UP_TO_DATE.rawValue != 0 {
            return .success(.upToDate)
        }
        if analysis.rawValue & GIT_MERGE_ANALYSIS_FASTFORWARD.rawValue != 0 {
            return .success(.fastForward(targetOID: theirs))
        }

        // 3. Real merge. Initialise default options and run.
        var mergeOpts = git_merge_options()
        git_merge_options_init(&mergeOpts, UInt32(GIT_MERGE_OPTIONS_VERSION))
        var checkoutOpts = git_checkout_options()
        git_checkout_options_init(&checkoutOpts, UInt32(GIT_CHECKOUT_OPTIONS_VERSION))
        checkoutOpts.checkout_strategy =
            GIT_CHECKOUT_SAFE.rawValue | GIT_CHECKOUT_ALLOW_CONFLICTS.rawValue

        let mergeResult: Int32 = withUnsafeMutablePointer(to: &headPtr) { headRef -> Int32 in
            return git_merge(self.pointer, headRef, 1, &mergeOpts, &checkoutOpts)
        }
        guard mergeResult == GIT_OK.rawValue else {
            return .failure(NSError(gitError: mergeResult, pointOfFailure: "git_merge"))
        }

        // 4. Walk the index for conflicts.
        var indexPtr: OpaquePointer? = nil
        let idxResult = git_repository_index(&indexPtr, self.pointer)
        guard idxResult == GIT_OK.rawValue, let index = indexPtr else {
            return .failure(NSError(gitError: idxResult, pointOfFailure: "git_repository_index"))
        }
        defer { git_index_free(index) }

        var conflicts: [MergeConflict] = []
        if git_index_has_conflicts(index) != 0 {
            var iter: OpaquePointer? = nil
            let iterResult = git_index_conflict_iterator_new(&iter, index)
            guard iterResult == GIT_OK.rawValue, let it = iter else {
                return .failure(NSError(gitError: iterResult, pointOfFailure: "git_index_conflict_iterator_new"))
            }
            defer { git_index_conflict_iterator_free(it) }

            while true {
                var ancestor: UnsafePointer<git_index_entry>? = nil
                var ours: UnsafePointer<git_index_entry>? = nil
                var theirs: UnsafePointer<git_index_entry>? = nil
                let next = git_index_conflict_next(&ancestor, &ours, &theirs, it)
                if next == GIT_ITEROVER.rawValue { break }
                guard next == GIT_OK.rawValue else {
                    return .failure(NSError(gitError: next, pointOfFailure: "git_index_conflict_next"))
                }
                // path is the same on all three sides; pick whichever is non-nil.
                let path: String? = entryPath(ancestor) ?? entryPath(ours) ?? entryPath(theirs)
                guard let p = path else { continue }
                conflicts.append(
                    MergeConflict(
                        path: p,
                        ancestorOID: ancestor.flatMap { OID($0.pointee.id) },
                        ourOID:      ours.flatMap     { OID($0.pointee.id) },
                        theirOID:    theirs.flatMap   { OID($0.pointee.id) }
                    )
                )
            }
        }

        return .success(.merged(conflicts: conflicts))
    }

    /// Remove a conflict entry for `path` from the index. Caller should call
    /// after writing the resolved blob to disk and `add(_ paths:)`-ing it.
    public func removeConflict(path: String) -> Result<(), NSError> {
        return unsafeIndex().flatMap { index in
            defer { git_index_free(index) }
            let result = path.withCString { git_index_conflict_remove(index, $0) }
            guard result == GIT_OK.rawValue else {
                return .failure(NSError(gitError: result, pointOfFailure: "git_index_conflict_remove"))
            }
            let writeResult = git_index_write(index)
            guard writeResult == GIT_OK.rawValue else {
                return .failure(NSError(gitError: writeResult, pointOfFailure: "git_index_write"))
            }
            return .success(())
        }
    }

    /// Reset the merge state (clears MERGE_HEAD, MERGE_MSG, etc.). Call after
    /// a successful merge commit, or to abandon a merge in progress.
    public func cleanupMerge() -> Result<(), NSError> {
        let result = git_repository_state_cleanup(self.pointer)
        guard result == GIT_OK.rawValue else {
            return .failure(NSError(gitError: result, pointOfFailure: "git_repository_state_cleanup"))
        }
        return .success(())
    }

    /// Read the raw bytes of a blob by OID.
    public func blob(_ oid: OID) -> Result<Data, NSError> {
        var blob: OpaquePointer? = nil
        var oidCopy = oid.oid
        let result = git_blob_lookup(&blob, self.pointer, &oidCopy)
        guard result == GIT_OK.rawValue, let b = blob else {
            return .failure(NSError(gitError: result, pointOfFailure: "git_blob_lookup"))
        }
        defer { git_blob_free(b) }
        let size = Int(git_blob_rawsize(b))
        guard let raw = git_blob_rawcontent(b) else {
            return .success(Data())
        }
        let data = Data(bytes: raw, count: size)
        return .success(data)
    }

    private func entryPath(_ entry: UnsafePointer<git_index_entry>?) -> String? {
        guard let e = entry else { return nil }
        return String(validatingUTF8: e.pointee.path)
    }
}
