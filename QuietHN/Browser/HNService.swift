import Foundation

actor HNService {
    private struct Entry: Codable { var item: HNItem; var fetched: Date }
    private var cache: [Int: Entry] = [:]
    private var inFlight: [Int: Task<HNItem?, Error>] = [:]
    private typealias User = HNAccount
    private var users: [String: CachedAccount] = [:]
    private var missingUsers: [String: Date] = [:]
    private let profileFile: URL
    private let profileLoader: (@Sendable (String) async throws -> HNAccount?)?
    private var scheduledProfileSave: Task<Void, Never>?
    private var userRequests: [String: Task<User?, Error>] = [:]
    private let file: URL

    private func profile(_ name: String) async throws -> User? {
        guard RecordArchive.validUsername(name) else { return nil }
        if let cached = users[name], cached.fresh(at: Date()) { return cached.account }
        if let missing = missingUsers[name], (0..<900).contains(Date().timeIntervalSince(missing)) { return nil }
        if let task = userRequests[name] { return try await task.value }
        let loader = profileLoader
        let task = Task<User?, Error> {
            if let loader { return try await loader(name) }
            var request = URLRequest(url: URL(string: "https://hacker-news.firebaseio.com/v0/user/\(name).json")!)
            request.timeoutInterval = 10
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            return try JSONDecoder().decode(User?.self, from: data)
        }
        userRequests[name] = task
        defer { userRequests[name] = nil }
        let user = try await task.value
        guard user == nil || user?.id == name else { throw URLError(.badServerResponse) }
        guard let user else { missingUsers[name] = Date(); return nil }
        let remembered = User(id: user.id, karma: user.karma, created: user.created ?? users[name]?.account.created)
        users[name] = CachedAccount(account: remembered)
        missingUsers[name] = nil
        if scheduledProfileSave == nil {
            scheduledProfileSave = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(300))
                await self?.flushProfiles()
            }
        }
        return remembered
    }

    private func evaluate(_ name: String, filters: AccountFilters, now: Date) async -> BranchDecision {
        do {
            let user = try await profile(name)
            let created = user?.created.flatMap { $0.isFinite ? Date(timeIntervalSince1970: $0) : nil }
            return filters.evaluate(karma: user?.karma, created: created, now: now)
        } catch { return .unresolved }
    }

    init(directory: URL? = nil, profileLoader: (@Sendable (String) async throws -> HNAccount?)? = nil) {
        let folder = directory ?? URL.cachesDirectory
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        file = folder.appendingPathComponent("QuietHN-ancestry.json")
        profileFile = folder.appendingPathComponent("QuietHN-accounts.json")
        self.profileLoader = profileLoader
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode([Int: Entry].self, from: data) { cache = saved }
        if let data = try? Data(contentsOf: profileFile), data.count <= 20_000_000,
           let saved = try? JSONDecoder().decode([String: CachedAccount].self, from: data) {
            users = saved.filter { name, entry in
                RecordArchive.validUsername(name) && entry.account.id == name && entry.fetched.timeIntervalSince1970.isFinite
            }
        }
    }

    func flushProfiles() {
        scheduledProfileSave = nil
        if users.count > 20_000 {
            users = Dictionary(uniqueKeysWithValues: users.sorted { $0.value.fetched > $1.value.fetched }.prefix(15_000).map { ($0.key, $0.value) })
        }
        if let data = try? JSONEncoder().encode(users) { try? data.write(to: profileFile, options: .atomic) }
    }

    func item(_ id: Int) async throws -> HNItem? {
        guard id > 0 else { return nil }
        if let entry = cache[id], Date().timeIntervalSince(entry.fetched) < 3600 { return entry.item }
        if let task = inFlight[id] { return try await task.value }
        let task = Task<HNItem?, Error> {
            var request = URLRequest(url: URL(string: "https://hacker-news.firebaseio.com/v0/item/\(id).json")!)
            request.timeoutInterval = 15
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            return try JSONDecoder().decode(HNItem?.self, from: data)
        }
        inFlight[id] = task
        defer { inFlight[id] = nil }
        do {
            guard var item = try await task.value else { return nil }
            // Remember a previously observed author/parent if HN later deletes them.
            if let old = cache[id]?.item {
                item = HNItem(id: item.id, by: item.by ?? old.by, parent: item.parent ?? old.parent,
                              type: item.type ?? old.type, deleted: item.deleted, dead: item.dead)
            }
            cache[id] = Entry(item: item, fetched: Date())
            return item
        } catch {
            // Previously observed ancestry is stable and can be used offline.
            if let old = cache[id] { return old.item }
            throw error
        }
    }

    func accountMatch(_ name: String, rules: [FilterRule], now: Date = Date()) async -> AccountRuleMatch {
        let cached = users[name]
        let initial = RuleEvaluation.match(for: name, rules: rules,
            karma: cached?.karma(at: now), created: cached?.creationDate, now: now)
        guard initial.effect == "unresolved" else { return initial }
        do {
            let user = try await profile(name)
            return RuleEvaluation.match(for: name, rules: rules, karma: user?.karma,
                created: user?.created.flatMap { $0.isFinite ? Date(timeIntervalSince1970: $0) : nil } ?? cached?.creationDate, now: now)
        } catch { return initial }
    }

    private func effect(_ name: String, rules: [FilterRule], now: Date) async -> String {
        await accountMatch(name, rules: rules, now: now).effect
    }

    struct ItemEffects: Sendable {
        var effects: [String: String]
        var labels: [String: String]
    }
    func decisions(ids: [Int], rules: [FilterRule], progress: (@Sendable (ItemEffects) async -> Void)? = nil) async -> ItemEffects {
        let now = Date()
        let checksBranches = rules.contains { $0.isActive && $0.effect == .block }
        var result: [String: String] = [:]
        var labels: [String: String] = [:]
        for start in stride(from: 0, to: ids.count, by: 8) {
            await withTaskGroup(of: (Int, String, String?).self) { group in
                for id in ids[start..<min(start + 8, ids.count)] {
                    group.addTask {
                        if checksBranches {
                            let branch = await Ancestry.classify(id: id, blocked: [], accountFiltersActive: true,
                                evaluateAuthor: { name in
                                    let effect = await self.effect(name, rules: rules, now: now)
                                    return effect == "blocked" ? .blocked : (effect == "unresolved" ? .unresolved : .visible)
                                }, fetch: { try await self.item($0) })
                            if branch != .visible { return (id, branch.rawValue, nil) }
                        }
                        guard let item = try? await self.item(id), let author = item.by else {
                            return (id, checksBranches ? "unresolved" : "visible", nil)
                        }
                        let match = await self.accountMatch(author, rules: rules, now: now)
                        var label: String?
                        if let priority = match.priority {
                            label = rules[priority - 1].contributionLabel(for: author)
                        }
                        return (id, match.effect == "unresolved" && !checksBranches ? "visible" : match.effect, label)
                    }
                }
                for await (id, effect, label) in group {
                    result[String(id)] = effect; labels[String(id)] = label
                    await progress?(ItemEffects(effects: [String(id): effect], labels: label.map { [String(id): $0] } ?? [:]))
                }
            }
        }
        if cache.count > 20_000 {
            cache = Dictionary(uniqueKeysWithValues: cache.sorted { $0.value.fetched > $1.value.fetched }.prefix(15_000).map { ($0.key, $0.value) })
        }
        if let data = try? JSONEncoder().encode(cache) { try? data.write(to: file, options: .atomic) }
        return ItemEffects(effects: result, labels: labels)
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
        if let data = try? JSONEncoder().encode(cache) { try? data.write(to: file, options: .atomic) }
        return result
    }
}
