//
//  Push.swift
//  SwiftGit2 — mantua additions
//
//  Adds push-with-credentials. Reuses the credential callback already used
//  by clone/fetch (see `credentialsCallback` in Credentials.swift).
//

import Foundation
import Clibgit2

private func pushOptions(credentials: Credentials) -> git_push_options {
    var options = git_push_options()
    git_push_options_init(&options, UInt32(GIT_PUSH_OPTIONS_VERSION))
    options.callbacks.payload = credentials.toPointer()
    options.callbacks.credentials = credentialsCallback
    return options
}

extension Repository {
    /// Push one or more refspecs to the named remote.
    ///
    /// - Parameters:
    ///   - remote: The remote to push to (e.g. obtained via `remote(named: "origin")`).
    ///   - credentials: Credentials for the remote. Use `.plaintext(username:password:)`
    ///                  for HTTPS with a personal-access-token (username typically
    ///                  `"x-access-token"` for GitHub fine-grained PATs).
    ///   - refspecs: Push refspecs (e.g. `["refs/heads/main:refs/heads/main"]`).
    ///               Defaults to pushing the current HEAD branch to the same name on the remote.
    /// - Returns: success or a libgit2 NSError on auth/transport/non-fast-forward failure.
    public func push(
        _ remote: Remote,
        credentials: Credentials = .default,
        refspecs: [String]? = nil
    ) -> Result<(), NSError> {
        var remotePointer: OpaquePointer? = nil
        let lookupResult = remote.name.withCString { name in
            git_remote_lookup(&remotePointer, self.pointer, name)
        }
        guard lookupResult == GIT_OK.rawValue, let remotePtr = remotePointer else {
            return .failure(NSError(gitError: lookupResult, pointOfFailure: "git_remote_lookup"))
        }
        defer { git_remote_free(remotePtr) }

        var opts = pushOptions(credentials: credentials)
        let specs = refspecs ?? defaultPushRefspecs()

        // Build a git_strarray from the Swift refspecs.
        let cStrings = specs.map { strdup($0) }
        defer { for c in cStrings { free(c) } }
        let argv = UnsafeMutablePointer<UnsafeMutablePointer<Int8>?>.allocate(capacity: cStrings.count)
        defer { argv.deallocate() }
        for (i, c) in cStrings.enumerated() { argv[i] = c }

        var strArr = git_strarray()
        strArr.strings = argv
        strArr.count = cStrings.count

        let result = git_remote_push(remotePtr, &strArr, &opts)
        guard result == GIT_OK.rawValue else {
            return .failure(NSError(gitError: result, pointOfFailure: "git_remote_push"))
        }
        return .success(())
    }

    /// Default refspec when caller doesn't pass one: push the current branch to
    /// the same name on the remote.
    private func defaultPushRefspecs() -> [String] {
        switch HEAD() {
        case .success(let ref):
            // ref.longName for a branch is "refs/heads/<name>".
            let name = ref.longName
            if name.hasPrefix("refs/heads/") {
                return ["\(name):\(name)"]
            }
            return [name]
        case .failure:
            // Fall back to main; caller's responsibility if HEAD isn't a branch.
            return ["refs/heads/main:refs/heads/main"]
        }
    }
}
