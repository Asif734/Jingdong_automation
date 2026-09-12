import CoreGraphics
import Foundation

protocol ChatImageDetecting: Sendable {
    func detect(in image: CGImage) -> [CGRect]
}

struct ConsensusChatImageDetector: ChatImageDetecting {
    func detect(in image: CGImage) -> [CGRect] {
        guard let pixels = PixelImage(image) else { return [] }
        let background = backgroundCandidates(in: pixels)
        let edges = edgeCandidates(in: pixels)
        var agreements: [(score: CGFloat, rect: CGRect)] = []

        for backgroundRect in background {
            for edgeRect in edges {
                let score = intersectionOverUnion(backgroundRect, edgeRect)
                guard score >= 0.70 else { continue }
                let intersection = backgroundRect.intersection(edgeRect).integral
                guard !intersection.isNull else { continue }
                agreements.append((score, intersection))
            }
        }

        agreements.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.rect.width * $0.rect.height > $1.rect.width * $1.rect.height
        }
        var accepted: [CGRect] = []
        for agreement in agreements where accepted.allSatisfy({
            intersectionOverUnion($0, agreement.rect) < 0.80
        }) {
            accepted.append(agreement.rect)
        }
        return accepted
    }

    private func backgroundCandidates(in image: PixelImage) -> [CGRect] {
        let borderWidth = max(1, min(5, min(image.width, image.height) / 4))
        var red: [UInt8] = []
        var green: [UInt8] = []
        var blue: [UInt8] = []
        red.reserveCapacity((image.width + image.height) * borderWidth * 2)
        green.reserveCapacity(red.capacity)
        blue.reserveCapacity(red.capacity)

        func append(_ x: Int, _ y: Int) {
            let color = image.rgb(x: x, y: y)
            red.append(color.0)
            green.append(color.1)
            blue.append(color.2)
        }
        for y in 0..<borderWidth {
            for x in 0..<image.width { append(x, y) }
        }
        for y in (image.height - borderWidth)..<image.height {
            for x in 0..<image.width { append(x, y) }
        }
        for y in 0..<image.height {
            for x in 0..<borderWidth { append(x, y) }
            for x in (image.width - borderWidth)..<image.width { append(x, y) }
        }
        red.sort()
        green.sort()
        blue.sort()
        let background = (red[red.count / 2], green[green.count / 2], blue[blue.count / 2])

        var mask = [Bool](repeating: false, count: image.width * image.height)
        for y in 0..<image.height {
            for x in 0..<image.width {
                let color = image.rgb(x: x, y: y)
                let distance = max(
                    abs(Int(color.0) - Int(background.0)),
                    abs(Int(color.1) - Int(background.1)),
                    abs(Int(color.2) - Int(background.2))
                )
                mask[y * image.width + x] = distance > 12
            }
        }
        mask = erode(dilate(mask, width: image.width, height: image.height, radius: 2),
                     width: image.width, height: image.height, radius: 2)

        let minimumWidth = max(60, image.width / 8)
        let minimumHeight = max(50, image.height / 8)
        let minimumArea = max(3_000, image.width * image.height / 40)
        return components(mask, width: image.width, height: image.height)
            .filter {
                $0.rect.width >= CGFloat(minimumWidth)
                    && $0.rect.height >= CGFloat(minimumHeight)
                    && $0.count >= minimumArea
                    && CGFloat($0.count) / ($0.rect.width * $0.rect.height) >= 0.55
            }
            .sorted { $0.count > $1.count }
            .map(\.rect)
    }

    fileprivate func edgeCandidates(in image: PixelImage) -> [CGRect] {
        var gray = [Int](repeating: 0, count: image.width * image.height)
        for y in 0..<image.height {
            for x in 0..<image.width {
                let color = image.rgb(x: x, y: y)
                gray[y * image.width + x] =
                    (299 * Int(color.0) + 587 * Int(color.1) + 114 * Int(color.2)) / 1_000
            }
        }

        var mask = [Bool](repeating: false, count: gray.count)
        guard image.width >= 3, image.height >= 3 else { return [] }
        for y in 1..<(image.height - 1) {
            for x in 1..<(image.width - 1) {
                let horizontal = abs(gray[y * image.width + x + 1] - gray[y * image.width + x - 1])
                let vertical = abs(gray[(y + 1) * image.width + x] - gray[(y - 1) * image.width + x])
                mask[y * image.width + x] = horizontal + vertical > 50
            }
        }
        for _ in 0..<2 {
            mask = erode(dilate(mask, width: image.width, height: image.height, radius: 1),
                         width: image.width, height: image.height, radius: 1)
        }

        let minimumWidth = max(60, image.width / 8)
        let minimumHeight = max(50, image.height / 8)
        let minimumBoxArea = max(3_000, image.width * image.height / 40)
        return components(mask, width: image.width, height: image.height)
            .filter {
                let boxArea = Int($0.rect.width * $0.rect.height)
                let perimeterEvidence = Int(2 * ($0.rect.width + $0.rect.height)) / 3
                return $0.rect.width >= CGFloat(minimumWidth)
                    && $0.rect.height >= CGFloat(minimumHeight)
                    && boxArea >= minimumBoxArea
                    && $0.count >= max(120, perimeterEvidence)
            }
            .sorted { $0.rect.width * $0.rect.height > $1.rect.width * $1.rect.height }
            .map(\.rect)
    }
}

