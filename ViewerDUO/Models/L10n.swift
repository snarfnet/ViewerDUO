import Foundation

enum L10n {
    static let isJa: Bool = Locale.preferredLanguages.first?.hasPrefix("ja") ?? false
    static func t(_ ja: String, _ en: String) -> String { isJa ? ja : en }

    static var appName: String { "Viewer DUO" }
    static var library: String { t("ライブラリ", "Library") }
    static var librarySubtitle: String { t("紙のように、めくる。", "Turn pages like paper.") }
    static var addBooks: String { t("本を追加", "Add books") }
    static var importHint: String { t("PDF・EPUB・TXT・ZIP・RAR（CBZ/CBR）に対応", "PDF, EPUB, TXT, ZIP and RAR (CBZ/CBR)") }
    static var emptyTitle: String { t("まだ本がありません", "No books yet") }
    static var emptyBody: String { t("「本を追加」からファイルを取り込んでください。\nPDF / EPUB / TXT / ZIP / RAR", "Tap Add books to import files.\nPDF / EPUB / TXT / ZIP / RAR") }
    static var delete: String { t("削除", "Delete") }
    static var deleteConfirm: String { t("この本を削除しますか？", "Delete this book?") }
    static var deleteMessage: String { t("ライブラリから取り除きます。元のファイルには影響しません。", "It will be removed from the library. The original file is untouched.") }
    static var rename: String { t("名前を変更", "Rename") }
    static var renameTitle: String { t("タイトル", "Title") }
    static var author: String { t("著者", "Author") }
    static var cancel: String { t("キャンセル", "Cancel") }
    static var ok: String { t("OK", "OK") }
    static var done: String { t("完了", "Done") }
    static var settings: String { t("設定", "Settings") }
    static var about: String { t("このアプリについて", "About") }
    static var appearance: String { t("見た目", "Appearance") }
    static var desk: String { t("机", "Desk") }
    static var paper: String { t("紙", "Paper") }
    static var typography: String { t("文字", "Typography") }
    static var font: String { t("書体", "Typeface") }
    static var fontSize: String { t("文字の大きさ", "Text size") }
    static var lineSpacing: String { t("行間", "Line spacing") }
    static var margins: String { t("余白", "Margins") }
    static var reading: String { t("読書", "Reading") }
    static var layout: String { t("レイアウト", "Layout") }
    static var layoutAuto: String { t("自動", "Auto") }
    static var layoutSingle: String { t("単ページ", "Single") }
    static var layoutSpread: String { t("見開き", "Spread") }
    static var rtl: String { t("右開き（縦書き・漫画）", "Right-to-left (vertical text / manga)") }
    static var vertical: String { t("縦書き", "Vertical writing") }
    static var followGlobal: String { t("全体設定に従う", "Follow global setting") }
    static var on: String { t("オン", "On") }
    static var off: String { t("オフ", "Off") }
    static var thisBook: String { t("この本", "This book") }
    static var warmth: String { t("暖色フィルター", "Warm filter") }
    static var haptics: String { t("ページをめくる手応え", "Page-turn haptics") }
    static var keepAwake: String { t("読書中はスリープしない", "Keep screen awake while reading") }
    static var coverAlone: String { t("最初のページを単独で表示", "Show the first page alone") }
    static var pageStack: String { t("ページの厚みを表示", "Show page thickness") }
    static var curlSoftness: String { t("めくりの柔らかさ", "Curl softness") }
    static var back: String { t("ライブラリへ戻る", "Back to library") }
    static var chapters: String { t("目次", "Contents") }
    static var bookmarks: String { t("しおり", "Bookmarks") }
    static var addBookmark: String { t("しおりを挟む", "Add bookmark") }
    static var removeBookmark: String { t("しおりを外す", "Remove bookmark") }
    static var noBookmarks: String { t("しおりはまだありません", "No bookmarks yet") }
    static var noChapters: String { t("目次がありません", "No table of contents") }
    static var search: String { t("検索", "Search") }
    static var searchPlaceholder: String { t("本文を検索", "Search in this book") }
    static var noResults: String { t("見つかりませんでした", "No matches") }
    static var searchUnavailable: String { t("この形式では本文検索を使えません", "Text search is not available for this format") }
    static var page: String { t("ページ", "Page") }
    static var pagesFormat: String { t("%dページ", "%d pages") }
    static var importFailed: String { t("取り込めませんでした", "Import failed") }
    static var importFailedBody: String { t("対応していない形式か、壊れたファイルです。", "Unsupported or damaged file.") }
    static var openFailed: String { t("この本を開けません", "This book cannot be opened") }
    static var loading: String { t("読み込み中…", "Loading…") }
    static var chapterN: String { t("第%d章", "Chapter %d") }
    static var noImages: String { t("画像が見つかりません", "No images found") }
    static var readerHint: String { t("端からドラッグでめくる／中央タップで操作を表示", "Drag from the edge to turn / tap the center for controls") }
    static var sort: String { t("並べ替え", "Sort") }
    static var sortRecent: String { t("最近開いた順", "Recently opened") }
    static var sortTitle: String { t("タイトル順", "Title") }
    static var sortAdded: String { t("追加した順", "Date added") }
    static var version: String { t("バージョン", "Version") }
    static var continueReading: String { t("続きから読む", "Continue reading") }
    static var zoom: String { t("拡大", "Zoom") }
    static var zoomHint: String { t("ピンチで拡大、タップで閉じる", "Pinch to zoom, tap to close") }
    static var duoTitle: String { "iPhone Duo" }
    static var duoBody: String { t("iPhone Duoを開くと、ヒンジを本の背にした見開き表示になります。", "On iPhone Duo the hinge becomes the spine of an open book.") }
    static var supportedFormats: String { t("対応形式", "Formats") }
    static var privacyNote: String { t("本はすべて端末内に保存され、外部へ送信されません。", "Every book stays on your device. Nothing is uploaded.") }
    static var sample: String { t("サンプル", "Sample") }
    static var aboutBody: String {
        t("""
        Viewer DUOは、紙の本をめくる感触をそのまま画面に持ち込んだ書籍ビューアです。

        ページは1枚ずつ物理的な紙としてシミュレートされ、指の動きに合わせて曲がり、影を落とし、手を離すと自然に落ち着きます。

        対応形式：PDF、EPUB、TXT、ZIP/CBZ、RAR/CBR。
        文字の本は、書体・大きさ・行間・縦書きを自由に変えられます。

        本はすべて端末内に保存され、外部へ送信されることはありません。
        """, """
        Viewer DUO brings the feel of turning real paper to the screen.

        Each page is simulated as a physical sheet: it bends with your finger, casts a shadow, and settles naturally when you let go.

        Formats: PDF, EPUB, TXT, ZIP/CBZ, RAR/CBR.
        For text books you can change the typeface, size, line spacing and vertical writing.

        Every book stays on your device. Nothing is uploaded.
        """)
    }
}
