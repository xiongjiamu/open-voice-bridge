import AudioToolbox
import CoreAudio
import Foundation

struct AudioDeviceInfo: Identifiable, Equatable {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

enum CoreAudioDeviceCatalog {
    static func outputDevices() -> [AudioDeviceInfo] {
        devices(scope: kAudioDevicePropertyScopeOutput)
    }

    static func inputDevices() -> [AudioDeviceInfo] {
        devices(scope: kAudioDevicePropertyScopeInput)
    }

    /// UID of the current system default input device, or `nil` if none is set.
    /// Read only — the app never changes the system default input.
    static func defaultInputDeviceUID() -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        ) == noErr, deviceID != 0 else { return nil }
        return stringProperty(deviceID, selector: kAudioDevicePropertyDeviceUID)
    }

    private static func devices(scope: AudioObjectPropertyScope) -> [AudioDeviceInfo] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size
        ) == noErr else { return [] }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = Array(repeating: AudioDeviceID(0), count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceIDs
        ) == noErr else { return [] }

        return deviceIDs.compactMap { deviceID in
            guard channelCount(for: deviceID, scope: scope) > 0,
                  let uid = stringProperty(deviceID, selector: kAudioDevicePropertyDeviceUID),
                  let name = stringProperty(deviceID, selector: kAudioObjectPropertyName)
            else { return nil }
            return AudioDeviceInfo(id: deviceID, uid: uid, name: name)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func stringProperty(
        _ objectID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(
            objectID,
            &address,
            0,
            nil,
            &size,
            &value
        ) == noErr else { return nil }
        return value?.takeUnretainedValue() as String?
    }

    private static func channelCount(
        for deviceID: AudioDeviceID,
        scope: AudioObjectPropertyScope
    ) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr,
              size >= UInt32(MemoryLayout<AudioBufferList>.size)
        else { return 0 }

        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, raw) == noErr else {
            return 0
        }
        let bufferList = UnsafeMutableAudioBufferListPointer(
            raw.assumingMemoryBound(to: AudioBufferList.self)
        )
        return bufferList.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}

/// Plays the remote's decoded voice into a virtual loopback device.
///
/// Deliberately built on a raw HAL output unit rather than `AVAudioEngine`.
/// `AVAudioEngine` hosts its graph on a per-process CoreAudio aggregate named
/// `CADefaultDeviceAggregate-<pid>-<n>`. When the system default output changes
/// — plugging in 3.5 mm headphones is such a change, done via
/// `SetTransientDefaultDeviceQuietly`, which emits no
/// `kAudioHardwarePropertyDefaultOutputDevice` "SetData" line — CoreAudio
/// rebuilds that aggregate and the engine re-points its AUHAL at it
/// (`AUHAL.cpp: SetProperty: caller requesting device change from <selected> to
/// <aggregate>`). The selected device then receives nothing, the remote's voice
/// comes out of the system default output instead, and no code in the app is
/// told. A raw HAL unit is bound to one device id and owns no such aggregate.
final class VirtualAudioOutput {
    /// The bridge decodes 16 kHz mono PCM. The HAL unit converts it to whatever
    /// the selected device runs at.
    static let clientSampleRate: Double = 16_000

    private let diagnostics: AudioPathDiagnostics

    private var audioUnit: AudioUnit?
    private var running = false

    /// Guards `fifo` and the completion bookkeeping shared with the render
    /// callback.
    private let lock = NSLock()
    private var fifo: [Float] = []
    private var readIndex = 0
    private var framesQueued: Int64 = 0
    private var framesConsumed: Int64 = 0
    private var pendingCompletions: [PendingCompletion] = []

    /// Runs off the realtime thread once the FIFO has consumed `targetFrame`
    /// frames. `true` = the audio sounded; `false` = it was dropped first.
    private struct PendingCompletion {
        let targetFrame: Int64
        let action: (Bool) -> Void
    }

    /// Completion callbacks never run on the render thread.
    private let completionQueue = DispatchQueue(
        label: "com.kingwell.XiaomiRemoteBridgeMac.audio-output-completions"
    )

    private(set) var selectedDevice: AudioDeviceInfo?
    private(set) var status = "未选择语音输出设备"

    init(diagnostics: AudioPathDiagnostics = AudioPathDiagnostics()) {
        self.diagnostics = diagnostics
    }

    /// Current output routing, used by the local-microphone feedback-loop guard.
    var currentOutput: (uid: String, isRunning: Bool) {
        (selectedDevice?.uid ?? "", running)
    }

    var isReadyForTestTone: Bool {
        selectedDevice != nil && running
    }

    // MARK: - configuration

