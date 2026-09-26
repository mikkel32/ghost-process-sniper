import Foundation

extension MemoryPatternAnalysis {
    /// Classify a memory series (bytes) by its shape, assuming one sample per
    /// second. Prefer analyze(samples:fitQuality:) when dates are known.
    public static func analyze(points: [Double], fitQuality: Double) -> MemoryPatternAnalysis {
        let origin = Date(timeIntervalSince1970: 0)
        let samples = points.enumerated().map { index, bytes in
            TrendSample(date: origin.addingTimeInterval(Double(index)), memoryBytes: UInt64(max(0, bytes)), cpuPercent: 0)
        }
        return analyze(samples: samples, fitQuality: fitQuality)
    }

    /// Classify a dated memory series by its shape. Measurement jitter is
    /// estimated from the data itself, so a clean leak with noisy samples is
    /// still a climb, and a GC sawtooth whose troughs keep rising is a leak.
    public static func analyze(samples: [TrendSample], fitQuality: Double) -> MemoryPatternAnalysis {
        guard samples.count >= 4, let origin = samples.first?.date else {
            return MemoryPatternAnalysis(pattern: .unknown, confidence: 0, detail: "Collecting samples", fitQuality: fitQuality)
        }
        let points = samples.map {
            RobustTrend.Point(minutes: $0.date.timeIntervalSince(origin) / 60, megabytes: Double($0.memoryBytes) / 1_048_576)
        }
        let values = points.map(\.megabytes)
        let mean = values.reduce(0, +) / Double(values.count)
        let range = (values.max() ?? 0) - (values.min() ?? 0)
        let noise = RobustTrend.noiseSigma(values)
        let trend = RobustTrend.theilSen(points) ?? RobustTrend.Slope(slope: 0, lower: 0, upper: 0)
        let span = (points.last?.minutes ?? 0) - (points.first?.minutes ?? 0)
        let netMegabytes = trend.slope * span
        func result(_ pattern: MemoryPattern, _ confidence: Double, _ detail: String, floorSlope: Double = 0) -> MemoryPatternAnalysis {
            MemoryPatternAnalysis(
                pattern: pattern,
                confidence: confidence,
                detail: detail,
                fitQuality: fitQuality,
                robustSlopeMegabytesPerMinute: trend.slope,
                slopeLowerBoundMegabytesPerMinute: trend.lower,
                floorSlopeMegabytesPerMinute: floorSlope,
                noiseMegabytes: noise
            )
        }

        // A band relative to the footprint only counts as flat while the
        // robust trend moves less than the band itself; a clean climb on a
        // large process is still a climb.
        if range < 16 || (range < mean * 0.03 && abs(netMegabytes) < max(16, 2 * noise)) {
            return result(.flat, 0.9, "Memory holds within \(RadarFormat.fixed0(range)) MB of \(RadarFormat.fixed0(mean)) MB")
        }

        if netMegabytes < -max(16, mean * 0.03), trend.upper < 0 {
            return result(.declining, 0.8, "Released \(RadarFormat.fixed0(-netMegabytes)) MB across the window")
        }

        // One jump that dominates the growth beyond noise is an allocation
        // event, not a continuous leak.
        let deltas = zip(values.dropFirst(), values).map { $0 - $1 }
        let significantRises = deltas.filter { $0 > max(2 * noise, 1) }
        let totalRise = significantRises.reduce(0, +)
        let largestStep = significantRises.max() ?? 0
        if totalRise > 0, largestStep >= totalRise * 0.7, largestStep >= 32 {
            return result(.stepJump, min(1, largestStep / totalRise),
                          "One \(RadarFormat.fixed0(largestStep)) MB step accounts for the growth")
        }

        let dips = RobustTrend.dips(points, threshold: dipThreshold(noise: noise, range: range))
        if dips.count >= 2 {
            let troughs = dips.map(\.trough)
            let floorSlope = RobustTrend.theilSen(troughs)?.slope ?? 0
            let floorSpan = (troughs.last?.minutes ?? 0) - (troughs.first?.minutes ?? 0)
            let medianAmplitude = RobustTrend.median(dips.map(\.amplitude))
            if floorSlope >= max(5, 0.25 * max(0, trend.slope)), floorSlope * floorSpan >= 0.5 * medianAmplitude {
                return result(
                    .risingFloor,
                    min(1, floorSlope * floorSpan / max(1, medianAmplitude)),
                    "Reclaims in cycles, but its floor rises \(RadarFormat.fixed0(floorSlope)) MB/min",
                    floorSlope: floorSlope
                )
            }
            let totalFall = deltas.filter { $0 < 0 }.reduce(0) { $0 - $1 }
            let totalGrowth = deltas.filter { $0 > 0 }.reduce(0, +)
            let reclaimed = Int(min(1, totalFall / max(1, totalGrowth)) * 100)
            return result(.sawtooth, min(1, totalFall / max(1, totalGrowth)),
                          "Reclaims \(reclaimed)% of what it allocates across \(dips.count) dips")
        }

        if trend.slope > 0, fitQuality >= 0.7 || (fitQuality >= 0.5 && trend.lower > 0) {
            return result(.steadyClimb, fitQuality,
                          "Monotonic growth of \(RadarFormat.fixed0(max(0, netMegabytes))) MB with little reclaim")
        }

        return result(.volatile, 0.5, "Irregular swings across a \(RadarFormat.fixed0(range)) MB range")
    }

