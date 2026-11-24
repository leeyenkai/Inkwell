import InkwellKit
import SwiftUI

struct HealthList: View {
    @Bindable var model: AppModel

    var body: some View {
        let issues = model.healthIssues
        List(selection: $model.selectedIssueID) {
            ForEach(SiteHealth.Category.allCases) { category in
                let group = issues.filter { $0.category == category }
                if !group.isEmpty {
                    Section(category.title) {
                        ForEach(group) { issue in
                            Label {
                                Text(issue.title).lineLimit(2)
                            } icon: {
                                SeverityIcon(severity: issue.severity)
                            }
                            .tag(issue.id)
                        }
                    }
                }
            }
        }
        .listStyle(.inset)
        .overlay {
            if model.health == nil {
                ProgressView("Checking the site")
            } else if issues.isEmpty {
                ContentUnavailableView("Nothing to fix", systemImage: "checkmark.seal",
                                       description: Text("Properties, links, images, sharing and the repository all look right."))
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                switch model.externalCheck {
                case .never:
                    Text("Links to other sites are not checked yet.").font(.caption).foregroundStyle(.secondary)
                case let .checking(done, total):
                    ProgressView(value: Double(done), total: Double(max(total, 1))).frame(width: 80)
                    Text("Checking \(done) of \(total) links").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                case let .checked(date):
                    Text("Links to other sites checked \(date.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Check Links") { model.checkExternalLinks() }
                    .disabled({ if case .checking = model.externalCheck { true } else { false } }())
                    .help("Ask each site your posts link to whether the page is still there")
            }
            .padding(10)
            .background(.bar)
        }
        .navigationTitle("Health")
        .navigationSubtitle(subtitle(issues))
        .onAppear { model.refreshHealth() }
    }
}

extension HealthList {
    func subtitle(_ issues: [SiteHealth.Issue]) -> String {
        let problems = model.healthProblems
        let suggestions = issues.count - problems
        switch (problems, suggestions) {
        case (0, 0): return String(localized: "No problems")
        case (_, 0): return String(localized: "\(problems) problems")
        case (0, _): return String(localized: "No problems · \(suggestions) suggestions")
        default: return String(localized: "\(problems) problems · \(suggestions) suggestions")
        }
    }
}

struct SeverityIcon: View {
    var severity: SiteHealth.Severity

    var body: some View {
        switch severity {
        case .error: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red).accessibilityLabel("Problem")
        case .warning: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).accessibilityLabel("Warning")
        case .info: Image(systemName: "lightbulb").foregroundStyle(.secondary).accessibilityLabel("Suggestion")
        }
    }
}

struct HealthDetail: View {
    var model: AppModel
    var issue: SiteHealth.Issue

    func line(_ edit: ContentEdit) -> String {
        guard edit.newText != nil else { return String(localized: "Delete \(edit.path)") }
        let exists = model.site.map { FileManager.default.fileExists(atPath: $0.root.appending(path: edit.path).path) } ?? false
        return exists ? String(localized: "Change \(edit.path)") : String(localized: "Add \(edit.path)")
    }

    func lines(_ edits: [ContentEdit]) -> String {
        var text = edits.prefix(8).map { line($0) }
        if edits.count > 8 { text.append(String(localized: "…and \(edits.count - 8) more")) }
        return text.joined(separator: "\n")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    SeverityIcon(severity: issue.severity).font(.title2)
                    Text(issue.title).font(.title2.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                }
                Text(issue.detail).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                if !issue.paths.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Files").font(.headline)
                        ForEach(issue.paths, id: \.self) { path in
                            if model.allDocuments.contains(where: { $0.relativePath == path }) {
                                Button(path) { model.openDocument(path: path) }.buttonStyle(.link)
                            } else {
                                Text(path).font(.callout.monospaced()).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                switch issue.fix {
                case let .edits(edits, summary)?:
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(summary)
                            Text(lines(edits))
                                .font(.caption.monospaced()).foregroundStyle(.secondary)
                            HStack {
                                Text("Nothing goes live until you publish.").font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Button("Fix") { model.applyFix(issue) }.buttonStyle(.borderedProminent)
                            }
                        }
                        .padding(4)
                    }
                case .openSettings?:
                    Button("Open Settings") { model.sidebarSelection = .settings }
                case nil:
                    EmptyView()
                }
            }
            .padding(24)
            .frame(maxWidth: 640, alignment: .leading)
        }
    }
}
