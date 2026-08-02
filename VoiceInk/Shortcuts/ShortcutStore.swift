import Foundation

enum ShortcutStore {
    static let shortcutDidChange = Notification.Name("ShortcutStoreShortcutDidChange")

    enum PersistenceState: Equatable {
        case unset
        case cleared
        case stored(Shortcut)
    }

    static func rawShortcut(for action: ShortcutAction) -> Shortcut? {
        shortcutData(for: action)
            .flatMap { try? JSONDecoder().decode(Shortcut.self, from: $0) }
    }

    static func shortcut(for action: ShortcutAction) -> Shortcut? {
        guard action.isStored else {
            return nil
        }

        guard !isShortcutCleared(for: action) else {
            return nil
        }

        return rawShortcut(for: action)
    }

    static func setShortcut(_ shortcut: Shortcut?, for action: ShortcutAction) {
        guard action.isStored else {
            return
        }

        if let shortcut, ShortcutValidator.validationError(for: shortcut, action: action) != nil {
            return
        }

        if let shortcut {
            persistStoredShortcut(shortcut, for: action)
        } else {
            persistClearedShortcut(for: action)
        }

        postShortcutDidChange(for: action)
    }

    static func persistenceState(for action: ShortcutAction) -> PersistenceState {
        guard action.isStored else {
            return .unset
        }

        // The cleared tombstone is the runtime source of truth if storage is ever corrupt enough
        // to contain both values, matching shortcut(for:) instead of changing behavior on restore.
        if isShortcutCleared(for: action) {
            return .cleared
        }

        return rawShortcut(for: action).map(PersistenceState.stored) ?? .unset
    }

    static func restorePersistenceState(_ state: PersistenceState, for action: ShortcutAction) {
        switch state {
        case .unset:
            removeShortcutStorage(for: action)
        case .cleared:
            setShortcut(nil, for: action)
        case .stored(let shortcut):
            guard action.isStored else { return }
            // This value was already accepted and persisted before capture began. Re-validating it
            // against mutable shortcuts can reject restoration and recreate the data-loss bug.
            persistStoredShortcut(shortcut, for: action)
            postShortcutDidChange(for: action)
        }
    }

    static func seedShortcut(
        _ shortcut: Shortcut,
        for action: ShortcutAction,
        replacingCleared: Bool = false
    ) {
        guard action.isStored,
              rawShortcut(for: action) == nil,
              replacingCleared || !isShortcutCleared(for: action) else {
            return
        }

        setShortcut(shortcut, for: action)
    }

    static func removeShortcutStorage(for action: ShortcutAction) {
        guard action.isStored else {
            return
        }

        UserDefaults.standard.removeObject(forKey: action.userDefaultsKey)
        UserDefaults.standard.removeObject(forKey: clearedUserDefaultsKey(for: action))
        ShortcutMigration.removeLegacyCustomRecordingShortcut(for: action)
        ShortcutMigration.removeLegacyKeyboardShortcut(for: action)
        postShortcutDidChange(for: action)
    }

    static func shortcuts(for actions: [ShortcutAction]) -> [ShortcutAction: Shortcut] {
        actions.reduce(into: [:]) { result, action in
            if let shortcut = shortcut(for: action) {
                result[action] = shortcut
            }
        }
    }

    private static func shortcutData(for action: ShortcutAction) -> Data? {
        UserDefaults.standard.data(forKey: action.userDefaultsKey)
    }

    static func isShortcutCleared(for action: ShortcutAction) -> Bool {
        UserDefaults.standard.bool(forKey: clearedUserDefaultsKey(for: action))
    }

    private static func clearedUserDefaultsKey(for action: ShortcutAction) -> String {
        "\(action.userDefaultsKey)_cleared"
    }

    private static func persistStoredShortcut(_ shortcut: Shortcut, for action: ShortcutAction) {
        guard let data = try? JSONEncoder().encode(shortcut) else {
            assertionFailure("Failed to encode stored shortcut")
            return
        }

        UserDefaults.standard.set(data, forKey: action.userDefaultsKey)
        UserDefaults.standard.removeObject(forKey: clearedUserDefaultsKey(for: action))
        ShortcutMigration.removeLegacyCustomRecordingShortcut(for: action)
        ShortcutMigration.removeLegacyKeyboardShortcut(for: action)
    }

    private static func persistClearedShortcut(for action: ShortcutAction) {
        UserDefaults.standard.removeObject(forKey: action.userDefaultsKey)
        UserDefaults.standard.set(true, forKey: clearedUserDefaultsKey(for: action))
        ShortcutMigration.removeLegacyCustomRecordingShortcut(for: action)
        ShortcutMigration.removeLegacyKeyboardShortcut(for: action)
    }

    private static func postShortcutDidChange(for action: ShortcutAction) {
        NotificationCenter.default.post(
            name: shortcutDidChange,
            object: action
        )
    }
}
