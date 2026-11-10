import SwiftUI

/// The Sport tab is the front page, whatever the server's flags say; a server without it gets the page's own
/// error or empty state.
struct SportsLandingView: View {
  let app: AppModel
  let browse: BrowseModel
  var body: some View {
    SportFrontView(app: app, browse: browse)
  }
}
