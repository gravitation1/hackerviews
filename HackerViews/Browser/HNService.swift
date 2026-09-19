import Foundation

actor HNService {
    static let shared = HNService()
    private var cachesLoaded = false
    @TaskLocal static var cacheOnly = false
    private struct Entry: Codable { var item: HNItem; var fetched: Date }
    private var cache: [Int: Entry] = [:]
    private var inFlight: [Int: Task<HNItem?, Error>] = [:]
    private typealias User = HNAccount
    private var users: [String: CachedAccount] = [:]
    private var missingUsers: [String: Date] = [:]
    private let profileFile: URL
    private let itemLoader: (@Sendable (Int) async throws -> HNItem?)?
    enum AccountField: String, Sendable { case karma, created }
    private var fieldRequests: [String: Task<Double?, Error>] = [:]
    private let fieldLoader: (@Sendable (String, AccountField) async throws -> Double?)?
    private let profileLoader: (@Sendable (String) async throws -> HNAccount?)?
    private var scheduledProfileSave: Task<Void, Never>?
    private var userRequests: [String: Task<User?, Error>] = [:]
    private let file: URL

    // Retry transport/server failures inside the shared request, so concurrent
    // checks of the same author or ancestor share recovery as well as the fetch.
    private static func recovering<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        for attempt in 0..<3 {
            do { return try await operation() }
            catch {
                guard attempt < 2, let failure = error as? URLError,
                      [.timedOut, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost,
                       .dnsLookupFailed, .notConnectedToInternet, .badServerResponse].contains(failure.code) else { throw error }
                ReaderTrace.event("request.retry", ["attempt": attempt + 1, "code": failure.errorCode])
                try await Task.sleep(for: .milliseconds(attempt == 0 ? 300 : 900))
            }
        }
        throw URLError(.unknown)
    }
    private static func failureDescription(_ error: Error, subject: String) -> String {
        if let error = error as? URLError {
            switch error.code {
            case .notConnectedToInternet: return "You’re offline. Couldn’t load \(subject)."
            case .timedOut: return "Hacker News took too long to load \(subject)."
            case .badServerResponse: return "Hacker News returned an error while loading \(subject)."
            default: return "Couldn’t connect to Hacker News to load \(subject)."
            }
        }
        if error is DecodingError { return "Hacker News returned unreadable data for \(subject)." }
        return "Couldn’t load \(subject): \(error.localizedDescription)"
    }

    private func accountField(_ name: String, _ field: AccountField) async throws -> Double? {
        let key = name + "/" + field.rawValue
        if let missing = missingUsers[key], (0..<900).contains(Date().timeIntervalSince(missing)) { return nil }
        if let task = fieldRequests[key] { ReaderTrace.event("profile.shared", ["key": String(name.hashValue)]); return try await task.value }
        let loader = fieldLoader
        let task = Task<Double?, Error> {
            try await Self.recovering {
                if let loader { return try await ReaderRequestPool.shared.run { try await loader(name, field) } }
                var request = URLRequest(url: URL(string: "https://hacker-news.firebaseio.com/v0/user/\(name)/\(field.rawValue).json")!)
                request.timeoutInterval = 10
                let (data, response) = try await ReaderRequestPool.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                ReaderTrace.event("profile.bytes", ["key": String(name.hashValue), "field": field.rawValue, "bytes": data.count])
                let value = try JSONDecoder().decode(Double?.self, from: data)
                guard value == nil || (value!.isFinite && (field != .karma || Int(exactly: value!) != nil)) else { throw URLError(.cannotParseResponse) }
                return value
            }
        }
        fieldRequests[key] = task
        defer { fieldRequests[key] = nil }
        let result = try await task.value
        missingUsers[key] = result == nil ? Date() : nil
        return result
    }

    private func profile(_ name: String, needsKarma: Bool, needsCreated: Bool) async throws -> User? {
        loadCachesIfNeeded()
        let started = Date(), traceKey = String(name.hashValue)
        ReaderTrace.event("profile.start", ["key": traceKey])
        defer { ReaderTrace.event("profile.end", ["key": traceKey, "ms": Date().timeIntervalSince(started)*1000]) }
        guard RecordArchive.validUsername(name) else { return nil }
        let cached = users[name]
        if Self.cacheOnly { return cached?.account }
        let fetchKarma = needsKarma && (cached?.karma(at: Date()) == nil)
        let fetchCreated = needsCreated && cached?.creationDate == nil
        if !fetchKarma && !fetchCreated { ReaderTrace.event("profile.cache", ["key": traceKey]); return cached?.account }
        var karma: Int?, created: Double?
        if let loader = profileLoader {
            // Preserve the whole-account fixture injection used by existing tests.
            let task: Task<User?, Error>
            if let pending = userRequests[name] { task = pending }
            else { task = Task { try await Self.recovering { try await loader(name) } }; userRequests[name] = task }
            defer { userRequests[name] = nil }
            let account = try await task.value
            guard account == nil || account?.id == name else { throw URLError(.badServerResponse) }
            karma = account?.karma; created = account?.created
        } else {
            async let fetchedKarma = fetchKarma ? accountField(name, .karma) : nil
            async let fetchedCreated = fetchCreated ? accountField(name, .created) : nil
            let values = try await (fetchedKarma, fetchedCreated)
            karma = values.0.flatMap(Int.init(exactly:)); created = values.1
        }
        // Merge against the latest entry: another field request may have finished
        // while this one was suspended. Only karma retrieval refreshes its expiry.
        let latest = users[name]
        let remembered = User(id: name, karma: karma ?? latest?.account.karma, created: created ?? latest?.account.created)
        let timestamp = fetchKarma && karma != nil ? Date() : latest?.fetched ?? .distantPast
        users[name] = CachedAccount(account: remembered, fetched: timestamp)
        if scheduledProfileSave == nil {
            scheduledProfileSave = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(300))
                await self?.flushProfiles()
            }
        }
        return User(id: name, karma: users[name]?.karma(at: Date()), created: remembered.created)
    }

    private func evaluate(_ name: String, filters: AccountFilters, now: Date) async -> BranchDecision {
        do {
            let user = try await profile(name, needsKarma: filters.karmaBelow != nil, needsCreated: filters.createdSince != nil || filters.youngerThanDays != nil)
            let created = user?.created.flatMap { $0.isFinite ? Date(timeIntervalSince1970: $0) : nil }
            return filters.evaluate(karma: user?.karma, created: created, now: now)
        } catch { return .unresolved }
    }

    init(directory: URL? = nil, profileLoader: (@Sendable (String) async throws -> HNAccount?)? = nil, itemLoader: (@Sendable (Int) async throws -> HNItem?)? = nil, fieldLoader: (@Sendable (String, AccountField) async throws -> Double?)? = nil) {
        let folder = directory ?? URL.cachesDirectory
        file = folder.appendingPathComponent("HackerViews-contributions-v3.json")
        profileFile = folder.appendingPathComponent("HackerViews-accounts.json")
        self.itemLoader = itemLoader
        self.fieldLoader = fieldLoader
        self.profileLoader = profileLoader
    }

    // Runs on the service actor at first use, never in a SwiftUI view initializer.
    // No suspension here: concurrent callers cannot install conflicting snapshots.
    private func loadCachesIfNeeded() {
        guard !cachesLoaded else { return }
        cachesLoaded = true
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode([Int: Entry].self, from: data) { cache = saved }
        if let data = try? Data(contentsOf: profileFile), data.count <= 20_000_000,
           let saved = try? JSONDecoder().decode([String: CachedAccount].self, from: data) {
            users = saved.filter { name, entry in
                RecordArchive.validUsername(name) && entry.account.id == name && entry.fetched.timeIntervalSince1970.isFinite
            }
        }
    }

    func flushProfiles() {
        loadCachesIfNeeded()
        scheduledProfileSave = nil
        if users.count > 20_000 {
            users = Dictionary(uniqueKeysWithValues: users.sorted { $0.value.fetched > $1.value.fetched }.prefix(15_000).map { ($0.key, $0.value) })
        }
        if let data = try? JSONEncoder().encode(users) { try? data.write(to: profileFile, options: .atomic) }
    }

    func item(_ id: Int) async throws -> HNItem? {
        loadCachesIfNeeded()
        let traceStart = Date()
        ReaderTrace.event("item.start", ["id": id])
        defer { ReaderTrace.event("item.end", ["id": id, "ms": Date().timeIntervalSince(traceStart)*1000]) }
        guard id > 0 else { return nil }
        if Self.cacheOnly { return cache[id]?.item }
        if let entry = cache[id], Date().timeIntervalSince(entry.fetched) < 60 { ReaderTrace.event("item.cache", ["id": id]); return entry.item }
        if let task = inFlight[id] { ReaderTrace.event("item.shared", ["id": id]); return try await task.value }
        let loader = itemLoader
        let task = Task<HNItem?, Error> {
            try await Self.recovering {
            if let loader { return try await ReaderRequestPool.shared.run { try await loader(id) } }
            var request = URLRequest(url: URL(string: "https://hacker-news.firebaseio.com/v0/item/\(id).json")!)
            request.timeoutInterval = 15
            let (data, response) = try await ReaderRequestPool.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            ReaderTrace.event("item.bytes", ["id": id, "bytes": data.count])
            return try JSONDecoder().decode(HNItem?.self, from: data)
            }
        }
        inFlight[id] = task
        defer { inFlight[id] = nil }
        do {
            guard var item = try await task.value else { return nil }
            // Remember a previously observed author/parent if HN later deletes them.
            if let old = cache[id]?.item {
                item = HNItem(id: item.id, by: item.by ?? old.by, parent: item.parent ?? old.parent,
                              type: item.type ?? old.type, deleted: item.deleted, dead: item.dead,
                              title: item.title, text: item.text, url: item.url, kids: item.kids, score: item.score, time: item.time, descendants: item.descendants)
            }
            if cache.count >= 20000 {
                cache = Dictionary(uniqueKeysWithValues: cache.sorted { $0.value.fetched > $1.value.fetched }.prefix(15000).map { ($0.key, $0.value) })
            }
            cache[id] = Entry(item: item, fetched: Date())
            scheduleItemSave()
            return item
        } catch {
            // Previously observed ancestry is stable and can be used offline.
            if let old = cache[id] { return old.item }
            throw error
        }
    }

    // Only author, type and parent are reused beyond the content TTL. Rules
    // inspecting text still need the normal mutable-content refresh.
    func ancestorItem(_ id: Int, rules: [FilterRule]) async throws -> HNItem? {
        loadCachesIfNeeded()
        if !rules.contains(where: { $0.isActive && $0.content != nil }),
           let item = cache[id]?.item, item.by != nil, let type = item.type,
           type != "comment" || item.parent != nil {
            return HNItem(id: item.id, by: item.by, parent: item.parent, type: type)
        }
        return try await item(id)
    }

    func accountMatch(_ name: String, rules: [FilterRule], now: Date = Date()) async -> AccountRuleMatch {
        loadCachesIfNeeded()
        let varies = rules.contains { $0.isActive && ($0.content != nil || ($0.scope != nil && $0.scope != .both) || !($0.itemIDs ?? []).isEmpty) }
        let accountRules = rules.map { rule -> FilterRule in
            var copy = rule
            if copy.content != nil || (copy.scope != nil && copy.scope != .both) { copy.enabled = false }
            copy.itemIDs = nil
            return copy
        }
        let (rule, effect, _) = await itemMatch(HNItem(id: -1, by: name, parent: nil, type: "story"), rules: accountRules, now: now)
        let cached = users[name]
        // A profile fetched during the check above is newer than `now`; judge its
        // freshness from when it arrived, or freshly cached karma reads as stale.
        let evaluatedAt = max(now, cached?.fetched ?? now)
        var match = RuleEvaluation.match(for: name, rules: accountRules,
            karma: Self.cacheOnly ? cached?.account.karma : cached?.karma(at: evaluatedAt), created: cached?.creationDate, now: evaluatedAt)
        if match.effect != effect {
            match = AccountRuleMatch(effect: effect, label: Self.effectLabel(rule, effect: effect),
                ruleName: rule?.name, priority: rule.flatMap { rule in rules.firstIndex(where: { $0.id == rule.id }).map { $0 + 1 } })
        }
        match.contributionCaveat = varies
        return match
    }

    private static func effectLabel(_ rule: FilterRule?, effect: String) -> String {
        switch effect {
        case "unresolved": return "Couldn’t verify effect"
        case "visible": return rule == nil ? "Shown without unverified styling" : "Show normally"
        default:
            guard let rule else { return "No matching filter" }
            switch rule.effect {
            case .block: return "Blocked"
            case .highlight: return "Highlight · " + rule.color.rawValue.capitalized
            case .allow: return "Show normally"
            case .fade: return "Fade · " + rule.fade.label
            }
        }
    }

    private func effect(_ name: String, rules: [FilterRule], now: Date) async -> String {
        await accountMatch(name, rules: rules, now: now).effect
    }

    struct ItemEffects: Sendable {
        var effects: [String: String]
        var labels: [String: String]
        /// Contributions blocked only because an ancestor matched a branch-blocking
        /// rule, keyed to that ancestor. Revealing the ancestor lifts these blocks.
        var inherited: [String: Int] = [:]
    }
    func decisions(ids: [Int], rules: [FilterRule], knownItems: [Int: HNItem] = [:], progress: (@Sendable (ItemEffects) async -> Void)? = nil) async -> ItemEffects {
        let now = Date()
        let checksBranches = rules.contains { $0.isActive && $0.effect == .block }
        var result: [String: String] = [:]
        var labels: [String: String] = [:]
        var inherited: [String: Int] = [:]
        for start in stride(from: 0, to: ids.count, by: 8) {
            if Task.isCancelled { break }
            await withTaskGroup(of: Decision.self) { group in
                for id in ids[start..<min(start + 8, ids.count)] {
                    group.addTask {
                        if let item = knownItems[id], item.by != nil,
                           !rules.contains(where: { $0.isActive && ($0.conditions.isActive || $0.content != nil) }),
                           item.type != "comment" || !rules.contains(where: { $0.isActive && $0.effect == .block && $0.includesReplies }) {
                            return await self.domDecision(item, rules: rules, now: now)
                        }
                        return await self.contributionDecision(id, rules: rules, now: now, checksBranches: checksBranches)
                    }
                }
                for await (id, effect, label, source) in group {
                    result[String(id)] = effect; labels[String(id)] = label; inherited[String(id)] = source
                    await progress?(ItemEffects(effects: [String(id): effect], labels: label.map { [String(id): $0] } ?? [:],
                                                inherited: source.map { [String(id): $0] } ?? [:]))
                }
            }
        }
        if cache.count > 20_000 {
            cache = Dictionary(uniqueKeysWithValues: cache.sorted { $0.value.fetched > $1.value.fetched }.prefix(15_000).map { ($0.key, $0.value) })
        }
        scheduleItemSave()
        return ItemEffects(effects: result, labels: labels, inherited: inherited)
    }

    // A policy edit evaluates the current snapshot, including retained account
    // values. It must never join or start a network request.
    func cachedDecisions(ids: [Int], rules: [FilterRule]) async -> ItemEffects {
        await Self.$cacheOnly.withValue(true) {
            var effects: [String: String] = [:], labels: [String: String] = [:], inherited: [String: Int] = [:]
            for id in ids {
                let (_, effect, label, source) = await contributionDecision(id, rules: rules, now: Date(),
                    checksBranches: rules.contains { $0.isActive && $0.effect == .block })
                effects[String(id)] = effect
                labels[String(id)] = label
                inherited[String(id)] = source
            }
            return ItemEffects(effects: effects, labels: labels, inherited: inherited)
        }
    }

    func checkedContribution(_ id: Int, rules: [FilterRule]) async -> ItemEffects {
        let (_, effect, label, source) = await contributionDecision(id, rules: rules, now: Date(), checksBranches: rules.contains { $0.isActive && $0.effect == .block })
        return ItemEffects(effects: [String(id): effect], labels: label.map { [String(id): $0] } ?? [:], inherited: source.map { [String(id): $0] } ?? [:])
    }
    private func scheduleItemSave() {
        loadCachesIfNeeded()
        if scheduledItemSave == nil {
            scheduledItemSave = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                await self?.flushItems()
            }
        }
    }
    private var scheduledItemSave: Task<Void, Never>?
    private func flushItems() {
        scheduledItemSave = nil
        if let data = try? JSONEncoder().encode(cache) { try? data.write(to: file, options: .atomic) }
    }

    private func itemMatch(_ item: HNItem, rules: [FilterRule], now: Date) async -> (FilterRule?, String, String?) {
        let traceStart = Date()
        defer { ReaderTrace.event("filter.end", ["id": item.id, "ms": Date().timeIntervalSince(traceStart)*1000]) }
        var pending: (FilterRule, String)?
        let eligible = rules.filter { $0.isActive && $0.applies(to: item) }
        if let direct = eligible.first(where: { $0.itemIDs?.contains(item.id) == true }) { return (direct, direct.result, nil) }
        for rule in eligible {
            let cached = item.by.flatMap { users[$0] }
            var decision = rule.matches(item: item, karma: Self.cacheOnly ? cached?.account.karma : cached?.karma(at: now), created: cached?.creationDate, now: now)
            // Deleted entries are tombstones, not failed account lookups. Keep
            // known matches/direct assignments, but missing deleted metadata cannot
            // establish a match. Surviving replies still check all known ancestors.
            if item.deleted == true && decision == .unresolved { continue }
            var lookupFailure: String?
            if decision == .unresolved, rule.conditions.isActive, let name = item.by {
                let account: HNAccount?
                do { account = try await profile(name, needsKarma: rule.conditions.karmaBelow != nil, needsCreated: rule.conditions.createdSince != nil || rule.conditions.youngerThanDays != nil) }
                catch { account = nil; lookupFailure = Self.failureDescription(error, subject: "account details for filter ‘\(rule.name)’") }
                decision = rule.matches(item: item, karma: account?.karma, created: account?.created.map { Date(timeIntervalSince1970: $0) } ?? cached?.creationDate, now: now)
            }
            if decision == .blocked {
                if let pending {
                    guard rule.effect == .block else { return (nil, "visible", nil) }
                    var uncertain = pending.0; uncertain.hideReplies = true
                    return (uncertain, "unresolved", pending.1)
                }
                return (rule, rule.result, nil)
            }
            if decision == .unresolved {
                let reason: String
                if item.by == nil { reason = "Hacker News omitted the author; can’t evaluate filter ‘\(rule.name)’." }
                else if rule.conditions.isActive { reason = lookupFailure ?? "Account details needed by filter ‘\(rule.name)’ are unavailable." }
                else { reason = "The content pattern in filter ‘\(rule.name)’ couldn’t be evaluated." }
                if let pending {
                    guard rule.effect == .block else { continue }
                    var uncertain = pending.0; uncertain.hideReplies = true
                    return (uncertain, "unresolved", pending.1)
                }
                if rule.effect == .block { return (rule, "unresolved", reason) }
                pending = (rule, reason)
            }
        }
        return (nil, "visible", nil)
    }

    /// (id, effect, label or unresolved reason, ancestor whose branch block this contribution inherits)
    typealias Decision = (Int, String, String?, Int?)
    private func contributionDecision(_ id: Int, rules: [FilterRule], now: Date, checksBranches: Bool) async -> Decision {
        let traceStart = Date()
        ReaderTrace.event("check.start", ["id": id])
        defer { ReaderTrace.event("check.end", ["id": id, "ms": Date().timeIntervalSince(traceStart)*1000]) }
        let item: HNItem
        do {
            guard let fetched = try await self.item(id) else { return (id, "unresolved", "This contribution is no longer available from Hacker News.", nil) }
            item = fetched
        } catch { return (id, "unresolved", Self.failureDescription(error, subject: "this contribution"), nil) }
        if checksBranches && item.type == "comment" && item.parent == nil { return (id, "unresolved", "Hacker News omitted this comment’s parent; can’t check blocked ancestors.", nil) }
        let (rule, effect, issue) = await itemMatch(item, rules: rules, now: now)
        // A blocked item stays hidden itself; only explicit branch blocking affects descendants.
        if checksBranches {
            var cursor = item.parent
            var visited: Set<Int> = [id]
            while let parentID = cursor {
                guard visited.count < 512, visited.insert(parentID).inserted else { return (id, "unresolved", "This comment’s ancestry is cyclic or too deep to verify.", nil) }
                ReaderTrace.event("check.ancestor", ["id": id, "parent": parentID])
                let parent: HNItem
                do {
                    guard let fetched = try await self.ancestorItem(parentID, rules: rules) else { return (id, "unresolved", "A parent contribution is unavailable; can’t check blocked ancestors.", nil) }
                    parent = fetched
                } catch { return (id, "unresolved", Self.failureDescription(error, subject: "a parent contribution"), nil) }
                let (ancestorRule, ancestorEffect, ancestorIssue) = await itemMatch(parent, rules: rules, now: now)
                if ancestorRule?.includesReplies == true {
                    if ancestorEffect == "blocked" { return (id, "blocked", ancestorRule.map { $0.name + " · Blocked ancestor" }, parentID) }
                    if ancestorEffect == "unresolved" { return (id, "unresolved", "Couldn’t verify a parent contribution. " + (ancestorIssue ?? "Its filter check failed."), nil) }
                }
                if parent.type == "comment" && parent.parent == nil { return (id, "unresolved", "Hacker News omitted a parent comment’s ancestry; can’t check blocked ancestors.", nil) }
                cursor = parent.parent
            }
        }
        return formattedDecision(item, rule: rule, effect: effect, issue: issue)
    }

    private func domDecision(_ item: HNItem, rules: [FilterRule], now: Date) async -> Decision {
        ReaderTrace.event("check.dom", ["id": item.id])
        let (rule, effect, issue) = await itemMatch(item, rules: rules, now: now)
        return formattedDecision(item, rule: rule, effect: effect, issue: issue)
    }
    private func formattedDecision(_ item: HNItem, rule: FilterRule?, effect: String, issue: String?) -> Decision {
        let id = item.id
        let label = rule.map { rule in
            let name = rule.name.isEmpty ? "Unnamed filter" : rule.name
            if rule.itemIDs?.contains(id) == true { return name + " · Assigned directly" }
            if let content = rule.content { return name + " · " + content.field.rawValue + ": " + content.pattern }
            return rule.contributionLabel(for: item.by ?? "") ?? name
        }
        // Keep a directly opened discussion available when only its post/comment is hidden.
        let result = effect == "blocked" && rule?.includesReplies == false ? "hidden-item" : effect
        return (id, result, result == "unresolved" ? issue : label, nil)
    }

    func highlights(names: [String], filters: AccountFilters) async -> [String] {
        guard filters.isActive else { return [] }
        var matches: [String] = []
        let now = Date()
        for start in stride(from: 0, to: names.count, by: 8) {
            await withTaskGroup(of: String?.self) { group in
                for name in names[start..<min(start + 8, names.count)] {
                    group.addTask { await self.evaluate(name, filters: filters, now: now) == .blocked ? name : nil }
                }
                for await name in group { if let name { matches.append(name) } }
            }
        }
        return matches
    }

    func decisions(ids: [Int], blocked: Set<String>, filters: AccountFilters = AccountFilters()) async -> [String: String] {
        let now = Date()
        var result: [String: String] = [:]
        // Bound requests so long comment-list pages cannot flood HN's API.
        for start in stride(from: 0, to: ids.count, by: 8) {
            await withTaskGroup(of: (Int, BranchDecision).self) { group in
                for id in ids[start..<min(start + 8, ids.count)] {
                    group.addTask {
                        let decision = await Ancestry.classify(id: id, blocked: blocked,
                            accountFiltersActive: filters.isActive,
                            evaluateAuthor: { await self.evaluate($0, filters: filters, now: now) },
                            fetch: { try await self.item($0) })
                        return (id, decision)
                    }
                }
                for await (id, decision) in group { result[String(id)] = decision.rawValue }
            }
        }
        if cache.count > 20_000 {
            cache = Dictionary(uniqueKeysWithValues: cache.sorted { $0.value.fetched > $1.value.fetched }.prefix(15_000).map { ($0.key, $0.value) })
        }
        scheduleItemSave()
        return result
    }
}

