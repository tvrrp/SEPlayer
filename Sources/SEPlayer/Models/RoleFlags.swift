//
//  RoleFlagsFlags.swift
//  SEPlayer
//
//  Created by tvrrp on 19.02.2026.
//

@frozen
public struct RoleFlags: OptionSet, Hashable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let main = RoleFlags(rawValue: 1)
    public static let alternate = RoleFlags(rawValue: 1 << 1)
    public static let supplementary = RoleFlags(rawValue: 1 << 2)
    public static let commentary = RoleFlags(rawValue: 1 << 3)
    public static let dub = RoleFlags(rawValue: 1 << 4)
    public static let emergency = RoleFlags(rawValue: 1 << 5)
    public static let caption = RoleFlags(rawValue: 1 << 6)
    public static let subtitle = RoleFlags(rawValue: 1 << 7)
    public static let sign = RoleFlags(rawValue: 1 << 8)
    public static let describesVideo = RoleFlags(rawValue: 1 << 9)
    public static let describesMusicAndSound = RoleFlags(rawValue: 1 << 10)
    public static let enhancedDialogIntelligibility = RoleFlags(rawValue: 1 << 11)
    public static let transcribesDialog = RoleFlags(rawValue: 1 << 12)
    public static let easyToRead = RoleFlags(rawValue: 1 << 13)
    public static let trickPlay = RoleFlags(rawValue: 1 << 14)
    public static let auxiliary = RoleFlags(rawValue: 1 << 15)
}
