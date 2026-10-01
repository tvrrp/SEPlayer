//
//  VideoOutput.swift
//  SEPlayer
//
//  Created by Damir Yackupov on 25.09.2026.
//

import AVFoundation

/// Something that shows video, such as ``SEPlayerLayer``.
///
/// The video renderer creates a display layer for every output and asks the output to show it.
/// When the video changes, an output briefly holds two layers, the new one on top, until the
/// renderer swaps them.
@MainActor
public protocol VideoOutput: AnyObject {
    /// Shows `layer` on top of the layers already shown.
    func attach(_ layer: AVSampleBufferDisplayLayer)
    func detach(_ layer: AVSampleBufferDisplayLayer)
    /// The size of the video on screen, with the pixel aspect ratio and the clean aperture
    /// applied. Called when the first sample of a video is known, and again when the video's size
    /// changes — together with the layer swap, if the aspect ratio changes.
    func setPresentationSize(_ size: CGSize)
}
