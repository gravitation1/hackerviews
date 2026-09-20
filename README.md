# HackerViews

A native **Mac and iPhone** companion for Hacker News. Read and participate on the actual HN website, while privately blocking users and their discussion branches and preserving the reasons with citations.

## Open and run

Open **HackerViews.xcodeproj** in Xcode. Select the **HackerViews** scheme and either **My Mac** or an iPhone simulator, then Run. There are no runtime package dependencies.

The local scheme works without iCloud provisioning. To install on a physical iPhone, choose your development team in Signing & Capabilities, use a bundle identifier you own, connect your phone, and Run. HN login happens inside the app, separately on each device.

Requirements: macOS 14+, iOS 17+, and an Xcode version with the relevant SDK. Developed and compiled using Xcode 27 / Swift 6.

### Built Mac app

After the command-line build below, the app is at `build/Build/Products/Debug/HackerViews.app`. Development builds are not notarized distribution releases.

```sh
xcodebuild -project HackerViews.xcodeproj -scheme HackerViews \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO build
open build/Build/Products/Debug/HackerViews.app
```

## Using it

- **Read:** HN's real pages, login, upvote/downvote controls (where your account is eligible), replying, and submissions. External articles open in your default browser.
- **Filters:** a Mac table with Order, Name, Matches, Effect, Status, and Details columns. Search names, matches, notes, and citations; narrow by status, effect, or match type. Column sorting never changes execution priority. Drag the Order handle only in the full execution-order view. Select rows with Command/Shift-click or Select all shown (Command-A), then activate, pause, change effect, move to top/bottom, or delete in bulk. Undo deletion restores the removed rules and positions without overwriting edits to other rules. Double-click a row to open its filter editor. Single-click selects rows; there is no side panel. iPhone uses compact selectable rows with the same search and bulk actions.
- **Fade:** choose Light (25%), Medium (50%), or Strong (75%) from the Effect menu, bulk actions, or filter editor. This overrides vote-based text coloring and dims matching titles/comments locally. It does not cast votes or fade other authors’ replies. First-match priority still applies.
- **Matching:** assign multiple users to a shared filter and optionally combine karma, creation date, and age conditions with ANY/ALL. Assigned users OR matching conditions qualify. Each condition has its own comparison direction. Empty filters match nobody. Changes save immediately.
- **⋯:** opens the author’s private notes and offers to save the captured contribution as a reference. Add or edit their filters from this editor. Notes and citations save immediately; Done closes without a discard prompt.
- **Saved references:** keep the original permalink, author, source text, context, capture date, and your annotation. Add multiple examples to a record. Later edits or deletions on HN do not change saved snapshots.
- **Tabs:** use the plus button / ⌘T to open another discussion, and ⌘L to paste an HN link. ⌘R reloads. Back and forward retain HN's normal navigation.
- **Settings:** export/import JSON backups, inspect sync status, or recover a damaged local journal from the previous successful save.

Opening an original citation in your external browser deliberately leaves the filtered app. Ordinary Firefox/Safari tabs are unaffected.

## Exact filtering behavior

1. Hide a blocked author's submitted stories, including their metadata and list spacer.
2. Hide their comments and all descendants, preserving ancestors and sibling branches.
3. Evaluate each author and check ancestry through the official HN API, including the story author. This covers direct comment links, reply pages, flat comment lists, and branches continued on another page.
4. Keep the browser surface hidden until filtering has finished. Dynamically inserted content and restored pages are checked again.
5. If one branch's ancestry cannot be verified, hide that branch and keep verified siblings. A direct link whose ancestry cannot be verified stays hidden with a retry action.
6. Cache observed authors and parent links. Deleted records without previously known authors are unresolved. Quotations or paraphrases in unrelated branches cannot reliably be attributed and are not filtered.

The app does not remove your HN account's participation restrictions or alter other people's view of HN. The original forms and links perform HN actions; the public API is used for account profiles and ancestry checks.

## Enable private iCloud synchronization

iCloud requires Apple provisioning. The code is implemented, but an unsigned local build cannot activate it. A paid Apple Developer membership with CloudKit capability is needed for the Cloud scheme.

1. Create `Config/Signing.local.xcconfig` (gitignored):

   ```xcconfig
   DEVELOPMENT_TEAM = YOURTEAMID
   HACKER_VIEWS_BUNDLE_ID = com.yourname.HackerViews
   HACKER_VIEWS_CLOUD_CONTAINER = iCloud.com.yourname.HackerViews
   ```

