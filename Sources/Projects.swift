import Foundation

struct Project: Codable, Equatable {
    var name: String
    var path: String

    var url: URL { URL(fileURLWithPath: path) }
}

enum ProjectStore {
    private static let key = "projects"

    static var all: [Project] {
        get {
            guard let data = UserDefaults.standard.data(forKey: key),
                  let list = try? JSONDecoder().decode([Project].self, from: data) else { return [] }
            return list
        }
        set {
            UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: key)
        }
    }

    static func touch(_ project: Project) {
        var list = all.filter { $0.path != project.path }
        list.insert(project, at: 0)
        all = list
    }

    static func remove(_ project: Project) {
        all = all.filter { $0.path != project.path }
    }

    static func rename(_ project: Project, to name: String) {
        all = all.map { $0.path == project.path ? Project(name: name, path: $0.path) : $0 }
    }
}
