import Foundation
import CoreGraphics
import ImageIO

struct SettingsAIPerception: Sendable {
    func controlCandidates(
        imageURL: URL,
        displaySize: CGSize,
        ocrLines: [SettingsAIOCRLine]
    ) throws -> [SettingsAIControlCandidate] {
        let bitmap = try SettingsAIBitmap.load(imageURL: imageURL)
        let rawSwitches = detectSwitches(in: bitmap)
        let scaleX = displaySize.width / CGFloat(max(bitmap.width, 1))
        let scaleY = displaySize.height / CGFloat(max(bitmap.height, 1))
        let scaledSwitches = rawSwitches.map { raw in
            SettingsAIRawSwitch(
                rect: CGRect(
                    x: raw.rect.minX * scaleX,
                    y: raw.rect.minY * scaleY,
                    width: raw.rect.width * scaleX,
                    height: raw.rect.height * scaleY
                ),
                state: raw.state,
                confidence: raw.confidence
            )
        }

        return scaledSwitches
            .sorted {
                if abs($0.rect.minY - $1.rect.minY) > 4 {
                    return $0.rect.minY < $1.rect.minY
                }
                return $0.rect.minX < $1.rect.minX
            }
            .enumerated()
            .map { index, raw in
                let label = nearestLabel(for: raw, ocrLines: ocrLines)
                let confidence = min(0.99, raw.confidence + (label == nil ? 0 : 0.08))
                return SettingsAIControlCandidate(
                    id: "toggle_\(index + 1)",
                    kind: "toggle",
                    label: label?.text,
                    state: raw.state,
                    rect: raw.rect,
                    center: CGPoint(x: raw.rect.midX, y: raw.rect.midY),
                    source: label == nil ? "image" : "image+ocr",
                    confidence: confidence
                )
            }
    }

    private func detectSwitches(in bitmap: SettingsAIBitmap) -> [SettingsAIRawSwitch] {
        var candidates = connectedComponents(in: bitmap, stateHint: "on", mask: isBlueSwitchPixel(_:))
        candidates.append(contentsOf: connectedComponents(in: bitmap, stateHint: "off", mask: isNeutralSwitchPixel(_:)))
        return deduplicate(candidates)
    }

    private func connectedComponents(
        in bitmap: SettingsAIBitmap,
        stateHint: String,
        mask: (SettingsAIPixel) -> Bool
    ) -> [SettingsAIRawSwitch] {
        var visited = [Bool](repeating: false, count: bitmap.width * bitmap.height)
        var candidates: [SettingsAIRawSwitch] = []

        for y in 0..<bitmap.height {
            for x in 0..<bitmap.width {
                let index = y * bitmap.width + x
                if visited[index] || !mask(bitmap.pixel(x: x, y: y)) {
                    continue
                }

                var stack = [index]
                visited[index] = true
                var minX = x
                var maxX = x
                var minY = y
                var maxY = y
                var area = 0

                while let current = stack.popLast() {
                    area += 1
                    let currentX = current % bitmap.width
                    let currentY = current / bitmap.width
                    minX = min(minX, currentX)
                    maxX = max(maxX, currentX)
                    minY = min(minY, currentY)
                    maxY = max(maxY, currentY)

                    for neighbor in bitmap.neighborIndexes(x: currentX, y: currentY) {
                        if visited[neighbor] {
                            continue
                        }
                        let neighborX = neighbor % bitmap.width
                        let neighborY = neighbor / bitmap.width
                        if mask(bitmap.pixel(x: neighborX, y: neighborY)) {
                            visited[neighbor] = true
                            stack.append(neighbor)
                        }
                    }
                }

                let width = maxX - minX + 1
                let height = maxY - minY + 1
                guard width >= 24, width <= 58, height >= 12, height <= 28 else {
                    continue
                }
                let aspect = Double(width) / Double(height)
                guard aspect >= 1.7, aspect <= 4.6 else {
                    continue
                }
                let fillRatio = Double(area) / Double(width * height)
                guard fillRatio >= 0.30 else {
                    continue
                }

                let rect = CGRect(x: minX, y: minY, width: width, height: height)
                guard rect.minX >= CGFloat(bitmap.width) * 0.38 else {
                    continue
                }
                let knob = knobSide(in: bitmap, rect: rect)
                let state: String
                switch (stateHint, knob) {
                case ("on", .right):
                    state = "on"
                case ("on", _):
                    state = "unknown"
                case ("off", .left):
                    state = "off"
                default:
                    state = "unknown"
                }
                let shapeConfidence = min(0.12, max(0, (fillRatio - 0.30) * 0.25))
                let knobConfidence = knob == .unknown ? 0 : 0.10
                let stateConfidence = state == "unknown" ? -0.06 : 0.04
                let base = stateHint == "on" ? 0.76 : 0.66
                candidates.append(
                    SettingsAIRawSwitch(
                        rect: rect,
                        state: state,
                        confidence: max(0.40, min(0.95, base + shapeConfidence + knobConfidence + stateConfidence))
                    )
                )
            }
        }

        return candidates
    }

    private func deduplicate(_ candidates: [SettingsAIRawSwitch]) -> [SettingsAIRawSwitch] {
        var result: [SettingsAIRawSwitch] = []
        for candidate in candidates.sorted(by: { $0.confidence > $1.confidence }) {
            let overlapsExisting = result.contains { existing in
                existing.rect.insetBy(dx: -4, dy: -4).intersects(candidate.rect)
                    || hypot(existing.rect.midX - candidate.rect.midX, existing.rect.midY - candidate.rect.midY) < 8
            }
            if !overlapsExisting {
                result.append(candidate)
            }
        }
        return result
    }

