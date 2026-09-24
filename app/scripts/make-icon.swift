// 사용법: swift app/scripts/make-icon.swift <원본 PNG> <출력 .iconset 디렉터리>
//
// 24x16 논리 픽셀 그림을 `k = max(1, floor(size/24))` 배 최근접 이웃으로 키워 투명
// 정사각형 가운데에 둔다. 16 은 만들지 않는다 — 24 픽셀 원화를 16 으로 줄이면 최근접
// 이웃이 눈 구멍을 뭉갠다. `iconutil` 은 항목을 크기가 아니라 이름으로 식별하므로 이름도
// 한 벌로 못박는다.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let entries: [(pixels: Int, name: String)] = [
    (32, "icon_16x16@2x.png"),
    (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),
    (256, "icon_128x128@2x.png"),
    (512, "icon_512x512.png"),
    (1024, "icon_512x512@2x.png"),
]

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("make-icon: \(message)\n".utf8))
    exit(1)
}

let arguments = CommandLine.arguments
guard arguments.count == 3 else { fail("인자는 <원본 PNG> <출력 .iconset> 둘이다") }
let inputURL = URL(fileURLWithPath: arguments[1])
let outputURL = URL(fileURLWithPath: arguments[2], isDirectory: true)

guard let source = CGImageSourceCreateWithURL(inputURL as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
else { fail("\(inputURL.path) 를 풀지 못함") }

do {
    try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
} catch {
    fail("\(outputURL.path) 를 만들지 못함: \(error)")
}

for entry in entries {
    let size = entry.pixels
    let scale = max(1, size / image.width)
    let width = image.width * scale
    let height = image.height * scale

    guard let context = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { fail("\(size) 문맥을 만들지 못함") }

    context.clear(CGRect(x: 0, y: 0, width: size, height: size))
    context.interpolationQuality = .none
    let origin = CGPoint(x: (size - width) / 2, y: (size - height) / 2)
    context.draw(image, in: CGRect(origin: origin, size: CGSize(width: width, height: height)))

    guard let scaled = context.makeImage() else { fail("\(size) 이미지를 만들지 못함") }
    let fileURL = outputURL.appendingPathComponent(entry.name)
    guard let destination = CGImageDestinationCreateWithURL(
        fileURL as CFURL, UTType.png.identifier as CFString, 1, nil
    ) else { fail("\(fileURL.path) 를 쓰지 못함") }
    CGImageDestinationAddImage(destination, scaled, nil)
    guard CGImageDestinationFinalize(destination) else { fail("\(fileURL.path) 를 마무리하지 못함") }
}
