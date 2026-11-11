import SwiftUI
import UIKit

struct ReaderView: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var settings: DuoSettings
    @StateObject private var controller = CurlController()
    @StateObject private var autoReader = AutoReader()
    @Environment(\.scenePhase) private var scenePhase

    let book: Book
    let onClose: () -> Void
    @State private var chromeVisible = true
    @State private var showSettings = false
    @State private var showContents = false
    @State private var showSearch = false
    @State private var zoomImage: UIImage?
    @State private var showHint = false
    /// Overrides the usual hint text for one flash (read-aloud messages).
    @State private var hintText: String?
    @State private var sliderValue: Double = 0
    @State private var sliderDragging = false
    /// Start of the reading time not yet added to the book.
    @State private var clockStart: Date?

    private var liveBook: Book { library.book(withID: book.id) ?? book }
    private var rtl: Bool { liveBook.rightToLeft ?? settings.rightToLeft }
    private var vertical: Bool { liveBook.verticalText ?? settings.verticalText }
    private var slide: Bool { (liveBook.turnStyle ?? settings.turnStyle) == "slide" }
    private var layout: LayoutMode { liveBook.layoutOverride.flatMap(LayoutMode.init(rawValue:)) ?? settings.layoutMode }

    private var textStyle: TextStyle {
        var s = settings.textStyle
        s.vertical = vertical
        s.title = liveBook.title
        s.trimMargins = liveBook.trimMargins ?? false
        return s
    }

    var body: some View {
        let desk = settings.desk
        ZStack {
            DeskBackground(desk: desk)
            PageCurlView(controller: controller)
                .padding(.horizontal, 4)
                .padding(.top, 6)
                .padding(.bottom, 6)
            if settings.warmth > 0.01 {
                Color(red: 1.0, green: 0.62, blue: 0.25)
                    .opacity(settings.warmth * 0.28)
                    .blendMode(.multiply)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }
            VStack(spacing: 0) {
                if chromeVisible {
                    topBar(desk)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                Spacer()
                if chromeVisible {
                    bottomBar(desk)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)
            .padding(.bottom, 8)
            .animation(.easeInOut(duration: 0.22), value: chromeVisible)

            if controller.isLoading {
                loadingOverlay(desk)
            } else if controller.failed {
                failedOverlay(desk)
            }
            if showHint {
                hintPill(desk)
            }
            if let img = zoomImage {
                ZoomOverlay(image: img) { zoomImage = nil }
                    .transition(.opacity)
                    .zIndex(20)
            }
        }
        .statusBarHidden(!chromeVisible)
        .preferredColorScheme(desk.isDark ? .dark : .light)
        .onAppear {
            configureController()
            library.markOpened(book)
            controller.open(book: book, url: library.fileURL(for: book), startPage: book.lastPage, startOffset: book.lastOffset)
            UIApplication.shared.isIdleTimerDisabled = settings.keepAwake
            if !ScreenshotMode.isActive { clockStart = Date() }
            if ScreenshotMode.target == "reader" || ScreenshotMode.target == "slide" {
                scheduleDemoCurl(attempt: 0)
            } else if !UserDefaults.standard.bool(forKey: "readerHintShown") {
                UserDefaults.standard.set(true, forKey: "readerHintShown")
                withAnimation { showHint = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) { withAnimation { showHint = false } }
            }
        }
        .onDisappear {
            autoReader.stop()
            UIApplication.shared.isIdleTimerDisabled = false
            controller.stopAnimating()
            savePosition(stopClock: true)
        }
        .onReceive(controller.$page) { p in
            if !sliderDragging { sliderValue = Double(p) }
            // $page fires before the controller stores the new value; reading controller.page here saved the
            // previous page (opening a PDF at page 50 wrote page 0 until the next turn).
            DispatchQueue.main.async { savePosition() }
            autoReader.controllerMoved()
        }
        .onChange(of: autoReader.mode) { _, mode in
            UIApplication.shared.isIdleTimerDisabled = settings.keepAwake || mode != .off
        }
        .onChange(of: scenePhase) { _, phase in
            // No background audio: speech and timers stop with the app instead of losing their place.
            if phase == .background { autoReader.stop() }
            // Save on the way out: an app closed from the switcher never gets onDisappear.
            if phase != .active { savePosition(stopClock: true) }
            else if clockStart == nil, !ScreenshotMode.isActive { clockStart = Date() }
        }
        .onReceive(controller.$pageCount) { _ in savePosition() }
        .onChange(of: settings.layoutMode) { _, _ in pushSettings() }
        .onChange(of: settings.fontID) { _, _ in pushSettings() }
        .onChange(of: settings.fontSize) { _, _ in pushSettings() }
        .onChange(of: settings.lineSpacing) { _, _ in pushSettings() }
        .onChange(of: settings.margin) { _, _ in pushSettings() }
        .onChange(of: settings.paperID) { _, _ in pushSettings() }
        .onChange(of: settings.verticalText) { _, _ in pushSettings() }
        .onChange(of: settings.rightToLeft) { _, _ in pushSettings() }
        .onChange(of: settings.coverAlone) { _, _ in pushSettings() }
        .onChange(of: settings.pageStack) { _, _ in pushSettings() }
        .onChange(of: settings.curlSoftness) { _, _ in pushSettings() }
        .onChange(of: settings.turnStyle) { _, _ in pushSettings() }
        .onChange(of: liveBook) { _, _ in pushSettings() }
        .onChange(of: settings.keepAwake) { _, v in UIApplication.shared.isIdleTimerDisabled = v }
        .sheet(isPresented: $showSettings) {
            SettingsView(book: liveBook)
                .environmentObject(settings)
                .environmentObject(library)
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showContents) {
            ContentsSheet(book: liveBook, chapters: controller.chapters, currentPage: controller.page,
                          currentOffset: controller.currentOffset, isReflowable: book.format.isReflowable) { page, offset in
                showContents = false
                if book.format.isReflowable, let offset { controller.goTo(offset: offset) } else { controller.goTo(page: page) }
            }
            .environmentObject(settings)
            .environmentObject(library)
        }
        .sheet(isPresented: $showSearch) {
            SearchSheet(controller: controller) { page in
                showSearch = false
                controller.goTo(page: page)
            }
            .environmentObject(settings)
        }
    }

    // MARK: - Wiring

    /// Screenshot mode: freeze a half-turned page once the book has finished loading.
    private func scheduleDemoCurl(attempt: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + (attempt == 0 ? 2.0 : 0.5)) {
            if controller.isLoading || controller.source == nil {
                if attempt < 12 { scheduleDemoCurl(attempt: attempt + 1) }
                return
            }
            if ScreenshotMode.target == "slide" { controller.freezeDemoSlide() } else { controller.freezeDemoCurl() }
        }
    }

    private func configureController() {
        controller.onCenterTap = { withAnimation { chromeVisible.toggle() } }
        controller.onTurnBegan = { settings.tap() }
        controller.onTurnCommitted = { settings.pageTurned() }
        controller.onBlocked = { settings.thud() }
        autoReader.onNothingToRead = { flashHint(L10n.nothingToRead) }
        controller.onDoubleTap = { page in
            controller.renderForZoom(page: page) { img in
                if let img { withAnimation { zoomImage = img } }
            }
        }
        pushSettings()
    }

    private func pushSettings() {
        controller.applySettings(layoutMode: layout, rightToLeft: rtl, style: textStyle,
                                 coverAlone: settings.coverAlone, showStack: settings.pageStack, softness: CGFloat(settings.curlSoftness),
                                 slide: slide)
    }

    private func flashHint(_ text: String? = nil) {
        hintText = text
        withAnimation { showHint = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
            withAnimation { showHint = false }
            hintText = nil
        }
    }

    private func startReadAloud() {
        settings.tap()
        autoReader.rate = Float(settings.speechRate)
        autoReader.startSpeech(controller: controller)
        withAnimation { chromeVisible = false }
        flashHint(L10n.readingAloudHint)
    }

    private func startAutoTurn(_ seconds: Int) {
        settings.tap()
        autoReader.startTimer(controller: controller, interval: TimeInterval(seconds))
        withAnimation { chromeVisible = false }
        flashHint(L10n.autoTurnHint)
    }

    @ViewBuilder
    private func autoReadButton(_ desk: DeskStyle) -> some View {
        if autoReader.isActive {
            ChromeButton(desk: desk, systemName: "stop.fill", size: 36, active: true) {
                settings.tap()
                autoReader.stop()
            }
            .accessibilityLabel(L10n.stopAuto)
        } else {
            Menu {
                if controller.supportsSpeech {
                    Button { startReadAloud() } label: { Label(L10n.readAloud, systemImage: "speaker.wave.2") }
                }
                Section(L10n.autoTurn) {
                    ForEach([5, 10, 20, 30, 60], id: \.self) { s in
                        Button { startAutoTurn(s) } label: { Text(String(format: L10n.everyNSeconds, s)) }
                    }
                }
            } label: {
                Image(systemName: "play.fill")
                    .font(.system(size: 36 * 0.42, weight: .medium))
                    .foregroundStyle(desk.ink.opacity(0.92))
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(.ultraThinMaterial))
                    .overlay(Circle().stroke(desk.ink.opacity(0.12), lineWidth: 0.6))
            }
            .disabled(controller.isLoading || controller.failed)
            .accessibilityLabel(L10n.autoRead)
        }
    }

    private func savePosition(stopClock: Bool = false) {
        // Reading time: the stretch since the last save, at most 10 minutes so a book left open on the desk
        // does not count as hours of reading.
        var seconds: Double = 0
        if let start = clockStart {
            seconds = min(max(0, Date().timeIntervalSince(start)), 600)
            clockStart = stopClock ? nil : Date()
        }
        guard !controller.isLoading, controller.source != nil else {
            if seconds > 0 { library.addReadingTime(book, seconds: seconds) }
            return
        }
        library.update(book, page: controller.page, offset: controller.currentOffset, pageCount: controller.pageCount,
                       readingSeconds: seconds)
    }

    private var isBookmarked: Bool {
        let b = liveBook
        if book.format.isReflowable {
            let off = controller.currentOffset
            let next = controller.page + 1 < controller.pageCount ? controller.source?.offset(forPage: controller.page + 1) ?? Int.max : Int.max
            return b.bookmarks.contains { $0.offset >= off && $0.offset < next }
        }
        return b.bookmarks.contains { $0.page == controller.page }
    }

    private func toggleBookmark() {
        settings.tap()
        let label = controller.chapters.last(where: { $0.page <= controller.page })?.title ?? String(format: "%@ %d", L10n.page, controller.page + 1)
        if book.format.isReflowable, isBookmarked, let existing = liveBook.bookmarks.first(where: { bm in
            let next = controller.page + 1 < controller.pageCount ? controller.source?.offset(forPage: controller.page + 1) ?? Int.max : Int.max
            return bm.offset >= controller.currentOffset && bm.offset < next
        }) {
            library.removeBookmark(book, id: existing.id)
            return
        }
        library.toggleBookmark(book, page: controller.page, offset: controller.currentOffset, label: label)
    }

    // MARK: - Bars

    private func topBar(_ desk: DeskStyle) -> some View {
        ChromeBar(desk: desk) {
            HStack(spacing: 10) {
                ChromeButton(desk: desk, systemName: "chevron.left", size: 38) {
                    settings.tap()
                    savePosition()
                    onClose()
                }
                .accessibilityLabel(L10n.back)
                VStack(spacing: 1) {
                    Text(liveBook.title)
                        .font(DuoFont.title(15))
                        .foregroundStyle(desk.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    HStack(spacing: 6) {
                        Text(book.format.label)
                            .font(.system(size: 9, weight: .bold, design: .rounded)).tracking(1.5)
                        if let ch = controller.chapters.last(where: { $0.page <= controller.page }) {
                            Text("·").font(.system(size: 9))
                            Text(ch.title).font(DuoFont.caption(10)).lineLimit(1)
                        }
                    }
                    .foregroundStyle(desk.ink.opacity(0.6))
                }
                .frame(maxWidth: .infinity)
                ChromeButton(desk: desk, systemName: isBookmarked ? "bookmark.fill" : "bookmark", size: 38, active: isBookmarked) { toggleBookmark() }
                    .accessibilityLabel(isBookmarked ? L10n.removeBookmark : L10n.addBookmark)
                ChromeButton(desk: desk, systemName: "magnifyingglass", size: 38, disabled: !controller.supportsSearch) {
                    settings.tap()
                    showSearch = true
                }
                .accessibilityLabel(L10n.search)
            }
        }
    }

    private func bottomBar(_ desk: DeskStyle) -> some View {
        ChromeBar(desk: desk) {
            VStack(spacing: 6) {
                HStack(spacing: 10) {
                    ChromeButton(desk: desk, systemName: rtl ? "chevron.right" : "chevron.left", size: 36, disabled: !controller.previousPageAvailable()) {
                        _ = controller.turn(direction: -1)
                    }
                    .accessibilityLabel(L10n.previousPage)
                    Slider(value: $sliderValue, in: 0...Double(max(1, controller.pageCount - 1)), step: 1, onEditingChanged: { editing in
                        sliderDragging = editing
                        if !editing { controller.goTo(page: Int(sliderValue.rounded())) }
                    })
                    .tint(desk.accent)
                    .environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight)
                    ChromeButton(desk: desk, systemName: rtl ? "chevron.left" : "chevron.right", size: 36, disabled: !controller.nextPageAvailable()) {
                        _ = controller.turn(direction: 1)
                    }
                    .accessibilityLabel(L10n.nextPage)
                }
                HStack(spacing: 12) {
                    Text("\(Int(sliderValue) + 1) / \(controller.pageCount)")
                        .font(DuoFont.caption(13)).monospacedDigit()
                        .foregroundStyle(desk.ink.opacity(0.85))
                        .frame(minWidth: 70, alignment: .leading)
                    Spacer()
                    autoReadButton(desk)
                    ChromeButton(desk: desk, systemName: "list.bullet", size: 36) { settings.tap(); showContents = true }
                        .accessibilityLabel(L10n.chapters)
                    ChromeButton(desk: desk, systemName: "rectangle.split.2x1", size: 36, active: slide) {
                        // Per-book switch: picture books can slide while novels keep the paper curl.
                        settings.tap()
                        let turningOn = !slide
                        library.setTurnStyle(liveBook, turningOn ? "slide" : "curl")
                        if turningOn { flashHint() }
                    }
                    .accessibilityLabel(L10n.turnSlide)
                    ChromeButton(desk: desk, systemName: layout.symbol, size: 36, active: layout != .auto, disabled: slide) {
                        settings.tap()
                        let all = LayoutMode.allCases
                        let i = all.firstIndex(of: layout) ?? 0
                        library.setLayoutOverride(liveBook, all[(i + 1) % all.count])
                    }
                    .accessibilityLabel(L10n.layout)
                    .accessibilityValue(layout.name)
                    ChromeButton(desk: desk, systemName: "textformat.size", size: 36) { settings.tap(); showSettings = true }
                        .accessibilityLabel(L10n.settings)
                }
            }
        }
    }

    // MARK: - Overlays

    private func loadingOverlay(_ desk: DeskStyle) -> some View {
        VStack(spacing: 12) {
            ProgressView().tint(desk.accent).scaleEffect(1.2)
            Text(L10n.loading).font(DuoFont.body(13)).foregroundStyle(desk.ink.opacity(0.8))
        }
        .padding(22)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.ultraThinMaterial))
        .allowsHitTesting(false)
    }

    private func failedOverlay(_ desk: DeskStyle) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "book.closed").font(.system(size: 36)).foregroundStyle(desk.accent)
            Text(L10n.openFailed).font(DuoFont.body(14)).foregroundStyle(desk.ink)
        }
        .padding(26)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.ultraThinMaterial))
    }

    private func hintPill(_ desk: DeskStyle) -> some View {
        VStack {
            Spacer()
            Text(hintText ?? (slide ? L10n.slideHint : L10n.readerHint))
                .font(DuoFont.caption(12))
                .foregroundStyle(desk.ink)
                .padding(.horizontal, 16).padding(.vertical, 9)
                .background(Capsule().fill(.ultraThinMaterial))
                .padding(.bottom, chromeVisible ? 130 : 40)
        }
        .transition(.opacity)
        .allowsHitTesting(false)
    }
}

