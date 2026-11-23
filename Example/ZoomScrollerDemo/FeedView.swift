import ZoomScroller
import SwiftUI

struct FeedView: View {
    @State private var index = 0

    private var post: FeedPost { FeedCatalog.posts[index] }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ZoomScrollerView(items: FeedCatalog.items, selection: $index,
                             style: .init(overlays: [.dust, .dirt]), allowsVerticalSwipes: true)
                .accessibilityIdentifier("feedCanvas")
                .ignoresSafeArea()

            LinearGradient(colors: [.clear, .black.opacity(0.53)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 188)
                .ignoresSafeArea(edges: .bottom)
                .allowsHitTesting(false)
                .accessibilityHidden(true)

            VStack(spacing: 8) {
                PostLikeButton(id: post.id)
                    .id(post.id)
                ShareLink(item: post.source) {
                    RailIcon("paperplane")
                }
                .accessibilityLabel("Share post")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
            .padding(.trailing, 8)
            .padding(.bottom, 8)
        }
        .background(.black)
        .preferredColorScheme(.dark)
        .statusBarHidden()
    }
}

private struct RailIcon: View {
    let symbol: String

    init(_ symbol: String) { self.symbol = symbol }

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 26, weight: .medium))
            .frame(width: 48, height: 44)
            .contentShape(Rectangle())
    }
}

private struct PostLikeButton: View {
    @AppStorage private var liked: Bool

    init(id: String) {
        _liked = AppStorage(wrappedValue: false, "zoomscrollerdemo.liked.\(id)")
    }

    var body: some View {
        Button { liked.toggle() } label: {
            RailIcon(liked ? "heart.fill" : "heart")
                .foregroundStyle(liked ? .pink : .white)
        }
        .accessibilityLabel(liked ? "Unlike post" : "Like post")
    }
}
