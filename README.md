# SEPlayer

SEPlayer (Swift ExoPlayer) is a userspace framework for building media players on Apple platforms. Its architecture is heavily inspired by [Jetpack Media3](https://github.com/androidx/media).

> SEPlayer is in active development. The API changes without notice, and it is not ready for production.

## Why SEPlayer

A player such as VLC is a finished implementation: you give it media and it plays. That is enough until playback becomes part of your own product. Then you need to decide how bytes are loaded, how much is buffered, when playback starts, which quality is picked, what gets measured, and what happens on an error. A finished player lets you adjust some of that, but it was not built for it.

SEPlayer is built for it. The whole pipeline, from the network request to the frame on screen, runs in your process as Swift code, and each stage is a protocol with a default implementation that you can replace:

| Stage | What you can replace | Default |
| --- | --- | --- |
| Loading | `DataSourceFactory`, `DataSource` | `URLSession` and file reading, with a memory and an optional disk cache |
| Parsing | `ExtractorsFactory`, `Extractor` | MP4, fragmented MP4, MPEG-TS, ADTS, AC-3, AC-4, MP3 |
| Sources | `MediaSourceFactory`, `MediaSource` | Progressive files and HLS |
| Buffering | `LoadControl` | Buffer sizes, when to keep loading, when to start playback |
| Quality | `TrackSelector`, `BandwidthMeter` | Adaptive selection from measured throughput |
| Errors | `LoadErrorHandlingPolicy` | Retries with backoff and variant exclusion |
| Decoding and output | `RenderersFactory`, `SERenderer` | VideoToolbox and AudioToolbox decoding, AVFoundation display |

Take the defaults and you have a working player in a few lines. Replace one stage and the rest keeps working around it.

## What you get

- **Control over loading.** Use your own network stack, headers, signing or CDN logic, and decide what is cached and where.
- **Control over buffering and startup.** Set how much is loaded ahead, how much is kept behind, and how much must be buffered before playback starts or resumes.
- **Control over quality.** Constrain or override track selection, or write your own adaptation logic.
- **Observability.** `SEPlayerDelegate` reports every state change, and `TransferListener` and the renderer listeners report each transfer, dropped frame and format change. That is what an analytics layer needs.
- **Your own decoders and renderers.** A renderer is a protocol, so a software decoder or a custom video output plugs in next to the system ones.
- **Code you can read and debug.** Nothing is hidden behind a system daemon: you can step through a stall, a seek or a bad stream.
- **Only what you use.** The package is split into modules (`DataSource`, `Extractor`, `Decoder`, `SEPlayer`) and the extractors are package traits, so unused formats stay out of the binary.

## What works today

**Playback**
- Playlists with gapless transitions, repeat and shuffle modes, and preloading of the next item.
- Seeking with selectable accuracy (exact or to the nearest sync sample), playback speed, volume.
- Live streams with playback speed adjustment towards the live edge.
- Audio session handling shared by all players of the app.

**Sources and containers**
- Progressive playback over HTTP and from files: MP4 and QuickTime, fragmented MP4, MPEG-TS, ADTS, AC-3, AC-4, MP3.
- HLS: multivariant playlists, adaptive bitrate, MPEG-TS and fragmented MP4 segments, alternate audio and subtitle renditions, live and VOD, `AES-128` encryption.

**Codecs** (decoded by the system, so the device decides what plays)
- Video: H.264, HEVC, Dolby Vision, AV1, VP9, ProRes, with HDR metadata carried through.
- Audio: AAC (including xHE-AAC), AC-3, E-AC-3, MP3, Opus, FLAC, ALAC, PCM.

**Text and metadata**
- Subtitles: WebVTT, CEA-608 and CEA-708, TX3G, DVB, with a subtitle layer and caption styles.
- Metadata: ID3, ICY, MP4 metadata.

**Platforms**: iOS 15, tvOS 15, Mac Catalyst 15, visionOS 1.

## Usage

```swift
import SEPlayer
import SEPlayerCommon

let factory = SEPlayerFactory()
let player = try factory.buildPlayer()

playerLayer.player = player // an SEPlayerLayer
player.set(mediaItems: [MediaItem.Builder().setUrl(url).build()])
player.prepare()
player.play()
```

Every argument of `buildPlayer` is one of the stages above:

```swift
let player = try factory.buildPlayer(
    dataSourceFactory: MyDataSourceFactory(),
    trackSelector: MyTrackSelector(),
    loadControl: MyLoadControl()
)
```

The `Demo` folder has an app that plays a catalog of streams and shows a debug overlay with the player's state.

## Roadmap

- Content protection: FairPlay, `SAMPLE-AES`, Common Encryption.
- HLS: interstitials and date ranges, content steering, low latency.
- DASH.
- More containers: Matroska and WebM, Ogg, FLAC, WAV.
- Software decoders for the formats the system has none for.
- Offline downloads.
- A dedicated analytics API on top of the existing listeners.
- A stable API, documentation and wider test coverage.

## Acknowledgements

SEPlayer is built on the design and much of the code of [AndroidX Media3](https://github.com/androidx/media), translated
to Swift. Media3 is licensed under the Apache License, Version 2.0; the files derived from it say so in their headers.
The reader of `CMBlockBuffer` bytes is derived from the `ByteBuffer` of [SwiftNIO](https://github.com/apple/swift-nio),
also Apache 2.0. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) and [NOTICE](NOTICE).

## License

SEPlayer is licensed under the Apache License, Version 2.0; see [LICENSE](LICENSE) and [NOTICE](NOTICE).
