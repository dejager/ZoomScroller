import ZoomScroller
import Foundation

struct FeedPost: Identifiable {
    enum Format { case photograph, film }

    let item: ZoomScrollerItem
    let source: URL
    var id: String { item.id }

    init(_ name: String, format: Format, accessibilityTitle: String, source: String) {
        // These static links are authored alongside the bundled collection.
        self.source = URL(string: source)!
        let file = Bundle.main.bundleURL.appendingPathComponent("Media")
            .appendingPathComponent(name).appendingPathExtension(format == .film ? "mp4" : "jpg")
        item = ZoomScrollerItem(id: name, media: format == .film ? .video(file) : .photo(file),
                                label: accessibilityTitle, strokes: [])
    }
}

enum FeedCatalog {
    static let posts = [
        FeedPost("tofino-headland", format: .photograph, accessibilityTitle: "Tofino from above",
                 source: "https://unsplash.com/photos/W3A6PiNOmXw"),
        FeedPost("surf-trim", format: .film, accessibilityTitle: "In trim",
                 source: "https://www.pexels.com/video/surfer-balancing-on-ocean-waves-in-black-and-white-35257447/"),
        FeedPost("tofino-fog", format: .photograph, accessibilityTitle: "Coastal fog",
                 source: "https://unsplash.com/photos/Vn7nOtD9DmQ"),
        FeedPost("surf-lip", format: .film, accessibilityTitle: "Over the lip",
                 source: "https://www.pexels.com/video/surfer-riding-the-waves-in-a-thrilling-adventure-32096724/"),
        FeedPost("tofino-boardwalk", format: .photograph, accessibilityTitle: "Forest boardwalk",
                 source: "https://unsplash.com/photos/wooden-walkway-through-a-lush-green-forest-NtTz9QdoE4Q")
    ]
    static let items = posts.map(\.item)
}
