import SwiftUI
import UIKit

struct ReaderView: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var settings: DuoSettings
    @StateObject private var controller = CurlController()

    let book: Book
    let onClose: () -> Void
    @State private var chromeVisible = true
    @State private var showSettings = false
    @State private var showContents = false
    @State private var showSearch = false
    @State private var zoomImage: UIImage?
    @State private var showHint = false
    @State private var sliderValue: Double = 0
    @State private var sliderDragging = false

    private var liveBook: Book { library.book(withID: book.id) ?? book }
    private var rtl: Bool { liveBook.rightToLeft ?? settings.rightToLeft }
    private var vertical: Bool { liveBook.verticalText ?? settings.verticalText }

    private var textStyle: TextStyle {
        var s = settings.textStyle
        s.vertical = vertical
        s.title = liveBook.title
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
            if ScreenshotMode.target == "reader" {
                scheduleDemoCurl(attempt: 0)
            } else if !UserDefaults.standard.bool(forKey: "readerHintShown") {
                UserDefaults.standard.set(true, forKey: "readerHintShown")
                withAnimation { showHint = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) { withAnimation { showHint = false } }
            }
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            controller.stopAnimating()
            savePosition()
        }
        .onReceive(controller.$page) { p in
            if !sliderDragging { sliderValue = Double(p) }
            savePosition()
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
        .onChange(of: settings.keepAwake) { _, v in UIApplication.shared.isIdleTimerDisabled = v }
        .onChange(of: liveBook.rightToLeft) { _, _ in pushSettings() }
        .onChange(of: liveBook.verticalText) { _, _ in pushSettings() }
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
            controller.freezeDemoCurl()
        }
    }

    private func configureController() {
        controller.onCenterTap = { withAnimation { chromeVisible.toggle() } }
        controller.onTurnBegan = { settings.tap() }
        controller.onTurnCommitted = { settings.pageTurned() }
        controller.onBlocked = { settings.thud() }
        controller.onDoubleTap = { page in
            controller.renderForZoom(page: page) { img in
                if let img { withAnimation { zoomImage = img } }
            }
        }
        pushSettings()
    }

    private func pushSettings() {
        controller.applySettings(layoutMode: settings.layoutMode, rightToLeft: rtl, style: textStyle,
                                 coverAlone: settings.coverAlone, showStack: settings.pageStack, softness: CGFloat(settings.curlSoftness))
    }

    private func savePosition() {
        guard !controller.isLoading, controller.source != nil else { return }
        library.update(book, page: controller.page, offset: controller.currentOffset, pageCount: controller.pageCount)
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
                ChromeButton(desk: desk, systemName: "magnifyingglass", size: 38, disabled: !controller.supportsSearch) {
                    settings.tap()
                    showSearch = true
                }
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
                    Slider(value: $sliderValue, in: 0...Double(max(1, controller.pageCount - 1)), step: 1, onEditingChanged: { editing in
                        sliderDragging = editing
                        if !editing { controller.goTo(page: Int(sliderValue.rounded())) }
                    })
                    .tint(desk.accent)
                    .environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight)
                    ChromeButton(desk: desk, systemName: rtl ? "chevron.left" : "chevron.right", size: 36, disabled: !controller.nextPageAvailable()) {
                        _ = controller.turn(direction: 1)
                    }
                }
                HStack(spacing: 12) {
                    Text("\(Int(sliderValue) + 1) / \(controller.pageCount)")
                        .font(DuoFont.caption(13)).monospacedDigit()
                        .foregroundStyle(desk.ink.opacity(0.85))
                        .frame(minWidth: 70, alignment: .leading)
                    Spacer()
                    ChromeButton(desk: desk, systemName: "list.bullet", size: 36) { settings.tap(); showContents = true }
                    ChromeButton(desk: desk, systemName: settings.layoutMode.symbol, size: 36, active: settings.layoutMode != .auto) {
                        settings.tap()
                        let all = LayoutMode.allCases
                        let i = all.firstIndex(of: settings.layoutMode) ?? 0
                        settings.layoutMode = all[(i + 1) % all.count]
                    }
                    ChromeButton(desk: desk, systemName: "textformat.size", size: 36) { settings.tap(); showSettings = true }
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
            Text(L10n.readerHint)
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
                                Button { onSelect(bm.page, isReflowable ? bm.offset : nil) } label: {
                                    HStack {
                                        Image(systemName: "bookmark.fill").foregroundStyle(desk.accent)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(bm.label).lineLimit(1)
                                            Text(bm.createdAt.formatted(date: .abbreviated, time: .shortened))
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        if !isReflowable {
                                            Text("\(bm.page + 1)").foregroundStyle(.secondary).monospacedDigit()
                                        }
                                    }
                                    .foregroundStyle(Color.primary)
                                }
                            }
                            .onDelete { idx in
                                for i in idx { library.removeBookmark(book, id: liveBook.bookmarks[i].id) }
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
