import SwiftUI

struct AboutView: View {
    @EnvironmentObject var settings: DuoSettings

    private var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }

    var body: some View {
        let desk = settings.desk
        List {
            Section {
                VStack(spacing: 10) {
                    Image(systemName: "book.pages")
                        .font(.system(size: 44, weight: .light))
                        .foregroundStyle(desk.accent)
                    Text(L10n.appName).font(.system(size: 24, weight: .bold, design: .serif))
                    Text("\(L10n.version) \(version)").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            Section {
                Text(L10n.aboutBody).font(.body)
            }
            Section(L10n.duoTitle) {
                Text(L10n.duoBody)
            }
            Section(L10n.supportedFormats) {
                Label("PDF", systemImage: "doc.richtext")
                Label("EPUB", systemImage: "book")
                Label("TXT", systemImage: "doc.plaintext")
                Label("ZIP / CBZ", systemImage: "photo.stack")
                Label("RAR / CBR", systemImage: "photo.stack")
            }
            Section {
                Text(L10n.privacyNote).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle(L10n.about)
        .navigationBarTitleDisplayMode(.inline)
    }
}
