import CoreGraphics
import ImageIO
import XCTest
@testable import HeadsUp

final class HeadMotionTests: XCTestCase {
  /// Crops the sample photo at two horizontal offsets, like a camera panning.
  private func crop(_ image: CGImage, x: Int) -> CVPixelBuffer {
    image.cropping(to: CGRect(x: x, y: 200, width: 360, height: 640))!.makePixelBuffer()!
  }

  func testShiftSignAndSize() throws {
    let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "bus", withExtension: "jpg"))
    let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
    let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))

    // Camera pans right by 18 px: the crop window moves right, so content moves LEFT.
    let estimator = HeadMotionEstimator()
    XCTAssertEqual(estimator.shift(for: crop(image, x: 200)), 0)
    let left = estimator.shift(for: crop(image, x: 218))
    XCTAssertEqual(left, -18.0 / 360 * 2, accuracy: 0.02)
    // And back: content moves right.
    let right = estimator.shift(for: crop(image, x: 200))
    XCTAssertEqual(right, 18.0 / 360 * 2, accuracy: 0.02)
    // No motion.
    XCTAssertEqual(estimator.shift(for: crop(image, x: 200)), 0, accuracy: 0.01)
  }
}