2. In your Apple developer account / Xcode Signing & Capabilities, enable **iCloud → CloudKit**, register that container, and associate it with the app identifier. Use the **same container and bundle identifier** for the Mac and iPhone builds.
3. Select the **HackerViews Cloud** scheme. Sign in to the same iCloud account on both devices and run this scheme on each.
4. The first development sync creates a private `HackerViews` record zone and `PersonRevision` records with a `payload` field. No query indexes are required: synchronization enumerates zone changes. Confirm that Settings reports a successful sync on both devices.
5. Before TestFlight/App Store distribution, deploy the CloudKit schema to production in CloudKit Console, and verify a production-signed build. Development and production databases are separate.

Sync runs after edits, on launch/activation, and once per minute while the app is active. Failed sync leaves local records intact and reports the error. There is no background push requirement. Large individual records exceeding the CloudKit payload limit remain local and exportable, with an explicit sync error.

### Conflict behavior

Every save creates an immutable revision. Devices exchange revisions; the newest timestamp wins, with a stable UUID tie-breaker. All earlier and concurrent revisions remain in **Edit history**, including their notes and citations. Restore any prior version to make it current. This is not automatic text merging: concurrent edits can require reviewing history.

Private notes do not go into HN's DOM or the ancestry API. HN cookies stay in WebKit's on-device website data store. iCloud sync stores only the private record journal. Backups are ordinary JSON containing your private notes and source snapshots; keep them somewhere appropriate.

## Tests

```sh
# Pure Swift records / ancestry regression tests
swift test

# DOM filtering tests; jsdom is a development-only dependency
npm ci --ignore-scripts
npm test

# Native WebKit integration against public HN, with ephemeral cookies and
# temporary test records. No login, votes, comments, or submissions.
zsh scripts/native-smoke.sh

# iPhone simulator build
xcodebuild -project HackerViews.xcodeproj -scheme HackerViews -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath build-ios \
  CODE_SIGNING_ALLOWED=NO build
```

The native smoke suite verifies live HN loading, isolated-world message handling, retained vote links, citation capture, block/unblock behavior, local persistence, history, and availability of the login form. Authenticated voting/comment submission and real two-device iCloud behavior require testing with your accounts; the tests never send participation actions.

## Structure

```text
HackerViews/Core/          Codable journal, validation, merge, ancestry rules
HackerViews/Browser/       WebKit host, isolated message bridge, API ancestry cache
HackerViews/Resources/     Page filter and annotation controls
HackerViews/Views/         SwiftUI browsing, records, citations, history, backups
HackerViews/Sync/          Private CloudKit revision exchange
Config/               Platform entitlements, Info.plist, optional signing config
Tests/                Swift, DOM, and native WebKit integration tests
```

`scripts/generate_project.py` regenerates the checked-in Xcode project from the Swift source tree without installing XcodeGen. Put signing overrides in the local xcconfig so regeneration preserves them.

## Remaining release verification

- Select your Apple team and provision CloudKit; test edits, offline changes, and conflicts between your actual Mac and iPhone.
- Test authenticated upvote/downvote/reply/submit with your own HN account.
- Visually review both interfaces, including accessibility, text scaling, keyboard use, and the iPhone keyboard. Computer Use permission was unavailable during this build session.
- Sign and distribute the app through your chosen Apple development/TestFlight/App Store workflow. This repository is a development app, not a published App Store release.

HN can change its markup; regression tests and the native smoke test should be rerun when that happens. The page is held on processing failures instead of silently disabling filters.

### Ordered filter semantics

For each author, filters are evaluated in list order and stop at the first match. Disabled filters and conditions that do not match are skipped. An earlier Highlight or Show normally rule can exempt that author from a later Block rule. When an ancestor’s effect is Block, its entire reply branch remains hidden; highlighting a descendant does not resurrect a blocked branch. Highlights apply only to the matching author’s contributions.

Unknown earlier conditions are not skipped in favor of later rules. If active block rules exist, unresolved account/ancestry checks keep affected content hidden. With only non-blocking rules, unresolved content stays visible without a highlight. Profiles persist in an atomic disk cache across launches. Cached creation dates do not expire; karma is usable for 15 minutes and refreshed only when needed to resolve a rule. The cache is bounded to 20,000 accounts, trimming to 15,000 recent entries when full. Age is calculated in rolling 24-hour days, and dates use the selected local midnight. Reload/retry re-evaluates rules; reordering and valid edits update open pages immediately.

