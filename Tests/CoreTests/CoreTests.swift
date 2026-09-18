import Foundation
import Testing
@testable import HackerViewsCore

@Test func concurrentEditsAreRetainedAndMergeOrderIsStable() throws {
    var a = PersonRevision(username: "alice", isBlocked: true, note: "Reason on Mac", citations: [], device: "Mac")
    var b = PersonRevision(username: "alice", isBlocked: false, note: "Reason on phone", citations: [], device: "iPhone")
    a.modifiedAt = Date(timeIntervalSince1970: 100)
    b.modifiedAt = a.modifiedAt
    var left = RecordArchive(revisions: [a]); try left.merge(RecordArchive(revisions: [b]))
    var right = RecordArchive(revisions: [b]); try right.merge(RecordArchive(revisions: [a]))
    #expect(left.current == right.current)
    #expect(left.history(for: "alice").count == 2)
    try left.merge(right)
    #expect(left.revisions.count == 2)
}

@Test func unblockingKeepsCitationsAndEarlierReason() throws {
    let citation = Citation(url: "https://news.ycombinator.com/item?id=123", author: "alice", excerpt: "Evidence before deletion", context: "A discussion")
    var first = PersonRevision(username: "alice", isBlocked: true, note: "Original reason", citations: [citation])
    first.modifiedAt = Date(timeIntervalSince1970: 100)
    var second = first; second.id = UUID(); second.isBlocked = false; second.note = "Reconsidered"
    second.modifiedAt = Date(timeIntervalSince1970: 200)
    var archive = RecordArchive(revisions: [first]); try archive.merge(RecordArchive(revisions: [second]))
    #expect(archive.blockedUsers.isEmpty)
    #expect(archive.current.first?.citations.first?.excerpt == "Evidence before deletion")
    #expect(archive.history(for: "alice").last?.note == "Original reason")
    let decoded = try JSONDecoder().decode(RecordArchive.self, from: JSONEncoder().encode(archive))
    #expect(decoded.revisions == archive.revisions)
}

@Test func invalidBackupDoesNotPartiallyMerge() throws {
    let valid = PersonRevision(username: "alice", isBlocked: true, note: "", citations: [])
    let invalid = PersonRevision(username: "bad user", isBlocked: true, note: "", citations: [])
    var archive = RecordArchive(revisions: [valid])
    #expect(throws: (any Error).self) { try archive.merge(RecordArchive(revisions: [invalid])) }
    #expect(archive.revisions == [valid])
    var collision = valid; collision.note = "Different payload"
    #expect(throws: (any Error).self) { try archive.merge(RecordArchive(revisions: [collision])) }
    #expect(!RecordArchive.validCitationURL("javascript:alert(1)"))
    #expect(!RecordArchive.validCitationURL("https://user:pass@example.com/"))
}

@Test func usernamesAreCaseSensitive() {
    let archive = RecordArchive(revisions: [PersonRevision(username: "Alice", isBlocked: true, note: "", citations: [])])
    #expect(archive.blockedUsers.contains("Alice"))
    #expect(!archive.blockedUsers.contains("alice"))
}

@Test func directDescendantOfBlockedParentIsBlocked() async {
    let tree = [3: HNItem(id: 3, by: "carol", parent: 2), 2: HNItem(id: 2, by: "bob", parent: 1),
                1: HNItem(id: 1, by: "alice", parent: nil, type: "story"), 4: HNItem(id: 4, by: "eve", parent: 1)]
    let hidden = await Ancestry.classify(id: 3, blocked: ["bob"]) { tree[$0] }
    let sibling = await Ancestry.classify(id: 4, blocked: ["bob"]) { tree[$0] }
    let blockedSubmission = await Ancestry.classify(id: 4, blocked: ["alice"]) { tree[$0] }
    #expect(hidden == .blocked)
    #expect(sibling == .visible)
    #expect(blockedSubmission == .blocked)
}

