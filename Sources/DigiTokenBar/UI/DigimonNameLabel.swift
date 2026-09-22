import SwiftUI

struct DigimonNameItem: Hashable, Sendable {
    let resource: DigimonNameResource
    var suffix = ""
}

/// A plain Text preserves wrapping of joined ability names and all parent typography.
@MainActor
struct DigimonNameText: View {
    let items: [DigimonNameItem]
    let language: AppLanguage
    let names: [DigimonNameResource: [String: String]]
    var failed: Set<DigimonNameResource> = []

    var text: String {
        items.map { item in
            guard let translations = names[item.resource] else {
                return (failed.contains(item.resource)
                        ? DigimonNameLocalization.identifier(item.resource.name) : "…") + item.suffix
            }
            return (language.resolveName(translations)
                    ?? DigimonNameLocalization.identifier(item.resource.name)) + item.suffix
        }.joined(separator: " · ")
    }
    var body: some View { Text(text) }
}

/// Synchronous presentation snapshot: reopening a detail starts with the last translated names.
/// The API client still owns disk caching, request deduplication, and freshness checks.
@MainActor @Observable
final class DigimonNameDisplayStore {
    static let shared = DigimonNameDisplayStore()
    private(set) var names: [DigimonNameResource: [String: String]] = [:]

    func load(_ resource: DigimonNameResource, provider: any DigimonNameProviding) async -> Bool {
        do {
            let translations = try await provider.names(for: resource)
            guard !Task.isCancelled else { return false }
            names[resource] = translations
            return true
        } catch {
            return false
        }
    }
}

/// Only mounted rows fetch names, following the LazyVStack's lazy row creation.
/// Language changes resolve the already-loaded multilingual response without restarting I/O.
@MainActor
struct DigimonNameLabel: View {
    let items: [DigimonNameItem]
    let language: AppLanguage
    var provider: any DigimonNameProviding = DigimonNameClient.shared
    var displayStore = DigimonNameDisplayStore.shared
    @State private var failed: Set<DigimonNameResource> = []

    init(_ kind: DigimonNameResource.Kind, _ name: String, language: AppLanguage, suffix: String = "") {
        items = [DigimonNameItem(resource: .init(kind: kind, name: name), suffix: suffix)]
        self.language = language
    }

    init(items: [DigimonNameItem], language: AppLanguage) {
        self.items = items
        self.language = language
    }

    var body: some View {
        DigimonNameText(items: items, language: language, names: displayStore.names, failed: failed)
            .task(id: items.map(\.resource)) {
                failed.subtract(items.map(\.resource))
                await withTaskGroup(of: (DigimonNameResource, Bool).self) { group in
                    for resource in Set(items.map(\.resource)) {
                        group.addTask { (resource, await displayStore.load(resource, provider: provider)) }
                    }
                    for await (resource, loaded) in group {
                        guard !Task.isCancelled else { return }
                        if !loaded { failed.insert(resource) }
                    }
                }
            }
    }
}