// MARK: - Contents / bookmarks

struct ContentsSheet: View {
    @EnvironmentObject var settings: DuoSettings
    @EnvironmentObject var library: Library
    @Environment(\.dismiss) private var dismiss
    let book: Book
    let chapters: [Chapter]
    let currentPage: Int
    let currentOffset: Int
    let isReflowable: Bool
    let onSelect: (Int, Int?) -> Void
    @State private var tab = 0
    @State private var editingBookmark: Bookmark?

    private var liveBook: Book { library.book(withID: book.id) ?? book }

    var body: some View {
        let desk = settings.desk
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $tab) {
                    Text(L10n.chapters).tag(0)
                    Text(L10n.bookmarks).tag(1)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                if tab == 0 {
                    if chapters.isEmpty {
                        emptyState(L10n.noChapters, symbol: "list.bullet")
                    } else {
                        List {
                            ForEach(chapters) { ch in
                                Button { onSelect(ch.page, nil) } label: {
                                    HStack {
                                        Text(ch.title)
                                            .padding(.leading, CGFloat(ch.depth) * 16)
                                            .lineLimit(2)
                                        Spacer()
                                        Text("\(ch.page + 1)").foregroundStyle(.secondary).monospacedDigit()
                                    }
                                    .foregroundStyle(ch.id == activeChapter?.id ? desk.accent : Color.primary)
                                }
                            }
                        }
                        .listStyle(.plain)
                    }
                } else {
                    if liveBook.bookmarks.isEmpty {
                        emptyState(L10n.noBookmarks, symbol: "bookmark")
                    } else {
                        List {
                            ForEach(liveBook.bookmarks) { bm in
                                HStack {
                                    Button { onSelect(bm.page, isReflowable ? bm.offset : nil) } label: {
                                      HStack {
                                        Image(systemName: "bookmark.fill").foregroundStyle(desk.accent)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(bm.label).lineLimit(1)
                                            if let note = bm.note, !note.isEmpty {
                                                Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                            }
                                            Text(bm.createdAt.formatted(date: .abbreviated, time: .shortened))
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        if !isReflowable {
                                            Text("\(bm.page + 1)").foregroundStyle(.secondary).monospacedDigit()
                                        }
                                      }
                                      .foregroundStyle(Color.primary)
                                    }.buttonStyle(.borderless)
                                    Button { editingBookmark = bm } label: { Image(systemName: "square.and.pencil") }
                                        .buttonStyle(.borderless)
                                        .accessibilityLabel(L10n.t("しおりのメモを編集", "Edit bookmark note"))
                                }
                            }
                            .onDelete { idx in
                                // Take the ids first: liveBook shrinks after each removal, so later indices would point
                                // at the wrong bookmark or past the end.
                                let marks = liveBook.bookmarks
                                let ids = idx.compactMap { $0 < marks.count ? marks[$0].id : nil }
                                for id in ids { library.removeBookmark(book, id: id) }
                            }
                        }
                        .listStyle(.plain)
                    }
                }
            }
            .navigationTitle(liveBook.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(L10n.done) { dismiss() } }
            }
            .sheet(item: $editingBookmark) { bookmark in
                BookmarkNoteSheet(bookmark: bookmark) { note in
                    library.setBookmarkNote(book, id: bookmark.id, note: note)
                }
            }
        }
        .tint(desk.accent)
    }

    private var activeChapter: Chapter? { chapters.last(where: { $0.page <= currentPage }) }

    private func emptyState(_ text: String, symbol: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 34)).foregroundStyle(.secondary)
            Text(text).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct BookmarkNoteSheet: View {
    @Environment(\.dismiss) private var dismiss
    let bookmark: Bookmark
    let onSave: (String) -> Void
    @State private var note = ""

    var body: some View {
        NavigationStack {
            TextEditor(text: $note)
                .padding()
                .navigationTitle(L10n.t("しおりのメモ", "Bookmark note"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button(L10n.cancel) { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L10n.done) { onSave(note); dismiss() }
                    }
                }
                .onAppear { note = bookmark.note ?? "" }
                .onChange(of: note) { _, newValue in
                    if newValue.count > 2000 { note = String(newValue.prefix(2000)) }
                }
        }
    }
}