@Test func missingDeletedAndCyclicAncestryStayUnresolved() async {
    let deleted = [1: HNItem(id: 1, by: nil, parent: nil, type: "story", deleted: true)]
    let cycle = [1: HNItem(id: 1, by: "a", parent: 2), 2: HNItem(id: 2, by: "b", parent: 1)]
    #expect(await Ancestry.classify(id: 1, blocked: ["bob"]) { _ in nil } == .unresolved)
    #expect(await Ancestry.classify(id: 1, blocked: ["bob"]) { deleted[$0] } == .unresolved)
    #expect(await Ancestry.classify(id: 1, blocked: ["bob"]) { cycle[$0] } == .unresolved)
    #expect(await Ancestry.classify(id: 1, blocked: []) { _ in nil } == .visible)
}

@Test func networkErrorsDoNotRevealTheBranch() async {
    #expect(await Ancestry.classify(id: 1, blocked: ["bob"]) { _ in throw URLError(.notConnectedToInternet) } == .unresolved)
}

@Test func accountFilterBoundariesAndUnknownProfiles() {
    let now = Date(timeIntervalSince1970: 2_000_000)
    var filters = AccountFilters()
    filters.enabled = true
    #expect(filters.evaluate(karma: nil, created: nil) == .visible)
    filters.karmaBelow = 100
    filters.youngerThanDays = 30
    let old = now.addingTimeInterval(-30 * 86400)
    #expect(filters.evaluate(karma: 100, created: old, now: now) == .visible)
    #expect(filters.evaluate(karma: 99, created: old, now: now) == .blocked)
    #expect(filters.evaluate(karma: 100, created: old.addingTimeInterval(1), now: now) == .blocked)
    #expect(filters.evaluate(karma: 99, created: nil, now: now) == .blocked)
    filters.match = .all
    #expect(filters.evaluate(karma: 100, created: nil, now: now) == .visible)
    #expect(filters.evaluate(karma: 99, created: nil, now: now) == .unresolved)
    #expect(filters.evaluate(karma: 99, created: now, now: now) == .blocked)
    #expect(filters.evaluate(karma: 99, created: now, now: now.addingTimeInterval(30 * 86400)) == .visible)
    filters.youngerThanDays = nil; filters.karmaBelow = nil; filters.createdSince = now
    #expect(filters.evaluate(karma: nil, created: now, now: now) == .blocked)
    #expect(filters.evaluate(karma: nil, created: now.addingTimeInterval(-1), now: now) == .visible)
}

@Test func accountRulesCheckOffPageAncestors() async {
    let decision = await Ancestry.classify(id: 3, blocked: [], accountFiltersActive: true,
        evaluateAuthor: { $0 == "newbie" ? .blocked : .visible }, fetch: { id in
            switch id {
            case 3: HNItem(id: 3, by: "veteran", parent: 2)
            case 2: HNItem(id: 2, by: "newbie", parent: 1)
            default: HNItem(id: 1, by: "submitter", parent: nil, type: "story")
            }
        })
    #expect(decision == .blocked)
}

@Test func filterBackupCompatibilityAndAtomicMerging() throws {
    var archive = try JSONDecoder().decode(RecordArchive.self, from: Data("{\"formatVersion\":1,\"revisions\":[]}".utf8))
    #expect(!archive.accountFilters.isActive)
    var filters = AccountFilters(); filters.enabled = true; filters.karmaBelow = 50
    let revision = AccountFilterRevision(filters: filters)
    var incoming = RecordArchive(); incoming.filterRevisions = [revision]
    try archive.merge(incoming)
    let restored = try JSONDecoder().decode(RecordArchive.self, from: JSONEncoder().encode(archive))
    #expect(restored.accountFilters == filters)
    var conflicting = revision; conflicting.filters.karmaBelow = 60
    incoming.filterRevisions = [conflicting]
    #expect(throws: ArchiveError.self) { try archive.merge(incoming) }
    #expect(archive.accountFilters == filters)
    conflicting.id = UUID(); conflicting.filters.youngerThanDays = -1
    incoming.filterRevisions = [conflicting]
    #expect(throws: ArchiveError.self) { try archive.merge(incoming) }
    #expect(archive.revisionCount == 1)
}

