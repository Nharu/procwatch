// 사용법: swift app/scripts/make-readme-gif.swift <프레임 PNG…> <출력 GIF>
//
// README 상단의 걸음 그림을 만든다. 24x16 논리 픽셀 프레임을 각각 6배 최근접 이웃으로
// 키워 투명 배경 GIF 의 한 장으로 쓴다 — 브라우저가 원화를 키우면 흐려지므로 미리 키운다.
// 프레임 지연은 0.15초, 반복은 무한이다.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let scale = 6
let frameDelay = 0.15

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("make-readme-gif: \(message)\n".utf8))
    exit(1)
}

let arguments = CommandLine.arguments
guard arguments.count >= 3 else { fail("인자는 <프레임 PNG…> <출력 GIF> 이고 프레임은 하나 이상이다") }
let inputURLs = arguments[1..<(arguments.count - 1)].map { URL(fileURLWithPath: $0) }
let outputURL = URL(fileURLWithPath: arguments[arguments.count - 1])

let images: [CGImage] = inputURLs.map { url in
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { fail("\(url.path) 를 풀지 못함") }
    return image
}

let width = images[0].width
let height = images[0].height
for (url, image) in zip(inputURLs, images) where image.width != width || image.height != height {
    fail("\(url.path) 의 크기 \(image.width)x\(image.height) 가 첫 프레임 \(width)x\(height) 와 다름")
}

do {
    try FileManager.default.createDirectory(
        at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true
    )
} catch {
    fail("\(outputURL.deletingLastPathComponent().path) 를 만들지 못함: \(error)")
}

guard let destination = CGImageDestinationCreateWithURL(
    outputURL as CFURL, UTType.gif.identifier as CFString, images.count, nil
) else { fail("\(outputURL.path) 를 쓰지 못함") }

let fileProperties = [
    kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
] as CFDictionary
CGImageDestinationSetProperties(destination, fileProperties)

let frameProperties = [
    kCGImagePropertyGIFDictionary: [
        kCGImagePropertyGIFDelayTime: frameDelay,
        kCGImagePropertyGIFUnclampedDelayTime: frameDelay,
    ],
] as CFDictionary

for (index, image) in images.enumerated() {
    let scaledWidth = width * scale
    let scaledHeight = height * scale
    guard let context = CGContext(
        data: nil,
        width: scaledWidth,
        height: scaledHeight,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { fail("\(index) 번 프레임 문맥을 만들지 못함") }

    context.clear(CGRect(x: 0, y: 0, width: scaledWidth, height: scaledHeight))
    context.interpolationQuality = .none
    context.draw(image, in: CGRect(x: 0, y: 0, width: scaledWidth, height: scaledHeight))

    guard let scaled = context.makeImage() else { fail("\(index) 번 프레임 이미지를 만들지 못함") }
    CGImageDestinationAddImage(destination, scaled, frameProperties)
}

guard CGImageDestinationFinalize(destination) else { fail("\(outputURL.path) 를 마무리하지 못함") }
