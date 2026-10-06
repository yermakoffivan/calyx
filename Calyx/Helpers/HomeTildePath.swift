// HomeTildePath.swift
// Calyx
//
// Writes a path with the home directory as "~", the way zsh's `%~`
// prompt and NSString.abbreviatingWithTildeInPath do. Shared by every
// place that shows a full path in short form (session tab titles, the
// Usage window's project picker), so they cannot disagree.

import Foundation

enum HomeTildePath {
    /// `path` with `home` written "~". Home is replaced only when it is a
    /// whole path-component prefix: `home` itself becomes "~" and
    /// `home/…` becomes "~/…", but a sibling that merely shares home's
    /// spelling (e.g. "/Users/me2" for home "/Users/me") is returned
    /// unchanged, as is every path outside home.
    static func abbreviate(_ path: String, home: String) -> String {
        if path == home { return "~" }
        if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}
