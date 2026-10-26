import Foundation
import Testing
@testable import BBCD4Mac

private actor WorkProbe {
    private(set) var active = 0
    private(set) var peak = 0
    private(set) var starts: [Int] = []
    func begin(_ item: Int) { active += 1; peak = max(peak, active); starts.append(item) }
    func end() { active -= 1 }
    func snapshot() -> (active: Int, peak: Int, starts: [Int]) { (active, peak, starts) }
}

@Test func segmentSchedulingRespectsLimitsAndRetainsFailures() async throws {
    for limit in [1, 2, 5, 10, 25, 50] {
        let probe = WorkProbe()
        let failures = try await DownloadEngine.fetchSegments(Array(0..<64), maximumConcurrent: limit, update: { _ in }) { segment in
            await probe.begin(segment)
            do {
                try await Task.sleep(for: .milliseconds(10))
                await probe.end()
                if segment == 9 { throw URLError(.timedOut) }
            } catch is CancellationError { await probe.end(); throw CancellationError() }
        }
        let measured = await probe.snapshot()
        #expect(measured.active == 0)
        #expect(measured.peak == limit)
        #expect(Set(measured.starts) == Set(0..<64))
        #expect(failures == [9])
    }
}

@Test func segmentSchedulingCancelsWithoutStartingRemainingWork() async throws {
    let probe = WorkProbe()
    let task = Task {
        try await DownloadEngine.fetchSegments(Array(0..<1000), maximumConcurrent: 5, update: { _ in }) { segment in
            await probe.begin(segment)
            do { try await Task.sleep(for: .seconds(10)); await probe.end() }
            catch { await probe.end(); throw error }
        }
    }
    for _ in 0..<1000 {
        if await probe.snapshot().active == 5 { break }
        try await Task.sleep(for: .milliseconds(1))
    }
    task.cancel()
    do { _ = try await task.value; Issue.record("Cancellation must propagate") }
    catch { #expect(error is CancellationError) }
    let measured = await probe.snapshot()
    #expect(measured.active == 0)
    #expect(measured.starts.count == 5)
}

@Test @MainActor func statusChecksAreBoundedDeduplicatedAndReusable() async throws {
    let probe = WorkProbe()
    let monitor = StreamAvailabilityMonitor { url in
        await probe.begin(Int(url)!)
        try await Task.sleep(for: .milliseconds(20))
        await probe.end()
        return url != "3"
    }
    let urls = (0..<25).map(String.init)
    let schedule = StreamAvailabilitySchedule(isEnabled: true, interval: 0, urls: urls + urls)
    #expect(schedule.urls == urls)
    await monitor.run(schedule)
    let measured = await probe.snapshot()
    #expect(measured.active == 0)
    #expect(measured.peak == StreamAvailabilityPreferences.maximumConcurrentChecks)
    #expect(measured.starts.count == 25)
    #expect(monitor.results.count == 25)
    #expect(monitor.results["3"]?.state == .offline)
    #expect(monitor.results["2"]?.state == .online)
    #expect(!monitor.isChecking && monitor.checkingURLs.isEmpty)
    await monitor.run(schedule)
    #expect(await probe.snapshot().starts.count == 25)
    await monitor.run(StreamAvailabilitySchedule(isEnabled: true, interval: 0, urls: ["2", "3"]))
    #expect(Set(monitor.results.keys) == ["2", "3"])
    await monitor.run(StreamAvailabilitySchedule(isEnabled: false, interval: 0, urls: urls))
    #expect(monitor.results.isEmpty)
}

@Test @MainActor func staleStatusChecksCannotRestoreDisabledResults() async throws {
    let probe = WorkProbe()
    let monitor = StreamAvailabilityMonitor { _ in
        await probe.begin(0)
        try? await Task.sleep(for: .milliseconds(50))
        await probe.end()
        return true
    }
    let task = Task { await monitor.run(StreamAvailabilitySchedule(isEnabled: true, interval: 0, urls: ["one"])) }
    for _ in 0..<1000 {
        if await probe.snapshot().active == 1 { break }
        try await Task.sleep(for: .milliseconds(1))
    }
    await monitor.run(StreamAvailabilitySchedule(isEnabled: false, interval: 0, urls: ["one"]))
    await task.value
    #expect(monitor.results.isEmpty && monitor.checkingURLs.isEmpty && !monitor.isChecking)
}

private actor UpdateProbe {
    private(set) var requests = 0
    private(set) var intervals: [Duration] = []
    func fetch(_ request: URLRequest) -> (Data, URLResponse) {
        requests += 1
        return (Data("{\"tag_name\":\"v9.0\",\"html_url\":\"https://example.test/release\"}".utf8),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    func sleep(_ interval: Duration) throws {
        intervals.append(interval)
        if intervals.count > 1 { throw CancellationError() }
    }
}

@Test @MainActor func updateIntervalsCheckAtLaunchAndAtSelectedFrequency() async {
    for (frequency, interval) in [(UpdateCheckFrequency.hourly, Duration.seconds(3600)), (.daily, .seconds(86400))] {
        let probe = UpdateProbe()
        let checker = UpdateChecker(currentVersion: "3.9", fetch: { await probe.fetch($0) }, sleep: { try await probe.sleep($0) })
        await checker.run(frequency: frequency)
        #expect(await probe.requests == 2)
        #expect(await probe.intervals == [interval, interval])
        #expect(checker.release?.version == "9.0")
    }
    for (frequency, count) in [(UpdateCheckFrequency.onLaunch, 1), (.never, 0)] {
        let probe = UpdateProbe()
        let checker = UpdateChecker(currentVersion: "3.9", fetch: { await probe.fetch($0) }, sleep: { try await probe.sleep($0) })
        await checker.run(frequency: frequency)
        #expect(await probe.requests == count)
        #expect(await probe.intervals.isEmpty)
    }
}

@Test func groupedSearchPreservesOrderingAndMembership() {
    let groups = [StreamGroup(name: "News"), StreamGroup(name: "Music"), StreamGroup(name: "Empty")]
    let streams = [Stream(name: "Second", url: "b", category: .television, groupID: groups[0].id),
                   Stream(name: "First", url: "a", category: .radio, groupID: groups[0].id),
                   Stream(name: "Music outside", url: "c", category: .television),
                   Stream(name: "Orphan", url: "d", category: .television, groupID: UUID())]
    let sections = StreamGrouping.sections(for: streams, groups: groups, includeEmptyGroups: true)
    #expect(sections.compactMap(\.title) == ["News", "Music", "Empty", "Ungrouped"])
    #expect(sections[0].streams.map(\.name) == ["Second", "First"])
    #expect(sections.last?.streams.map(\.name) == ["Music outside", "Orphan"])
    #expect(StreamGrouping.searchSections(for: streams, groups: groups, query: "news").first?.streams.count == 2)
    #expect(StreamGrouping.searchSections(for: streams, groups: groups, query: "first").first?.streams.map(\.name) == ["First"])
    #expect(StreamGrouping.searchSections(for: streams, groups: groups, query: "Empty").map(\.title) == ["Empty"])
    #expect(StreamGrouping.searchSections(for: streams, groups: groups, query: "no match").isEmpty)
}
