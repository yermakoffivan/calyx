// CorruptFileSuffix.swift
// Calyx
//
// The one definition of the suffix given to a file that is moved aside
// because it cannot be read: `<name>.corrupt-<suffix>`. Shared by
// MCPServerRegistry (an undecodable servers document) and UsageStore (an
// unusable usage database) so both leave files named the same way.

import Foundation

enum CorruptFileSuffix {
    /// `<unix seconds>-<8 hex digits>`: the time orders the files, and the
    /// random part keeps two move-asides within one second from colliding.
    /// Not isolated to any actor, so it is callable from the main actor
    /// and from a store actor alike.
    static func make() -> String {
        let seconds = Int(Date().timeIntervalSince1970)
        return "\(seconds)-\(UUID().uuidString.prefix(8).lowercased())"
    }
}
