import Foundation

enum PluginEvent {
    static let lineMarks = name("lineMarks")
    static let lineMarksRequest = name("lineMarksRequest")
    static let wordMarks = name("wordMarks")
    static let wordMarksRequest = name("wordMarksRequest")
    static let bookmarks = name("bookmarks")
    static let bookmarksRequest = name("bookmarksRequest")
    static let foldMarks = name("foldMarks")
    static let foldMarksRequest = name("foldMarksRequest")
    static let rulerClicked = name("rulerClicked")
    static let gitChanged = name("gitChanged")
    static let externalDiagnostics = name("externalDiagnostics")
    static let lspFiles = name("lspFiles")
    static let lspFilesRequest = name("lspFilesRequest")
    static let hoverShown = name("hoverShown")
    static let completionItems = name("completionItems")

    private static func name(_ id: String) -> Notification.Name { Notification.Name("FlareStackIDE." + id) }
}