// MARK: - Search

struct SearchSheet: View {
    @EnvironmentObject var settings: DuoSettings
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var controller: CurlController
    let onSelect: (Int) -> Void
    @State private var query = ""
    @State private var results: [SearchHit] = []
    @State private var searched = false
    @State private var searching = false
    @FocusState private var focused: Bool

    var body: some View {
        let desk = settings.desk
        NavigationStack {
            VStack(spacing: 0) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(L10n.searchPlaceholder, text: $query)
                        .focused($focused)
                        .submitLabel(.search)
                        .onSubmit { run() }
                    if !query.isEmpty {
                        Button { query = ""; results = []; searched = false } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground)))
                .padding(16)
                if searching {
                    ProgressView().padding()
                    Spacer()
                } else if !controller.supportsSearch {
                    Text(L10n.searchUnavailable).foregroundStyle(.secondary).padding()
                    Spacer()
                } else if searched && results.isEmpty {
                    Text(L10n.noResults).foregroundStyle(.secondary).padding()
                    Spacer()
                } else {
                    List(results) { hit in
                        Button { onSelect(hit.page) } label: {
                            HStack(alignment: .top) {
                                Text(hit.snippet).font(.subheadline).lineLimit(3).foregroundStyle(Color.primary)
                                Spacer()
                                Text("\(hit.page + 1)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle(L10n.search)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(L10n.done) { dismiss() } }
            }
            .onAppear { focused = true }
        }
        .tint(desk.accent)
    }

    private func run() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        searching = true
        controller.search(q) { hits in
            results = hits
            searched = true
            searching = false
        }
    }
}

// MARK: - Zoom

struct ZoomOverlay: View {
    let image: UIImage
    let onClose: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.92).ignoresSafeArea()
            ZoomableImage(image: image, onTap: onClose)
                .ignoresSafeArea()
            VStack {
                Spacer()
                Text(L10n.zoomHint)
                    .font(DuoFont.caption(12))
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Capsule().fill(.ultraThinMaterial))
                    .padding(.bottom, 30)
            }
            .allowsHitTesting(false)
        }
    }
}