    // A reclaim must be larger than jitter could explain. When the swings
    // are the series (a fast alternating sawtooth), the first-difference
    // noise estimate measures the saw itself, so only the range floor applies.
    private static func dipThreshold(noise: Double, range: Double) -> Double {
        let noiseIsMeaningful = range >= 2.5 * noise
        return max(8, range * 0.15, noiseIsMeaningful ? 4 * noise : 0)
    }
}

/// Robust slope and noise estimates for short, jittery memory series.
enum RobustTrend {
    struct Point: Equatable, Sendable {
        let minutes: Double
        let megabytes: Double
    }

    struct Slope: Equatable, Sendable {
        let slope: Double
        let lower: Double
        let upper: Double
    }

    struct Dip: Equatable, Sendable {
        let trough: Point
        let amplitude: Double
    }

    /// Theil-Sen slope with Sen's ~95% confidence band, over at most `limit`
    /// time bins (at most 435 pairs).
    static func theilSen(_ points: [Point], limit: Int = 30) -> Slope? {
        let sample = decimated(points, limit: limit)
        guard sample.count >= 2 else { return nil }
        var slopes: [Double] = []
        slopes.reserveCapacity(sample.count * (sample.count - 1) / 2)
        for i in 0..<(sample.count - 1) {
            for j in (i + 1)..<sample.count {
                let dx = sample[j].minutes - sample[i].minutes
                guard dx > 0 else { continue }
                slopes.append((sample[j].megabytes - sample[i].megabytes) / dx)
            }
        }
        guard !slopes.isEmpty else { return nil }
        slopes.sort()
        let n = Double(sample.count)
        let pairs = Double(slopes.count)
        let spread = 1.96 * (n * (n - 1) * (2 * n + 5) / 18).squareRoot()
        let lowerIndex = Int(((pairs - spread) / 2).rounded(.down))
        let upperIndex = Int(((pairs + spread) / 2).rounded(.up))
        return Slope(
            slope: medianOfSorted(slopes),
            lower: slopes[min(max(0, lowerIndex), slopes.count - 1)],
            upper: slopes[min(max(0, upperIndex), slopes.count - 1)]
        )
    }

    /// Per-sample noise: the scaled MAD of first differences, divided by √2
    /// because each difference carries two samples' noise. Floored at 1 MB.
    static func noiseSigma(_ values: [Double]) -> Double {
        let deltas = zip(values.dropFirst(), values).map { $0 - $1 }
        guard !deltas.isEmpty else { return 1 }
        let center = median(deltas)
        let mad = median(deltas.map { abs($0 - center) })
        return max(1, 1.4826 * mad / 2.0.squareRoot())
    }

    /// Peak-to-trough falls of at least `threshold` MB.
    static func dips(_ points: [Point], threshold: Double) -> [Dip] {
        var result: [Dip] = []
        var index = 1
        while index < points.count {
            guard points[index].megabytes < points[index - 1].megabytes else {
                index += 1
                continue
            }
            let peak = points[index - 1].megabytes
            var trough = index
            while trough + 1 < points.count, points[trough + 1].megabytes < points[trough].megabytes {
                trough += 1
            }
            let fall = peak - points[trough].megabytes
            if fall >= threshold {
                result.append(Dip(trough: points[trough], amplitude: fall))
            }
            index = trough + 1
        }
        return result
    }

    static func median(_ values: [Double]) -> Double {
        medianOfSorted(values.sorted())
    }

    private static func medianOfSorted(_ sorted: [Double]) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }

    // Bin means rather than picked points: each bin averages away some of
    // the jitter while keeping the pair count bounded.
    private static func decimated(_ points: [Point], limit: Int) -> [Point] {
        guard points.count > limit, limit >= 2 else { return points }
        return (0..<limit).map { bin in
            let lower = bin * points.count / limit
            let upper = (bin + 1) * points.count / limit
            let slice = points[lower..<upper]
            let count = Double(slice.count)
            return Point(
                minutes: slice.reduce(0) { $0 + $1.minutes } / count,
                megabytes: slice.reduce(0) { $0 + $1.megabytes } / count
            )
        }
    }
}
