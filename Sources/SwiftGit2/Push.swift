//
//  Push.swift
//  SwiftGit2 — mantua additions
//
//  Adds push-with-credentials. Reuses the credential callback already used
//  by clone/fetch (see `credentialsCallback` in Credentials.swift).
//

import Foundation
import Clibgit2

/// Box passed as the push callback payload. Carries the credentials pointer
/// libgit2's existing `credentialsCallback` expects, plus a slot for the first
/// server-side ref rejection so the caller can surface it.
final class PushCallbackPayload {
    let credentialsPointer: UnsafeMutableRawPointer
    var rejection: (refName: String, message: String)?
    init(credentialsPointer: UnsafeMutableRawPointer) {
        self.credentialsPointer = credentialsPointer
    }
}

private let pushUpdateReferenceCallback: git_push_update_reference_cb = { refname, status, payload in
    guard let payload = payload, let status = status else { return 0 }
    let box = Unmanaged<PushCallbackPayload>.fromOpaque(payload).takeUnretainedValue()
    let name = refname.flatMap { String(cString: $0) } ?? "?"
    let msg = String(cString: status)
    if box.rejection == nil {
        box.rejection = (refName: name, message: msg)
    }
    return 0
}

private func pushOptions(payload: PushCallbackPayload) -> git_push_options {
    var options = git_push_options()
    git_push_options_init(&options, UInt32(GIT_PUSH_OPTIONS_VERSION))
    // libgit2's credentialsCallback expects the Credentials pointer directly
    // as the payload. We pass our box and forward the cred pointer via a
    // shim so existing credentialsCallback semantics keep working.
    options.callbacks.payload = Unmanaged.passUnretained(payload).toOpaque()
    options.callbacks.credentials = pushCredentialsShim
    options.callbacks.push_update_reference = pushUpdateReferenceCallback
    return options
}

/// Shim so the existing credential machinery stays intact: unbox the payload,
/// hand the credential pointer back to the original `credentialsCallback`.
private let pushCredentialsShim: git_credential_acquire_cb = { cred, url, username, allowed, payload in
    guard let payload = payload else { return -1 }
    let box = Unmanaged<PushCallbackPayload>.fromOpaque(payload).takeUnretainedValue()
    return credentialsCallback(cred: cred, url: url, username: username, allowed, payload: box.credentialsPointer)
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

        let payload = PushCallbackPayload(credentialsPointer: credentials.toPointer())
        var opts = pushOptions(payload: payload)
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
        if let rejection = payload.rejection {
            // Server accepted the push protocol but rejected the ref update
            // (branch protection, hook, ruleset, etc). Surface it.
            let err = NSError(
                domain: libGit2ErrorDomain,
                code: -1,
                userInfo: [NSLocalizedDescriptionKey:
                    "remote rejected \(rejection.refName): \(rejection.message)"]
            )
            return .failure(err)
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