@Test func accountFiltersDefaultEnabledButPreserveSavedPause() throws {
    var filters = AccountFilters()
    #expect(filters.enabled)
    #expect(!filters.isActive)
    filters.youngerThanDays = 360
    #expect(filters.isActive)
    filters.enabled = false
    let restored = try JSONDecoder().decode(AccountFilters.self, from: JSONEncoder().encode(filters))
    #expect(!restored.enabled)
    #expect(!restored.isActive)
    #expect(restored.youngerThanDays == 360)
}

@Test func preferredClassesUseInclusiveMinimumsAndStrictCreationCutoff() {
    var rule = AccountFilters(); rule.preferHigher = true
    let now = Date(timeIntervalSince1970: 4_000_000)
    rule.karmaBelow = 500
    #expect(rule.evaluate(karma: 500, created: nil, now: now) == .blocked)
    #expect(rule.evaluate(karma: 499, created: nil, now: now) == .visible)
    rule.youngerThanDays = 30; rule.match = .all
    #expect(rule.evaluate(karma: 500, created: now.addingTimeInterval(-30 * 86400), now: now) == .blocked)
    #expect(rule.evaluate(karma: 500, created: now, now: now) == .visible)
    #expect(rule.evaluate(karma: 500, created: nil, now: now) == .unresolved)
    rule.karmaBelow = nil; rule.youngerThanDays = nil; rule.createdSince = now
    #expect(rule.evaluate(karma: nil, created: now, now: now) == .visible)
    #expect(rule.evaluate(karma: nil, created: now.addingTimeInterval(-1), now: now) == .blocked)
}

@Test func preferredRecordsAndRulesSurviveBackupMerges() throws {
    var person = PersonRevision(username: "alice", isBlocked: false, note: "Thoughtful explanations", citations: [])
    person.isPreferred = true
    var rules = AccountFilters(); rules.preferHigher = true; rules.karmaBelow = 500
    var revision = AccountFilterRevision(filters: AccountFilters()); revision.highlights = rules
    var archive = RecordArchive(revisions: [person]); archive.filterRevisions = [revision]
    let decoded = try JSONDecoder().decode(RecordArchive.self, from: JSONEncoder().encode(archive))
    var merged = RecordArchive(); try merged.merge(decoded)
    #expect(merged.preferredUsers == ["alice"])
    #expect(merged.highlightFilters == rules)
    #expect(merged.blockedUsers.isEmpty)
}

@Test func declarationOrderDeterminesEffectAndExceptions() {
    var block = FilterRule(); block.username = "alice"
    var highlight = block; highlight.id = "highlight"; highlight.effect = .highlight; highlight.color = .purple
    #expect(RuleEvaluation.effect(for: "alice", rules: [highlight, block], karma: nil, created: nil) == "highlight:#b18be8")
    #expect(RuleEvaluation.effect(for: "alice", rules: [block, highlight], karma: nil, created: nil) == "blocked")
    var allow = highlight; allow.effect = .allow
    #expect(RuleEvaluation.effect(for: "alice", rules: [allow, block], karma: nil, created: nil) == "visible")
    highlight.enabled = false
    #expect(RuleEvaluation.effect(for: "alice", rules: [highlight, block], karma: nil, created: nil) == "blocked")
    var unknown = FilterRule(); unknown.conditions.karmaBelow = 100
    #expect(RuleEvaluation.effect(for: "alice", rules: [unknown, allow], karma: nil, created: nil) == "unresolved")
    #expect(RuleEvaluation.effect(for: "alice", rules: [unknown, allow], karma: 1000, created: nil) == "visible")
}

