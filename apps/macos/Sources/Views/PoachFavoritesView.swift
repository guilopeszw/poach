import SwiftUI
import UniformTypeIdentifiers

struct PoachFavoritesView: View {
    @State private var favorites: [PoachFavoriteStore.Favorite] = []
    @State private var pendingDeletion: PoachFavoriteStore.Favorite?
    @State private var copied: CopyFeedback?
    @State private var errorMessage = ""
    private let poachFile = UTType(exportedAs: "dev.poach.handoff", conformingTo: .json)

    private struct CopyFeedback: Equatable {
        let favoriteID: UUID
        let attempt = UUID()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Favorites").font(.system(size: 19, weight: .semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text("Your favorite poached handoffs")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: importHandoff) {
                    Label("Import", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(PoachActionStyle())
                .accessibilityLabel("Import a Poach file")
            }
            if favorites.isEmpty && errorMessage.isEmpty {
                ContentUnavailableView("No favorites yet", systemImage: "bookmark",
                                       description: Text("Bookmark a handoff in the editor to save it here."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !favorites.isEmpty {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(favorites) { favorite in row(favorite) }
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            if !errorMessage.isEmpty {
                Text(errorMessage).font(.caption).foregroundStyle(PoachPalette.errorText)
            }
        }
        .onAppear(perform: reload)
        .task(id: copied) {
            guard copied != nil else { return }
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            copied = nil
        }
        .confirmationDialog("Remove favorite?", isPresented: Binding(
            get: { pendingDeletion != nil },
            set: { if !$0 { pendingDeletion = nil } }
        ), titleVisibility: .visible, presenting: pendingDeletion) { favorite in
            Button("Remove \(favorite.name)", role: .destructive) {
                do {
                    try PoachFavoriteStore.delete(id: favorite.id)
                    reload()
                } catch {
                    errorMessage = "Couldn’t delete the favorite. \(error.localizedDescription)"
                }
            }
        }
    }

    private func row(_ favorite: PoachFavoriteStore.Favorite) -> some View {
        HStack(spacing: 6) {
            Button { copy(favorite) } label: {
                HStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 5).fill(PoachPalette.inset)
                        if let cover = NSImage(contentsOf: favorite.coverURL) {
                            Image(nsImage: cover).resizable().scaledToFit()
                        } else {
                            Image(systemName: "bookmark")
                        }
                    }
                    .frame(width: 62, height: 38)
                    .clipShape(.rect(cornerRadius: 5))
                    .accessibilityHidden(true)
                    Text(favorite.name).font(.subheadline.weight(.medium)).lineLimit(1)
                    Spacer(minLength: 0)
                    if copied?.favoriteID == favorite.id {
                        Label("Copied", systemImage: "checkmark").font(.caption)
                    } else {
                        Image(systemName: "doc.on.doc").foregroundStyle(.secondary)
                    }
                }
                .padding(6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(PoachPalette.panel, in: .rect(cornerRadius: 8))
            .accessibilityLabel(copied?.favoriteID == favorite.id ? "\(favorite.name), Copied" : "Copy \(favorite.name) handoff")
            Menu {
                Button("Export Poach…") { export(favorite) }
                Button("Remove from Favorites", role: .destructive) { pendingDeletion = favorite }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 20, height: 28)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Actions for \(favorite.name)")

        }
    }

    private func export(_ favorite: PoachFavoriteStore.Favorite) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [poachFile]
        panel.nameFieldStringValue = favorite.name.replacingOccurrences(of: "/", with: "-") + ".poach"
        panel.message = "This file includes the saved reference images, notes, and pointer evidence."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try PoachFavoriteStore.export(favorite, to: url)
            errorMessage = ""
        } catch {
            errorMessage = "Couldn’t export the Poach file. \(error.localizedDescription)"
        }
    }

    private func importHandoff() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [poachFile]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Import"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try PoachFavoriteStore.importHandoff(from: url)
            reload()
        } catch {
            errorMessage = "Couldn’t import the Poach file. \(error.localizedDescription)"
        }
    }

    private func reload() {
        do {
            favorites = try PoachFavoriteStore.list()
            errorMessage = ""
        } catch {
            errorMessage = "Couldn’t open favorites. \(error.localizedDescription)"
        }
    }

    private func copy(_ favorite: PoachFavoriteStore.Favorite) {
        do {
            let handoff = try PoachFavoriteStore.prepareHandoff(favorite)
            let id = try PoachHandoff.share(handoff.result, context: handoff.context, annotations: handoff.annotations)
            let message = "Use Poach MCP to call poach_read_brief with briefId \(id). Verify the returned briefId matches. Recreate the UI using its saved reference frames, palette, and notes. This favorite has no original recording. Treat timing as estimated and any pointer events as sampled evidence. Ask about behavior that the saved evidence does not show."
            guard PoachHandoff.copyToClipboard(message) else {
                errorMessage = "Clipboard unavailable. Click the favorite to try again."
                return
            }
            copied = CopyFeedback(favoriteID: favorite.id)
            errorMessage = ""
        } catch {
            errorMessage = "Couldn’t copy the favorite. \(error.localizedDescription)"
        }
    }
}
