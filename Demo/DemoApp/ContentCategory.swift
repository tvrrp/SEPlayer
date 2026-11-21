//
//  ContentCategory.swift
//  DemoApp
//
//  Created by Damir Yackupov on 11.10.2026.
//

import Foundation

enum ContentFormat: String, Hashable {
    case hlsLowLatency = "HLS · low latency"
    case hlsLive = "HLS · live"
    case hlsOnDemand = "HLS · on demand"
    case progressive = "Progressive"
}

/// A sample stream or file.
struct ContentItem: Identifiable, Hashable {
    let id = UUID()
    /// The url, or several separated by `|` to play as a playlist.
    let url: String

    /// The urls of the items to play.
    var playlistUrls: [String] {
        url.split(separator: "|").map(String.init)
    }
}

struct ContentCategory: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let format: ContentFormat
    var items: [ContentItem]

    init(_ title: String, format: ContentFormat, urls: [String]) {
        self.title = title
        self.format = format
        items = urls.map(ContentItem.init(url:))
    }
}

extension ContentCategory {
    /// The samples the demo starts with. A new kind of content, as DASH, is a new format and a category of it.
    static let samples: [ContentCategory] = [
        ContentCategory("Low-latency live", format: .hlsLowLatency, urls: [
            "https://stream.mux.com/v69RSHhFelSm4701snP22dYz2jICy4E4FUyk02rW4gxRM.m3u8",
            "https://ll-hls.softvelum.com/sldp/bbloop/playlist.m3u8",
            "https://llhls-demo.ovenmediaengine.com/app/stream/llhls.m3u8",
        ]),
        ContentCategory("Live", format: .hlsLive, urls: [
            "https://dai.google.com/linear/hls/event/Sid4xiTQTkCT1SLu6rjUSQ/master.m3u8",
            "https://playertest.longtailvideo.com/adaptive/wowzaid3/playlist.m3u8",
        ]),
        ContentCategory("On demand", format: .hlsOnDemand, urls: [
            "https://devstreaming-cdn.apple.com/videos/wwdc/2026/382/1/a1dfe905-059c-45b1-b109-e68230f76399/cmaf.m3u8?25626",
            "https://d3rlna7iyyu8wu.cloudfront.net/DolbyVision_Atmos/profile5_HLS/master.m3u8",
            "https://devstreaming-cdn.apple.com/videos/streaming/examples/av1-sample/av1-sample.m3u8",
            "https://devstreaming-cdn.apple.com/videos/streaming/examples/adv_dv_atmos/main.m3u8",
            "https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8",
            "https://devstreaming-cdn.apple.com/videos/streaming/examples/bipbop_4x3/bipbop_4x3_variant.m3u8",
            "https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_fmp4/master.m3u8",
            "https://vod-dash-ww-rd-live.akamaized.net/testcard/2/manifests/avc-full.m3u8",
        ]),
        ContentCategory(
            "Shorts",
            format: .progressive,
            urls: (1 ... 12).map {
                "https://storage.googleapis.com/exoplayer-test-media-0/shorts_android_developers/shorts_\($0).mp4"
            }
        ),
        ContentCategory("Long", format: .progressive, urls: [
            "https://streams.videolan.org/streams/mp4/GHOST_IN_THE_SHELL_V5_DOLBY%20-%203.m4v",
            "https://storage.googleapis.com/exoplayer-test-media-0/BigBuckBunny_320x180.mp4",
            "https://github.com/chthomos/video-media-samples/raw/refs/heads/master/big-buck-bunny-1080p-60fps-30sec.mp4",
            "https://storage.googleapis.com/exoplayer-test-media-1/mp4/frame-counter-one-hour.mp4",
            "https://download.dolby.com/us/en/test-tones/dolby-atmos-trailer_amaze_1080.mp4",
        ]),
    ]

    /// The samples with the files the app carries, when it has any.
    static var samplesWithBundledFiles: [ContentCategory] {
        let bundled = [("DBVTEST", "MOV")].compactMap { name, type in
            Bundle.main.url(forResource: name, withExtension: type)?.absoluteString
        }
        guard !bundled.isEmpty else { return samples }
        return samples + [ContentCategory("Bundled", format: .progressive, urls: bundled)]
    }

    /// The title of the category urls typed in the demo go to.
    static let customTitle = "Added"
}