@Test func cleanFiltersPreserveNotesAndMembershipBackups() throws {
    let person = PersonRevision(username: "alice", isBlocked: true, note: "Keep evidence", citations: [])
    var archive = RecordArchive(revisions: [person])
    var old = AccountFilterRevision(filters: AccountFilters())
    var previous = FilterRule(); previous.username = "alice"; previous.name = "Old"
    old.orderedRules = [previous]; archive.filterRevisions = [old]
    #expect(archive.rules == [.blockedDefault])
    #expect(!archive.rules[0].isActive)
    var rule = FilterRule.blockedDefault; rule.assignedUsers = ["alice", "bob"]
    var revision = AccountFilterRevision(filters: AccountFilters())
    revision.membershipVersion = 1; revision.orderedRules = [rule]
    archive.filterRevisions?.append(revision)
    let backup = try JSONDecoder().decode(RecordArchive.self, from: JSONEncoder().encode(archive))
    var merged = RecordArchive(); try merged.merge(backup)
    #expect(merged.rules[0].assignedUsers == ["alice", "bob"])
    #expect(merged.current.first?.note == "Keep evidence")
    revision.id = UUID(); revision.orderedRules = [rule, rule]
    var invalid = RecordArchive(); invalid.filterRevisions = [revision]
    #expect(throws: ArchiveError.self) { try merged.merge(invalid) }
    #expect(merged.rules.count == 1)
}

@Test func membershipsUnionConditionsAndRespectPriority() {
    var rule = FilterRule.blockedDefault
    #expect(RuleEvaluation.effect(for: "alice", rules: [rule], karma: nil, created: nil) == "visible")
    rule.assignedUsers = ["alice", "bob"]
    rule.conditions.karmaBelow = 100
    #expect(RuleEvaluation.effect(for: "alice", rules: [rule], karma: nil, created: nil) == "blocked")
    #expect(RuleEvaluation.effect(for: "other", rules: [rule], karma: 50, created: nil) == "blocked")
    #expect(RuleEvaluation.effect(for: "other", rules: [rule], karma: 500, created: nil) == "visible")
    var preferred = FilterRule(); preferred.assignedUsers = ["alice"]; preferred.effect = .highlight
    #expect(RuleEvaluation.effect(for: "alice", rules: [preferred, rule], karma: nil, created: nil).hasPrefix("highlight:"))
    #expect(RuleEvaluation.effect(for: "alice", rules: [rule, preferred], karma: nil, created: nil) == "blocked")
    rule.assignedUsers.remove("alice"); rule.conditions = AccountFilters()
    #expect(RuleEvaluation.effect(for: "alice", rules: [rule], karma: nil, created: nil) == "visible")
    #expect(RuleEvaluation.effect(for: "bob", rules: [rule], karma: nil, created: nil) == "blocked")
}

@Test func conditionsSupportIndependentComparisons() {
    var rule = FilterRule(); rule.conditions.karmaBelow = 1000; rule.conditions.karmaHigher = true
    rule.conditions.youngerThanDays = 30; rule.conditions.ageOlder = false; rule.conditions.match = .all
    rule.effect = .highlight
    let now = Date()
    #expect(RuleEvaluation.effect(for: "alice", rules: [rule], karma: 1000, created: now, now: now).hasPrefix("highlight:"))
    #expect(RuleEvaluation.effect(for: "alice", rules: [rule], karma: 999, created: now, now: now) == "visible")
}

@Test func bulkMovesPreserveRelativeExecutionOrder() {
    let rules = (0..<5).map { i in var rule = FilterRule(); rule.id = String(i); return rule }
    #expect(RuleListEdits.moving(["1", "3"], in: rules, toEnd: false).map(\.id) == ["1", "3", "0", "2", "4"])
    #expect(RuleListEdits.moving(["1", "3"], in: rules, toEnd: true).map(\.id) == ["0", "2", "4", "1", "3"])
}

