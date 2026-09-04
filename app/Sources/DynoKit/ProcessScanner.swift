import Darwin
import Foundation

/// Enumerates processes that look like an LLM runtime, or that hold a GPU
/// client and a meaningful amount of memory.
///
/// This uses `libproc` rather than shelling out to `ps`: a GUI app should not
/// spawn a subprocess every second, and task info gives a true instantaneous
/// CPU share instead of `ps`'s decaying average.
public final class ProcessScanner {
    /// Ordered most specific first; the first pattern that matches the command
    /// line decides the label.
    private static let runtimeRules: [(label: String, pattern: NSRegularExpression)] = {
        let definitions: [(String, String)] = [
            ("Ollama", #"\bollama\b"#),
            ("llama.cpp", #"\b(llama-server|llama-cli|llama-bench|llama-run|llama-quantize)\b"#),
            ("LM Studio", #"LM Studio|lmstudio|\blms\b"#),
            ("MLX", #"\bmlx[_.-]?(lm|vlm|whisper|server)?\b"#),
            ("vLLM", #"\bvllm\b"#),
            ("llama.cpp", #"llama\.cpp|llamacpp"#),
            ("koboldcpp", #"koboldcpp"#),
            ("text-gen", #"text-generation-(server|webui)|\btgi\b"#),
            ("whisper.cpp", #"whisper-(cli|server)|whisper\.cpp"#),
            ("ComfyUI", #"comfyui"#),
            ("PyTorch", #"\btorchrun\b|torch\.distributed"#),
            ("Diffusers", #"diffusers|stable[-_]diffusion"#),
        ]
        return definitions.compactMap { label, pattern in
            guard let regex = try? NSRegularExpression(
                pattern: pattern, options: [.caseInsensitive]
            ) else { return nil }
            return (label, regex)
        }
    }()

    /// Shells and helpers whose command line often merely mentions a runtime.
    private static let notARuntime: Set<String> = [
        "zsh", "bash", "sh", "fish", "tmux", "screen", "grep", "ps", "tail", "less",
        "vim", "nvim", "code", "man", "watch", "sudo", "env", "xargs", "dyno",
    ]

    /// A matched runtime is worth showing even when idle, but not when it is a
    /// few megabytes of launcher.
    private static let runtimeMinimumMemory: Int64 = 64 * 1024 * 1024

    private struct CPUSnapshot {
        var user: UInt64
        var system: UInt64
    }

    private var previousCPU: [Int32: CPUSnapshot] = [:]
    private var previousTime = CFAbsoluteTimeGetCurrent()
    private let argumentMax: Int
    /// `proc_taskinfo` reports CPU time in mach absolute ticks, not
    /// nanoseconds. On Apple Silicon one tick is 125/3 ns; without this
    /// conversion every process reads ~24x too idle.
    private let ticksToSeconds: Double

    public init() {
        argumentMax = Int(Sysctl.integer("kern.argmax") ?? 262_144)
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let numerator = timebase.numer == 0 ? 1 : Double(timebase.numer)
        let denominator = timebase.denom == 0 ? 1 : Double(timebase.denom)
        ticksToSeconds = numerator / denominator / 1e9
    }

    public func scan(
        gpuPIDs: Set<Int32>, minimumMemory: Int64, limit: Int
    ) -> [ProcessSample] {
        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = max(now - previousTime, 1e-6)
        previousTime = now

        let count = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard count > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(count) / MemoryLayout<Int32>.size)
        let written = proc_listpids(
            UInt32(PROC_ALL_PIDS), 0, &pids, Int32(pids.count * MemoryLayout<Int32>.size)
        )
        guard written > 0 else { return [] }
        pids = Array(pids.prefix(Int(written) / MemoryLayout<Int32>.size)).filter { $0 > 0 }

        let selfPID = getpid()
        var currentCPU: [Int32: CPUSnapshot] = [:]
        currentCPU.reserveCapacity(pids.count)
        var rows: [ProcessSample] = []

        for pid in pids where pid != selfPID {
            var info = proc_taskinfo()
            let size = proc_pidinfo(
                pid, PROC_PIDTASKINFO, 0, &info, Int32(MemoryLayout<proc_taskinfo>.size)
            )
            guard size == Int32(MemoryLayout<proc_taskinfo>.size) else { continue }

            let cpu = CPUSnapshot(user: info.pti_total_user, system: info.pti_total_system)
            currentCPU[pid] = cpu

            let memory = Int64(info.pti_resident_size)
            let usesGPU = gpuPIDs.contains(pid)
            // Skip the expensive argv lookup for processes that cannot qualify.
            if memory < Self.runtimeMinimumMemory && !usesGPU { continue }

            let command = commandLine(for: pid) ?? executablePath(for: pid) ?? ""
            guard !command.isEmpty else { continue }
            let name = Self.displayName(for: command)

            var runtime: String?
            if !Self.notARuntime.contains(name) {
                let range = NSRange(command.startIndex..., in: command)
                for rule in Self.runtimeRules
                where rule.pattern.firstMatch(in: command, range: range) != nil {
                    runtime = rule.label
                    break
                }
            }

            let knownRuntime = runtime != nil && memory >= Self.runtimeMinimumMemory
            guard knownRuntime || (usesGPU && memory >= minimumMemory) else { continue }

            var cpuPercent = 0.0
            if let previous = previousCPU[pid] {
                let deltaTicks = Double(cpu.user &- previous.user)
                    + Double(cpu.system &- previous.system)
                cpuPercent = deltaTicks * ticksToSeconds / elapsed * 100
            }

            rows.append(ProcessSample(
                pid: pid,
                name: String(name.prefix(28)),
                runtime: knownRuntime ? runtime : nil,
                memory: memory,
                cpuPercent: max(0, cpuPercent),
                usesGPU: usesGPU,
                command: command
            ))
        }

        previousCPU = currentCPU
        rows.sort {
            if $0.isKnownRuntime != $1.isKnownRuntime { return $0.isKnownRuntime }
            return $0.memory > $1.memory
        }
        return Array(rows.prefix(limit))
    }

    /// Best-effort executable name. Handles both a path containing spaces
    /// (`/Applications/Foo.app/Contents/MacOS/Foo Bar --flag`) and a bare name
    /// followed by a subcommand (`ollama runner --model ...`).
    static func displayName(for command: String) -> String {
        let head = command.components(separatedBy: " -").first?
            .trimmingCharacters(in: .whitespaces) ?? command
        if head.hasPrefix("/") {
            return (head as NSString).lastPathComponent
        }
        return head.split(separator: " ").first.map(String.init) ?? String(command.prefix(28))
    }

    private func executablePath(for pid: Int32) -> String? {
        // PROC_PIDPATHINFO_MAXSIZE (4 * MAXPATHLEN) is not exposed to Swift.
        var buffer = [CChar](repeating: 0, count: 4 * 1024)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    /// Full argv via `KERN_PROCARGS2`. Fails for processes owned by other
    /// users, in which case the caller falls back to the executable path.
    private func commandLine(for pid: Int32) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = argumentMax
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size
        else { return nil }

        let argc = buffer.withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
        guard argc > 0 else { return nil }

        var index = MemoryLayout<Int32>.size
        // The exec path comes first, then null padding, then argc arguments.
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }

        var arguments: [String] = []
        var start = index
        while index < size, arguments.count < argc {
            if buffer[index] == 0 {
                if index > start,
                   let piece = String(bytes: buffer[start..<index], encoding: .utf8) {
                    arguments.append(piece)
                }
                start = index + 1
            }
            index += 1
        }
        let joined = arguments.joined(separator: " ")
        return joined.isEmpty ? nil : joined
    }
}
