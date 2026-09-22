import SwiftUI

struct FavouritesView: View {
    @ObservedObject var app: AppModel
    @ObservedObject var model: BrowseModel
    @State private var selection: Channel?
    @State private var pending: Channel?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack {
                        Text("Your saved channels").font(.title2.bold())
                        Spacer()
                        Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.loadFavourites() } }
                    }
                    if let error = model.favouritesError {
                        RetryBanner(message: error) { Task { await model.loadFavourites() } }
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 270), spacing: 22)], spacing: 22) {
                        ForEach(model.favourites) { channel in
                            Button { selection = channel } label: { ChannelCard(channel: channel, client: model.client, logo: model.logo(for: channel)) }
                                .buttonStyle(PigSurfaceButtonStyle(drawSurface: false, cornerRadius: 22))
                        }
                    }
                    if model.favouritesBusy { ProgressView("Loading favourites…") }
                    if model.favourites.isEmpty && !model.favouritesBusy && model.favouritesError == nil {
                        ContentUnavailableView("Keep your channels close", systemImage: "heart",
                            description: Text("Open a channel in Live TV and add it to your favourites. They are saved to your PigTV account."))
                    }
                }.padding(32)
            }
            .navigationTitle("Favourites")
            .task { await model.loadFavourites() }
            .fullScreenCover(item: $selection, onDismiss: {
                if let channel = pending { pending = nil; app.beginPlayback(channel) }
                Task { await model.loadFavourites() }
            }) { channel in
                ChannelDetails(channel: channel, browse: model) {
                    pending = channel
                    selection = nil
                }
            }
        }
    }
}

struct FavouriteControl: View {
    let channel: Channel
    let client: APIClient
    @State private var saved: Bool?
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let saved {
                Button(saved ? "Remove from favourites" : "Add to favourites",
                       systemImage: saved ? "heart.fill" : "heart") {
                    Task { await change(!saved) }
                }.disabled(busy)
            } else if busy {
                ProgressView("Checking favourite…")
            } else {
                Button("Check favourite status") { Task { await check() } }
            }
            if let error { Text(error).font(.callout).foregroundStyle(.secondary) }
        }.task { await check() }
    }

    private func check() async {
        guard !busy else { return }
        busy = true
        error = nil
        defer { busy = false }
        do {
            let result: FavouriteCheck = try await client.request("favorites/check", query: [
                URLQueryItem(name: "sourceId", value: String(channel.sourceId)),
                URLQueryItem(name: "itemId", value: channel.rawID),
                URLQueryItem(name: "itemType", value: "channel")
            ])
            saved = result.isFavorite
        } catch { self.error = error.localizedDescription }
    }

    private func change(_ value: Bool) async {
        guard !busy else { return }
        busy = true
        error = nil
        defer { busy = false }
        do {
            let result: ActionResult = try await client.request("favorites", method: value ? "POST" : "DELETE",
                body: FavouriteBody(sourceId: channel.sourceId, itemId: channel.rawID))
            guard result.success else { throw PigTVError.message("The server did not confirm the favourite change.") }
            saved = value
        } catch { self.error = error.localizedDescription }
    }
}
