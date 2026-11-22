# Third-party notices

SEPlayer contains code derived from the projects below. Each derived source file says so in its header, with the
classes it was derived from.

## AndroidX Media3

- Source: https://github.com/androidx/media
- Copyright (C) The Android Open Source Project
- License: Apache License, Version 2.0, in [LICENSE](LICENSE)

SEPlayer's architecture and many of its components are translated from Media3's Java code to Swift and adapted to
Apple platforms: the player and its playback loop, media sources and periods, sample queues, track selection, load
control, the HLS implementation, the extractors (MP4, fragmented MP4, MPEG-TS, ADTS, AC-3, AC-4, MP3), the metadata
decoders, the subtitle parsers (WebVTT, TTML, TX3G, CEA-608, CEA-708, DVB), and the player tests with their test
utilities. The derived files carry the copyright notice of the Media3 files they come from and state that they were
changed.

Media3 has no NOTICE file.

## SwiftNIO

- Source: https://github.com/apple/swift-nio
- Copyright (c) Apple Inc. and the SwiftNIO project authors
- License: Apache License, Version 2.0, in [LICENSE](LICENSE)

`BlockBufferReader` and `BlockBufferView` follow SwiftNIO's `ByteBuffer` and `ByteBufferView`: their reader index,
integer, string and slice accessors and many of their docs, rewritten to read a `CMBlockBuffer`.

SwiftNIO's NOTICE file is reproduced in [NOTICE](NOTICE), as its license requires.
