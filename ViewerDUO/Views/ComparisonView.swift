import SwiftUI

/// Each pane owns a separate reader and controller, so the books keep separate positions.
struct ComparisonView: View {
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var settings: DuoSettings
    let onClose: () -> Void
    @State private var first: Book?
    @State private var second: Book?

    var body: some View {
        Group {
            if let first, let second {
                GeometryReader { geometry in
                    Group {
                        if geometry.size.width >= 700 {
                            HStack(spacing: 1) { pane(first); pane(second) }
                        } else {
                            VStack(spacing: 1) { pane(first); pane(second) }
                        }
                    }
                    .background(Color.black)
                }
            } else {
                NavigationStack {
                    List(library.sorted(by: settings.sortOrder)) { book in
                        Button {
                            if first == nil { first = book }
                            else if first?.id != book.id { second = book }
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(book.title)
                                    if !book.author.isEmpty { Text(book.author).font(.caption).foregroundStyle(.secondary) }
                                }
                                Spacer()
                                if first?.id == book.id { Image(systemName: "checkmark") }
                            }
                        }
                        .disabled(first?.id == book.id)
                    }
                    .navigationTitle(first == nil ? L10n.t("１冊目を選ぶ", "Choose the first book") : L10n.t("２冊目を選ぶ", "Choose the second book"))
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(L10n.cancel) { onClose() }
                        }
                    }
                }
            }
        }
    }

    private func pane(_ book: Book) -> some View {
        ReaderView(book: book, onClose: onClose)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
    }
}