Existing settings migrate into the list with block rules before highlight rules to preserve prior behavior. Notes/citations remain independent. Rule IDs and list order are saved in the revision journal, recovery files, backups, and optional CloudKit payloads. Legacy backups remain readable; once an ordered list exists, legacy person block/preference flags are no longer the active policy. Physical-device provisioning and live iCloud verification remain deferred.

Deletion undo is available within the current Filters view session. Switching views or reopening the app does not retain the UI undo stack; durable backup/revision history remains intact.

Newly created filters take priority 1 in both the account panel and the general filter editor. Existing filters retain their position when edited. Active/Paused text is a one-click status control without a pause/play glyph.

User profiles display the current effect and first matching filter name/priority. Blocked profiles remain readable for review. Unknown results show a retry action rather than an assumed effect. Cached creation dates can satisfy age/date rules offline without fetching stale karma. Contributions appear progressively as their author and ancestry checks finish. Thread/reply pages wait for the focused item’s check before revealing the page; unchecked contributions remain hidden.

### Shared filter membership

Filters now start clean with an empty **Blocked** filter; prior filter declarations are not carried forward. Existing user notes, citations, and their history stay available. Assign users from the account panel or the filter’s detail pane/editor. A user may belong to several filters; the first matching active filter wins, including matches from conditions. Removing an assignment or deleting a filter preserves user records. Naming a new filter saves it even before members are assigned. An untouched empty editor creates nothing.

Opening the account panel creates no record or reference. Notes save when edited. Profile banner actions open notes without capturing the profile. Reference excerpts and optional annotations live under Details; existing saved references are preserved.

Profile pages show editable private Notes and Saved references below the filter banner. Notes save after a short pause or on leaving the field. References can be added, annotated, opened, and removed inline. The profile’s Edit filters button opens a filter-only panel; contribution capture panels still offer notes and deliberate reference saving.

The profile’s **Your notes** list combines account notes and source annotations. Notes are fully visible in reading mode, with source links and Edit/Remove actions. Only saved excerpts collapse. Add note defaults to the current profile and can target another source URL. Inline edits autosave; each new note uses a stable ID to avoid duplicate entries.

## Post, comment, and content filters

Filters can apply to posts, comments, or both. Assign an individual contribution from its ellipsis menu under **This contribution**, or enter its HN item ID in the filter editor. Direct item assignments take precedence over user and content matches; filter order breaks ties. Scope and enabled state still apply. A blocked ancestor whose filter hides replies still hides the branch, including directly assigned descendants.

Combine the configured user group, account-condition group, and content pattern with **Match any (OR)** or **Match all (AND)**. Empty groups do not participate. Account conditions keep their own any/all setting. Direct item assignments bypass these conditions. Empty filters match nobody.

Content fields are post title, post URL, post domain, and body text. Title/URL/domain do not match comments. Body text strips HTML markup and decodes common HN entities and numeric character references. Matching supports literal text or ICU regular expressions, with case-insensitive matching on by default. Enter regex directly (no surrounding `/` delimiters). The tester marks the first matched range. Invalid drafts never replace the last valid saved rule.

Regex uses Foundation's [progress callbacks](https://developer.apple.com/documentation/foundation/nsregularexpression/matchingoptions/reportprogress) to stop long-running operations after a 25 ms budget at the next callback. This is cooperative cancellation, not a hard real-time guarantee or a linear-time regex engine. Patterns are limited to 2,000 UTF-8 bytes and tested text to 200,000 UTF-16 units. Timeout/oversize results remain unverified rather than silently being treated as nonmatches. The tester runs off the UI thread.

**When blocking** defaults to **Hide contribution and replies**, for both new and existing filters without an explicit choice. **Hide matching contribution only** remains an explicit option that leaves discussions and replies available. Notes remain associated with the contribution independently of its filter assignments.

### Durable record transactions

Record edits first save a small immutable transaction in `record-transactions` next to `records.json`. A utility queue coalesces these into a full snapshot and keeps the previous completed snapshot as `records.json.previous`. Startup replays any transactions left by a quit or interrupted checkpoint; copy the entire application-support directory when making a filesystem backup. In-app exports still contain the complete archive. New person revisions reference all known branch tips instead of repeating their full ancestry; existing revisions remain unchanged.

