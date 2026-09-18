import Foundation

@main struct ContributionFilterSmoke {
    static func main() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        struct Entry: Codable { var item: HNItem; var fetched = Date() }
        let post = HNItem(id: 1, by: "alice", parent: nil, type: "story", title: "Hiring developers")
        let comment = HNItem(id: 2, by: "alice", parent: 1, text: "hello")
        let reply = HNItem(id: 3, by: "bob", parent: 2, text: "reply")
        try JSONEncoder().encode(["1": Entry(item: post), "2": Entry(item: comment), "3": Entry(item: reply)])
            .write(to: folder.appendingPathComponent("HackerViews-contributions-v2.json"))
        let lazyFolder = folder.appendingPathComponent("lazy-load")
        try FileManager.default.createDirectory(at: lazyFolder, withIntermediateDirectories: true)
        let lazyService = HNService(directory: lazyFolder, itemLoader: { _ in fatalError("Fresh disk cache should avoid the network") })
        // Write after construction: a constructor-time cache read would miss this.
        try JSONEncoder().encode(["1": Entry(item: post)])
            .write(to: lazyFolder.appendingPathComponent("HackerViews-contributions-v3.json"))
        async let firstCached = lazyService.item(1)
        async let secondCached = lazyService.item(1)
        let cachedPair = try await (firstCached, secondCached)
        precondition(cachedPair.0?.id == 1 && cachedPair.1?.id == 1)
        precondition(HNService.shared === HNService.shared)
        print("PASS cache initialization is deferred and concurrent readers share it")
        let service = HNService(directory: folder, itemLoader: { id in [1: post, 2: comment, 3: reply][id] })
        let stylingOffline = HNService(directory: folder.appendingPathComponent("styling-offline"),
            profileLoader: { _ in throw URLError(.notConnectedToInternet) }, itemLoader: { _ in post })
        for effect in [FilterRule.Effect.highlight, .fade, .allow] {
            var styling = FilterRule(); styling.effect = effect; styling.conditions.karmaBelow = 100
            let visible = await stylingOffline.decisions(ids: [1], rules: [styling])
            precondition(visible.effects["1"] == "visible", "Unknown styling must not hide readable content")
            var block = FilterRule(); block.assignedUsers = ["alice"]
            let mixed = await stylingOffline.decisions(ids: [1], rules: [styling, block])
            precondition(mixed.effects["1"] == "unresolved", "Unknown earlier styling cannot bypass a possible block")
            let blocked = await stylingOffline.decisions(ids: [1], rules: [block, styling])
            precondition(blocked.effects["1"] == "blocked", "Known earlier block must still win")
            block.enabled = false
            let disabled = await stylingOffline.decisions(ids: [1], rules: [styling, block])
            precondition(disabled.effects["1"] == "visible")
        }
        print("PASS offline non-blocking rules stay visible; mixed policies preserve blocking and priority")
        actor RequestCounter { var count = 0; func hit() { count += 1 } }
        let baselineCounter = RequestCounter(), domCounter = RequestCounter()
        let feedItems = Dictionary(uniqueKeysWithValues: (100...129).map { ($0, HNItem(id: $0, by: "alice", parent: nil, type: "story")) })
        var authorRule = FilterRule(); authorRule.assignedUsers = ["alice"]
        let baselineFeed = HNService(directory: folder.appendingPathComponent("feed-api"), itemLoader: { id in
            await baselineCounter.hit(); return feedItems[id]
        })
        let domFeed = HNService(directory: folder.appendingPathComponent("feed-dom"), itemLoader: { id in
            await domCounter.hit(); return feedItems[id]
        })
        let feedIDs = Array(100...129)
        let baselineResult = await baselineFeed.decisions(ids: feedIDs, rules: [authorRule])
        let domResult = await domFeed.decisions(ids: feedIDs, rules: [authorRule], knownItems: feedItems)
        precondition(baselineResult.effects == domResult.effects && baselineResult.labels == domResult.labels)
        let beforeRequests = await baselineCounter.count, afterRequests = await domCounter.count
        precondition(beforeRequests == 30 && afterRequests == 0)
        let guardedComment = HNItem(id: 2, by: "alice", parent: nil, type: "comment")
        let ancestryService = HNService(directory: folder.appendingPathComponent("dom-ancestry"), itemLoader: { id in
            await domCounter.hit(); return [1: post, 2: comment][id]
        })
        _ = await ancestryService.decisions(ids: [2], rules: [authorRule], knownItems: [2: guardedComment])
        let ancestryRequests = await domCounter.count
        precondition(ancestryRequests > 0, "DOM data must not bypass required ancestor checks")
        print("PASS 30-row author-filter fixture: \(beforeRequests) item requests before, \(afterRequests) after; identical effects")
        let bobStory = HNItem(id: 200, by: "bob", parent: nil, type: "story")
        let bobReply = HNItem(id: 201, by: "bob", parent: 200, type: "comment")
        let mixedOffline = HNService(directory: folder.appendingPathComponent("mixed-offline"),
            profileLoader: { _ in throw URLError(.notConnectedToInternet) }, itemLoader: { id in id == 200 ? bobStory : bobReply })
        var unknownStyle = FilterRule(); unknownStyle.effect = .highlight; unknownStyle.conditions.karmaBelow = 100
        var aliceBlock = FilterRule(); aliceBlock.assignedUsers = ["alice"]
        var secondUnknown = FilterRule(); secondUnknown.effect = .fade; secondUnknown.conditions.youngerThanDays = 5
        var bobBlock = FilterRule(); bobBlock.assignedUsers = ["bob"]
        for (tail, expected) in [(aliceBlock, "visible"), (bobBlock, "unresolved"), (secondUnknown, "visible")] {
            let policy = [unknownStyle, tail]
            let live = await mixedOffline.decisions(ids: [200,201], rules: policy)
            let cached = await mixedOffline.cachedDecisions(ids: [200,201], rules: policy)
            precondition(live.effects["200"] == expected && live.effects["201"] == expected)
            precondition(cached.effects == live.effects, "Cached and ancestor checks must use the same mixed-policy rule")
            let account = await mixedOffline.accountMatch("bob", rules: policy)
            precondition(account.effect == expected)
        }
        var knownStyle = FilterRule(); knownStyle.effect = .highlight; knownStyle.assignedUsers = ["bob"]
        var knownAllow = knownStyle; knownAllow.effect = .allow
        var unknownBlock = unknownStyle; unknownBlock.effect = .block
        for (policy, expected) in [
            ([secondUnknown, knownStyle], "visible"),
            ([unknownStyle, secondUnknown], "visible"),
            ([secondUnknown, knownAllow], "visible"),
            ([knownStyle, secondUnknown], knownStyle.result),
            ([unknownStyle, secondUnknown, bobBlock], "unresolved"),
            ([unknownStyle, unknownBlock], "unresolved"),
            ([unknownStyle, knownAllow, bobBlock], "visible")
        ] {
            let live = await mixedOffline.decisions(ids: [200,201], rules: policy)
            let cached = await mixedOffline.cachedDecisions(ids: [200,201], rules: policy)
            precondition(live.effects["200"] == expected && live.effects["201"] == expected)
            precondition(cached.effects == live.effects)
            let profile = await mixedOffline.accountMatch("bob", rules: policy)
            precondition(profile.effect == expected)
            if expected == "unresolved" { precondition(live.labels["200"]?.contains("offline") == true) }
        }
        print("PASS styling-only uncertainty stays visible; reachable blocks remain unresolved; offline cause retained")
        var scoped = FilterRule(); scoped.scope = .posts; scoped.assignedUsers = ["other"]
        let account = await mixedOffline.accountMatch("bob", rules: [scoped,bobBlock])
        precondition(account.effect == "blocked" && account.priority == 2 && account.contributionCaveat)
        print("PASS mixed policy: later no-match, match, and unknown across item, ancestor, cached, and profile checks")
        var broad = FilterRule(); broad.name = "Alice"; broad.assignedUsers = ["alice"]; broad.hideReplies = false
        var result = await service.decisions(ids: [1,2,3], rules: [broad])
        precondition(result.effects["1"] == "hidden-item" && result.effects["2"] == "hidden-item" && result.effects["3"] == "visible")
        var direct = FilterRule(); direct.name = "Exception"; direct.itemIDs = [2]; direct.effect = .highlight
        result = await service.decisions(ids: [2], rules: [broad,direct])
        precondition(result.effects["2"] == "highlight:#27a99a")
        precondition(result.labels["2"] == "Exception · Assigned directly")
        broad.hideReplies = true
        result = await service.decisions(ids: [2,3], rules: [broad,direct])
        precondition(result.effects["2"] == "blocked" && result.effects["3"] == "blocked")
        broad.scope = .comments; broad.hideReplies = false
        result = await service.decisions(ids: [1,2,3], rules: [broad])
        precondition(result.effects["1"] == "visible" && result.effects["2"] == "hidden-item" && result.effects["3"] == "visible")
        var pattern = ContentPattern(); pattern.field = .title; pattern.pattern = "hiring"
        var content = FilterRule(); content.name = "Jobs"; content.content = pattern; content.effect = .fade
        result = await service.decisions(ids: [1,2], rules: [content])
        precondition(result.effects["1"] == "fade:50" && result.effects["2"] == "visible")
        let snapshotFolder = folder.appendingPathComponent("snapshot")
        try FileManager.default.createDirectory(at: snapshotFolder, withIntermediateDirectories: true)
        try JSONEncoder().encode(["1": Entry(item: post, fetched: .distantPast),
                                  "2": Entry(item: comment, fetched: .distantPast),
                                  "3": Entry(item: reply, fetched: .distantPast)])
            .write(to: snapshotFolder.appendingPathComponent("HackerViews-contributions-v3.json"))
        try JSONEncoder().encode(["alice": CachedAccount(account: HNAccount(id: "alice", karma: 10, created: 100),
                                                         fetched: .distantPast)])
            .write(to: snapshotFolder.appendingPathComponent("HackerViews-accounts.json"))
        let snapshot = HNService(directory: snapshotFolder,
            itemLoader: { _ in preconditionFailure("Local edits must not fetch items") },
            fieldLoader: { _, _ in preconditionFailure("Local edits must not fetch accounts") })
        var snapshotKarmaRule = FilterRule(); snapshotKarmaRule.conditions.karmaBelow = 20; snapshotKarmaRule.hideReplies = true
        let local = await snapshot.cachedDecisions(ids: [1,2,3], rules: [snapshotKarmaRule])
        precondition(local.effects["1"] == "blocked" && local.effects["3"] == "blocked",
                     "Local edits use expired snapshot karma and propagate branch blocks")
        let absent = await snapshot.cachedDecisions(ids: [999], rules: [snapshotKarmaRule])
        precondition(absent.effects["999"] == "unresolved")
        let noRules = await snapshot.cachedDecisions(ids: [1,2,3], rules: [])
        precondition(noRules.effects.values.allSatisfy { $0 == "visible" })
        actor Attempts {
            var count = 0
            func load(_ id: Int) throws -> HNItem? {
                count += 1
                if count < 3 { throw URLError(.timedOut) }
                return HNItem(id: id, by: "reader", parent: nil, type: "story")
            }
        }
        let attempts = Attempts()
        let recovering = HNService(directory: folder.appendingPathComponent("recovery"), itemLoader: { try await attempts.load($0) })
        async let first = recovering.item(99)
        async let second = recovering.item(99)
        let recovered = try await (first, second)
        precondition(recovered.0?.id == 99 && recovered.1?.id == 99)
        let count = await attempts.count
        precondition(count == 3, "Concurrent readers must share all retry attempts")
        let offline = HNService(directory: folder.appendingPathComponent("offline"), itemLoader: { _ in throw URLError(.notConnectedToInternet) })
        let failure = await offline.decisions(ids: [99], rules: [])
        precondition(failure.effects["99"] == "unresolved")
        precondition(failure.labels["99"]?.contains("offline") == true)
        let missing = HNService(directory: folder.appendingPathComponent("missing"), itemLoader: { _ in nil })
        let unavailable = await missing.decisions(ids: [99], rules: [])
        precondition(unavailable.labels["99"]?.contains("no longer available") == true)
        let deleted = HNService(directory: folder.appendingPathComponent("deleted"), itemLoader: { id in HNItem(id: id, by: nil, parent: nil, type: "story", deleted: true) })
        let omitted = await deleted.decisions(ids: [99], rules: [broad])
        // Use a both-scope rule so the missing author must actually be checked.
        broad.scope = .both
        let unknownAuthor = await deleted.decisions(ids: [99], rules: [broad])
        precondition(omitted.effects["99"] == "visible")
        precondition(unknownAuthor.effects["99"] == "visible", "Deleted tombstones must not fail author filtering")
        let tombstoneService = HNService(directory: folder.appendingPathComponent("tombstone"), itemLoader: { id in
            switch id {
            case 1: return HNItem(id: 1, by: "alice", parent: nil, type: "story")
            case 2: return HNItem(id: 2, by: nil, parent: 1, deleted: true, kids: [3])
            default: return HNItem(id: 3, by: "reader", parent: 2, text: "Surviving reply")
            }
        })
        var userRule = FilterRule(); userRule.assignedUsers = ["someone"]
        let surviving = await tombstoneService.decisions(ids: [2,3], rules: [userRule])
        precondition(surviving.effects["2"] == "visible" && surviving.effects["3"] == "visible")
        userRule.assignedUsers = ["alice"]
        let blockedAbove = await tombstoneService.decisions(ids: [3], rules: [userRule])
        precondition(blockedAbove.effects["3"] == "blocked", "Deletion must not bypass known blocked ancestors")
        userRule.assignedUsers = []; userRule.itemIDs = [2]
        let assignedDeleted = await tombstoneService.decisions(ids: [3], rules: [userRule])
        precondition(assignedDeleted.effects["3"] == "blocked", "Direct branch assignment on a tombstone remains effective")
        actor FieldCalls {
            var calls: [String] = []
            func load(_ name: String, _ field: HNService.AccountField) -> Double? {
                calls.append(field.rawValue)
                return field == .created ? 1_000_000_000 : 500
            }
        }
        let fields = FieldCalls()
        let fieldFolder = folder.appendingPathComponent("fields")
        let narrow = HNService(directory: fieldFolder, itemLoader: { id in HNItem(id: id, by: "reader", parent: nil, type: "story") }, fieldLoader: { await fields.load($0, $1) })
        var ageRule = FilterRule(); ageRule.conditions.createdSince = Date(); ageRule.effect = .highlight
        _ = await narrow.decisions(ids: [99], rules: [ageRule])
        _ = await narrow.decisions(ids: [99], rules: [ageRule])
        let dateCalls = await fields.calls
        precondition(dateCalls == ["created"])
        var karmaRule = FilterRule(); karmaRule.conditions.karmaBelow = 1000
        _ = await narrow.decisions(ids: [99], rules: [karmaRule])
        let bothCalls = await fields.calls
        precondition(bothCalls == ["created", "karma"])
        await narrow.flushProfiles()
        // Expire only karma; creation dates must remain reusable after restart.
        let old = CachedAccount(account: HNAccount(id: "reader", karma: 500, created: 1_000_000_000), fetched: Date(timeIntervalSinceNow: -86400))
        try JSONEncoder().encode(["reader": old]).write(to: fieldFolder.appendingPathComponent("HackerViews-accounts.json"))
        let restored = HNService(directory: fieldFolder, itemLoader: { id in HNItem(id: id, by: "reader", parent: nil, type: "story") }, fieldLoader: { await fields.load($0, $1) })
        _ = await restored.decisions(ids: [99], rules: [ageRule])
        let cachedDateCalls = await fields.calls
        precondition(cachedDateCalls == bothCalls)
        _ = await restored.decisions(ids: [99], rules: [karmaRule])
        let refreshedCalls = await fields.calls
        precondition(refreshedCalls == ["created", "karma", "karma"])
        actor PoolProbe {
            var active = 0, peak = 0, completed = 0
            func begin() { active += 1; peak = max(peak, active) }
            func end() { active -= 1; completed += 1 }
        }
        let probe = PoolProbe()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<96 {
                group.addTask {
                    try! await ReaderRequestPool.shared.run {
                        await probe.begin()
                        try await Task.sleep(for: .milliseconds(20))
                        await probe.end()
                    }
                }
            }
        }
        let peak = await probe.peak, completed = await probe.completed
        precondition(peak == 32 && completed == 96, "Global request pool must refill without exceeding 32")
        actor ArrivalOrder { var values: [Int] = []; func record(_ value: Int) { values.append(value) } }
        let ordering = ArrivalOrder(), priorityPool = ReaderRequestPool(limit: 1)
        await priorityPool.acquire()
        let background = Task { try await ReaderRequestPool.$priority.withValue(2) { try await priorityPool.run { await ordering.record(2) } } }
        try await Task.sleep(for: .milliseconds(20))
        let visible = Task { try await ReaderRequestPool.$priority.withValue(0) { try await priorityPool.run { await ordering.record(0) } } }
        try await Task.sleep(for: .milliseconds(20))
        await priorityPool.release()
        try await background.value; try await visible.value
        let arrivals = await ordering.values
        precondition(arrivals == [0,2], "Visible requests must take the next free slot before background work")
        print("PASS visible requests take priority over queued background requests")
        print("PASS shared network pool: 96 operations completed with peak concurrency 32")
        print("PASS field selection, persistent creation dates, and independent karma expiry")
        print("PASS shared transient retries and specific offline, missing-item and omitted-author failures")
        print("PASS contribution decisions: scope, overrides, branch blocking, item-only blocking, content patterns and explanations")
    }
}
