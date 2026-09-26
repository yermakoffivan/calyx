// ConfigReloadCoordinator.swift
// Calyx
//
// Debounced config reload coordinator that replaces the direct
// GhosttyAppController.reloadConfig implementation.

import Foundation

// MARK: - ConfigReloadDeps

/// Protocol abstracting the side-effects of config reload.
/// Production code injects a bridge to GhosttyAppController;
/// tests inject a lightweight mock.
@MainActor
protocol ConfigReloadDeps: AnyObject {
    /// Attempt to load a fresh config from disk.
    /// Returns a generation ID on success, nil on failure.
    func loadConfigFromDisk() -> Int?

    /// Propagate the current config to all open windows.
    func propagateConfigToAllWindows()
}

// MARK: - ConfigReloadCoordinator

@MainActor
final class ConfigReloadCoordinator {
    /// Monotonically increasing config version. 0 = no successful load yet.
    private(set) var configGeneration: Int = 0

    private weak let deps: ConfigReloadDeps?
    private var reloadDebounceWork: DispatchWorkItem?

    init(deps: ConfigReloadDeps) {
        self.deps = deps
    }

    /// Trigger a debounced config reload.
    /// - Parameter soft: If true, reload from disk only. If false, also propagate to windows.
    func reloadConfig(soft: Bool) {
        reloadDebounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let deps = self.deps else { return }

                guard let newGeneration = deps.loadConfigFromDisk() else {
                    // Keep last-known-good config on failure
                    return
                }

                self.configGeneration = newGeneration

                if !soft {
                    deps.propagateConfigToAllWindows()
                }
            }
        }
        reloadDebounceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }
}
