import CoreFoundation
import Foundation

/// Bindings for `/usr/lib/libIOReport.dylib`.
///
/// IOReport is the telemetry layer `powermetrics` sits on top of. Reading it
/// directly needs no elevated privileges, which is why this app never asks for
/// a password. The symbols are resolved at run time because the library ships
/// no public header.
enum IOReportLibrary {
    private static let handle = dlopen("/usr/lib/libIOReport.dylib", RTLD_LAZY)

    static func symbol<T>(_ name: String, as type: T.Type = T.self) -> T? {
        guard let handle, let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }

    static var isAvailable: Bool { handle != nil }
}

private typealias CopyChannelsInGroupFn = @convention(c) (
    CFString?, CFString?, UInt64, UInt64, UInt64
) -> UnsafeMutableRawPointer?
private typealias MergeChannelsFn = @convention(c) (
    UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?
) -> Void
private typealias CreateSubscriptionFn = @convention(c) (
    UnsafeMutableRawPointer?, UnsafeMutableRawPointer?,
    UnsafeMutablePointer<UnsafeMutableRawPointer?>?, UInt64, UnsafeMutableRawPointer?
) -> UnsafeMutableRawPointer?
private typealias CreateSamplesFn = @convention(c) (
    UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?
) -> UnsafeMutableRawPointer?
private typealias CreateSamplesDeltaFn = @convention(c) (
    UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?
) -> UnsafeMutableRawPointer?
private typealias ChannelStringFn = @convention(c) (UnsafeRawPointer?) -> UnsafeRawPointer?
private typealias ChannelFormatFn = @convention(c) (UnsafeRawPointer?) -> Int32
private typealias SimpleValueFn = @convention(c) (UnsafeRawPointer?, Int32) -> Int64
private typealias StateCountFn = @convention(c) (UnsafeRawPointer?) -> Int32
private typealias StateNameFn = @convention(c) (UnsafeRawPointer?, Int32) -> UnsafeRawPointer?
private typealias StateResidencyFn = @convention(c) (UnsafeRawPointer?, Int32) -> Int64

private let copyChannelsInGroup: CopyChannelsInGroupFn? =
    IOReportLibrary.symbol("IOReportCopyChannelsInGroup")
private let mergeChannels: MergeChannelsFn? = IOReportLibrary.symbol("IOReportMergeChannels")
private let createSubscription: CreateSubscriptionFn? =
    IOReportLibrary.symbol("IOReportCreateSubscription")
private let createSamples: CreateSamplesFn? = IOReportLibrary.symbol("IOReportCreateSamples")
private let createSamplesDelta: CreateSamplesDeltaFn? =
    IOReportLibrary.symbol("IOReportCreateSamplesDelta")
private let channelGetGroup: ChannelStringFn? = IOReportLibrary.symbol("IOReportChannelGetGroup")
private let channelGetSubGroup: ChannelStringFn? =
    IOReportLibrary.symbol("IOReportChannelGetSubGroup")
private let channelGetName: ChannelStringFn? =
    IOReportLibrary.symbol("IOReportChannelGetChannelName")
private let channelGetUnit: ChannelStringFn? =
    IOReportLibrary.symbol("IOReportChannelGetUnitLabel")
private let channelGetFormat: ChannelFormatFn? = IOReportLibrary.symbol("IOReportChannelGetFormat")
private let simpleGetValue: SimpleValueFn? =
    IOReportLibrary.symbol("IOReportSimpleGetIntegerValue")
private let stateGetCount: StateCountFn? = IOReportLibrary.symbol("IOReportStateGetCount")
private let stateGetName: StateNameFn? = IOReportLibrary.symbol("IOReportStateGetNameForIndex")
private let stateGetResidency: StateResidencyFn? =
    IOReportLibrary.symbol("IOReportStateGetResidency")

/// Release a CoreFoundation object obtained from a `Copy`/`Create` function.
/// Swift hides `CFRelease`, so go through `Unmanaged` instead.
@inline(__always)
func cfRelease(_ pointer: UnsafeMutableRawPointer?) {
    guard let pointer else { return }
    Unmanaged<AnyObject>.fromOpaque(pointer).release()
}

@inline(__always)
func cfString(_ pointer: UnsafeRawPointer?) -> String? {
    guard let pointer else { return nil }
    return unsafeBitCast(pointer, to: CFString.self) as String
}

/// One decoded channel from a sample delta.
public struct IOReportChannel {
    public enum Format: Int32 {
        case simple = 1
        case state = 2
    }

    public let group: String
    public let subgroup: String?
    public let name: String
    public let unit: String
    public let format: Format
    public let value: Int64
    public let states: [(name: String, residency: Int64)]

    /// Energy channels report in different units depending on the SoC.
    public var joules: Double? {
        switch unit {
        case "nJ": return Double(value) * 1e-9
        case "uJ": return Double(value) * 1e-6
        case "mJ": return Double(value) * 1e-3
        case "J": return Double(value)
        default: return nil
        }
    }
}

public enum IOReportError: Error, LocalizedError {
    case unavailable
    case noChannels
    case subscriptionFailed

    public var errorDescription: String? {
        switch self {
        case .unavailable: return "IOReport is not available on this system."
        case .noChannels: return "No IOReport channels matched the requested groups."
        case .subscriptionFailed: return "Could not subscribe to IOReport channels."
        }
    }
}

/// A live subscription to a set of IOReport groups.
///
/// Counters accumulate; a delta between two samples yields energy consumed and
/// time spent in each power state over the interval.
public final class IOReportSubscription {
    public struct Group: Sendable {
        public let name: String
        public let subgroup: String?
        public init(_ name: String, _ subgroup: String? = nil) {
            self.name = name
            self.subgroup = subgroup
        }
    }