/// A deliberately permissive rectangle finder used only to decide where it is
/// worth probing Qianniu's non-destructive Copy action. A candidate is not
/// treated as an image unless the pasteboard subsequently contains an image.
struct ImageCopyCandidateDetector: ChatImageDetecting {
    func detect(in image: CGImage) -> [CGRect] {
        guard let pixels = PixelImage(image) else { return [] }
        var candidates = ConsensusChatImageDetector().edgeCandidates(in: pixels)
        candidates.append(contentsOf: paleLeftAnchoredCandidates(in: pixels))
        var accepted: [CGRect] = []
        for candidate in candidates.sorted(by: {
            $0.width * $0.height > $1.width * $1.height
        }) where accepted.allSatisfy({ intersectionOverUnion($0, candidate) < 0.80 }) {
            accepted.append(candidate)
        }
        return accepted
    }

    private func paleLeftAnchoredCandidates(in image: PixelImage) -> [CGRect] {
        guard image.width >= 120, image.height >= 120 else { return [] }
        let minimumX = max(60, image.width / 5)
        let maximumX = min(image.width - 2, image.width * 3 / 4)
        let minimumRun = max(80, image.height / 4)
        var result: [CGRect] = []

        for x in minimumX...maximumX {
            var runStart: Int?
            var longest: (start: Int, end: Int)?
            for y in 0..<image.height {
                let left = image.rgb(x: x, y: y)
                let right = image.rgb(x: x + 1, y: y)
                let distance = max(
                    abs(Int(left.0) - Int(right.0)),
                    abs(Int(left.1) - Int(right.1)),
                    abs(Int(left.2) - Int(right.2))
                )
                if distance >= 3 {
                    if runStart == nil { runStart = y }
                } else if let start = runStart {
                    let end = y - 1
                    if longest == nil || end - start > longest!.end - longest!.start {
                        longest = (start, end)
                    }
                    runStart = nil
                }
            }
            if let start = runStart {
                let end = image.height - 1
                if longest == nil || end - start > longest!.end - longest!.start {
                    longest = (start, end)
                }
            }
            guard let longest, longest.end - longest.start + 1 >= minimumRun else { continue }

            // Customer media in the Qianniu main chat is left anchored. The
            // long right border remains visible even for almost blank images.
            let top = max(0, longest.start - 10)
            let bottom = min(image.height, longest.end + 5)
            let rect = CGRect(x: 0, y: top, width: x + 1, height: bottom - top)
            guard rect.width >= CGFloat(minimumX), rect.height >= CGFloat(minimumRun) else { continue }
            result.append(rect)
        }
        return result
    }
}

