import AppKit
import CoreGraphics
import Vision

struct DetectorParams {
    var padX: CGFloat = 2
    var padY: CGFloat = 1
    var rowDiffThreshold: Int = 90
    var minRowPixels: Int = 2
    var mergeGapX: CGFloat = 24
}

// A detected text region and the average color of the text inside it.
struct DetectedRect {
    let rect: CGRect      // window coords, points, top-left origin
    let color: CGColor?   // nil → caller picks a neutral fallback
}

// RGBA8 pixel buffer for a CGImage. Keeps the backing context alive.
final class PixelBuf {
    let w: Int, h: Int
    let px: UnsafeMutablePointer<UInt8>
    private let ctx: CGContext

    init?(_ img: CGImage) {
        w = img.width; h = img.height
        guard w > 0, h > 0,
              let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        c.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let d = c.data else { return nil }
        ctx = c
        px = d.bindMemory(to: UInt8.self, capacity: w * h * 4)
    }
}

// Vision text detection, line-level boxes, in window coords (points, top-left).
func visionLineBoxes(_ img: CGImage, size: CGSize, p: DetectorParams) -> [CGRect] {
    let req = VNRecognizeTextRequest()
    req.recognitionLevel = .fast
    req.usesLanguageCorrection = false
    let handler = VNImageRequestHandler(cgImage: img, options: [:])
    guard (try? handler.perform([req])) != nil, let obs = req.results else { return [] }
    var rects: [CGRect] = []
    for o in obs {
        let bb = o.boundingBox // normalized, origin bottom-left
        rects.append(CGRect(x: bb.minX * size.width - p.padX,
                            y: (1 - bb.maxY) * size.height - p.padY,
                            width: bb.width * size.width + 2 * p.padX,
                            height: bb.height * size.height + 2 * p.padY))
    }
    return rects
}

// Merge only boxes on the same visual line (vertical overlap) that are close
// horizontally. Never merges across lines, so background stays visible.
func mergeLineBoxes(_ rects: [CGRect], gapX: CGFloat) -> [CGRect] {
    var out: [CGRect] = []
    for var r in rects {
        var merged = true
        while merged {
            merged = false
            for (i, e) in out.enumerated() {
                let vOverlap = min(e.maxY, r.maxY) - max(e.minY, r.minY)
                let hGap = max(e.minX, r.minX) - min(e.maxX, r.maxX)
                if vOverlap > 0.5 * min(e.height, r.height) && hGap < gapX {
                    r = r.union(e)
                    out.remove(at: i)
                    merged = true
                    break
                }
            }
        }
        out.append(r)
    }
    return out
}

