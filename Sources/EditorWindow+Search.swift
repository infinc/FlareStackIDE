import AppKit

extension EditorWindowController {
    func replaceInProject(_ query: String, with replacement: String, options: ProjectSearch.Options) {
        guard let window else { return }
        if let error = saveAll() { return showError(error) }
        let base = baseDirectory
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let plan = ProjectSearch.replacements(query, with: replacement, in: base, options: options)
            DispatchQueue.main.async {
                guard let self else { return }
                let count = plan.reduce(0) { $0 + $1.count }
                guard count > 0 else {
                    Toasts.post("置換する箇所はありません", in: window)
                    return
                }
                let alert = NSAlert()
                alert.messageText = "\(count) 件を置換しますか？"
                alert.informativeText = plan.prefix(12).map { "・\(self.relativePath($0.url))（\($0.count) 件）" }.joined(separator: "\n")
                    + (plan.count > 12 ? "\n…ほか \(plan.count - 12) ファイル" : "")
                alert.addButton(withTitle: "置換")
                alert.addButton(withTitle: "キャンセル")
                alert.beginSheetModal(for: window) { response in
                    guard response == .alertFirstButtonReturn else { return }
                    self.applyReplacements(plan, count: count)
                }
            }
        }
    }

    private func applyReplacements(_ plan: [ProjectSearch.Replacement], count: Int) {
        let paths = Set(plan.map { $0.url.standardizedFileURL.path })
        do {
            let originals = try ProjectSearch.apply(plan)
            reloadExternal(paths)
            Toasts.post("\(count) 件を置換しました", message: "\(originals.count) ファイル", actions: [("元に戻す", { [weak self] in
                guard let self else { return }
                if let error = self.saveAll() { return self.showError(error) }
                do { try ProjectSearch.restore(originals) } catch { self.showError(error) }
                self.reloadExternal(paths)
            })], in: window)
        } catch {
            reloadExternal(paths)
            showError(error)
        }
    }
}
