import Testing
@testable import ServerLabKit

@Suite struct TCPSegmentOrderingTests {
    func line(_ seq: Int, _ hex: String, port: Int = 5432, stream: Int = 0, time: String = "0.1") -> String {
        "\(time)\t\(port)\t\(stream)\t\(seq)\t\(hex)"
    }

    func payloads(_ output: String) -> [String] {
        output.split(separator: "\n").map { String($0.split(separator: "\t").last ?? "") }
    }

    @Test func retransmissionsAreDropped() {
        let input = [line(1, "aabb"), line(1, "aabb"), line(3, "cc")].joined(separator: "\n")
        #expect(payloads(TCPSegmentOrdering.ordered(fromTSharkFields: input)) == ["aabb", "cc"])
    }

    @Test func overlapsAreTrimmed() {
        let input = [line(1, "aabb"), line(2, "bbccdd")].joined(separator: "\n")
        #expect(payloads(TCPSegmentOrdering.ordered(fromTSharkFields: input)) == ["aabb", "ccdd"])
    }

    @Test func earlySegmentsWaitForTheGap() {
        let input = [line(1, "aa"), line(3, "cc"), line(2, "bb")].joined(separator: "\n")
        #expect(payloads(TCPSegmentOrdering.ordered(fromTSharkFields: input)) == ["aa", "bb", "cc"])
    }

    @Test func directionsAndStreamsAreSeparate() {
        let input = [line(1, "aa"), line(1, "bb", port: 50000), line(1, "cc", stream: 1)].joined(separator: "\n")
        #expect(payloads(TCPSegmentOrdering.ordered(fromTSharkFields: input)) == ["aa", "bb", "cc"])
    }
}