@Test func deletionUndoRestoresPositionsWithoutOverwritingOtherEdits() {
    let rules = (0..<5).map { i in var rule = FilterRule(); rule.id = String(i); return rule }
    let deleted = RuleListEdits.removed(["1", "3"], from: rules)
    var remaining = rules.filter { !["1", "3"].contains($0.id) }
    remaining[1].name = "Edited while others were deleted"
    let restored = RuleListEdits.restoring(deleted, into: remaining)
    #expect(restored.map(\.id) == rules.map(\.id))
    #expect(restored[2].name == "Edited while others were deleted")
    #expect(RuleListEdits.restoring(deleted, into: restored).count == 5)
}

@Test func newFilterDraftDoesNotCreateEmptyRules() {
    var draft = FilterRule()
    #expect(RuleListEdits.updating(draft, in: []).isEmpty)
    draft.name = "New highlight"; draft.effect = .highlight
    #expect(RuleListEdits.updating(draft, in: []).count == 1)
    draft.username = "alice"
    let saved = RuleListEdits.updating(draft, in: [])
    #expect(saved.count == 1)
    #expect(saved.first?.id == draft.id)
    draft.color = .pink
    #expect(RuleListEdits.updating(draft, in: saved).count == 1)
    #expect(RuleListEdits.updating(draft, in: saved).first?.color == .pink)
}

@Test func newFiltersTakeFirstPriorityWhileEditsKeepTheirPosition() {
    var broad = FilterRule(); broad.conditions.karmaBelow = 1000
    var exception = FilterRule(); exception.username = "alice"; exception.effect = .highlight
    let created = RuleListEdits.updating(exception, in: [broad])
    #expect(created.map(\.id) == [exception.id, broad.id])
    #expect(RuleEvaluation.effect(for: "alice", rules: created, karma: 10, created: nil).hasPrefix("highlight:"))
    broad.name = "Renamed"
    #expect(RuleListEdits.updating(broad, in: created).map(\.id) == [exception.id, broad.id])
}

@Test func cachedCreationSurvivesKarmaExpiryAndRestart() throws {
    let fetched = Date(timeIntervalSince1970: 2_000_000)
    let cached = CachedAccount(account: HNAccount(id: "alice", karma: 100, created: 1_000_000), fetched: fetched)
    let reopened = try JSONDecoder().decode(CachedAccount.self, from: JSONEncoder().encode(cached))
    #expect(reopened.karma(at: fetched.addingTimeInterval(899)) == 100)
    #expect(reopened.karma(at: fetched.addingTimeInterval(900)) == nil)
    #expect(reopened.karma(at: fetched.addingTimeInterval(-1)) == nil)
    #expect(reopened.creationDate == Date(timeIntervalSince1970: 1_000_000))
    var rule = FilterRule(); rule.conditions.youngerThanDays = 30
    #expect(RuleEvaluation.effect(for: "alice", rules: [rule], karma: reopened.karma(at: fetched.addingTimeInterval(900)), created: reopened.creationDate, now: fetched) == "blocked")
}

@Test func profileSummaryIdentifiesFirstMatchingRuleAndUnknowns() {
    var first = FilterRule(); first.username = "bob"
    var next = FilterRule(); next.name = "Experienced accounts"; next.conditions.karmaBelow = 1000; next.conditions.karmaHigher = true
    next.effect = .highlight; next.color = .blue
    let matched = RuleEvaluation.match(for: "alice", rules: [first, next], karma: 1000, created: nil)
    #expect(matched.label == "Highlight · Blue")
    #expect(matched.priority == 2)
    #expect(matched.ruleName == "Experienced accounts")
    let unknown = RuleEvaluation.match(for: "alice", rules: [first, next], karma: nil, created: nil)
    #expect(unknown.effect == "unresolved")
    #expect(unknown.priority == 2)
    #expect(RuleEvaluation.match(for: "alice", rules: [], karma: nil, created: nil).priority == nil)
}

