import XCTest
@testable import HorizonCore

final class CoreTests: XCTestCase {
    func testFullTurnNeverExposesCorners() throws {
        for source in [Size2(2160, 3840), Size2(1080, 1920), Size2(3024, 4032)] {
            for output in [Size2(1920, 1080), Size2(1080, 1920), Size2(1080, 1080)] {
                for degree in stride(from: -720.0, through: 720, by: 3) {
                    for target in [Point2(-900, 9999), source.center, Point2(10000, -800)] {
                        let p = try CropGeometry.plan(source: source, output: output,
                            angle: degree * .pi / 180, zoom: 1.4, fullTurn: true,
                            reserve: 0.80, requestedCenter: target)
                        for corner in [Point2(0, 0), Point2(output.width, 0),
                                       Point2(0, output.height), Point2(output.width, output.height)] {
                            let s = p.outputToSource(corner)
                            XCTAssertGreaterThanOrEqual(s.x, -1e-7)
                            XCTAssertGreaterThanOrEqual(s.y, -1e-7)
                            XCTAssertLessThanOrEqual(s.x, source.width + 1e-7)
                            XCTAssertLessThanOrEqual(s.y, source.height + 1e-7)
                        }
                    }
                }
            }
        }
    }
    func testNonHorizonCropAlsoHasNoBlackCorners() throws {
        for degree in stride(from: 0.0, through: 360, by: 5) {
            let p = try CropGeometry.plan(source: Size2(2160,3840), output: Size2(1920,1080),
                angle: degree * .pi / 180, fullTurn: false, requestedCenter: Point2(0,0))
            for c in [Point2(0,0), Point2(1920,0), Point2(0,1080), Point2(1920,1080)] {
                let s = p.outputToSource(c)
                XCTAssertTrue(s.x >= -1e-7 && s.x <= 2160 + 1e-7 && s.y >= -1e-7 && s.y <= 3840 + 1e-7)
            }
        }
    }
    func testNoBreathingOverRotation() throws {
        let scales = try (0...360).map { d in
            try CropGeometry.plan(source: Size2(2160,3840), output: Size2(1920,1080),
                                  angle: Double(d) * .pi / 180, fullTurn: true).scale
        }
        XCTAssertEqual(scales.min()!, scales.max()!, accuracy: 1e-12)
    }
    func testTransformRoundTripAndOffCenterAnchor() throws {
        let p = try CropGeometry.plan(source: Size2(2160,3840), output: Size2(1080,1920),
                                     angle: 1.1, zoom: 3, fullTurn: true)
        let target = Point2(1200,2100), anchor = Point2(0.3,0.7)
        let center = p.centerHolding(target: target, at: anchor)
        let q = try CropGeometry.plan(source: p.source, output: p.output, angle: p.angle,
            zoom: 3, fullTurn: true, requestedCenter: center)
        let mapped = q.sourceToOutput(target)
        XCTAssertEqual(mapped.x, anchor.x * 1080, accuracy: 1e-8)
        XCTAssertEqual(mapped.y, anchor.y * 1920, accuracy: 1e-8)
        let back = q.outputToSource(mapped)
        XCTAssertEqual(back.x, target.x, accuracy: 1e-8)
        XCTAssertEqual(back.y, target.y, accuracy: 1e-8)
    }
    func testClampIsReported() throws {
        let p = try CropGeometry.plan(source: Size2(1080,1920), output: Size2(1920,1080),
                                     angle: .pi/4, fullTurn: true, requestedCenter: Point2(-1,9999))
        XCTAssertTrue(p.wasClamped)
    }
    func testInvalidGeometryIsRejected() {
        XCTAssertThrowsError(try CropGeometry.plan(source: Size2(0,1), output: Size2(1,1), angle: 0, fullTurn: true))
        XCTAssertThrowsError(try CropGeometry.plan(source: Size2(1,1), output: Size2(1,1), angle: .nan, fullTurn: true))
        XCTAssertThrowsError(try CropGeometry.plan(source: Size2(1,1), output: Size2(1,1), angle: 0, zoom: 0, fullTurn: true))
    }
    func testHorizonIsContinuousThroughMultipleTurns() {
        var estimator = HorizonEstimator()
        var last: Double?
        for d in 0...1080 {
            let a = Double(d) * .pi/180
            let s = estimator.update(MotionReading(time: Double(d)/60, gx: -sin(a), gy: -cos(a), gz: 0, rateZ: .pi/3))
            XCTAssertEqual(s.angle, a, accuracy: 1e-8)
            if let last { XCTAssertLessThan(abs(s.angle-last), 0.02) }
            last = s.angle
        }
    }
    func testFrontCameraRollSign() {
        var rear = HorizonEstimator(), front = HorizonEstimator()
        let m = MotionReading(time: 1, gx: 0.5, gy: -sqrt(0.75), gz: 0, rateZ: 0)
        XCTAssertEqual(rear.update(m).angle, -.pi/6, accuracy: 1e-8)
        XCTAssertEqual(front.update(m, unmirroredFront: true).angle, .pi/6, accuracy: 1e-8)
    }
    func testVerticalSingularityUsesGyroAndReportsUnreliable() {
        var e = HorizonEstimator()
        _ = e.update(MotionReading(time: 0, gx: 0, gy: -1, gz: 0, rateZ: 0))
        let s = e.update(MotionReading(time: 0.05, gx: 0, gy: 0, gz: -1, rateZ: 2))
        XCTAssertFalse(s.gravityReliable)
        XCTAssertEqual(s.angle, 0.1, accuracy: 1e-10)
    }
    func testMotionInterpolationStalenessAndBoundedMemory() {
        var h = MotionHistory(capacity: 3)
        for i in 0...4 { h.append(MotionReading(time: Double(i), gx: Double(i), gy: 0, gz: 0, rateZ: 0)) }
        XCTAssertEqual(h.readings.count, 3)
        XCTAssertEqual(h.sample(at: 2.5)?.gx, 2.5)
        XCTAssertNil(h.sample(at: 1))
        XCTAssertNil(h.sample(at: 4.5))
        h.append(MotionReading(time: 3, gx: 0, gy: 0, gz: 0, rateZ: 0))
        XCTAssertEqual(h.readings.last?.time, 4)
    }
    func testRealtimeVideoAndAudioStayOnSameTimeline() {
        var t = RecordingTimeline(cadence: .realtime)
        XCTAssertNil(t.audioTime(sourceTime: 5))
        XCTAssertEqual(t.accept(sourceTime: 5), 0)
        XCTAssertEqual(t.accept(sourceTime: 6), 1)
        XCTAssertEqual(t.audioTime(sourceTime: 6), 1)
        XCTAssertNil(t.accept(sourceTime: 6))
        XCTAssertNil(t.accept(sourceTime: 4))
        XCTAssertNil(t.audioTime(sourceTime: 4))
    }
    func testSlowMotionIsReallyFourTimesSlower() {
        var t = RecordingTimeline(cadence: .slowMotion(captureFPS: 120, playbackFPS: 30))
        XCTAssertEqual(t.accept(sourceTime: 10), 0)
        XCTAssertEqual(t.accept(sourceTime: 11), 4)
        XCTAssertNil(t.audioTime(sourceTime: 11))
    }
    func testTimelapseSkipsFramesAndOutputsThirtyFPS() {
        var t = RecordingTimeline(cadence: .timeLapse(interval: 0.5, playbackFPS: 30))
        XCTAssertEqual(t.accept(sourceTime: 2), 0)
        XCTAssertNil(t.accept(sourceTime: 2.1))
        XCTAssertEqual(t.accept(sourceTime: 2.5)!, 1.0/30, accuracy: 1e-9)
        XCTAssertEqual(t.accept(sourceTime: 3)!, 2.0/30, accuracy: 1e-9)
        XCTAssertNil(t.audioTime(sourceTime: 3))
    }
    func testAngleWrapAtPi() {
        XCTAssertEqual(AngleMath.unwrap(-.pi + 0.01, near: .pi - 0.01), .pi + 0.01, accuracy: 1e-10)
    }
    func testZoomTransitionIsMonotonicAndFrameRateIndependent() throws {
        func run(_ fps: Double) -> Double {
            var z = 1.0
            for _ in 0..<Int(0.25*fps) {
                let next = ZoomTransition.step(current:z,target:4,deltaTime:1/fps)
                XCTAssertGreaterThanOrEqual(next,z); XCTAssertLessThanOrEqual(next,4); z = next
            }
            return z
        }
        XCTAssertEqual(run(30),4,accuracy:0.01); XCTAssertEqual(run(120),4,accuracy:0.01)
        var down = 4.0
        for _ in 0..<20 { let next = ZoomTransition.step(current:down,target:1,deltaTime:1/60); XCTAssertLessThanOrEqual(next,down); XCTAssertGreaterThanOrEqual(next,1); down = next }
        XCTAssertEqual(down,1,accuracy:0.01)
    }
    func testCropPlanRecordsRequestedZoom() throws {
        let p = try CropGeometry.plan(source:Size2(1080,1920),output:Size2(1080,1920),angle:0.3,zoom:2.25,fullTurn:true,reserve:0.95)
        XCTAssertEqual(p.zoom,2.25,accuracy:1e-12)
    }
    func testFrameLockMotionDirectionsMatchFloatingCropConvention() {
        let rightPan = FrameLockMath.delta(rateX: 0, rateY: 2, dt: 0.02, horizontalFOVDegrees: 70, sourceAspect: 16.0/9.0)
        let downTilt = FrameLockMath.delta(rateX: 2, rateY: 0, dt: 0.02, horizontalFOVDegrees: 70, sourceAspect: 16.0/9.0)
        XCTAssertLessThan(rightPan.x, 0)
        XCTAssertEqual(rightPan.y, 0, accuracy: 1e-12)
        XCTAssertGreaterThan(downTilt.y, 0)
        XCTAssertEqual(downTilt.x, 0, accuracy: 1e-12)
    }

    func testFloatingCropPinsAtEdgeAndMovesAgainWhenDirectionReverses() throws {
        let source = Size2(1280,720), output = Size2(1280,720)
        let edge = try CropGeometry.plan(source: source, output: output, angle: 0, zoom: 3, fullTurn: false, reserve: 0.8,
                                         requestedCenter: Point2(-10_000,360))
        XCTAssertTrue(edge.wasClamped)
        let farther = try CropGeometry.plan(source: source, output: output, angle: 0, zoom: 3, fullTurn: false, reserve: 0.8,
                                            requestedCenter: Point2(edge.center.x-500,360))
        XCTAssertEqual(farther.center.x,edge.center.x,accuracy:1e-9)
        let reversed = try CropGeometry.plan(source: source, output: output, angle: 0, zoom: 3, fullTurn: false, reserve: 0.8,
                                             requestedCenter: Point2(edge.center.x+80,360))
        XCTAssertGreaterThan(reversed.center.x,edge.center.x)
    }

}
