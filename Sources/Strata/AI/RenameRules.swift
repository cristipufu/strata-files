import Foundation

/// Batch rename (Finder's Rename N Items…): one rule applied to every selected item's name. Pure, so the sheet can
/// preview it on every keystroke; the validator and executor shared with Ask Strata check and apply the result.
package nonisolated struct RenameRules: Sendable, Equatable {
    package enum Mode: Int, Sendable, CaseIterable {
        case replace, add, format, changeCase

        package var title: String {
            switch self {
            case .replace: String(localized: "Replace Text", comment: "Batch rename rule")
            case .add: String(localized: "Add Text", comment: "Batch rename rule")
            case .format: String(localized: "Format", comment: "Batch rename rule: name items from a pattern like “{name} {n}”")
            case .changeCase: String(localized: "Change Case", comment: "Batch rename rule")
            }
        }
    }

    package var mode: Mode = .replace
    // Replace Text
    package var find = ""
    package var replacement = ""
    package var useRegex = false
    package var matchCase = false
    // Add Text
    package var addition = ""
    package var addAtEnd = true
    // Format: Ask Strata's tokens ({name}, {n}, {date}, {camera}…)
    package var template = "{name} {n}"
    package var startNumber = 1
    package static let startRange = 0...999_999
    // Change Case
    package var transform: PlanRecipe.NameTransform = .titlecase
    /// The rule sees (and may change) the extension too; otherwise it applies to the name before it. Format always
    /// keeps extensions (its {name} is the name without one).
    package var includeExtension = false

    package init() {}

    /// Whether extensions are part of what the rule changes.
    package var changesExtensions: Bool { includeExtension && mode != .format }

    /// A regular expression gets this long for the whole preview: some patterns take exponentially long on some names.
    package static let regexBudget: TimeInterval = 0.5

    package struct Problem: Error, Equatable {
        package let message: String
    }

    /// The new full name of each item, in order, or why the rule can't be applied (a bad or too slow regular expression).
    package func names(for items: [PlanItem]) -> Result<[String], Problem> {
        let includeExtension = changesExtensions
        let startNumber = min(max(startNumber, Self.startRange.lowerBound), Self.startRange.upperBound)
        let deadline = Date().addingTimeInterval(Self.regexBudget)
        var regex: NSRegularExpression?
        if mode == .replace, useRegex, !find.isEmpty {
            do {
                regex = try NSRegularExpression(pattern: find, options: matchCase ? [] : [.caseInsensitive])
            } catch {
                return .failure(Problem(message: String(localized: "That regular expression isn’t valid.")))
            }
        }
        let last = startNumber + max(items.count - 1, 0)
        let width = String(last).count
        var result: [String] = []
        for (index, item) in items.enumerated() {
            let ext = item.ext
            let target = includeExtension || item.isFolder || ext.isEmpty ? item.name : item.baseName
            var changed: String
            switch mode {
            case .replace:
                if find.isEmpty {
                    changed = target
                } else if let regex {
                    guard let replaced = Self.replace(regex, in: target, with: replacement, before: deadline) else {
                        return .failure(Problem(message: String(localized: "That regular expression takes too long on these names.")))
                    }
                    changed = replaced
                } else {
                    changed = target.replacingOccurrences(of: find, with: replacement, options: matchCase ? [] : [.caseInsensitive])
                }
            case .add:
                changed = addAtEnd ? target + addition : addition + target
            case .format:
                changed = PlanExpander.render(template, item: item, index: startNumber + index, width: width, source: .best)
            case .changeCase:
                changed = transform.apply(target)
            }
            let keepsExtension = !(includeExtension || item.isFolder || ext.isEmpty)
            result.append(keepsExtension ? changed + "." + ext : changed)
        }
        return .success(result)
    }

    /// `stringByReplacingMatches`, but giving up (nil) once `deadline` passes, even in the middle of one name.
    private static func replace(_ regex: NSRegularExpression, in text: String, with template: String, before deadline: Date) -> String? {
        let source = text as NSString
        let result = NSMutableString()
        var last = 0
        var tooSlow = false
        regex.enumerateMatches(in: text, options: [.reportProgress], range: NSRange(location: 0, length: source.length)) { match, _, stop in
            if Date() > deadline {
                tooSlow = true
                stop.pointee = true
                return
            }
            guard let match else { return }
            result.append(source.substring(with: NSRange(location: last, length: match.range.location - last)))
            result.append(regex.replacementString(for: match, in: text, offset: 0, template: template))
            last = match.range.location + match.range.length
        }
        guard !tooSlow else { return nil }
        result.append(source.substring(from: last))
        return result as String
    }

    /// The rule as a plan: the same checks as Ask Strata (clashes, invalid names, replacing something), with swaps and
    /// chains allowed (they're moved through temporary names).
    package func plan(for items: [PlanItem], baseFolder: URL) -> Result<Plan, Problem> {
        names(for: items).map { names in
            let operations = zip(items, names).map { ProposedOperation.rename($0.url, to: $1) }
            let request = PlanGenerator.Request(instruction: mode.title, items: items, baseFolder: baseFolder)
            return PlanValidator.validate(operations, request: request, source: .rules, interpretation: mode.title,
                                          allowChains: true, keepExtensions: !changesExtensions)
        }
    }
}
