import CoreGraphics
import ImageIO
import XCTest
@testable import HeadsUp

final class DetectorTests: XCTestCase {
  /// Ultralytics' sample street photo: several people standing in front of a bus.
  func testFindsPeopleAndBusInSamplePhoto() throws {
    let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "bus", withExtension: "jpg"))
    let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
    let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    let buffer = try XCTUnwrap(image.makePixelBuffer())

    let detections = try YOLODetector().detect(buffer, minConfidence: 0.4)
    for d in detections { print("DET", d.objectClass, d.confidence, d.left, d.right, d.top, d.bottom) }

    let people = detections.filter { $0.objectClass == .person }
    let bus = try XCTUnwrap(detections.first { $0.objectClass == .bus })
    XCTAssertGreaterThanOrEqual(people.count, 3)
    // The bus fills most of the width; people are narrow and in the lower half.
    XCTAssertGreaterThan(bus.width, 1.5)
    for p in people {
      XCTAssertLessThan(p.width, 0.8)
      XCTAssertGreaterThan(p.bottom, 0.6)
    }
    for d in detections {
      XCTAssertTrue((-1.01...1.01).contains(d.left) && (-1.01...1.01).contains(d.right))
      XCTAssertTrue((-0.01...1.01).contains(d.top) && (-0.01...1.01).contains(d.bottom))
      XCTAssertLessThan(d.left, d.right)
      XCTAssertLessThan(d.top, d.bottom)
    }
    // The leftmost person in the photo stands at the left edge of the frame.
    XCTAssertLessThan(people.map(\.left).min() ?? 0, -0.7)
  }
}
