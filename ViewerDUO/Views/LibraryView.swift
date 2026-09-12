import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var settings: DuoSettings
    @State private var showImporter = false
    @State private var showSettings = false
    @State private var openBook: Book?
    @State private var renameTarget: Book?
    @State private var deleteTarget: Book?
    @State private var importFailed = false
    @State private var query = ""

    private var importTypes: [UTType] {
        var t: [UTType] = [.pdf, .epub, .plainText, .text, .zip, .archive]
        for id in ["com.rarlab.rar-archive", "com.tokyonasu.cbz", "com.tokyonasu.cbr"] {
            if let u = UTType(id) { t.append(u) }
        }
        return t
    }

    private var books: [Book] {
        let all = library.sorted(by: settings.sortOrder)
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return all }
        return all.filter { $0.title.localizedCaseInsensitiveContains(q) || $0.author.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        let desk = settings.desk
        ZStack {
            DeskBackground(desk: desk)
            VStack(spacing: 0) {
                header(desk)
                if library.books.isEmpty {
                    emptyState(desk)
                } else {
                    ScrollView {
                        VStack(spacing: 18) {
                            if let recent = library.mostRecent, query.isEmpty, settings.sortOrder == "recent" {
                                continueCard(recent, desk: desk)
                            }
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 128, maximum: 170), spacing: 16)], spacing: 22) {
                                ForEach(books) { book in
                                    BookCard(book: book, desk: desk, coverVersion: library.coverVersion)
                                        .onTapGesture {
                                            settings.tap()
                                            withAnimation(.easeInOut(duration: 0.3)) { openBook = book }
                                        }
                                        .contextMenu {
                                            Button { renameTarget = book } label: { Label(L10n.rename, systemImage: "pencil") }
                                            Button(role: .destructive) { deleteTarget = book } label: { Label(L10n.delete, systemImage: "trash") }
                                        }
                                }
                            }
                            .padding(.horizontal, 18)
                            .padding(.bottom, 110)
                        }
                        .padding(.top, 6)
                    }
                }
            }
            VStack {
                Spacer()
                addButton(desk)
                    .padding(.bottom, 18)
            }
            if let book = openBook {
                // Presented inline rather than as a cover so the reader owns the whole window on every device.
                ReaderView(book: book) {
                    withAnimation(.easeInOut(duration: 0.3)) { openBook = nil }
                }
                .environmentObject(library)
                .environmentObject(settings)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(5)
            }
        }
        .preferredColorScheme(desk.isDark ? .dark : .light)
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(settings)
                .environmentObject(library)
        }
        .sheet(item: $renameTarget) { book in
            RenameSheet(book: book)
                .environmentObject(library)
                .environmentObject(settings)
                .presentationDetents([.height(260)])
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: importTypes, allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            var failed = false
            for u in urls where library.importFile(from: u) == nil { failed = true }
            importFailed = failed
        }
        .alert(L10n.importFailed, isPresented: $importFailed) {
            Button(L10n.ok, role: .cancel) {}
        } message: {
            Text(L10n.importFailedBody)
        }
        .alert(L10n.deleteConfirm, isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })) {
            Button(L10n.delete, role: .destructive) {
                if let b = deleteTarget { library.delete(b) }
                deleteTarget = nil
            }
            Button(L10n.cancel, role: .cancel) { deleteTarget = nil }
        } message: {
            Text(L10n.deleteMessage)
        }
        .onAppear {
            if ScreenshotMode.target == "reader", let first = library.sorted(by: "added").first {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { openBook = first }
            }
        }
    }

    // MARK: - Pieces

    private func header(_ desk: DeskStyle) -> some View {
        VStack(spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.appName)
                        .font(.system(size: 30, weight: .bold, design: .serif))
                        .foregroundStyle(desk.ink)
                    Text(L10n.librarySubtitle)
                        .font(DuoFont.caption(12))
                        .foregroundStyle(desk.ink.opacity(0.6))
                }
                Spacer()
                Menu {
                    Picker(L10n.sort, selection: $settings.sortOrder) {
                        Text(L10n.sortRecent).tag("recent")
                        Text(L10n.sortTitle).tag("title")
                        Text(L10n.sortAdded).tag("added")
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(desk.ink.opacity(0.9))
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(.ultraThinMaterial))
                }
                ChromeButton(desk: desk, systemName: "gearshape", size: 38) {
                    settings.tap()
                    showSettings = true
                }
            }
            if library.books.count > 6 {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(desk.ink.opacity(0.5))
                    TextField(L10n.search, text: $query)
                        .foregroundStyle(desk.ink)
                        .textFieldStyle(.plain)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.ultraThinMaterial))
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    private func continueCard(_ book: Book, desk: DeskStyle) -> some View {
        Button {
            settings.tap()
            withAnimation(.easeInOut(duration: 0.3)) { openBook = book }
        } label: {
            HStack(spacing: 14) {
                CoverImage(book: book, version: library.coverVersion)
                    .frame(width: 58, height: 82)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .shadow(color: .black.opacity(0.35), radius: 6, y: 3)
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.continueReading)
                        .font(DuoFont.caption(11)).tracking(1)
                        .foregroundStyle(desk.accent)
                    Text(book.title)
                        .font(DuoFont.title(16))
                        .foregroundStyle(desk.ink)
                        .lineLimit(2)
                    if book.pageCount > 1 {
                        HStack(spacing: 8) {
                            ProgressView(value: book.progress).tint(desk.accent).frame(maxWidth: 140)
                            Text("\(Int(book.progress * 100))%")
                                .font(DuoFont.caption(11)).monospacedDigit()
                                .foregroundStyle(desk.ink.opacity(0.7))
                        }
                    }
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(desk.ink.opacity(0.5))
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.ultraThinMaterial))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(desk.ink.opacity(0.12), lineWidth: 0.6))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 18)
    }

    private func addButton(_ desk: DeskStyle) -> some View {
        Button {
            settings.tap()
            showImporter = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus")
                Text(L10n.addBooks)
            }
            .font(.system(size: 15, weight: .semibold, design: .rounded))
            .foregroundStyle(desk.isDark ? Color(red: 0.15, green: 0.10, blue: 0.05) : .white)
            .padding(.horizontal, 22).padding(.vertical, 13)
            .background(Capsule().fill(desk.accent))
            .shadow(color: .black.opacity(0.3), radius: 12, y: 5)
        }
        .buttonStyle(.plain)
    }

    private func emptyState(_ desk: DeskStyle) -> some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "books.vertical")
                .font(.system(size: 54, weight: .light))
                .foregroundStyle(desk.accent)
            Text(L10n.emptyTitle).font(DuoFont.title(20)).foregroundStyle(desk.ink)
            Text(L10n.emptyBody)
                .font(DuoFont.body(14))
                .multilineTextAlignment(.center)
                .foregroundStyle(desk.ink.opacity(0.7))
            Spacer()
            Spacer()
        }
        .padding(.horizontal, 30)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Cards

