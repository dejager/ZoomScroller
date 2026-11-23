# ZoomScroller

A gesture-driven photo and video viewer for SwiftUI, rendered with Metal.

Pinch from a photo into a playing video. Hold halfway, then pinch back. Each frame samples several positions along the zoom, so the motion blur follows your fingers.

## Installation

Use an iOS 17 or later app target with Metal support.

In Xcode, choose **File → Add Package Dependencies… → Add Local…**. Select the folder containing `Package.swift`, then add **ZoomScroller** to your app target.

## Quick start

Give each photo or SDR video a local file URL and a stable, unique ID. For bundled media, add the files to your app target and resolve their URLs with `Bundle.main.url(forResource:withExtension:)`.

```swift
import SwiftUI
import ZoomScroller

struct Gallery: View {
    let photoURL: URL
    let videoURL: URL
    @State private var selection = 0

    var body: some View {
        ZoomScrollerView(
            items: [
                ZoomScrollerItem(id: "coast", media: .photo(photoURL)),
                ZoomScrollerItem(id: "wave", media: .video(videoURL))
            ],
            selection: $selection,
            style: .init(overlays: []),
            allowsVerticalSwipes: true
        )
    }
}
```

Spread two fingers to move forward; pinch together to go back. Enable vertical swipes to navigate with a one-finger drag up or down.

Hold the transition at any point, reverse it, or release and let your momentum carry the lens to rest. At either end of the gallery, the current shot bends, dims slightly, and springs back.

Read `selection` for the settled index, or set it to navigate. VoiceOver supports stepping between items. Reduce Motion switches directly between shots and pauses video playback.

## Control the transition

Use `ZoomScrollerTransition` to drive the zoom with a slider, scroll offset, or other progress value. At `0`, it shows the first shot. At `1`, it shows the second.

```swift
struct Scrubber: View {
    let first: ZoomScrollerItem
    let second: ZoomScrollerItem
    @State private var progress = 0.0

    var body: some View {
        VStack {
            ZoomScrollerTransition(from: first, to: second, progress: progress)
            Slider(value: $progress, in: 0...1)
        }
    }
}
```

Drag the slider backward to retrace the camera's path. Visible videos loop silently; their playback runs independently of transition progress.

## Tune the look

Both views accept a `ZoomScrollerStyle`:

- `distortion` controls fisheye strength.
- `shutter` controls motion blur.

Both range from `0` (off) to `1` (full strength).

All overlay layers are enabled by default. Pass `overlays: []` for just the lens and media, as in the gallery example, or choose individual layers:

| Layers                  | Content                                                      |
| ----------------------- | ------------------------------------------------------------ |
| `.labels`, `.text`      | Set each item's `label` for a title and `text` for up to three lines. |
| `.curves`, `.squiggles` | Use the included Bézier strokes or supply custom paths through each item's `strokes`. Coordinates are normalized, with the origin at the top left. |
| `.dust`, `.dirt`        | Enable either texture in the style. The renderer generates both. |

## Try the example

Run **ZoomScrollerDemo** on an iPhone simulator to explore the gestures with bundled surf photography and video.

[Media credits](Example/Credits.md)