@Test func accountHighlightLabelsOnlyAddDistinctNames() {
    var rule = FilterRule(); rule.effect = .highlight; rule.username = "simonw"
    #expect(rule.contributionLabel == nil)
    rule.name = "simonw"
    #expect(rule.contributionLabel == nil)
    rule.name = "  simonw  "
    #expect(rule.contributionLabel == nil)
    rule.name = "Helpful explanations"
    #expect(rule.contributionLabel == "Helpful explanations")
    rule.username = nil
    #expect(rule.contributionLabel == "Helpful explanations")
    rule.effect = .allow
    #expect(rule.contributionLabel == nil)
}

@Test func membershipLabelsUseSharedNames() {
    var filter = FilterRule(); filter.effect = .highlight; filter.assignedUsers = ["alice", "bob"]
    filter.name = "Thoughtful contributors"
    #expect(filter.contributionLabel(for: "alice") == "Thoughtful contributors")
    filter.name = "alice"
    #expect(filter.contributionLabel(for: "alice") == nil)
    #expect(filter.contributionLabel(for: "bob") == "alice")
}

@Test func fadeEffectPersistsAndObeysPriority() throws {
    var rule = FilterRule(); rule.assignedUsers = ["alice"]; rule.effect = .fade
    #expect(rule.result == "fade:50")
    rule.fadeLevel = .strong
    let copy = try JSONDecoder().decode(FilterRule.self, from: JSONEncoder().encode(rule))
    #expect(copy.result == "fade:75")
    var block = FilterRule.blockedDefault; block.assignedUsers = ["alice"]
    #expect(RuleEvaluation.effect(for: "alice", rules: [copy, block], karma: nil, created: nil) == "fade:75")
    #expect(RuleEvaluation.effect(for: "alice", rules: [block, copy], karma: nil, created: nil) == "blocked")
    #expect(RuleEvaluation.match(for: "alice", rules: [copy], karma: nil, created: nil).label == "Fade · Strong (75%)")
}

@Test func fadeLabelsFollowHighlightNamingRules() {
    var rule = FilterRule(); rule.effect = .fade; rule.name = "Potential bot"
    #expect(rule.contributionLabel(for: "alice") == "Potential bot")
    rule.assignedUsers = ["alice"]; rule.name = "alice"
    #expect(rule.contributionLabel(for: "alice") == nil)
    rule.name = "Custom label"
    #expect(rule.contributionLabel(for: "alice") == "Custom label")
}

@Test func appliedEffectExplainsOnlyMatchingConditions() {
    var rule = FilterRule(); rule.name = "New or low karma"
    rule.conditions.karmaBelow = 100; rule.conditions.youngerThanDays = 30
    let now = Date()
    let match = RuleEvaluation.match(for: "alice", rules: [rule], karma: 500, created: now, now: now)
    #expect(match.matchedConditions?.karmaBelow == nil)
    #expect(match.matchedConditions?.youngerThanDays == 30)
    rule.assignedUsers = ["alice"]
    let direct = RuleEvaluation.match(for: "alice", rules: [rule], karma: 500, created: now, now: now)
    #expect(direct.matchedConditions == nil)
}

@Test func legacyProfilePlaceholdersAreRemovedWithoutLosingNotesOrIntentionalReferences() {
    let empty = Citation(url: "https://news.ycombinator.com/user?id=alice", author: "alice", excerpt: "", context: "Profile: alice | Hacker News")
    var annotated = empty; annotated.id = UUID(); annotated.annotation = "Keep this"
    var explicit = empty; explicit.id = UUID(); explicit.savedIntentionally = true
    let person = PersonRevision(username: "alice", isBlocked: false, note: "My notes", citations: [empty, annotated, explicit])
    var archive = RecordArchive(revisions: [person])
    archive.removeLegacyProfilePlaceholders()
    #expect(archive.current[0].citations.map(\.id) == [annotated.id, explicit.id])
    #expect(archive.current[0].note == "My notes")
    #expect(archive.history(for: "alice").last?.citations.count == 3)
    let count = archive.revisionCount
    archive.removeLegacyProfilePlaceholders()
    #expect(archive.revisionCount == count)
}

