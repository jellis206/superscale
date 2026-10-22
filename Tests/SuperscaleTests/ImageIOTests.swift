// ABOUTME: Tests for ImageLoader and ImageWriter — image format support, colour profiles, alpha handling.
// ABOUTME: Validates AC6.1 (format support), AC6.2 (colour profile preservation), AC6.3 (alpha handling).

import XCTest
import CoreGraphics
import ImageIO
@testable import SuperscaleKit

final class ImageIOTests: XCTestCase {

    private var projectRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // SuperscaleTests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // project root
    }

    private var testImagesDir: URL {
        projectRoot.appendingPathComponent("Tests/images")
    }

    // RT-012: ImageLoader reads PNG and JPEG with correct dimensions
    func test_image_loader_reads_formats_with_correct_dimensions_RT012() throws {
        // PNG
        let pngURL = testImagesDir.appendingPathComponent("sketch1.png")
        try XCTSkipIf(!FileManager.default.fileExists(atPath: pngURL.path),
                      "Test image sketch1.png not found")

        let pngResult = try ImageLoader.load(from: pngURL)
        XCTAssertEqual(pngResult.image.width, 4085, "PNG width")
        XCTAssertEqual(pngResult.image.height, 4085, "PNG height")

        // JPEG
        let jpgURL = testImagesDir.appendingPathComponent("remy2.jpg")
        try XCTSkipIf(!FileManager.default.fileExists(atPath: jpgURL.path),
                      "Test image remy2.jpg not found")

        let jpgResult = try ImageLoader.load(from: jpgURL)
        XCTAssertEqual(jpgResult.image.width, 1024, "JPEG width")
        XCTAssertEqual(jpgResult.image.height, 1024, "JPEG height")
    }

    // RT-013: ImageWriter preserves colour profile from input
    func test_image_writer_preserves_colour_profile_RT013() throws {
        let pngURL = testImagesDir.appendingPathComponent("sketch1.png")
        try XCTSkipIf(!FileManager.default.fileExists(atPath: pngURL.path),
                      "Test image sketch1.png not found")

        let loaded = try ImageLoader.load(from: pngURL)

        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("superscale_test_\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        try ImageWriter.write(loaded.image, to: tmpURL, format: .png,
                              colorSpace: loaded.colorSpace)

        // Re-read and check colour space is preserved
        let reloaded = try ImageLoader.load(from: tmpURL)
        if let originalSpace = loaded.colorSpace,
           let reloadedSpace = reloaded.colorSpace {
            XCTAssertEqual(originalSpace.name, reloadedSpace.name,
                           "Colour profile should be preserved")
        }
    }

    // RT-014: Alpha channel is separated and recombined correctly
    func test_alpha_channel_separation_and_recombination_RT014() throws {
        // Create a test image with alpha
        let image = try makeTestImageWithAlpha(width: 64, height: 64)

        // Load via ImageLoader (it should detect and separate alpha)
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("superscale_alpha_test_\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        // Write the test image with alpha to disk
        try ImageWriter.write(image, to: tmpURL, format: .png, colorSpace: nil)

        let loaded = try ImageLoader.load(from: tmpURL)
        XCTAssertEqual(loaded.image.width, 64)
        XCTAssertEqual(loaded.image.height, 64)

        // If the input had alpha, alphaChannel should be non-nil
        if loaded.hasAlpha {
            XCTAssertNotNil(loaded.alphaChannel, "Alpha channel should be extracted")
            if let alpha = loaded.alphaChannel {
                XCTAssertEqual(alpha.width, 64, "Alpha width should match input")
                XCTAssertEqual(alpha.height, 64, "Alpha height should match input")
            }
        }

        // Recombine and verify dimensions match
        if let alpha = loaded.alphaChannel {
            let recombined = try ImageLoader.recombineAlpha(
                rgb: loaded.image, alpha: alpha)
            XCTAssertEqual(recombined.width, 64)
            XCTAssertEqual(recombined.height, 64)
        }
    }

    // MARK: - Helpers

    private func makeTestImageWithAlpha(width: Int, height: Int) throws -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: colorSpace, bitmapInfo: bitmapInfo.rawValue
        ) else {
            throw NSError(domain: "ImageIOTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to create CGContext"])
        }

        // Draw with varying alpha (left side transparent, right side opaque)
        for y in 0..<height {
            for x in 0..<width {
                let alpha = CGFloat(x) / CGFloat(width)
                context.setFillColor(red: 0.5, green: 0.3, blue: 0.8, alpha: alpha)
                context.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }

        guard let image = context.makeImage() else {
            throw NSError(domain: "ImageIOTests", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to create CGImage"])
        }
        return image
    }

    // MARK: - AC100.1: dimensions are pixels, whatever resolution the file records

    /// A per-run directory beneath the operating system's temporary directory.
    ///
    /// Removed exactly, never a shared parent, on success and on failure alike.
    private func scratchDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("image-dpi-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    /// Writes a picture of a given size, recording the resolution asked for.
    ///
    /// - Parameter resolution: the dpi to record, or nothing to record none at all. A PNG with no
    ///   `pHYs` chunk is the commonest real file and takes a different path through `ImageIO`.
    ///
    /// - Parameter orientation: an EXIF orientation to record. The left half of the stored pixels
    ///   is red and the right half blue, so where red ends up shows which way it was turned.
    private func writeImage(
        width: Int, height: Int,
        resolution: (horizontal: Double, vertical: Double)?,
        type: CFString,
        named name: String,
        in directory: URL,
        orientation: Int? = nil
    ) throws -> URL {
        let context = try XCTUnwrap(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.3, green: 0.5, blue: 0.7, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if orientation != nil {
            context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
            context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
            context.fill(CGRect(x: width / 2, y: 0, width: width - width / 2, height: height))
        }
        let image = try XCTUnwrap(context.makeImage())

        let url = directory.appendingPathComponent(name)
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithURL(url as CFURL, type, 1, nil))

        var properties: [CFString: Any] = [:]
        if let resolution {
            properties[kCGImagePropertyDPIWidth] = resolution.horizontal
            properties[kCGImagePropertyDPIHeight] = resolution.vertical
        }
        if let orientation {
            properties[kCGImagePropertyOrientation] = orientation
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination), "the fixture was written")
        return url
    }

    /// The resolution the file actually records, read back through `ImageIO`.
    private func recordedResolution(of url: URL) throws -> (Double, Double)? {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
            as? [CFString: Any] else { return nil }
        guard let horizontal = properties[kCGImagePropertyDPIWidth] as? Double,
              let vertical = properties[kCGImagePropertyDPIHeight] as? Double
        else { return nil }
        return (horizontal, vertical)
    }

    // RT-100.1, RT-100.3
    //
    // The defect's own case. `NSImage.size` is DPI-adjusted, so this picture reports about
    // 492 x 369 in points while being 2048 x 1536 in pixels — and every sizing decision the
    // application makes is arithmetic on pixels.
    //
    // RT-100.3 is folded in deliberately: without proving the fixture genuinely records 300 dpi,
    // the whole test is vacuous, because a fixture that silently failed to record it would leave
    // points and pixels equal again and pass regardless.
    func test_anImageStoredAt300DPIHasItsFullPixelDimensions_RT100_1() throws {
        let directory = try scratchDirectory()
        let url = try writeImage(
            width: 2048, height: 1536, resolution: (300, 300),
            type: "public.png" as CFString, named: "high.png", in: directory)

        let recorded = try XCTUnwrap(recordedResolution(of: url), "the fixture records a resolution")
        XCTAssertEqual(recorded.0, 300, accuracy: 0.5, "and it is the one asked for")
        XCTAssertEqual(recorded.1, 300, accuracy: 0.5)

        let loaded = try ImageLoader.load(from: url)
        XCTAssertEqual(loaded.image.width, 2048)
        XCTAssertEqual(loaded.image.height, 1536)
    }

    // RT-100.2
    //
    // The same content at the default resolution. Guards against a correction that introduces a
    // resolution-dependent path in the other direction, and against a hard-coded answer, since the
    // dimensions here differ from every other fixture in this group.
    func test_theSameContentAt72DPIHasIdenticalDimensions_RT100_2() throws {
        let directory = try scratchDirectory()
        let url = try writeImage(
            width: 1600, height: 900, resolution: (72, 72),
            type: "public.png" as CFString, named: "default.png", in: directory)

        let loaded = try ImageLoader.load(from: url)
        XCTAssertEqual(loaded.image.width, 1600)
        XCTAssertEqual(loaded.image.height, 900)
    }

    // RT-100.4
    //
    // A PNG frequently carries no `pHYs` chunk at all. `ImageIO` takes a different path and
    // `NSImage` assumes 72, so this is a distinct condition from "72 recorded" and it is the
    // commonest real file.
    func test_anImageWithNoResolutionRecordedHasItsFullPixelDimensions_RT100_4() throws {
        let directory = try scratchDirectory()
        let url = try writeImage(
            width: 1234, height: 567, resolution: nil,
            type: "public.png" as CFString, named: "bare.png", in: directory)

        let loaded = try ImageLoader.load(from: url)
        XCTAssertEqual(loaded.image.width, 1234)
        XCTAssertEqual(loaded.image.height, 567)
    }

    // RT-100.5
    //
    // Non-square resolution. An implementation dividing by a single resolution value passes every
    // square case and is wrong here, and both TIFF and JPEG permit it.
    func test_anImageWithDifferingAxisResolutionsHasItsFullPixelDimensions_RT100_5() throws {
        let directory = try scratchDirectory()
        let url = try writeImage(
            width: 800, height: 1200, resolution: (300, 150),
            type: "public.png" as CFString, named: "anisotropic.png", in: directory)

        let recorded = try XCTUnwrap(recordedResolution(of: url))
        XCTAssertNotEqual(recorded.0, recorded.1, "the axes genuinely differ")

        let loaded = try ImageLoader.load(from: url)
        XCTAssertEqual(loaded.image.width, 800)
        XCTAssertEqual(loaded.image.height, 1200)
    }

    // RT-100.6
    //
    // **The format the defect actually arrives in.** Resolution is stored by an entirely different
    // mechanism per format — `pHYs` in PNG, JFIF density and EXIF in JPEG — and every photograph the
    // author works with is a JPEG. Testing PNG alone would test the format it is least likely to
    // arrive in.
    func test_thePropertyHoldsForJPEGAsWellAsPNG_RT100_6() throws {
        let directory = try scratchDirectory()
        let url = try writeImage(
            width: 1920, height: 1080, resolution: (300, 300),
            type: "public.jpeg" as CFString, named: "photo.jpg", in: directory)

        let recorded = try XCTUnwrap(recordedResolution(of: url), "the JPEG records a resolution")
        XCTAssertEqual(recorded.0, 300, accuracy: 0.5)

        let loaded = try ImageLoader.load(from: url)
        XCTAssertEqual(loaded.image.width, 1920)
        XCTAssertEqual(loaded.image.height, 1080)
    }

    // MARK: - Orientation

    // A camera stores a portrait sideways and records orientation 6 ("turn 90° clockwise to
    // view") instead of rotating the pixels. Loading must apply it, or the upscale, which carries
    // no orientation, comes out sideways.
    func test_aPictureRecordingAnOrientationLoadsUpright() throws {
        let directory = try scratchDirectory()
        let url = try writeImage(
            width: 40, height: 20, resolution: nil,
            type: "public.jpeg" as CFString, named: "portrait.jpg", in: directory,
            orientation: 6)

        let loaded = try ImageLoader.load(from: url).image
        XCTAssertEqual(loaded.width, 20, "turned to portrait")
        XCTAssertEqual(loaded.height, 40)
        // Turning clockwise brings the stored left (red) half to the top.
        let (top, bottom) = try (rgb(of: loaded, x: 10, y: 5), rgb(of: loaded, x: 10, y: 35))
        XCTAssertGreaterThan(top.red, 200, "top is red: \(top)")
        XCTAssertGreaterThan(bottom.blue, 200, "bottom is blue: \(bottom)")
    }

    // The writer only makes PNG and JPEG, so a HEIC or TIFF input must not get its own extension
    // on what is really a PNG.
    func test_outputFilenameNamesTheFormatActuallyWritten() {
        XCTAssertEqual(ImageWriter.outputFilename(for: "/a/photo.jpg", scale: 2), "photo_2x.jpg")
        XCTAssertEqual(ImageWriter.outputFilename(for: "/a/photo.JPEG", scale: 4), "photo_4x.JPEG")
        XCTAssertEqual(ImageWriter.outputFilename(for: "/a/shot.png", scale: 2.4), "shot_2.4x.png")
        XCTAssertEqual(ImageWriter.outputFilename(for: "/a/IMG_1.HEIC", scale: 2), "IMG_1_2x.png")
        XCTAssertEqual(ImageWriter.outputFilename(for: "/a/scan.tiff", scale: 2), "scan_2x.png")
        XCTAssertEqual(ImageWriter.outputFilename(for: "/a/bare", scale: 2), "bare_2x.png")
    }

    /// The colour of one pixel, `y` counted from the top.
    private func rgb(of image: CGImage, x: Int, y: Int) throws -> (red: UInt8, green: UInt8, blue: UInt8) {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try XCTUnwrap(
            CGContext(
                data: &pixels, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let i = (y * image.width + x) * 4
        return (pixels[i], pixels[i + 1], pixels[i + 2])
    }
}
