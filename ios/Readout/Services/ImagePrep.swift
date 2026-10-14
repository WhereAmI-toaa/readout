import UIKit

enum ImagePrep {
    /// Redraws the image so its pixels are upright, at 1 point = 1 pixel.
    static func upright(_ img: UIImage) -> UIImage {
        let size = CGSize(width: img.size.width * img.scale, height: img.size.height * img.scale)
        if img.imageOrientation == .up && img.scale == 1 { return img }
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        fmt.opaque = true
        return UIGraphicsImageRenderer(size: size, format: fmt).image { _ in
            img.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    /// Shrinks to fit Claude's limits: a maximum long edge and a maximum number of 28 px image tiles.
    static func fit(_ img: UIImage, maxLong: CGFloat, maxTokens: Int) -> UIImage {
        let w = img.size.width, h = img.size.height
        guard w > 0, h > 0 else { return img }
        var s = min(1, maxLong / max(w, h))
        func tokens(_ s: CGFloat) -> Int { Int(ceil(w * s / 28) * ceil(h * s / 28)) }
        while tokens(s) > maxTokens && s > 0.05 { s *= 0.97 }
        if s >= 0.999 { return img }
        let size = CGSize(width: floor(w * s), height: floor(h * s))
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        fmt.opaque = true
        return UIGraphicsImageRenderer(size: size, format: fmt).image { _ in
            img.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    static func crop(_ img: UIImage, _ rect: CGRect) -> UIImage? {
        let r = rect.integral.intersection(CGRect(origin: .zero, size: img.size))
        guard r.width > 32, r.height > 32, let cg = img.cgImage?.cropping(to: r) else { return nil }
        return UIImage(cgImage: cg)
    }

    static func jpeg(_ img: UIImage) -> Data? { img.jpegData(compressionQuality: 0.9) }

    /// Maps a rectangle on screen to the photo, given the preview fills the screen (aspect fill).
    static func visibleRect(imageSize: CGSize, viewSize: CGSize, rectInView: CGRect) -> CGRect {
        guard viewSize.width > 0, viewSize.height > 0 else { return .zero }
        let scale = max(viewSize.width / imageSize.width, viewSize.height / imageSize.height)
        let ox = (imageSize.width * scale - viewSize.width) / 2
        let oy = (imageSize.height * scale - viewSize.height) / 2
        let r = CGRect(x: (rectInView.minX + ox) / scale, y: (rectInView.minY + oy) / scale,
                       width: rectInView.width / scale, height: rectInView.height / scale)
        return r.intersection(CGRect(origin: .zero, size: imageSize))
    }

    /// Focus measure: variance of the Laplacian on a small grayscale copy. Higher is sharper.
    static func sharpness(_ img: UIImage) -> Double {
        guard let cg = img.cgImage, cg.width > 0 else { return 0 }
        let W = 384
        let H = max(8, Int(Double(cg.height) * Double(W) / Double(cg.width)))
        var px = [UInt8](repeating: 0, count: W * H)
        let ok: Bool = px.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: W, height: H))
            return true
        }
        guard ok else { return 0 }
        var sum = 0.0, sum2 = 0.0, n = 0.0
        for y in 1..<(H - 1) {
            for x in 1..<(W - 1) {
                let i = y * W + x
                let l = 4 * Double(px[i]) - Double(px[i - 1]) - Double(px[i + 1]) - Double(px[i - W]) - Double(px[i + W])
                sum += l
                sum2 += l * l
                n += 1
            }
        }
        guard n > 0 else { return 0 }
        let mean = sum / n
        return sum2 / n - mean * mean
    }
}
