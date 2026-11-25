//
//  NativeAppsReader.swift
//  Hangar
//
//  Reads the list of native apps the background installer (SideStore) keeps for its widget:
//  widget_data.json plus WidgetIcons/<bundle id>.png in Hangar's app group. Same shape as
//  SideStore/Widget/WidgetData/WidgetModels.swift.
//

import Foundation

struct NativeApp: Codable, Identifiable {
    var name: String
    var bundleIdentifier: String
    var expirationDate: Date
    var refreshedDate: Date
    var tintColorHex: String?
    var id: String { bundleIdentifier }
}

struct NativeAppsSnapshot: Codable {
    var activeApps: [NativeApp]
    var allApps: [NativeApp]
    var lastUpdated: Date
}

enum NativeAppsReader {
    static let fileName = "widget_data.json"

    /// Where the installer may have written widget_data.json. Its hooks map its app group to Hangar's,
    /// but that can be missing after re-signing, so a few fallbacks are checked too.
    static func candidateFolders() -> [URL] {
        var folders: [URL] = []
        if let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: LCSharedUtils.appGroupID()) {
            folders.append(group)
        }
        let doc = LCPath.docPath
        folders.append(doc.appendingPathComponent("SideStore"))
        folders.append(doc.appendingPathComponent("Data/AppGroup/group.com.SideStore.SideStore"))
        folders.append(doc.appendingPathComponent("Data/AppGroup/\(LCSharedUtils.appGroupID())"))
        return folders
    }

    static func find() -> URL? {
        let fm = FileManager.default
        for folder in candidateFolders() {
            let direct = folder.appendingPathComponent(fileName)
            if fm.fileExists(atPath: direct.path) { return direct }
        }
        // Last resort: a shallow search.
        for folder in candidateFolders() {
            guard let e = fm.enumerator(at: folder, includingPropertiesForKeys: nil, options: [.skipsPackageDescendants]) else { continue }
            var checked = 0
            for case let url as URL in e {
                checked += 1
                if checked > 4000 { break }
                if e.level > 5 { e.skipDescendants(); continue }
                if url.lastPathComponent == fileName { return url }
            }
        }
        return nil
    }

    /// The snapshot and the file it came from (its folder also holds WidgetIcons/).
    static func load() -> (NativeAppsSnapshot?, URL?) {
        guard let url = find() else { return (nil, nil) }
        let snapshot = try? JSONDecoder().decode(NativeAppsSnapshot.self, from: Data(contentsOf: url))
        return (snapshot, url)
    }
}