fileprivate struct PixelImage {
    let width: Int
    let height: Int
    private let bytes: [UInt8]

    init?(_ image: CGImage) {
        width = image.width
        height = image.height
        guard width > 0, height > 0 else { return nil }
        var storage = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &storage,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        bytes = storage
    }

    func rgb(x: Int, y: Int) -> (UInt8, UInt8, UInt8) {
        let offset = (y * width + x) * 4
        return (bytes[offset], bytes[offset + 1], bytes[offset + 2])
    }
}

private struct Component {
    let rect: CGRect
    let count: Int
}

private func components(_ mask: [Bool], width: Int, height: Int) -> [Component] {
    var visited = [Bool](repeating: false, count: mask.count)
    var result: [Component] = []
    var queue: [Int] = []
    queue.reserveCapacity(mask.count / 4)

    for seed in mask.indices where mask[seed] && !visited[seed] {
        queue.removeAll(keepingCapacity: true)
        queue.append(seed)
        visited[seed] = true
        var head = 0
        var minX = width
        var minY = height
        var maxX = 0
        var maxY = 0

        while head < queue.count {
            let index = queue[head]
            head += 1
            let x = index % width
            let y = index / width
            minX = min(minX, x)
            minY = min(minY, y)
            maxX = max(maxX, x)
            maxY = max(maxY, y)

            for offsetY in -1...1 {
                for offsetX in -1...1 where offsetX != 0 || offsetY != 0 {
                    let nextX = x + offsetX
                    let nextY = y + offsetY
                    guard nextX >= 0, nextX < width, nextY >= 0, nextY < height else { continue }
                    let next = nextY * width + nextX
                    guard mask[next], !visited[next] else { continue }
                    visited[next] = true
                    queue.append(next)
                }
            }
        }
        result.append(Component(
            rect: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1),
            count: queue.count
        ))
    }
    return result
}

private func dilate(_ mask: [Bool], width: Int, height: Int, radius: Int) -> [Bool] {
    windowFilter(mask, width: width, height: height, radius: radius) {
        count, _ in count > 0
    }
}

private func erode(_ mask: [Bool], width: Int, height: Int, radius: Int) -> [Bool] {
    windowFilter(mask, width: width, height: height, radius: radius) {
        count, area in count == area
    }
}

private func windowFilter(
    _ mask: [Bool],
    width: Int,
    height: Int,
    radius: Int,
    accepts: (Int, Int) -> Bool
) -> [Bool] {
    let stride = width + 1
    var integral = [Int](repeating: 0, count: stride * (height + 1))
    for y in 0..<height {
        var rowSum = 0
        for x in 0..<width {
            if mask[y * width + x] { rowSum += 1 }
            integral[(y + 1) * stride + x + 1] = integral[y * stride + x + 1] + rowSum
        }
    }

    var output = [Bool](repeating: false, count: mask.count)
    for y in 0..<height {
        for x in 0..<width {
            let left = max(0, x - radius)
            let right = min(width - 1, x + radius)
            let top = max(0, y - radius)
            let bottom = min(height - 1, y + radius)
            let count = integral[(bottom + 1) * stride + right + 1]
                - integral[top * stride + right + 1]
                - integral[(bottom + 1) * stride + left]
                + integral[top * stride + left]
            output[y * width + x] = accepts(
                count,
                (right - left + 1) * (bottom - top + 1)
            )
        }
    }
    return output
}

private func intersectionOverUnion(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
    let intersection = lhs.intersection(rhs)
    guard !intersection.isNull else { return 0 }
    let intersectionArea = intersection.width * intersection.height
    let unionArea = lhs.width * lhs.height + rhs.width * rhs.height - intersectionArea
    return unionArea > 0 ? intersectionArea / unionArea : 0
}
