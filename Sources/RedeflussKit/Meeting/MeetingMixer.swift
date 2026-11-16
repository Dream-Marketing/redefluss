struct MeetingMixer {
    enum Source {
        case system
        case microphone
    }

    let maxLag: Int
    private var system: [Float] = []
    private var microphone: [Float] = []

    init(maxLag: Int) {
        self.maxLag = maxLag
    }

    mutating func append(_ samples: [Float], from source: Source) -> [Float] {
        switch source {
        case .system: system.append(contentsOf: samples)
        case .microphone: microphone.append(contentsOf: samples)
        }
        let longer = max(system.count, microphone.count)
        let count = longer > maxLag ? longer : min(system.count, microphone.count)
        return take(count)
    }

    mutating func flush() -> [Float] {
        take(max(system.count, microphone.count))
    }

    private mutating func take(_ count: Int) -> [Float] {
        guard count > 0 else { return [] }
        var mixed = [Float](repeating: 0, count: count)
        for index in 0..<count {
            let fromSystem = index < system.count ? system[index] : 0
            let fromMicrophone = index < microphone.count ? microphone[index] : 0
            mixed[index] = min(1, max(-1, fromSystem + fromMicrophone))
        }
        system.removeFirst(min(count, system.count))
        microphone.removeFirst(min(count, microphone.count))
        return mixed
    }
}