struct ZoomableImage: UIViewRepresentable {
    let image: UIImage
    let onTap: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onTap: onTap) }

    func makeUIView(context: Context) -> UIScrollView {
        let sv = UIScrollView()
        sv.delegate = context.coordinator
        sv.minimumZoomScale = 1
        sv.maximumZoomScale = 5
        sv.showsVerticalScrollIndicator = false
        sv.showsHorizontalScrollIndicator = false
        sv.backgroundColor = .clear
        let iv = UIImageView(image: image)
        iv.contentMode = .scaleAspectFit
        iv.frame = sv.bounds
        iv.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        sv.addSubview(iv)
        context.coordinator.imageView = iv
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped))
        sv.addGestureRecognizer(tap)
        let dbl = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTapped(_:)))
        dbl.numberOfTapsRequired = 2
        sv.addGestureRecognizer(dbl)
        tap.require(toFail: dbl)
        return sv
    }

    func updateUIView(_ sv: UIScrollView, context: Context) {
        // Resetting the frame while zoomed in threw the reader back to the unzoomed picture.
        guard sv.zoomScale <= 1.001 else { return }
        context.coordinator.imageView?.frame = CGRect(origin: .zero, size: sv.bounds.size)
        sv.contentSize = sv.bounds.size
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        let onTap: () -> Void
        weak var imageView: UIImageView?
        init(onTap: @escaping () -> Void) { self.onTap = onTap }
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
        @objc func tapped() { onTap() }
        @objc func doubleTapped(_ g: UITapGestureRecognizer) {
            guard let sv = g.view as? UIScrollView else { return }
            if sv.zoomScale > 1.1 {
                sv.setZoomScale(1, animated: true)
            } else {
                let p = g.location(in: imageView)
                let w = sv.bounds.width / 2.5, h = sv.bounds.height / 2.5
                sv.zoom(to: CGRect(x: p.x - w / 2, y: p.y - h / 2, width: w, height: h), animated: true)
            }
        }
    }
}