// Debug-only, bounded JSONL trace. Write off the actor/main thread; never include
// comment text, filter patterns, URLs, cookies, or authenticated action links.
enum ReaderTrace {
    private static let queue = DispatchQueue(label: "HackerViews.performance", qos: .utility)
    static func event(_ name: String, _ fields: [String: Any] = [:]) {
        #if DEBUG
        var payload = fields
        payload["event"] = name
        payload["time"] = Date().timeIntervalSince1970
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        queue.async {
            let url = URL.cachesDirectory.appendingPathComponent("HackerViews-performance.jsonl")
            let manager = FileManager.default
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 8_000_000 {
                let previous = url.deletingLastPathComponent().appendingPathComponent("HackerViews-performance-previous.jsonl")
                try? manager.removeItem(at: previous)
                try? manager.moveItem(at: url, to: previous)
            }
            if !manager.fileExists(atPath: url.path) { manager.createFile(atPath: url.path, contents: nil) }
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            try? handle.seekToEnd()
            try? handle.write(contentsOf: data + Data([10]))
        }
        #endif
    }
}


actor ReaderRequestPool {
    static let shared = ReaderRequestPool(limit: 32)
    @TaskLocal static var priority = 1
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = 32
        return URLSession(configuration: config)
    }()
    private let limit: Int
    private var active = 0
    private var waiting: [(priority: Int, continuation: CheckedContinuation<Void, Never>)] = []
    init(limit: Int) { self.limit = limit }
    func acquire() async {
        if active < limit { active += 1 }
        else { await withCheckedContinuation { continuation in
            let priority = Self.priority
            let index = waiting.firstIndex { $0.priority > priority } ?? waiting.endIndex
            waiting.insert((priority, continuation), at: index)
        } }
        ReaderTrace.event("pool.acquired", ["active": active, "waiting": waiting.count])
    }
    func release() {
        if waiting.isEmpty { active -= 1 }
        else { waiting.removeFirst().continuation.resume() }
    }
    func run<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        await acquire()
        do {
            try Task.checkCancellation()
            let value = try await operation()
            release()
            return value
        } catch { release(); throw error }
    }
    static func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await shared.run { try await session.data(for: request) }
    }
}