@Test func contentPatternsAndScopes() throws {
    var pattern = ContentPattern(); pattern.field = .title; pattern.mode = .regex
    pattern.pattern = #"\b(hiring|seeking work)\b"#
    let post = HNItem(id: 1, by: "alice", parent: nil, type: "story", title: "HIRING engineers")
    let comment = HNItem(id: 2, by: "alice", parent: 1, text: "HIRING engineers")
    #expect(pattern.evaluate(post) == .blocked)
    #expect(pattern.evaluate(comment) == .visible)
    pattern.ignoreCase = false
    #expect(pattern.evaluate(post) == .visible)
    pattern.field = .body; pattern.pattern = "fish & chips"; pattern.mode = .contains
    #expect(pattern.evaluate(HNItem(id: 3, by: "a", parent: 1, text: "<p>fish &amp; chips</p>")) == .blocked)
    #expect(ContentPattern.readable("&#x41;&#66;&lt;tag&gt;") == "AB<tag>")
    var rule = FilterRule(); rule.content = pattern; rule.scope = .comments
    #expect(rule.isActive && rule.isValid)
    #expect(!rule.applies(to: post) && rule.applies(to: comment))
    rule.content?.pattern = "["; rule.content?.mode = .regex
    #expect(!rule.isValid)
    #expect(RuleListEdits.updating(rule, in: []).isEmpty)
}

@Test func contentCombinesWithUsersAndConditions() {
    var rule = FilterRule(); rule.assignedUsers = ["alice"]
    var pattern = ContentPattern(); pattern.pattern = "spam"; rule.content = pattern
    let ordinary = HNItem(id: 1, by: "alice", parent: 9, text: "hello")
    let spam = HNItem(id: 2, by: "bob", parent: 9, text: "spam")
    #expect(rule.matches(item: ordinary, karma: nil, created: nil, now: Date()) == .blocked)
    #expect(rule.matches(item: spam, karma: nil, created: nil, now: Date()) == .blocked)
    rule.combine = .all
    #expect(rule.matches(item: ordinary, karma: nil, created: nil, now: Date()) == .visible)
    #expect(rule.matches(item: spam, karma: nil, created: nil, now: Date()) == .visible)
    rule.itemIDs = [2]
    #expect(rule.matches(item: spam, karma: nil, created: nil, now: Date()) == .blocked)
    rule.scope = .posts
    #expect(rule.matches(item: spam, karma: nil, created: nil, now: Date()) == .visible)
}

@Test func slowRegexStopsAndReportsUnverified() {
    var pattern = ContentPattern(); pattern.mode = .regex; pattern.pattern = "(a+)+$"
    let start = Date()
    #expect(pattern.test(String(repeating: "a", count: 5000) + "!").decision == .unresolved)
    #expect(Date().timeIntervalSince(start) < 1)
}

@Test func contributionFilterRoundTrip() throws {
    var rule = FilterRule(); rule.name = "Patterns"; rule.scope = .posts; rule.hideReplies = false
    rule.itemIDs = [123]; rule.combine = .all
    var pattern = ContentPattern(); pattern.field = .domain; pattern.pattern = "example.com"; rule.content = pattern
    #expect(try JSONDecoder().decode(FilterRule.self, from: JSONEncoder().encode(rule)) == rule)
    var legacy = FilterRule(); legacy.assignedUsers = ["alice"]
    #expect(legacy.includesReplies && legacy.applies(to: HNItem(id: 1, by: "alice", parent: nil, type: "story")))
}

