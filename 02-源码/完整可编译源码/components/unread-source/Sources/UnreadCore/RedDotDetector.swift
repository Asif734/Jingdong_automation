import Foundation
import CoreGraphics
public enum RedDotDetector {
    public static func targets(image: PixelImage, window: CGRect, rows: [ConversationRow]) -> [ConversationRow] {
        rows.filter { hasDot(image: image, window: window, frame: $0.frame) }
            .sorted { $0.frame.minY < $1.frame.minY }
    }

    public static func targets(image: PixelImage, window: CGRect,
                               candidates: [ConversationCandidate]) -> [ConversationCandidate] {
        candidates.filter { hasDot(image: image, window: window, frame: $0.frame) }
            .sorted { $0.frame.minY < $1.frame.minY }
    }

    private static func hasDot(image: PixelImage, window: CGRect, frame: CGRect) -> Bool {
        guard image.width > 0, image.height > 0, image.width <= 20000, image.height <= 20000,
              image.rgba.count == image.width * image.height * 4, window.width > 0, window.height > 0 else { return false }
        let sx = CGFloat(image.width) / window.width, sy = CGFloat(image.height) / window.height
        guard abs(sx / sy - 1) < 0.03,
              window.contains(frame), frame.height >= 30 else { return false }
            let h = frame.height
            // Search enough of the avatar to reject components connected to its red artwork.
            let area = CGRect(x: frame.minX, y: frame.minY, width: h * 1.1, height: h)
            let x0 = max(0, Int((area.minX - window.minX) * sx)), x1 = min(image.width, Int(ceil((area.maxX - window.minX) * sx)))
            let y0 = max(0, Int((area.minY - window.minY) * sy)), y1 = min(image.height, Int(ceil((area.maxY - window.minY) * sy)))
            guard x0 < x1, y0 < y1 else { return false }
            func red(_ x: Int, _ y: Int) -> Bool {
                let i = (y * image.width + x) * 4
                let r = Int(image.rgba[i]), g = Int(image.rgba[i+1]), b = Int(image.rgba[i+2])
                return r >= 185 && g < 100 && b < 115 && r - g > 100 && r - b > 85
            }
            var visited = Set<Int>()
            for y in y0..<y1 { for x in x0..<x1 {
                let key = y * image.width + x
                guard !visited.contains(key), red(x, y) else { continue }
                visited.insert(key)
                var queue = [(x, y)], index = 0
                var minX = x, maxX = x, minY = y, maxY = y
                while index < queue.count {
                    let (px, py) = queue[index]; index += 1
                    minX = min(minX, px); maxX = max(maxX, px); minY = min(minY, py); maxY = max(maxY, py)
                    for (nx, ny) in [(px-1,py),(px+1,py),(px,py-1),(px,py+1)] where nx >= x0 && nx < x1 && ny >= y0 && ny < y1 {
                        let next = ny * image.width + nx
                        if !visited.contains(next) && red(nx, ny) { visited.insert(next); queue.append((nx, ny)) }
                    }
                }
                let w = CGFloat(maxX - minX + 1) / sx, height = CGFloat(maxY - minY + 1) / sy
                let cx = (CGFloat(minX + maxX) * 0.5 / sx + window.minX - frame.minX) / h
                let cy = (CGFloat(minY + maxY) * 0.5 / sy + window.minY - frame.minY) / h
                let density = CGFloat(queue.count) / CGFloat((maxX-minX+1)*(maxY-minY+1))
                if cx >= 0.62 && cx <= 0.93 && cy >= 0.04 && cy <= 0.34,
                   w >= h * 0.07 && w <= h * 0.23, height >= h * 0.07 && height <= h * 0.23,
                   w / height >= 0.65 && w / height <= 1.5, density >= 0.55,
                   minX > x0 && maxX < x1-1 && minY > y0 && maxY < y1-1 { return true }
            } }
            return false
    }
}
