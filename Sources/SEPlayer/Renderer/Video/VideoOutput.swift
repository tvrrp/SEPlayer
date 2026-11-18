//
//  VideoOutput.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 25.09.2026.
//

import QuartzCore

/// Something that shows video, such as ``SEPlayerLayer``.
///
/// The video renderer makes a layer for every output and asks the output to show it: an
/// `AVSampleBufferDisplayLayer`. It reshapes its picture to the size of a sample as soon as the sample is enqueued, ahead
/// of the frames still to show, so the output places the picture itself, with the presentation size, and gives the layer
/// a gravity that undoes that: `.resize` on a device, where each frame is stretched to the picture, and
/// `.resizeAspectFill` on the simulator, where it is fitted by its aspect ratio. When the clock changes, an output
/// briefly holds two of these layers, the new one on top, until the renderer swaps them.
@MainActor
public protocol VideoOutput: AnyObject {
    /// Shows `layer` on top of the layers already shown.
    func attach(_ layer: CALayer)
    func detach(_ layer: CALayer)
    /// The size of the video, with the pixel aspect ratio and the clean aperture applied.
    ///
    /// Called when the first sample of a video is known, and for every change of size: ahead of the change too, with the
    /// time its first frame shows, again whenever that time moves, and then once it showed, without a time. A flush
    /// that drops the change calls it again with the size still on screen.
    ///
    /// - Parameters:
    ///   - size: The size.
    ///   - hostTime: The host time (`CACurrentMediaTime()`) the first frame of this size shows; until then the picture
    ///     keeps the size before it. Infinite while the clock stands and the time isn't known yet; `nil` when the
    ///     size is on screen now.
    func setPresentationSize(_ size: CGSize, at hostTime: CFTimeInterval?)
}