// The screenshot API may letterbox the window content into a larger canvas
// instead of scaling it. Find the bounding box of non-transparent pixels so
// coordinates map from actual content, not the padded canvas.
func contentBounds(_ buf: PixelBuf) -> CGRect? {
    var minX = buf.w, maxX = -1, minY = buf.h, maxY = -1
    var y = 0
    while y < buf.h {
        let rowOff = y * buf.w * 4
        var x = 0
        while x < buf.w {
            if buf.px[rowOff + x * 4 + 3] > 16 {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
            x += 2
        }
        y += 2
    }
    guard maxX >= minX, maxY >= minY else { return nil }
    return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
}

// Pixel analysis: bands of rows containing anything that differs from the
// dominant background color. Tight per-line coverage independent of OCR.
// nil if the background is not uniform enough to trust this method.
func contentRowBands(_ buf: PixelBuf, windowSize: CGSize, p: DetectorParams) -> [CGRect]? {
    let w = buf.w, h = buf.h
    let px = buf.px

    // Dominant color via 5-bit/channel histogram, sampling every 4th pixel.
    var hist = [Int](repeating: 0, count: 32768)
    let total = w * h
    var i = 0
    while i < total {
        let o = i * 4
        let key = ((Int(px[o]) >> 3) << 10) | ((Int(px[o + 1]) >> 3) << 5) | (Int(px[o + 2]) >> 3)
        hist[key] += 1
        i += 4
    }
    var modeKey = 0, modeCount = 0
    for (k, c) in hist.enumerated() where c > modeCount { modeKey = k; modeCount = c }
    guard modeCount * 4 >= total * 2 / 5 else { return nil } // bg must cover ≥40%
    let bgR = (((modeKey >> 10) & 31) << 3) + 4
    let bgG = (((modeKey >> 5) & 31) << 3) + 4
    let bgB = ((modeKey & 31) << 3) + 4

    let sx = windowSize.width / CGFloat(w)
    let sy = windowSize.height / CGFloat(h)
    var bands: [CGRect] = []
    var bandStart = -1
    var bandMinX = w, bandMaxX = 0
    func closeBand(_ endRow: Int) {
        guard bandStart >= 0 else { return }
        bands.append(CGRect(x: CGFloat(bandMinX) * sx - p.padX,
                            y: CGFloat(bandStart) * sy - p.padY,
                            width: CGFloat(bandMaxX - bandMinX + 1) * sx + 2 * p.padX,
                            height: CGFloat(endRow - bandStart) * sy + 2 * p.padY))
        bandStart = -1; bandMinX = w; bandMaxX = 0
    }
    for row in 0..<h {
        var count = 0, minX = w, maxX = 0
        let rowOff = row * w * 4
        var x = 0
        while x < w {
            let o = rowOff + x * 4
            let d = abs(Int(px[o]) - bgR) + abs(Int(px[o + 1]) - bgG) + abs(Int(px[o + 2]) - bgB)
            if d > p.rowDiffThreshold {
                count += 1
                if x < minX { minX = x }
                if x > maxX { maxX = x }
            }
            x += 2
        }
        if count >= p.minRowPixels {
            if bandStart < 0 { bandStart = row }
            if minX < bandMinX { bandMinX = minX }
            if maxX > bandMaxX { bandMaxX = maxX }
        } else if bandStart >= 0 {
            closeBand(row)
        }
    }
    closeBand(h)
    return bands
}

// Average color of the "text" pixels inside a rect: find the rect's own
// dominant (background) color, then average everything that differs from it.
func localTextColor(_ buf: PixelBuf, pixelRect pr: CGRect) -> CGColor? {
    let x0 = max(0, Int(pr.minX)), y0 = max(0, Int(pr.minY))
    let x1 = min(buf.w - 1, Int(pr.maxX)), y1 = min(buf.h - 1, Int(pr.maxY))
    guard x1 > x0, y1 > y0 else { return nil }
    var hist = [Int](repeating: 0, count: 32768)
    var y = y0
    while y <= y1 {
        let ro = y * buf.w * 4
        var x = x0
        while x <= x1 {
            let o = ro + x * 4
            hist[((Int(buf.px[o]) >> 3) << 10) | ((Int(buf.px[o + 1]) >> 3) << 5) | (Int(buf.px[o + 2]) >> 3)] += 1
            x += 2
        }
        y += 2
    }
    var mk = 0, mc = 0
    for (k, c) in hist.enumerated() where c > mc { mk = k; mc = c }
    let br = (((mk >> 10) & 31) << 3) + 4
    let bg = (((mk >> 5) & 31) << 3) + 4
    let bb = ((mk & 31) << 3) + 4
    var sr = 0, sg = 0, sb = 0, n = 0
    y = y0
    while y <= y1 {
        let ro = y * buf.w * 4
        var x = x0
        while x <= x1 {
            let o = ro + x * 4
            let r = Int(buf.px[o]), g = Int(buf.px[o + 1]), b = Int(buf.px[o + 2])
            if abs(r - br) + abs(g - bg) + abs(b - bb) > 70 {
                sr += r; sg += g; sb += b; n += 1
            }
            x += 2
        }
        y += 2
    }
    guard n >= 6 else { return nil }
    return CGColor(red: CGFloat(sr / n) / 255, green: CGFloat(sg / n) / 255,
                   blue: CGFloat(sb / n) / 255, alpha: 1)
}

// Combined detection for one window capture. Also returns the working image
// (cropped to real content if the capture was letterboxed) for debug dumps.
func detectTextRects(img inImg: CGImage, size: CGSize, isTerminal: Bool, p: DetectorParams)
    -> (dets: [DetectedRect], method: String, workImg: CGImage) {
    var img = inImg
    var method = ""
    if let b0 = PixelBuf(img), let cb = contentBounds(b0), cb.width > 8, cb.height > 8,
       cb.width < CGFloat(img.width) * 0.98 || cb.height < CGFloat(img.height) * 0.98,
       let c = img.cropping(to: cb) {
        img = c
        method = "crop+"
    }
    guard let buf = PixelBuf(img) else {
        return ([DetectedRect(rect: CGRect(origin: .zero, size: size), color: nil)], method + "nobuf", img)
    }
    var vision = mergeLineBoxes(visionLineBoxes(img, size: size, p: p), gapX: p.mergeGapX)
    method += "vision(\(vision.count))"
    var rects: [CGRect]
    if isTerminal {
        if let bands = contentRowBands(buf, windowSize: size, p: p) {
            method += "+bands(\(bands.count))"
            // Bands are authoritative in terminals: drop Vision boxes they already cover.
            vision = vision.filter { v in
                let a = v.width * v.height
                guard a > 0 else { return false }
                var inter: CGFloat = 0
                for b in bands {
                    let i = v.intersection(b)
                    if !i.isNull { inter += i.width * i.height }
                }
                return inter < 0.5 * a
            }
            rects = vision + bands
        } else if vision.isEmpty {
            method += "+failclosed"
            rects = [CGRect(origin: .zero, size: size)]
        } else {
            method += "+nobands"
            rects = vision
        }
    } else {
        rects = vision
    }
    let sx = CGFloat(buf.w) / size.width
    let sy = CGFloat(buf.h) / size.height
    let dets = rects.map { r in
        DetectedRect(rect: r,
                     color: localTextColor(buf, pixelRect: CGRect(x: r.minX * sx, y: r.minY * sy,
                                                                  width: r.width * sx, height: r.height * sy)))
    }
    return (dets, method + " → \(dets.count)", img)
}

// Debug: draw detection rects (in their sampled colors) over the capture.
func saveAnnotated(_ img: CGImage, dets: [DetectedRect], size: CGSize, to url: URL) {
    let w = img.width, h = img.height
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    let sx = CGFloat(w) / size.width
    let sy = CGFloat(h) / size.height
    ctx.setLineWidth(2)
    for d in dets {
        let r = d.rect
        let cg = CGRect(x: r.origin.x * sx,
                        y: CGFloat(h) - (r.origin.y + r.height) * sy,
                        width: r.width * sx, height: r.height * sy)
        let c = d.color ?? CGColor(red: 1, green: 0, blue: 0, alpha: 1)
        ctx.setFillColor(c.copy(alpha: 0.5) ?? c)
        ctx.setStrokeColor(CGColor(red: 1, green: 0, blue: 0, alpha: 0.85))
        ctx.fill(cg)
        ctx.stroke(cg)
    }
    guard let out = ctx.makeImage() else { return }
    let rep = NSBitmapImageRep(cgImage: out)
    if let d = rep.representation(using: .png, properties: [:]) {
        try? d.write(to: url)
    }
}