    private var channels: UnsafeMutableRawPointer?
    private var subscription: UnsafeMutableRawPointer?
    private var subscribedChannels: UnsafeMutableRawPointer?
    private var previousSample: UnsafeMutableRawPointer?
    private var previousTime: CFAbsoluteTime

    public init(groups: [Group]) throws {
        guard IOReportLibrary.isAvailable,
              let copyChannelsInGroup, let createSubscription, let createSamples
        else { throw IOReportError.unavailable }

        // Each lookup walks the whole registry and costs ~200 ms whether or not
        // the group exists, so fetch them concurrently instead of serially.
        var fetched = [UnsafeMutableRawPointer?](repeating: nil, count: groups.count)
        fetched.withUnsafeMutableBufferPointer { buffer in
            DispatchQueue.concurrentPerform(iterations: groups.count) { index in
                let group = groups[index]
                buffer[index] = copyChannelsInGroup(
                    group.name as CFString,
                    group.subgroup as CFString?,
                    0, 0, 0
                )
            }
        }

        var merged: UnsafeMutableRawPointer?
        for candidate in fetched {
            guard let candidate else { continue }
            if merged == nil {
                merged = candidate
            } else {
                mergeChannels?(merged, candidate, nil)
                cfRelease(candidate)
            }
        }
        guard let merged else { throw IOReportError.noChannels }
        channels = merged

        var subscribed: UnsafeMutableRawPointer?
        let handle = withUnsafeMutablePointer(to: &subscribed) { pointer in
            createSubscription(nil, merged, pointer, 0, nil)
        }
        guard let handle else {
            cfRelease(merged)
            channels = nil
            throw IOReportError.subscriptionFailed
        }
        subscription = handle
        subscribedChannels = subscribed
        previousSample = createSamples(handle, subscribed, nil)
        previousTime = CFAbsoluteTimeGetCurrent()
    }

    deinit { close() }

    public func close() {
        cfRelease(previousSample); previousSample = nil
        cfRelease(subscription); subscription = nil
        cfRelease(subscribedChannels); subscribedChannels = nil
        cfRelease(channels); channels = nil
    }

    /// Whether the subscription covers a subgroup, without taking a sample.
    /// Sampling to find out would reset the delta baseline.
    public func hasSubgroup(_ subgroup: String) -> Bool {
        guard let channels else { return false }
        let dictionary = unsafeBitCast(channels, to: CFDictionary.self)
        guard let raw = CFDictionaryGetValue(
            dictionary, unsafeBitCast("IOReportChannels" as CFString, to: UnsafeRawPointer.self)
        ) else { return false }
        let array = unsafeBitCast(raw, to: CFArray.self)
        for index in 0..<CFArrayGetCount(array) {
            let item = CFArrayGetValueAtIndex(array, index)
            if cfString(channelGetSubGroup?(item)) == subgroup { return true }
        }
        return false
    }

    /// Channels changed since the previous call, plus elapsed seconds.
    ///
    /// `keep` filters by (group, subgroup, name) before state arrays are
    /// decoded: one bandwidth subgroup alone carries seventy channels of
    /// thirty-two states each.
    public func sample(
        keep: ((String, String?, String) -> Bool)? = nil
    ) -> (channels: [IOReportChannel], interval: TimeInterval) {
        guard let subscription, let createSamples, let createSamplesDelta else { return ([], 0) }
        let current = createSamples(subscription, subscribedChannels, nil)
        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = now - previousTime
        let delta = createSamplesDelta(previousSample, current, nil)
        cfRelease(previousSample)
        previousSample = current
        previousTime = now
        defer { cfRelease(delta) }
        return (decode(delta, keep: keep), max(elapsed, 1e-6))
    }

    private func decode(
        _ delta: UnsafeMutableRawPointer?,
        keep: ((String, String?, String) -> Bool)?
    ) -> [IOReportChannel] {
        guard let delta else { return [] }
        let dictionary = unsafeBitCast(delta, to: CFDictionary.self)
        guard let raw = CFDictionaryGetValue(
            dictionary, unsafeBitCast("IOReportChannels" as CFString, to: UnsafeRawPointer.self)
        ) else { return [] }
        let array = unsafeBitCast(raw, to: CFArray.self)

        var result: [IOReportChannel] = []
        result.reserveCapacity(CFArrayGetCount(array))
        for index in 0..<CFArrayGetCount(array) {
            let item = CFArrayGetValueAtIndex(array, index)
            let group = cfString(channelGetGroup?(item)) ?? ""
            let subgroup = cfString(channelGetSubGroup?(item))
            let name = cfString(channelGetName?(item)) ?? ""
            if let keep, !keep(group, subgroup, name) { continue }

            let unit = (cfString(channelGetUnit?(item)) ?? "")
                .trimmingCharacters(in: .whitespaces)
            let rawFormat = channelGetFormat?(item) ?? 0
            guard let format = IOReportChannel.Format(rawValue: rawFormat) else { continue }

            switch format {
            case .simple:
                result.append(IOReportChannel(
                    group: group, subgroup: subgroup, name: name, unit: unit,
                    format: format, value: simpleGetValue?(item, 0) ?? 0, states: []
                ))
            case .state:
                let count = stateGetCount?(item) ?? 0
                var states: [(name: String, residency: Int64)] = []
                states.reserveCapacity(Int(count))
                for stateIndex in 0..<count {
                    let stateName = (cfString(stateGetName?(item, stateIndex)) ?? "")
                        .trimmingCharacters(in: .whitespaces)
                    states.append((stateName, stateGetResidency?(item, stateIndex) ?? 0))
                }
                result.append(IOReportChannel(
                    group: group, subgroup: subgroup, name: name, unit: unit,
                    format: format, value: 0, states: states
                ))
            }
        }
        return result
    }
}
