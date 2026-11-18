//
//  WebvttCssStyle.swift
//  SEPlayer
//

import CoreGraphics
import SEPlayerCommon

/// The style of a `::cue` rule of a WebVTT STYLE block: what it applies to, and the properties it sets.
///
/// A style matches an element by its id, tag, classes and voice; ``specificityScore(id:tag:classes:voice:)`` scores the
/// match, so that more specific styles are applied after less specific ones.
final class WebvttCssStyle {
    enum FontSizeUnit {
        case pixel
        case em
        case percent
    }

    private(set) var targetId = ""
    private(set) var targetTag = ""
    private(set) var targetClasses: Set<String> = []
    private(set) var targetVoice = ""

    var fontFamily: String?
    var fontColor: CGColor?
    var backgroundColor: CGColor?
    var isLinethrough = false
    var isUnderline = false
    var isBold: Bool?
    var isItalic: Bool?
    var fontSizeUnit: FontSizeUnit?
    var fontSize: CGFloat = 0
    var rubyPosition: Cue.AnnotationPosition?
    var combinesUpright = false

    func setTargetId(_ targetId: String) { self.targetId = targetId }
    func setTargetTagName(_ targetTag: String) { self.targetTag = targetTag }
    func setTargetClasses(_ targetClasses: [String]) { self.targetClasses = Set(targetClasses) }
    func setTargetVoice(_ targetVoice: String) { self.targetVoice = targetVoice }

    /// How specifically the style targets an element, or 0 if it doesn't match it.
    ///
    /// The score follows the specificity of CSS selectors: an id weighs most, then voices and classes, then tags. A
    /// style without a selector matches only the whole cue, which has no tag, with the lowest score.
    func specificityScore(id: String?, tag: String, classes: Set<String>, voice: String) -> Int {
        if targetId.isEmpty, targetTag.isEmpty, targetClasses.isEmpty, targetVoice.isEmpty {
            return tag.isEmpty ? 1 : 0
        }
        var score = 0
        score = Self.updateScoreForMatch(score, target: targetId, actual: id, score: 0x4000_0000)
        score = Self.updateScoreForMatch(score, target: targetTag, actual: tag, score: 2)
        score = Self.updateScoreForMatch(score, target: targetVoice, actual: voice, score: 4)
        guard score != -1, targetClasses.isSubset(of: classes) else { return 0 }
        return score + targetClasses.count * 4
    }

    private static func updateScoreForMatch(_ currentScore: Int, target: String, actual: String?, score: Int) -> Int {
        guard !target.isEmpty, currentScore != -1 else { return currentScore }
        return target == actual ? currentScore + score : -1
    }
}