    @discardableResult
    func configure(deviceUID: String) -> Bool {
        stop()
        guard !deviceUID.isEmpty else {
            status = "未选择语音输出设备"
            return false
        }
        guard let device = CoreAudioDeviceCatalog.outputDevices().first(where: { $0.uid == deviceUID }) else {
            status = "所选语音输出设备不可用"
            return false
        }

        var componentDescription = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &componentDescription) else {
            status = "无法打开音频输出单元"
            AppLogger.shared.write("AUDIO ERROR hal_component_missing")
            return false
        }
        var unit: AudioUnit?
        guard AudioComponentInstanceNew(component, &unit) == noErr, let unit else {
            status = "无法打开音频输出单元"
            AppLogger.shared.write("AUDIO ERROR hal_instance_failed")
            return false
        }
        var shouldDispose = true
        defer { if shouldDispose { AudioComponentInstanceDispose(unit) } }

        // Pure output: element 1 (input) off, element 0 (output) on. This must
        // happen before the device is chosen, as in Apple's HAL examples.
        var enableOutput: UInt32 = 1
        var enableInput: UInt32 = 0
        guard AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0,
            &enableOutput, UInt32(MemoryLayout<UInt32>.size)
        ) == noErr,
        AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1,
            &enableInput, UInt32(MemoryLayout<UInt32>.size)
        ) == noErr else {
            status = "无法配置音频输出单元"
            AppLogger.shared.write("AUDIO ERROR hal_io_config_failed")
            return false
        }

        // The single binding that keeps the voice on the selected device: a raw
        // HAL unit is pinned to this device id and never follows the system
        // default output.
        var deviceID = device.id
        guard AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
            &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size)
        ) == noErr else {
            status = "无法选择音频设备"
            AppLogger.shared.write("AUDIO ERROR device_select_failed want=\(device.id)")
            return false
        }

        // Client-side format. The unit converts to the device's own rate and
        // channel count, so the bridge can keep feeding 16 kHz mono.
        var format = AudioStreamBasicDescription(
            mSampleRate: Self.clientSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: UInt32(MemoryLayout<Float>.size),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(MemoryLayout<Float>.size),
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        guard AudioUnitSetProperty(
            unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0,
            &format, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        ) == noErr else {
            status = "无法配置音频输出格式"
            AppLogger.shared.write("AUDIO ERROR hal_format_failed want=\(device.id)")
            return false
        }

        var callback = AURenderCallbackStruct(
            inputProc: VirtualAudioOutput.renderCallback,
            inputProcRefCon: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        )
        guard AudioUnitSetProperty(
            unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
            &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        ) == noErr,
        AudioUnitInitialize(unit) == noErr else {
            status = "启动音频输出失败：初始化失败"
            AppLogger.shared.write("AUDIO ERROR start_failed=initialize")
            return false
        }

        // Read the bound device back and refuse to pretend. The previous
        // AVAudioEngine build trusted this same check, but AVAudioEngine could
        // re-point the unit later without telling anyone; here it stays bound.
        var bound = AudioDeviceID(0)
        var boundSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let readBack = AudioUnitGetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &bound, &boundSize
        )
        guard readBack == noErr, bound == device.id else {
            let actual = readBack == noErr ? String(bound) : "unknown"
            AudioUnitUninitialize(unit)
            status = "输出设备未生效（当前绑定 \(actual)，期望 \(device.id)）"
            AppLogger.shared.write("AUDIO ERROR device_not_applied want=\(device.id) actual=\(actual)")
            return false
        }

        guard AudioOutputUnitStart(unit) == noErr else {
            AudioUnitUninitialize(unit)
            status = "启动音频输出失败：设备未就绪"
            AppLogger.shared.write("AUDIO ERROR start_failed=hal_start")
            return false
        }

        shouldDispose = false
        audioUnit = unit
        running = true
        selectedDevice = device
        status = "语音输出：\(device.name)"
        AppLogger.shared.write("AUDIO READY")
        return true
    }

    // MARK: - playback

    private static let renderCallback: AURenderCallback = { refCon, _, _, _, frameCount, ioData in
        let output = Unmanaged<VirtualAudioOutput>.fromOpaque(UnsafeRawPointer(refCon)).takeUnretainedValue()
        return output.render(frameCount: Int(frameCount), ioData: ioData)
    }

    /// Runs on the realtime thread: silence first, then whatever the FIFO holds.
    /// Completion callbacks are never invoked here.
    private func render(frameCount: Int, ioData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
        guard let ioData else { return noErr }
        let buffers = UnsafeMutableAudioBufferListPointer(ioData)
        for buffer in buffers {
            if let data = buffer.mData {
                memset(data, 0, Int(buffer.mDataByteSize))
            }
        }
        guard frameCount > 0,
              let destination = buffers.first?.mData?.assumingMemoryBound(to: Float.self)
        else { return noErr }

        var due: [(Bool) -> Void] = []
        lock.lock()
        let take = min(frameCount, fifo.count - readIndex)
        if take > 0 {
            fifo.withUnsafeBufferPointer { source in
                if let base = source.baseAddress {
                    destination.update(from: base + readIndex, count: take)
                }
            }
            readIndex += take
            framesConsumed += Int64(take)
        }
        if !pendingCompletions.isEmpty {
            var index = 0
            while index < pendingCompletions.count {
                guard pendingCompletions[index].targetFrame <= framesConsumed else {
                    index += 1
                    continue
                }
                due.append(pendingCompletions[index].action)
                pendingCompletions.remove(at: index)
            }
        }
        lock.unlock()

        if !due.isEmpty {
            completionQueue.async {
                for action in due { action(true) }
            }
        }
        return noErr
    }

    @discardableResult
    func enqueue(
        samples: [Int16],
        diagnosticsSession: AudioPathDiagnostics.Session? = nil
    ) -> Bool {
        guard running, audioUnit != nil, !samples.isEmpty else {
            if let diagnosticsSession {
                diagnostics.recordQueueRejected(for: diagnosticsSession)
            }
            return false
        }
        let floats = samples.map { Float($0) / Float(Int16.max) }
        guard let diagnosticsSession else {
            append(floats, completion: nil)
            return true
        }
        diagnostics.recordQueueAccepted(samples: samples, for: diagnosticsSession)
        guard let watermark = diagnostics.requestPlaybackWatermark(for: diagnosticsSession) else {
            append(floats, completion: nil)
            return true
        }
        append(floats) { [weak self] played in
            // Only a buffer that actually sounded may complete a watermark.
            guard played else { return }
            self?.diagnostics.recordPlaybackWatermarkCompleted(watermark)
        }
        return true
    }

    /// Schedules the 1-second test tone and reports whether it really sounded —
    /// the equivalent of the old `.dataPlayedBack` callback.
    @discardableResult
    func playTestTone(completion: @escaping (Bool) -> Void) -> Bool {
        guard isReadyForTestTone else { return false }
        let samples = TestToneGenerator.samples(sampleRate: Self.clientSampleRate)
        guard !samples.isEmpty else { return false }
        append(samples.map { Float($0) / Float(Int16.max) }) { played in
            completion(played)
        }
        return true
    }

    /// Flushes any buffer currently queued (including an in-flight test tone) so
    /// real RC003 voice audio scheduled right after this call is not delayed.
    func cancelTestTone() {
        flushPlayer()
    }

    func endSession(diagnosticsSession: AudioPathDiagnostics.Session) {
        diagnostics.endSession(diagnosticsSession)
        flushPlayer()
    }

    /// Flushes shared playback when no RC003 diagnostic session owns it (for
    /// example the test-tone helper), so local audio never contaminates RC003
    /// status.
    func endSession() {
        flushPlayer()
    }

    /// Flushes PCM already queued — used when the local microphone session ends
    /// or is preempted so no residual local audio plays after RC003 takes over.
    func flushPending() {
        flushPlayer()
    }

    func stop() {
        lock.lock()
        pendingCompletions.removeAll()
        fifo.removeAll(keepingCapacity: false)
        readIndex = 0
        framesQueued = 0
        framesConsumed = 0
        lock.unlock()

        if let unit = audioUnit {
            AudioOutputUnitStop(unit)
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }
        audioUnit = nil
        running = false
        selectedDevice = nil
    }

    private func append(_ floats: [Float], completion: ((Bool) -> Void)?) {
        lock.lock()
        if readIndex > 0 {
            fifo.removeFirst(readIndex)
            readIndex = 0
        }
        fifo.append(contentsOf: floats)
        framesQueued += Int64(floats.count)
        if let completion {
            pendingCompletions.append(PendingCompletion(targetFrame: framesQueued, action: completion))
        }
        lock.unlock()
    }

    /// Drops queued PCM and settles every pending completion as "did not sound",
    /// so a caller tracking a test tone cannot stay stuck in a playing state.
    private func flushPlayer() {
        lock.lock()
        let dropped = pendingCompletions
        pendingCompletions.removeAll()
        fifo.removeAll(keepingCapacity: false)
        readIndex = 0
        framesQueued = 0
        framesConsumed = 0
        lock.unlock()

        guard !dropped.isEmpty else { return }
        completionQueue.async {
            for item in dropped { item.action(false) }
        }
    }
}