struct CoverImage: View {
    let book: Book
    let version: Int

    var body: some View {
        Group {
            if let img = CoverStore.shared.image(for: book.id) {
                Image(uiImage: img).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color(hue: book.hue, saturation: 0.4, brightness: 0.45)
                    Text(book.title).font(DuoFont.caption(11)).foregroundStyle(.white).padding(6).multilineTextAlignment(.center)
                }
            }
        }
        .id(version)
    }
}

struct BookCard: View {
    let book: Book
    let desk: DeskStyle
    let coverVersion: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ZStack(alignment: .topTrailing) {
                CoverImage(book: book, version: coverVersion)
                    .aspectRatio(0.7, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Color.white.opacity(0.18), lineWidth: 0.6))
                    .shadow(color: .black.opacity(desk.isDark ? 0.5 : 0.25), radius: 9, y: 5)
                Text(book.format.label)
                    .font(.system(size: 8, weight: .bold, design: .rounded)).tracking(1)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(Capsule().fill(Color.black.opacity(0.55)))
                    .padding(6)
            }
            Text(book.title)
                .font(DuoFont.title(13))
                .foregroundStyle(desk.ink)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !book.author.isEmpty {
                Text(book.author).font(DuoFont.caption(11)).foregroundStyle(desk.ink.opacity(0.6)).lineLimit(1)
            }
            if book.pageCount > 1 {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(desk.ink.opacity(0.15))
                        Capsule().fill(desk.accent).frame(width: max(3, g.size.width * book.progress))
                    }
                }
                .frame(height: 3)
            }
        }
    }
}

// MARK: - Rename

struct RenameSheet: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var settings: DuoSettings
    @Environment(\.dismiss) private var dismiss
    let book: Book
    @State private var title = ""
    @State private var author = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField(L10n.renameTitle, text: $title)
                TextField(L10n.author, text: $author)
            }
            .navigationTitle(L10n.rename)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L10n.cancel) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.ok) {
                        library.rename(book, title: title, author: author)
                        dismiss()
                    }
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                title = book.title
                author = book.author
            }
        }
        .tint(settings.desk.accent)
    }
}
