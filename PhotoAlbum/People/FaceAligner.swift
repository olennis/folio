import CoreGraphics
import Foundation

/// 원본 이미지의 RGB 픽셀. 한 사진의 여러 얼굴을 뽑을 때 한 번만 풀어 둔다.
struct RGBImage: Sendable {
    let width: Int
    let height: Int
    /// RGBA 순서, 한 픽셀 4바이트. 알파는 쓰지 않는다.
    var pixels: [UInt8]

    init(width: Int, height: Int, pixels: [UInt8]) {
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    /// sRGB로 풀어 둔다. 사진 앱의 Display P3 사진도 sRGB로 바꿔야 dlib이 배운 색과 맞는다.
    init?(_ image: CGImage) {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        self.init(width: width, height: height, pixels: pixels)
    }

    func cgImage() -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(pixels) as CFData)
        else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }

    /// 가로·세로를 반으로 줄인다(2x2 평균). 줄인 이미지의 (x, y)는 원본의 (2x+0.5, 2y+0.5)다.
    func halved() -> RGBImage {
        let w = width / 2, h = height / 2
        var out = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                for c in 0..<3 {
                    let i = ((2 * y) * width + 2 * x) * 4 + c
                    let sum = Int(pixels[i]) + Int(pixels[i + 4]) + Int(pixels[i + width * 4]) + Int(pixels[i + width * 4 + 4])
                    out[(y * w + x) * 4 + c] = UInt8((sum + 2) / 4)
                }
            }
        }
        return RGBImage(width: w, height: h, pixels: out)
    }
}

protocol FaceAligning: Sendable {
    /// 5점 랜드마크(이미지 픽셀)로 150x150 정렬 얼굴을 뽑는다.
    func chip(from image: RGBImage, landmarks: [CGPoint]) -> RGBImage?
}

/// dlib `get_face_chip(size: 150, padding: 0.25)`와 같은 방식으로 얼굴을 정렬한다.
///
/// 유사 변환으로 칩 좌표를 이미지에 옮기고 이중선형 보간한 뒤 소수점을 버린다(dlib과 같다).
/// 배율이 2보다 큰 큰 얼굴은 dlib이 이미지 피라미드로 먼저 줄이므로, 여기서는 2x2 평균으로 반씩 줄여 근사한다.
struct DlibFaceAligner: FaceAligning {
    var size = FaceGeometry.chipSize
    var padding = FaceGeometry.padding

    func chip(from image: RGBImage, landmarks: [CGPoint]) -> RGBImage? {
        guard let chip = FaceGeometry.chip(for: landmarks, size: size, padding: padding) else { return nil }
        var source = image
        var t = chip.transform
        // dlib: 줄인 사각형의 넓이가 칩보다 크면 한 단계 더 줄인다. 배율 2, 4, 8…을 넘을 때마다 반으로.
        var scale = chip.scale
        while scale > 2, source.width > 16, source.height > 16 {
            source = source.halved()
            // 원본 좌표 u → 줄인 좌표 (u - 0.5) / 2
            t = FaceGeometry.Affine(a: t.a / 2, b: t.b / 2, c: t.c / 2, d: t.d / 2, tx: (t.tx - 0.5) / 2, ty: (t.ty - 0.5) / 2)
            scale /= 2
        }
        return Self.sample(source, transform: t, size: size)
    }

    /// 칩의 각 픽셀을 변환한 자리에서 이중선형 보간한다. 이미지 밖은 검게 둔다(dlib과 같다).
    static func sample(_ image: RGBImage, transform t: FaceGeometry.Affine, size: Int) -> RGBImage {
        var out = [UInt8](repeating: 0, count: size * size * 4)
        let w = image.width, h = image.height
        image.pixels.withUnsafeBufferPointer { src in
            for y in 0..<size {
                for x in 0..<size {
                    let o = (y * size + x) * 4
                    out[o + 3] = 255
                    let px = t.a * Double(x) + t.b * Double(y) + t.tx
                    let py = t.c * Double(x) + t.d * Double(y) + t.ty
                    let left = Int(floor(px)), top = Int(floor(py))
                    guard left >= 0, top >= 0, left + 1 < w, top + 1 < h else { continue }
                    let fx = px - Double(left), fy = py - Double(top)
                    let i00 = (top * w + left) * 4, i01 = i00 + 4, i10 = i00 + w * 4, i11 = i10 + 4
                    for c in 0..<3 {
                        let v = (1 - fy) * ((1 - fx) * Double(src[i00 + c]) + fx * Double(src[i01 + c]))
                            + fy * ((1 - fx) * Double(src[i10 + c]) + fx * Double(src[i11 + c]))
                        out[o + c] = UInt8(min(max(v, 0), 255))
                    }
                }
            }
        }
        return RGBImage(width: size, height: size, pixels: out)
    }
}
