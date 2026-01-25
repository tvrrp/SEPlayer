# SEPlayer

SEPlayer(Swift ExoPlayer) is a userspace video player. Heavely ispired by [Jetpack Media3](https://github.com/androidx/media).

> SEPlayer is still in active development and must not be used in production.

## What works
- Simple video playback (from the network via HTTP requests or from a file URL), seeking, and transitions between media items in a playlist.
- Support for the MP4 container.
- AVC (H.264) and AAC decoding and playback. Additional codecs supported by Apple’s media frameworks may work, but are untested.

## Plans for the alpha version
- 100% stability across all modules, from `DataSource` to renderers.
- Proper error handling everywhere.
- More tests.