import XCTest
@testable import HorseWhisprer

extension XCTestCase {
    func makeTestSettings() -> AppSettings {
        let suite = "HorseWhisprerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        return AppSettings(defaults: defaults)
    }
}

actor TestGate {
    private var isOpen = false
    private var entered = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        entered = true
        entryWaiters.forEach { $0.resume() }
        entryWaiters.removeAll()
        if !isOpen { await withCheckedContinuation { waiters.append($0) } }
    }

    func waitUntilEntered() async {
        if !entered { await withCheckedContinuation { entryWaiters.append($0) } }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

extension ASRModelDescriptor {
    /// Download tests push fixture bytes through the real validator, so they
    /// need a catalog model without its pinned size and digest.
    var unpinned: ASRModelDescriptor {
        ASRModelDescriptor(
            id: id,
            displayName: displayName,
            fileName: fileName,
            downloadURL: downloadURL,
            languages: languages,
            diskSizeDescription: diskSizeDescription,
            notes: notes,
            isRecommended: isRecommended,
            expectedSHA256: nil,
            expectedFileSizeBytes: nil,
            engineKind: engineKind
        )
    }
}
