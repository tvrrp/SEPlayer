//
//  ChannelLayout+CoreAudio.swift
//  SEPlayer
//

import AudioToolbox
import CoreAudio

public extension ChannelLayout {
    /// The layout as Core Audio describes it: the tag AudioToolbox has for the channels, or else the channels
    /// themselves.
    var audioChannelLayout: ManagedAudioChannelLayout {
        let layout = ManagedAudioChannelLayout(labels: channels.map(\.label))
        guard let tag = try? AudioFormatProperties.tag(for: layout), tag != kAudioChannelLayoutTag_Unknown else {
            return layout
        }
        return ManagedAudioChannelLayout(layoutTag: tag)
    }
}

extension ChannelLayout.Channel {
    var label: AudioChannelLabel {
        Self.labels.first { $0.0 == self }?.1 ?? kAudioChannelLabel_Unknown
    }

    private static let labels: [(ChannelLayout.Channel, AudioChannelLabel)] = [
        (.left, kAudioChannelLabel_Left),
        (.right, kAudioChannelLabel_Right),
        (.center, kAudioChannelLabel_Center),
        (.lowFrequency, kAudioChannelLabel_LFEScreen),
        (.leftSurround, kAudioChannelLabel_LeftSurround),
        (.rightSurround, kAudioChannelLabel_RightSurround),
        (.leftRearSurround, kAudioChannelLabel_RearSurroundLeft),
        (.rightRearSurround, kAudioChannelLabel_RearSurroundRight),
        (.centerSurround, kAudioChannelLabel_CenterSurround),
        (.leftCenter, kAudioChannelLabel_LeftCenter),
        (.rightCenter, kAudioChannelLabel_RightCenter),
        (.leftTopFront, kAudioChannelLabel_VerticalHeightLeft),
        (.rightTopFront, kAudioChannelLabel_VerticalHeightRight),
        (.centerTopFront, kAudioChannelLabel_VerticalHeightCenter),
        (.leftTopRear, kAudioChannelLabel_TopBackLeft),
        (.rightTopRear, kAudioChannelLabel_TopBackRight),
        (.centerTopRear, kAudioChannelLabel_TopBackCenter),
        (.topCenterSurround, kAudioChannelLabel_TopCenterSurround),
        (.leftWide, kAudioChannelLabel_LeftWide),
        (.rightWide, kAudioChannelLabel_RightWide),
        (.lowFrequency2, kAudioChannelLabel_LFE2),
    ]
}
