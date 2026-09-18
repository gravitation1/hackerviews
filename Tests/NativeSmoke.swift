// A standalone native integration test, using an ephemeral browser and temporary
// records. It never logs in, votes, posts, or reads the user's browser session.
import AppKit
import WebKit
import Foundation

@main
struct NativeSmoke {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do { try await run(); print("PASS native integration suite"); exit(0) }
            catch { print("FAIL \(error)"); exit(1) }
        }
        app.run()
    }

    @MainActor static func run() async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent("HackerViews-smoke-\(UUID())")
        let store = RecordStore(directory: directory)
        let accountCache = directory.appendingPathComponent("account-cache")
        let service = HNService(directory: accountCache, profileLoader: { name in
            HNAccount(id: name, karma: 10000, created: 1_000_000)
        })
        var age = FilterRule(); age.conditions.youngerThanDays = 30; age.conditions.ageOlder = true
        let firstMatch = await service.accountMatch("fixture", rules: [age])
        guard firstMatch.effect == "blocked" else { throw Failure("Fixture profile fetch failed") }
        await service.flushProfiles()
        let persisted = accountCache.appendingPathComponent("HackerViews-accounts.json")
        var saved = try JSONDecoder().decode([String: CachedAccount].self, from: Data(contentsOf: persisted))
        saved["fixture"]?.fetched = Date().addingTimeInterval(-3600)
        try JSONEncoder().encode(saved).write(to: persisted, options: .atomic)
        let offline = HNService(directory: accountCache, profileLoader: { _ in throw URLError(.notConnectedToInternet) })
        guard await offline.accountMatch("fixture", rules: [age]).effect == "blocked" else { throw Failure("Persisted creation date was not reused offline") }
        var karmaRule = FilterRule(); karmaRule.conditions.karmaBelow = 100
        guard await offline.accountMatch("fixture", rules: [karmaRule]).effect == "unresolved" else { throw Failure("Stale karma was trusted offline") }
        print("PASS disk profile cache reuses creation dates and rejects stale karma offline")
        let recoveryDirectory = directory.appendingPathComponent("recovery")
        let recoveryStore = RecordStore(directory: recoveryDirectory)
        guard recoveryStore.save(username: "fixture_user", blocked: true, note: "Keep this reason", citations: []),
              { recoveryStore.flushJournal(); return recoveryStore.save(username: "fixture_user", blocked: false, note: "Newer reason", citations: []) }() else { throw Failure("Recovery fixture could not be saved") }
        recoveryStore.flushJournal()
        try Data("corrupt".utf8).write(to: recoveryDirectory.appendingPathComponent("records.json"))
        let corrupted = RecordStore(directory: recoveryDirectory)
        guard !corrupted.storageAvailable else { throw Failure("Corrupt journal did not pause browsing") }
        corrupted.restoreRecoveryCopy()
        guard corrupted.storageAvailable, corrupted.blocked.contains("fixture_user") else { throw Failure("Previous journal did not recover") }
        corrupted.importBackup(try JSONEncoder().encode(recoveryStore.archive))
        guard corrupted.blocked.isEmpty, corrupted.archive.revisions.count == 2 else { throw Failure("Backup merge lost revisions or block status") }
        print("PASS corrupt journal pauses browsing; recovery and import preserve history")
        let tab = BrowserTab(store: store, service: HNService(), persistentSession: false)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = tab.webView
        tab.webView.frame = NSRect(x: 0, y: 0, width: 1000, height: 800)
        if CommandLine.arguments.contains("--snapshots") { tab.webView.appearance = NSAppearance(named: .darkAqua) }
        tab.load(URL(string: "https://news.ycombinator.com/item?id=8863")!)
        try await wait(tab, for: .ready)
        print("PASS public HN page loads through the native isolated-world bridge")

        let controls = try await evaluate(tab, "return {votes:document.querySelectorAll('a[id^=up_]').length, records:document.querySelectorAll('.qhn-record').length}") as? [String: Int]
        guard (controls?["votes"] ?? 0) > 0, (controls?["records"] ?? 0) > 0 else { throw Failure("HN controls or annotation controls missing") }
        print("PASS voting links remain intact and record controls are installed")
        let headerVisible = try await evaluate(tab, "return document.querySelector('.pagetop').getBoundingClientRect().height > 0") as? Bool
        guard headerVisible == true else { throw Failure("HN section/account navigation is hidden") }
        print("PASS HN section/account navigation remains visible")
        if CommandLine.arguments.contains("--snapshots") { try await snapshot(tab, name: "thread") }

        var captured: RecordDraft?
        tab.onRecord = { captured = $0 }
        _ = try await evaluate(tab, "document.querySelector('.comtr .qhn-record').click()")
        try await Task.sleep(for: .milliseconds(200))
        guard let capture = captured, let citation = capture.citation, !citation.excerpt.isEmpty,
              citation.url.contains("item?id=") else { throw Failure("Citation capture did not reach the native editor") }
        print("PASS canonical citation and source snapshot reach native code")

        guard store.save(username: "dhouston", blocked: true, note: "Synthetic smoke-test record", citations: []) else { throw Failure("Local write failed") }
        try await wait(tab, for: .blocked)
        print("PASS changing the blocklist immediately holds a blocked submission")
        let reopened = RecordStore(directory: directory)
        guard reopened.blocked == ["dhouston"] else { throw Failure("Record did not persist") }
        guard store.save(username: "dhouston", blocked: false, note: "Synthetic unblock", citations: []) else { throw Failure("Unblock failed") }
        try await wait(tab, for: .ready)
        guard store.archive.history(for: "dhouston").count == 2 else { throw Failure("History lost") }
        print("PASS unblocking restores content and retains record history")

        guard store.save(username: "dhouston", blocked: false, note: "Preferred fixture", citations: [], preferred: true) else { throw Failure("Preference save failed") }
        try await wait(tab, for: .ready)
        let highlighted = try await evaluate(tab, "return document.querySelector('.fatitem .qhn-preferred') !== null") as? Bool
        guard highlighted == true else { throw Failure("Preferred submission was not highlighted") }
        guard RecordStore(directory: directory).archive.preferredUsers.contains("dhouston") else { throw Failure("Preference did not persist") }
        if CommandLine.arguments.contains("--snapshots") { try await snapshot(tab, name: "preferred-thread") }
        guard store.save(username: "dhouston", blocked: false, note: "Preferred fixture", citations: [], preferred: false) else { throw Failure("Preference pause failed") }
        try await wait(tab, for: .ready)
        print("PASS preferred submission highlights through the native bridge and persists")

        var highlightRules = AccountFilters(); highlightRules.preferHigher = true; highlightRules.karmaBelow = -1_000_000
        guard store.saveFilters(highlightRules, highlighting: true) else { throw Failure("Highlight rule save failed") }
        try await wait(tab, for: .ready)
        let highlightDeadline = Date().addingTimeInterval(30)
        var classHighlighted = false
        while Date() < highlightDeadline {
            classHighlighted = (try await evaluate(tab, "return document.querySelector('.qhn-preferred-author') !== null") as? Bool) == true
            if classHighlighted { break }
            try await Task.sleep(for: .milliseconds(200))
        }
        guard classHighlighted else { throw Failure("Live account rule did not highlight an author") }
        highlightRules.enabled = false
        guard store.saveFilters(highlightRules, highlighting: true) else { throw Failure("Highlight rule pause failed") }
        try await wait(tab, for: .ready)
        print("PASS live profile highlight rule updates the displayed author")
        tab.load(URL(string: "https://news.ycombinator.com/reply?id=8863")!)
        try await wait(tab, for: .ready)
        var accountFilters = AccountFilters()
        accountFilters.enabled = true; accountFilters.karmaBelow = 1_000_000_000
        guard store.saveFilters(accountFilters) else { throw Failure("Filter save failed") }
        try await wait(tab, for: .blocked)
        guard RecordStore(directory: directory).archive.accountFilters == accountFilters else { throw Failure("Filters did not persist") }
        accountFilters.enabled = false
        guard store.saveFilters(accountFilters) else { throw Failure("Filter disable failed") }
        try await wait(tab, for: .ready)
        print("PASS live profile filters hold a reply page, persist, and restore content when disabled")

        var pink = FilterRule(); pink.username = "dhouston"; pink.effect = .highlight; pink.color = .pink
        var block = FilterRule(); block.username = "dhouston"
        guard store.saveRules([pink, block]) else { throw Failure("Ordered rules save failed") }
        tab.load(URL(string: "https://news.ycombinator.com/item?id=8863")!)
        try await wait(tab, for: .ready)
        let pinkApplied = try await evaluate(tab, "return document.querySelector('.fatitem .qhn-preferred')?.style.getPropertyValue('--qhn-highlight')") as? String
        guard pinkApplied == "#e98caf" else { throw Failure("First rule highlight color missing") }
        guard store.saveRules([block, pink]) else { throw Failure("Reorder failed") }
        try await wait(tab, for: .blocked)
        guard RecordStore(directory: directory).archive.rules.first?.effect == .block else { throw Failure("Order not persisted") }
        guard store.saveRules([]) else { throw Failure("Clear ordered rules failed") }
        try await wait(tab, for: .ready)
        print("PASS ordered effects: highlight before block, reorder to block, persisted order, and clearing rules")

        guard store.saveRules([pink]) else { throw Failure("Profile rule save failed") }
        tab.load(URL(string: "https://news.ycombinator.com/user?id=dhouston")!)
        try await wait(tab, for: .ready)
        let profileDeadline = Date().addingTimeInterval(15)
        var profileSummary = ""
        while Date() < profileDeadline {
            profileSummary = (try await evaluate(tab, "return document.getElementById('qhn-profile-effect')?.textContent") as? String) ?? ""
            if profileSummary.contains("Highlight · Pink") { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard profileSummary.contains("Highlight · Pink"), profileSummary.contains("Filter 1") else { throw Failure("Profile effect summary missing") }
        if CommandLine.arguments.contains("--snapshots") { try await snapshot(tab, name: "profile-effect") }
        print("PASS live HN profile displays its matching effect and priority")

        tab.load(URL(string: "https://news.ycombinator.com/login")!)
        try await wait(tab, for: .ready)
        let login = try await evaluate(tab, "return document.querySelector('input[type=password]') !== null && document.querySelector('form') !== null") as? Bool
        guard login == true else { throw Failure("HN login form missing") }
        print("PASS HN login form is available without submitting credentials")
        if CommandLine.arguments.contains("--snapshots") {
            tab.load(URL(string: "https://news.ycombinator.com/news")!)
            try await wait(tab, for: .ready)
            try await snapshot(tab, name: "feed")
        }
        window.close()
    }

    @MainActor static func evaluate(_ tab: BrowserTab, _ script: String) async throws -> Any? {
        try await tab.webView.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: WKContentWorld.world(name: "HackerViews"))
    }

    @MainActor static func snapshot(_ tab: BrowserTab, name: String) async throws {
        _ = try await evaluate(tab, "window.scrollTo(0, 0)")
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build/previews")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            tab.webView.takeSnapshot(with: nil) { image, error in
                do {
                    if let error { throw error }
                    guard let tiff = image?.tiffRepresentation,
                          let data = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { throw Failure("Snapshot unavailable") }
                    try data.write(to: directory.appendingPathComponent("\(name).png"))
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    @MainActor static func wait(_ tab: BrowserTab, for expected: PageState) async throws {
        let until = Date().addingTimeInterval(45)
        while Date() < until {
            if tab.state == expected { return }
            if case .failed(let reason) = tab.state { throw Failure(reason) }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw Failure("Expected \(expected), got \(tab.state)")
    }
    struct Failure: Error, CustomStringConvertible { let description: String; init(_ value: String) { description = value } }
}