### Reader parity

Topic comments use API data, with authenticated HN HTML supplying available edit/delete, flag/hide/favorite actions and community fading. Moderated text is withheld until that HTML includes it, respecting HN's current presentation for the signed-in account. Polls use the canonical HN page, including its native options and voting. The redirect immediately after submitting a reply also uses HN HTML to avoid API lag, with the reply link retaining the parent-comment anchor. No posting or voting is performed automatically.

One header is rendered by the app on every page type. Feed pages replace HN's header table with it, and the topic shell emits it before its own content; both take their links from HN's `.pagetop` markup (initially a default set on the shell, then the authenticated HTML), so per-user thread links and the logout token stay correct. Karma is kept, the wordmark is dropped and `home` is inserted. The topic shell also loads HN's `news.css`, so the reader stylesheet is an overlay on the same base as feed pages. Filter status lives in the header: a chip appears only when contributions are hidden, and a second chip with a retry action when checks could not finish. The hidden chip is a toggle: pressing it reveals the hidden contributions in place for this page view only, faded and labelled with the filter that hid them, with replies of a revealed comment loading as usual. Unchecked contributions stay hidden. A reload or any filter change hides them again. Following a link out of a revealed contribution opens that discussion already revealed: the page script reports the intent, the tab carries it into the topic shell, and the discussion shows a "Temporarily revealed" notice with a Hide again control instead of asking a second time. Revealing a hidden discussion root, by either route, also shows the replies that were hidden only because of it. Native checks report which ancestor a block is inherited from, so those replies are lifted with that ancestor and carry no label, while replies hidden by their own rules stay hidden and are what the chip counts. The identity slot holds its width until HN's HTML arrives. A story's "Add a comment" control opens a comment box in place. The box is built from the comment form in HN's own HTML for the discussion, which the reader already fetches for vote and flag links, so it posts through HN with HN's token and lands back on the discussion as a reply from HN's page would. HN's reply page rejects stories, so the reader never links there for one; when HN's HTML offers no form, the box says so and offers HN's own page.

Moderated and deleted comments keep their place in the tree with the same row scaffold as a live comment, including indentation, navigation links and a collapse toggle whose state persists like any other. Flat comment lists such as `newcomments` and a user's comments page are filtered and styled like threaded comments. Pages without HN's header, such as login, still get the shared header. The topic shell's story line reads "points by author · age | hide | favorite | N comments", and a comment's navigation links, collapse toggle and timestamp never wrap onto a line of their own.

Simple author/direct-item rules on list pages use available DOM metadata without item requests. Content/account conditions and required ancestor checks still use the service. If no active blocking rule exists, an unresolved styling/allow condition leaves the contribution visible without applying an uncertain effect; mixed blocking policies remain conservative.

Explicit recovery (Restore previous or importing a backup while storage is damaged) replays readable pending transactions and preserves unreadable ones in a named recovery directory. A persistent banner and Settings notice identify potentially missing edits and preserved files. Normal startup still stops on unreadable transactions.

Cloud sync persists an account/container-scoped checkpoint containing the change token and downloaded archive together. Subsequent syncs fetch changes and send unknown revisions in batches of 100. Unreadable remote records are preserved in the checkpoint and reported in Settings; valid records continue syncing. Expired server tokens trigger a fresh enumeration. Existing immutable CloudKit revision records are retained.

Ancestor-only filter checks reuse cached author, parent and item type beyond the 60-second content freshness window. Content-based filters and displayed items still use normal refreshes. Note edits coalesce for five seconds idle, with earlier saves on blur, dismissal or leaving the active app; normal Mac quit also saves. An abrupt force quit can lose the current draft.

CloudKit keeps a second archive copy with its change token; unchanged change pages avoid rewriting that checkpoint. Its process-local account identity cache is invalidated on account-change notifications.

Mac reader commands: Command-W closes the selected tab when several are open, otherwise it closes the window while preserving the reading session. Shift-Command-W closes the window when multiple reader tabs are open. The History menu provides Back (Command-[) and Forward (Command-]) for the selected tab.

During a running session, reader history retains loaded pages in memory. Back/Forward reuse their web views and restore the saved comment offset instead of rebuilding the topic or fetching the home page again. Explicit Refresh still reloads. Closing a tab or replacing its forward-history branch releases those retained pages; after quitting the app, session restoration loads pages on demand from the saved reading anchors.
