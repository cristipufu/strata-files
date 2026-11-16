import AppKit
import CNativeDrawing
import CNativeDrawingTestSupport
import Testing
@testable import StrataDev

@MainActor struct GitStatusBadgeRenderingTests {
    private func drawing(size: NSSize = NSSize(width: 64, height: 32), _ body: () throws -> Void) throws -> NSBitmapImageRep {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                            bytesPerRow: 0, space: space,
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        try body()
        return NSBitmapImageRep(cgImage: try #require(context.makeImage()))
    }

    private func containsInk(_ bitmap: NSBitmapImageRep) -> Bool {
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0 { return true }
        }
        return false
    }

    @Test func nativeGlyphsHaveInkAndKeepTheirImageAfterTheirOwnerIsReleased() throws {
        for scale: CGFloat in [1, 2, 3] {
            for letter in ["M", "A", "D", "R", "C", "U", "?", "!"] {
                let image: CGImage = try autoreleasepool {
                    let glyph = try STBadgeGlyph.render(letter, color: .white, size: GitStatusBadge.tileSize, scale: scale)
                    return withExtendedLifetime(glyph) { glyph.image }
                }
                #expect(image.width == Int(15 * scale) && image.height == Int(14 * scale))
                #expect(containsInk(NSBitmapImageRep(cgImage: image)), "\(letter), scale \(scale)")
            }
        }
    }

