import SwiftUI

@main
struct ViewerDUOApp: App {
    @StateObject private var library = Library()
    @StateObject private var settings = DuoSettings()

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environmentObject(library)
                .environmentObject(settings)
                .tint(settings.desk.accent)
                .onOpenURL { url in
                    library.importFile(from: url)
                }
        }
    }
}
