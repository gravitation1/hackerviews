import SwiftUI
import UniformTypeIdentifiers

struct BackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(archive: RecordArchive) {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        data = (try? encoder.encode(archive)) ?? Data()
    }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct SettingsView: View {
    @ObservedObject var store: RecordStore
    @AppStorage("HackerViews.preferPrivateExternalLinks") private var preferPrivateExternalLinks = false
    @State private var exporting = false
    @State private var importing = false
    @State private var importData: Data?
    @State private var confirmImport = false
    @State private var importSummary = ""
    var body: some View {
        Form {
            if let notice = store.recoveryNotice {
                Section("Recovery needs review") {
                    Text(notice).textSelection(.enabled).foregroundStyle(.orange)
                }
            }
            #if os(macOS)
            Section("External links") {
                Toggle("Prefer opening external links in a private browser window", isOn: $preferPrivateExternalLinks)
                Text("Uses your default browser. Opens normally when private opening isn’t supported or the attempt fails.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            #endif
            Section("Private records") {
                LabeledContent("People", value: String(store.people.count))
                LabeledContent("Active filters", value: String(store.archive.rules.filter(\.isActive).count))
                LabeledContent("Saved revisions", value: String(store.archive.revisionCount))
                Text("Notes and saved excerpts belong to your private records. HN receives only your normal browsing and participation.").foregroundStyle(.secondary)
            }
            Section("Synchronization") {
                Label(store.syncStatus, systemImage: store.cloudEnabled ? "icloud" : "internaldrive")
                if store.cloudEnabled {
                    Button("Sync now") { Task { await store.synchronize() } }.disabled(store.isSyncing)
                    Text("Uses your private iCloud database. Checks on launch, after edits, when the app becomes active, and every minute while active.").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("This local build saves records on this device. To enable Mac–iPhone sync, configure your Apple team and iCloud container, then build the Cloud scheme. Setup instructions are in the project README.").font(.callout).foregroundStyle(.secondary)
                }
            }
            Section("Backups") {
                if !store.storageAvailable {
                    Button("Restore previous local save") { store.restoreRecoveryCopy() }
                    Text("Recovery preserves the unreadable original as a separate file.").font(.caption).foregroundStyle(.secondary)
                }
                Button { exporting = true } label: { Label("Export records and history", systemImage: "square.and.arrow.up") }
                    .disabled(!store.storageAvailable)
                Button { importing = true } label: { Label("Import and merge backup", systemImage: "square.and.arrow.down") }
                Text("Exports include private notes and citation text. Import merges revisions and keeps history; newer revisions can change block status and account filters.").font(.caption).foregroundStyle(.secondary)
            }
            Section("How filtering works") {
                Label("Submissions, comments, and descendant replies", systemImage: "hand.raised")
                Label("Ancestor checks for direct links and pagination", systemImage: "arrow.triangle.branch")
                Label("Content stays hidden if ancestry can’t be checked", systemImage: "eye.slash")
                Text("A deleted comment without a known author may prevent a page from being shown while you have active blocks. Quotes in unrelated branches can’t be reliably attributed and are not filtered.").font(.caption).foregroundStyle(.secondary)
            }
            Section("About") {
                Text("HackerViews").font(.headline)
                Text("An independent companion for Hacker News. Your HN account stays logged in separately on each device. External article links open in your default browser.").foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        #if os(iOS)
        .navigationTitle("Settings & backups")
        #endif
        .fileExporter(isPresented: $exporting, document: BackupDocument(archive: store.archive), contentType: .json,
                      defaultFilename: "hackerviews-\(Date().formatted(.iso8601.year().month().day()))") { result in
            if case .failure(let error) = result { store.error = error.localizedDescription }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            do {
                let url = try result.get()
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 50_000_000 else { throw ArchiveError.tooLarge }
                let data = try Data(contentsOf: url)
                let archive = try JSONDecoder().decode(RecordArchive.self, from: data)
                try archive.validate()
                importSummary = "Merge \(archive.revisionCount) revisions for \(archive.current.count) people? Newer records may change individual blocks and account filters. Your existing history is retained."
                importData = data; confirmImport = true
            } catch { store.error = error.localizedDescription }
        }
        .confirmationDialog("Import backup", isPresented: $confirmImport, titleVisibility: .visible) {
            Button("Merge records") { if let data = importData { store.importBackup(data) }; importData = nil }
            Button("Cancel", role: .cancel) { importData = nil }
        } message: { Text(importSummary) }
    }
}