    @Test func invalidGeometryAndUnboundedTextAreRejectedBeforeAllocation() throws {
        let invalid: [(NSSize, CGFloat)] = [
            (.init(width: 0, height: 14), 2), (.init(width: -CGFloat.infinity, height: 14), 2),
            (.init(width: CGFloat.nan, height: 14), 2), (.init(width: 15, height: CGFloat.infinity), 2),
            (.init(width: CGFloat.greatestFiniteMagnitude, height: 14), 2),
            (.init(width: 15, height: 14), 0), (.init(width: 15, height: 14), .infinity),
            (.init(width: 15, height: 14), .nan), (.init(width: 513, height: 14), 1),
            (.init(width: 15, height: 14), 0.01), (.init(width: 15, height: 14), 9),
        ]
        for (size, scale) in invalid {
            #expect(throws: (any Error).self) { try STBadgeGlyph.render("M", color: .white, size: size, scale: scale) }
        }
        for text in ["", String(repeating: "M", count: 65)] {
            #expect(throws: (any Error).self) {
                try STBadgeGlyph.render(text, color: .white, size: GitStatusBadge.tileSize, scale: 2)
            }
        }
    }

    @Test func nativeSetupMeasurementAndDrawingFailuresStayInsideTheBoundary() throws {
        let failures: [(STBadgeFailurePoint, String)] = [
            (.setup, "glyph setup"), (.missingFont, "glyph setup"), (.invalidFont, "glyph setup"),
            (.measurement, "glyph measurement"), (.drawing, "glyph drawing"),
        ]
        _ = try drawing {
            let previous = NSGraphicsContext.current
            for (failure, operation) in failures {
                var restored: ObjCBool = false, returnedImage: ObjCBool = true
                let error = STTestBadgeGlyphFailure(failure, &restored, &returnedImage) as NSError
                #expect(error.domain == "StrataNativeDrawing")
                #expect(error.userInfo["operation"] as? String == operation)
                #expect(restored.boolValue && !returnedImage.boolValue)
                #expect(NSGraphicsContext.current === previous)
            }
        }
    }

    @Test func aFailedTextRendererIsRetiredWithoutPaintingAndOtherBadgesStillDraw() throws {
        var calls = 0
        let failed = GitStatusBadge(glyphRenderer: { _, _, _, _ in
            calls += 1
            var restored: ObjCBool = false, returnedImage: ObjCBool = true
            let error = STTestBadgeGlyphFailure(.measurement, &restored, &returnedImage) as NSError
            #expect(error.domain == "StrataNativeDrawing" && restored.boolValue && !returnedImage.boolValue)
            throw error
        })
        failed.frame = NSRect(x: 0, y: 0, width: 21, height: 14)
        failed.drawsBacking = true
        failed.badge = GitBadge(state: .modified, staging: .staged, isFolder: false)
        #expect(!containsInk(try drawing { failed.draw(failed.bounds) }))
        #expect(calls == 1 && failed.isHidden && failed.intrinsicContentSize.width == 0)
        failed.backgroundStyle = .emphasized
        failed.badge = GitBadge(state: .renamed, staging: .partiallyStaged, isFolder: false)
        #expect(!containsInk(try drawing { failed.draw(failed.bounds) }))
        #expect(calls == 1 && failed.isHidden)
        failed.badge = GitBadge(state: .modified, staging: nil, isFolder: true)
        #expect(containsInk(try drawing { failed.draw(failed.bounds) }))
        #expect(calls == 1 && !failed.isHidden)
        let healthy = GitStatusBadge(frame: failed.frame)
        healthy.badge = GitBadge(state: .added, staging: .staged, isFolder: false)
        #expect(containsInk(try drawing { healthy.draw(healthy.bounds) }))
        #expect(!healthy.isHidden && healthy.intrinsicContentSize.width == 21)
    }

    @Test func glyphImagesPreserveTheOriginalOrientationAndPlacement() throws {
        let view = GitStatusBadge(frame: NSRect(x: 0, y: 0, width: 21, height: 14))
        let tile = NSRect(x: 6, y: 0, width: 15, height: 14)
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try #require(NSAppearance(named: name))
            view.appearance = appearance
            for state in [GitFileState.added, .renamed, .untracked, .ignored] {
                view.badge = GitBadge(state: state, staging: .staged, isFolder: false)
                let actual = try drawing(size: view.bounds.size) {
                    appearance.performAsCurrentDrawingAppearance { view.draw(view.bounds) }
                }
                let reference = try drawing(size: view.bounds.size) {
                    appearance.performAsCurrentDrawingAppearance {
                        GitColors.solid(state).setFill()
                        NSBezierPath(roundedRect: tile, xRadius: 4, yRadius: 4).fill()
                        #expect(STDrawLegacyBadgeText(state.letter, .white, tile) == nil)
                    }
                }
                #expect(try difference(actual, reference) < difference(actual, reference, mirrored: true), "\(state), \(name)")
            }
        }
    }

    @Test func aReentrantRendererCannotHideOrPaintOverAReplacementBadge() throws {
        weak var owner: GitStatusBadge?
        var calls = 0
        let replacement = GitBadge(state: .added, staging: .staged, isFolder: false)
        let view = GitStatusBadge(glyphRenderer: { text, color, size, scale in
            calls += 1
            if calls == 1 {
                owner?.badge = replacement
                throw NSError(domain: "ControlledOldBadgeFailure", code: 1)
            }
            owner?.badge = nil
            let glyph = try STBadgeGlyph.render(text, color: color, size: size, scale: scale)
            return withExtendedLifetime(glyph) { glyph.image }
        })
        owner = view
        view.frame = NSRect(x: 0, y: 0, width: 21, height: 14)
        view.badge = GitBadge(state: .modified, staging: .unstaged, isFolder: false)
        #expect(!containsInk(try drawing { view.draw(view.bounds) }))
        #expect(calls == 1 && view.badge == replacement && !view.isHidden)
        #expect(!containsInk(try drawing { view.draw(view.bounds) }))
        #expect(calls == 2 && view.badge == nil && view.isHidden)
    }

    private func difference(_ actual: NSBitmapImageRep, _ reference: NSBitmapImageRep, mirrored: Bool = false) throws -> CGFloat {
        var total: CGFloat = 0
        for y in 0..<actual.pixelsHigh {
            for x in 0..<actual.pixelsWide {
                let left = try #require(actual.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                let right = try #require(reference.colorAt(x: x, y: mirrored ? reference.pixelsHigh - y - 1 : y)?.usingColorSpace(.sRGB))
                total += abs(left.redComponent - right.redComponent) + abs(left.greenComponent - right.greenComponent)
                    + abs(left.blueComponent - right.blueComponent) + abs(left.alphaComponent - right.alphaComponent)
            }
        }
        return total
    }

    @Test func everyBadgeStateDrawsInBothAppearancesIncludingNarrowFramesAndReuse() throws {
        let view = GitStatusBadge()
        let staging: [GitStaging?] = [nil, .staged, .unstaged, .partiallyStaged]
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try #require(NSAppearance(named: appearanceName))
            view.appearance = appearance
            for state in GitFileState.allCases {
                for staging in staging {
                    for folder in [false, true] {
                        view.badge = GitBadge(state: state, staging: staging, isFolder: folder)
                        for selected in [false, true] {
                            view.backgroundStyle = selected ? .emphasized : .normal
                            for backing in [false, true] {
                                view.drawsBacking = backing
                                for width: CGFloat in [0, 1, 15, 21, 64] {
                                    view.frame = NSRect(x: 0, y: 0, width: width, height: 14)
                                    _ = try drawing {
                                        appearance.performAsCurrentDrawingAppearance { view.draw(view.bounds) }
                                    }
                                    #expect(view.isHidden == (!folder && state == .clean))
                                }
                            }
                        }
                    }
                }
            }
        }
        view.badge = nil
        #expect(view.isHidden && view.intrinsicContentSize.width == 0)
    }
}