@Test func contributionAssignmentAcceptsHNLinksAndRejectsOtherURLs() {
    #expect(HNItem.assignmentID(" https://news.ycombinator.com/item?id=123#456 ") == 123)
    #expect(HNItem.assignmentID("123") == 123)
    #expect(HNItem.assignmentID("https://example.com/item?id=123") == nil)
    #expect(HNItem.assignmentID("https://news.ycombinator.com/user?id=123") == nil)
    #expect(HNItem.assignmentID("https://news.ycombinator.com/item?id=-1") == nil)
}

@Test func savedNotesDirectorySkipsEmptyRecordsAndSearchesReferenceContent() {
    var person = PersonRevision(username: "alice", isBlocked: false, note: " \n", citations: [])
    #expect(!person.hasSavedNotes)
    var citation = Citation(url: "https://news.ycombinator.com/item?id=123", author: "alice", excerpt: "Original excerpt", context: "Source title")
    citation.annotation = "Useful explanation"
    person.citations = [citation]
    #expect(person.hasSavedNotes)
    #expect(person.savedNotePreview == "Useful explanation")
    #expect(person.matchesSavedNotesSearch("EXPLANATION"))
    #expect(person.matchesSavedNotesSearch("original"))
    #expect(person.matchesSavedNotesSearch("alice"))
    #expect(!person.matchesSavedNotesSearch("missing"))
    person.note = "Profile note"
    #expect(person.savedNotePreview == "Profile note")
}


@Test func pendingMembershipEditsSurviveExternalChanges() {
    let base: Set<String> = ["alice", "bob", "carol"]
    // Remove Alice and add Dave locally while another editor removes Bob and adds Eve.
    let edited: Set<String> = ["bob", "carol", "dave"]
    let stored: Set<String> = ["alice", "carol", "eve"]
    let merged = RuleListEdits.mergingMembers(base: base, edited: edited, stored: stored)
    #expect(merged == ["carol", "dave", "eve"])
    // A second store publication must not lose the original pending removal.
    #expect(RuleListEdits.mergingMembers(base: stored, edited: merged,
        stored: stored.union(["frank"])) == ["carol", "dave", "eve", "frank"])
    #expect(RuleListEdits.mergingMembers(base: base, edited: base, stored: stored) == stored)
    // Acknowledging a successful save clears the local delta.
    #expect(RuleListEdits.mergingMembers(base: merged, edited: merged, stored: ["carol"]) == ["carol"])
}


@Test func revisionHeadsPreserveConcurrentBranchesWithoutQuadraticAncestry() throws {
    let root = PersonRevision(username: "alice", isBlocked: false, note: "root", citations: [])
    let left = PersonRevision(username: "alice", isBlocked: false, note: "left", citations: [], parentIDs: [root.id])
    let right = PersonRevision(username: "alice", isBlocked: false, note: "right", citations: [], parentIDs: [root.id])
    var archive = RecordArchive(revisions: [root, left, right])
    #expect(Set(archive.revisionHeads(for: "alice")) == [left.id, right.id])
    for _ in 0..<1000 {
        let parents = archive.revisionHeads(for: "alice")
        archive.revisions.append(PersonRevision(username: "alice", isBlocked: false, note: "edit", citations: [], parentIDs: parents))
    }
    #expect(archive.revisions.flatMap(\.parentIDs).count == 1003)
    var oldShape = archive
    for index in oldShape.revisions.indices {
        oldShape.revisions[index].parentIDs = Array(oldShape.revisions.prefix(index).map(\.id))
    }
    let oldBytes = try JSONEncoder().encode(oldShape).count
    let newBytes = try JSONEncoder().encode(archive).count
    #expect(newBytes * 20 < oldBytes)
    print("Journal ancestry fixture: \(oldBytes) bytes before, \(newBytes) bytes after (\(archive.revisionCount) revisions)")
    let originalIDs = Set(archive.revisions.map(\.id))
    try archive.merge(RecordArchive(revisions: [root, left, right]))
    #expect(Set(archive.revisions.map(\.id)) == originalIDs)
}
