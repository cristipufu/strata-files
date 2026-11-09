import AppKit
import CoreGraphics
import Foundation
import StrataModel
import StrataSupport

package final class GeoTrackPreviewView: PreviewView {
    private let canvasView = GeoTrackCanvasView()

    package init(url: URL) {
        super.init(frame: .zero)
        canvasView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(canvasView)
        NSLayoutConstraint.activate(canvasView.fillingConstraints(in: contentView))
        load({ try await Self.loadTrack(url) }) { [weak self] (track, summary, note) in
            guard let self else { return }
            canvasView.track = track
            footer.show(summary, note: note)
        }
    }

    @available(*, unavailable)
    package required init?(coder: NSCoder) { fatalError() }

    @concurrent private static func loadTrack(_ url: URL) async throws -> (GeoTrackMetadata.Track, [String], String?) {
        try Task.checkCancellation()
        guard let track = GeoTrackMetadata.read(url), !track.points.isEmpty else {
            throw PreviewError.unsupported
        }
        let ext = url.pathExtension.lowercased()
        let format = switch ext {
        case "gpx": "GPX"
        case "kml": "KML"
        case "geojson": "GeoJSON"
        default: ext.uppercased()
        }
        var summary = [format]
        if let meters = track.distanceMeters, meters > 0 {
            let text = meters >= 1000
                ? (meters / 1000).formatted(.number.grouping(.never).precision(.fractionLength(0...2))) + " km"
                : meters.formatted(.number.grouping(.never).precision(.fractionLength(0))) + " m"
            summary.append(text)
        }
        if let gain = track.elevationGainMeters, gain > 0 {
            summary.append("+" + gain.formatted(.number.grouping(.never).precision(.fractionLength(0))) + " m")
        }
        summary.append(String(localized: "\(track.points.count) points", comment: "plural"))
        return (track, summary, track.name)
    }
}

private final class GeoTrackCanvasView: NSView {
    var track: GeoTrackMetadata.Track? {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let track, !track.points.isEmpty,
              let context = NSGraphicsContext.current?.cgContext else { return }

        let insetBounds = bounds.insetBy(dx: 24, dy: 24)
        guard insetBounds.width > 40, insetBounds.height > 40 else { return }

        let elevations = track.points.compactMap(\.elevation)
        let hasElevation = elevations.count >= 2 && insetBounds.height >= 180
        let elevationHeight: CGFloat = hasElevation ? min(90, insetBounds.height * 0.28) : 0
        let mapRect = NSRect(
            x: insetBounds.minX,
            y: insetBounds.minY + (hasElevation ? elevationHeight + 18 : 0),
            width: insetBounds.width,
            height: insetBounds.height - (hasElevation ? elevationHeight + 18 : 0)
        )

        drawRoute(points: track.points, in: mapRect, context: context)
        if hasElevation {
            let chartRect = NSRect(x: insetBounds.minX, y: insetBounds.minY, width: insetBounds.width, height: elevationHeight)
            drawElevation(elevations: elevations, in: chartRect, context: context)
        }
    }

    private func drawRoute(points: [GeoTrackMetadata.Point], in rect: NSRect, context: CGContext) {
        var minLat = Double.greatestFiniteMagnitude, maxLat = -Double.greatestFiniteMagnitude
        var minLon = Double.greatestFiniteMagnitude, maxLon = -Double.greatestFiniteMagnitude
        for pt in points {
            minLat = min(minLat, pt.latitude)
            maxLat = max(maxLat, pt.latitude)
            minLon = min(minLon, pt.longitude)
            maxLon = max(maxLon, pt.longitude)
        }

        let midLatRadians = ((minLat + maxLat) * 0.5) * .pi / 180.0
        let lonScale = max(0.1, cos(midLatRadians))
        let spanLon = max(0.00001, (maxLon - minLon) * lonScale)
        let spanLat = max(0.00001, maxLat - minLat)

        let scale = min(Double(rect.width) / spanLon, Double(rect.height) / spanLat)
        let drawnWidth = CGFloat(spanLon * scale)
        let drawnHeight = CGFloat(spanLat * scale)
        let originX = rect.minX + (rect.width - drawnWidth) * 0.5
        let originY = rect.minY + (rect.height - drawnHeight) * 0.5

        func project(_ pt: GeoTrackMetadata.Point) -> CGPoint {
            let x = originX + CGFloat((pt.longitude - minLon) * lonScale * scale)
            let y = originY + CGFloat((pt.latitude - minLat) * scale)
            return CGPoint(x: x, y: y)
        }

        context.saveGState()
        let path = CGMutablePath()
        for (idx, pt) in points.enumerated() {
            let cgPt = project(pt)
            if idx == 0 { path.move(to: cgPt) }
            else { path.addLine(to: cgPt) }
        }
        context.addPath(path)
        context.setStrokeColor(NSColor.controlAccentColor.cgColor)
        context.setLineWidth(2.5)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.strokePath()

        if let first = points.first {
            let startPt = project(first)
            context.setFillColor(NSColor.systemGreen.cgColor)
            context.fillEllipse(in: CGRect(x: startPt.x - 4.5, y: startPt.y - 4.5, width: 9, height: 9))
        }
        if let last = points.last, points.count > 1 {
            let endPt = project(last)
            context.setFillColor(NSColor.systemRed.cgColor)
            context.fillEllipse(in: CGRect(x: endPt.x - 4.5, y: endPt.y - 4.5, width: 9, height: 9))
        }
        context.restoreGState()
    }

    private func drawElevation(elevations: [Double], in rect: NSRect, context: CGContext) {
        guard let minEle = elevations.min(), let maxEle = elevations.max() else { return }
        let spanEle = max(1.0, maxEle - minEle)

        context.saveGState()
        let linePath = CGMutablePath()
        let fillPath = CGMutablePath()
        for (idx, ele) in elevations.enumerated() {
            let fractionX = CGFloat(idx) / CGFloat(max(1, elevations.count - 1))
            let fractionY = CGFloat((ele - minEle) / spanEle)
            let pt = CGPoint(x: rect.minX + fractionX * rect.width, y: rect.minY + fractionY * rect.height)
            if idx == 0 {
                linePath.move(to: pt)
                fillPath.move(to: CGPoint(x: pt.x, y: rect.minY))
                fillPath.addLine(to: pt)
            } else {
                linePath.addLine(to: pt)
                fillPath.addLine(to: pt)
            }
        }
        fillPath.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        fillPath.closeSubpath()

        context.addPath(fillPath)
        context.setFillColor(NSColor.controlAccentColor.withAlphaComponent(0.14).cgColor)
        context.fillPath()

        context.addPath(linePath)
        context.setStrokeColor(NSColor.controlAccentColor.withAlphaComponent(0.75).cgColor)
        context.setLineWidth(1.5)
        context.strokePath()
        context.restoreGState()
    }
}
