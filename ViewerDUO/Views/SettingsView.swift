import SwiftUI

/// Appearance and reading settings. When `book` is given, per-book overrides are shown too.
struct SettingsView: View {
    @EnvironmentObject var settings: DuoSettings
    @EnvironmentObject var library: Library
    @Environment(\.dismiss) private var dismiss
    var book: Book?
    var showReadingSection = true

    var body: some View {
        let desk = settings.desk
        NavigationStack {
            Form {
                Section(L10n.appearance) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L10n.desk).font(DuoFont.caption(12)).foregroundStyle(.secondary)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(DeskStyle.all) { d in
                                    Swatch(colors: [d.highlight, d.base, d.shadow], label: d.name, selected: d.id == settings.deskID,
                                           accent: desk.accent, ink: Color.primary) {
                                        settings.tap()
                                        settings.deskID = d.id
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L10n.paper).font(DuoFont.caption(12)).foregroundStyle(.secondary)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(PaperStyle.all) { p in
                                    Swatch(colors: [Color(p.background), Color(p.background)], label: p.name, selected: p.id == settings.paperID,
                                           accent: desk.accent, ink: Color.primary) {
                                        settings.tap()
                                        settings.paperID = p.id
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    HStack {
                        Text(L10n.warmth)
                        Slider(value: $settings.warmth, in: 0...1)
                            .tint(desk.accent)
                            .frame(maxWidth: 200)
                    }
                }

                Section(L10n.typography) {
                    Picker(L10n.font, selection: $settings.fontID) {
                        ForEach(FontChoice.allCases) { f in
                            Text(f.name).font(f.swiftUIFont).tag(f.id)
                        }
                    }
                    HStack {
                        Text(L10n.fontSize)
                        Spacer()
                        Text("\(Int(settings.fontSize))").monospacedDigit().foregroundStyle(.secondary)
                        Stepper("", value: $settings.fontSize, in: 11...34, step: 1).labelsHidden()
                    }
                    HStack {
                        Text(L10n.lineSpacing)
                        Slider(value: $settings.lineSpacing, in: 1.3...2.4, step: 0.05).tint(desk.accent)
                    }
                    HStack {
                        Text(L10n.margins)
                        Slider(value: $settings.margin, in: 0.5...1.8, step: 0.05).tint(desk.accent)
                    }
                    Toggle(L10n.vertical, isOn: $settings.verticalText)
                    Toggle(L10n.rtl, isOn: $settings.rightToLeft)
                }

                if let book {
                    Section(L10n.thisBook) {
                        Picker(L10n.rtl, selection: Binding(
                            get: { (currentBook ?? book).rightToLeft.map { $0 ? "on" : "off" } ?? "global" },
                            set: { v in library.setOverrides(book, rightToLeft: v == "global" ? nil : v == "on", verticalText: currentBook?.verticalText) })) {
                            Text(L10n.followGlobal).tag("global")
                            Text(L10n.on).tag("on")
                            Text(L10n.off).tag("off")
                        }
                        if book.format.isReflowable {
                            Picker(L10n.vertical, selection: Binding(
                                get: { (currentBook ?? book).verticalText.map { $0 ? "on" : "off" } ?? "global" },
                                set: { v in library.setOverrides(book, rightToLeft: currentBook?.rightToLeft, verticalText: v == "global" ? nil : v == "on") })) {
                                Text(L10n.followGlobal).tag("global")
                                Text(L10n.on).tag("on")
                                Text(L10n.off).tag("off")
                            }
                        }
                    }
                }

                if showReadingSection {
                    Section(L10n.reading) {
                        Picker(L10n.layout, selection: $settings.layoutMode) {
                            ForEach(LayoutMode.allCases) { m in
                                Label(m.name, systemImage: m.symbol).tag(m)
                            }
                        }
                        Toggle(L10n.coverAlone, isOn: $settings.coverAlone)
                        Toggle(L10n.pageStack, isOn: $settings.pageStack)
                        HStack {
                            Text(L10n.curlSoftness)
                            Slider(value: $settings.curlSoftness, in: 0...1).tint(desk.accent)
                        }
                        Toggle(L10n.haptics, isOn: $settings.haptics)
                        Toggle(L10n.keepAwake, isOn: $settings.keepAwake)
                    }
                }

                Section {
                    NavigationLink(L10n.about) { AboutView() }
                }
            }
            .navigationTitle(L10n.settings)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.done) { dismiss() }
                }
            }
        }
        .tint(desk.accent)
    }

    private var currentBook: Book? {
        guard let book else { return nil }
        return library.book(withID: book.id) ?? book
    }
}