    private func nearestLabel(
        for rawSwitch: SettingsAIRawSwitch,
        ocrLines: [SettingsAIOCRLine]
    ) -> SettingsAIOCRLine? {
        let centerY = rawSwitch.rect.midY
        let sameRowTolerance = max(18, rawSwitch.rect.height * 1.5)
        let ignored = Set(["+", "-", "−", ""])
        let leftLabels = ocrLines.filter { line in
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return line.confidence >= 0.20
                && !ignored.contains(text)
                && abs(line.rect.midY - centerY) <= sameRowTolerance
                && line.rect.maxX <= rawSwitch.rect.minX - 8
        }
        if let label = leftLabels.min(by: { lhs, rhs in
            let lhsDistance = rawSwitch.rect.minX - lhs.rect.maxX + abs(lhs.rect.midY - centerY) * 3
            let rhsDistance = rawSwitch.rect.minX - rhs.rect.maxX + abs(rhs.rect.midY - centerY) * 3
            return lhsDistance < rhsDistance
        }) {
            return label
        }

        return ocrLines
            .filter { line in
                let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
                return line.confidence >= 0.20
                    && !ignored.contains(text)
                    && abs(line.rect.midY - centerY) <= sameRowTolerance
            }
            .min(by: {
                abs($0.rect.midX - rawSwitch.rect.midX) < abs($1.rect.midX - rawSwitch.rect.midX)
            })
    }

    private func knobSide(in bitmap: SettingsAIBitmap, rect: CGRect) -> SettingsAIKnobSide {
        let minX = max(0, Int(rect.minX.rounded(.down)))
        let maxX = min(bitmap.width - 1, Int(rect.maxX.rounded(.up)))
        let minY = max(0, Int(rect.minY.rounded(.down)))
        let maxY = min(bitmap.height - 1, Int(rect.maxY.rounded(.up)))
        let midX = (minX + maxX) / 2
        var leftWhite = 0
        var rightWhite = 0

        for y in minY...maxY {
            for x in minX...maxX {
                guard isWhiteKnobPixel(bitmap.pixel(x: x, y: y)) else {
                    continue
                }
                if x <= midX {
                    leftWhite += 1
                } else {
                    rightWhite += 1
                }
            }
        }

        let minimumWhitePixels = max(12, Int(rect.height * rect.height * 0.20))
        if rightWhite >= minimumWhitePixels, rightWhite > leftWhite * 2 {
            return .right
        }
        if leftWhite >= minimumWhitePixels, leftWhite > rightWhite * 2 {
            return .left
        }
        return .unknown
    }

    private func isBlueSwitchPixel(_ pixel: SettingsAIPixel) -> Bool {
        pixel.alpha > 180
            && pixel.blue > 145
            && pixel.green > 85
            && pixel.green < 190
            && pixel.red < 95
            && pixel.blue > pixel.red + 80
            && pixel.blue > pixel.green + 20
    }

    private func isNeutralSwitchPixel(_ pixel: SettingsAIPixel) -> Bool {
        guard pixel.alpha > 180 else {
            return false
        }
        let maxChannel = max(pixel.red, pixel.green, pixel.blue)
        let minChannel = min(pixel.red, pixel.green, pixel.blue)
        return maxChannel >= 155
            && maxChannel <= 225
            && minChannel >= 145
            && maxChannel - minChannel <= 16
    }

    private func isWhiteKnobPixel(_ pixel: SettingsAIPixel) -> Bool {
        pixel.alpha > 180
            && pixel.red > 232
            && pixel.green > 232
            && pixel.blue > 232
    }
}

private struct SettingsAIRawSwitch: Sendable {
    let rect: CGRect
    let state: String
    let confidence: Double
}

private enum SettingsAIKnobSide {
    case left
    case right
    case unknown
}

private struct SettingsAIBitmap: Sendable {
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let data: [UInt8]

    static func load(imageURL: URL) throws -> SettingsAIBitmap {
        guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw RunnerError.hostCommandFailed("Could not load screenshot for Settings AI perception.")
        }

        let width = image.width
        let height = image.height
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var data = [UInt8](repeating: 0, count: height * bytesPerRow)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
            | CGBitmapInfo.byteOrder32Big.rawValue

        try data.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress,
                  let context = CGContext(
                    data: baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: colorSpace,
                    bitmapInfo: bitmapInfo
                  )
            else {
                throw RunnerError.hostCommandFailed("Could not allocate bitmap context for Settings AI perception.")
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }

        return SettingsAIBitmap(width: width, height: height, bytesPerRow: bytesPerRow, data: data)
    }

    func pixel(x: Int, y: Int) -> SettingsAIPixel {
        let offset = y * bytesPerRow + x * 4
        return SettingsAIPixel(
            red: Int(data[offset]),
            green: Int(data[offset + 1]),
            blue: Int(data[offset + 2]),
            alpha: Int(data[offset + 3])
        )
    }

    func neighborIndexes(x: Int, y: Int) -> [Int] {
        var neighbors: [Int] = []
        if x > 0 {
            neighbors.append(y * width + x - 1)
        }
        if x + 1 < width {
            neighbors.append(y * width + x + 1)
        }
        if y > 0 {
            neighbors.append((y - 1) * width + x)
        }
        if y + 1 < height {
            neighbors.append((y + 1) * width + x)
        }
        return neighbors
    }
}

private struct SettingsAIPixel: Sendable {
    let red: Int
    let green: Int
    let blue: Int
    let alpha: Int
}
