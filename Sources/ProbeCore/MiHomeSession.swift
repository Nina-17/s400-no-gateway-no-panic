import Foundation

// Swift adaptation of xiaomi-s400-live auth.py/protocol.py (Apache-2.0).
// See bundled ThirdPartyNotices.txt. No frame contents are logged.
enum ScaleChannel: String, CaseIterable { case command = "0010", auth = "0019", application = "001A", measurement = "001B" }

struct ScaleWrite: Equatable {
    let channel: ScaleChannel
    let data: Data
}

struct ParcelReceiver {
    enum Result { case ready, more, complete(Data) }
    private(set) var expected = 0
    private var next = 1
    private var buffer = Data()
    var active: Bool { expected > 0 }

    mutating func receive(_ data: Data, maximumBytes: Int = 4096) throws -> Result {
        let b = Array(data)
        if b.count == 6 && b[0...2] == [0, 0, 0] {
            guard !active else { throw ScaleProtocolError.framing }
            let count = Int(b[4]) | Int(b[5]) << 8
            guard count > 0, count <= (maximumBytes + 17) / 18 else { throw ScaleProtocolError.framing }
            expected = count; next = 1; buffer = Data()
            return .ready
        }
        guard active, (3...20).contains(b.count), (Int(b[0]) | Int(b[1]) << 8) == next,
              buffer.count + b.count - 2 <= maximumBytes else { throw ScaleProtocolError.framing }
        // All non-final fragments must have the protocol's full payload length.
        guard next == expected || b.count == 20 else { throw ScaleProtocolError.framing }
        buffer.append(contentsOf: b.dropFirst(2))
        next += 1
        if next > expected {
            let result = buffer
            self = ParcelReceiver()
            return .complete(result)
        }
        return .more
    }

    static func frames(_ data: Data) -> [Data] {
        let bytes = Array(data)
        return stride(from: 0, to: bytes.count, by: 18).enumerated().map { index, offset in
            Data([UInt8((index + 1) & 255), UInt8((index + 1) >> 8)]) + Data(bytes[offset..<min(offset + 18, bytes.count)])
        }
    }
}

final class MiHomeSession {
    enum Stage: String { case idle, randomReady, randomAck, deviceRandom, deviceHMAC, infoReady, infoAck, confirmation, streaming }
    enum Effect { case write(ScaleWrite), authenticated, payload(Data), applicationSent }
    static let ready = Data([0, 0, 1, 1])
    static let ok = Data([0, 0, 1, 0])
    private(set) var stage: Stage = .idle
    private var receiveDeadline: Date?
    private var sendDeadline: Date?
    var deadline: Date? { [receiveDeadline, sendDeadline].compactMap { $0 }.min() }
    private var outbound: Data?
    private var outboundAwaitingAck = false
    private var nextSendCounter: UInt32 = 0
    private var token: Data
    private let random: Data
    private var deviceRandom = Data()
    private var keys: SessionKeys?
    private var authParcel = ParcelReceiver()
    private var measurementParcel = ParcelReceiver()
    private var lastCounter: UInt16?
    private var loginConfirmed = false

    init(token: Data, random: Data) throws {
        guard token.count == 12 else { throw ScaleProtocolError.tokenFormat }
        guard random.count == 16 else { throw ScaleProtocolError.randomLength }
        self.token = token; self.random = random
    }

    private func transition(_ stage: Stage, at now: Date) {
        self.stage = stage
        receiveDeadline = stage == .streaming ? nil : now.addingTimeInterval(8)
    }

    func checkDeadline(at now: Date) throws {
        if let deadline, now >= deadline { throw ScaleProtocolError.timeout }
    }

    func start(at now: Date) throws -> [Effect] {
        guard stage == .idle else { throw ScaleProtocolError.framing }
        transition(.randomReady, at: now)
        return [write(.command, [0x24, 0, 0, 0]), write(.auth, [0, 0, 0, 0x0b, 1, 0])]
    }

    func sendApplication(_ plain: Data, at now: Date) throws -> [Effect] {
        try checkDeadline(at: now)
        guard stage == .streaming, let keys, outbound == nil, nextSendCounter <= UInt16.max else {
            throw ScaleProtocolError.framing
        }
        let packet = try keys.encryptForDevice(plain, counter: UInt16(nextSendCounter))
        nextSendCounter += 1
        outbound = packet; outboundAwaitingAck = false; sendDeadline = now.addingTimeInterval(8)
        let count = (packet.count + 17) / 18
        // App-to-device business parcels use type 0 in the captured Mi Home session.
        return [write(.application, [0, 0, 0, 0, UInt8(count & 255), UInt8(count >> 8)])]
    }

    func receive(_ data: Data, on channel: ScaleChannel, at now: Date) throws -> [Effect] {
        try checkDeadline(at: now)
        if channel == .application {
            guard stage == .streaming, let outbound else { throw ScaleProtocolError.framing }
            if !outboundAwaitingAck {
                guard data == Self.ready else { throw ScaleProtocolError.framing }
                outboundAwaitingAck = true; sendDeadline = now.addingTimeInterval(8)
                return ParcelReceiver.frames(outbound).map { .write(ScaleWrite(channel: .application, data: $0)) }
            }
            guard data == Self.ok else { throw ScaleProtocolError.framing }
            self.outbound = nil; sendDeadline = nil; outboundAwaitingAck = false
            return [.applicationSent]
        }
        if channel == .command {
            guard data == Data([0x21, 0, 0, 0]), stage == .infoAck || stage == .confirmation else {
                throw ScaleProtocolError.rejected
            }
            loginConfirmed = true
            if stage == .confirmation { transition(.streaming, at: now); return [.authenticated] }
            return [] // UPNP confirmation can arrive before AVDTP's final ACK.
        }
        if channel == .measurement {
            guard stage == .streaming, let keys else { throw ScaleProtocolError.authentication }
            switch try measurementParcel.receive(data) {
            case .ready:
                receiveDeadline = now.addingTimeInterval(8)
                return [.write(ScaleWrite(channel: .measurement, data: Self.ready))]
            case .more: return []
            case .complete(let packet):
                guard packet.count >= 7 else { throw ScaleProtocolError.ciphertext }
                let b = Array(packet.prefix(2))
                let counter = UInt16(b[0]) | UInt16(b[1]) << 8
                if let lastCounter, counter <= lastCounter { throw ScaleProtocolError.replay }
                let plaintext = try keys.decrypt(packet)
                lastCounter = counter
                receiveDeadline = nil
                return [.write(ScaleWrite(channel: .measurement, data: Self.ok)), .payload(plaintext)]
            }
        }
        switch stage {
        case .randomReady:
            guard data == Self.ready else { throw ScaleProtocolError.framing }
            transition(.randomAck, at: now)
            return ParcelReceiver.frames(random).map { .write(ScaleWrite(channel: .auth, data: $0)) }
        case .randomAck:
            guard data == Self.ok else { throw ScaleProtocolError.framing }
            transition(.deviceRandom, at: now); return []
        case .deviceRandom, .deviceHMAC:
            let randomPhase = stage == .deviceRandom
            switch try authParcel.receive(data, maximumBytes: randomPhase ? 16 : 32) {
            case .ready: return [.write(ScaleWrite(channel: .auth, data: Self.ready))]
            case .more: return []
            case .complete(let parcel):
                var effects: [Effect] = [.write(ScaleWrite(channel: .auth, data: Self.ok))]
                if randomPhase {
                    guard parcel.count == 16 else { throw ScaleProtocolError.randomLength }
                    deviceRandom = parcel
                    transition(.deviceHMAC, at: now)
                } else {
                    guard parcel.count == 32 else { throw ScaleProtocolError.authentication }
                    let derived = try SessionKeys.derive(token: token, appRandom: random, deviceRandom: deviceRandom)
                    guard derived.verifiesRemote(parcel, appRandom: random, deviceRandom: deviceRandom) else {
                        throw ScaleProtocolError.authentication
                    }
                    keys = derived; token = Data()
                    transition(.infoReady, at: now)
                    effects.append(write(.auth, [0, 0, 0, 0x0a, 2, 0]))
                }
                return effects
            }
        case .infoReady:
            guard data == Self.ready, let keys else { throw ScaleProtocolError.framing }
            let hmac = SessionKeys.hmac(key: keys.appKey, message: random + deviceRandom)
            transition(.infoAck, at: now)
            return ParcelReceiver.frames(hmac).map { .write(ScaleWrite(channel: .auth, data: $0)) }
        case .infoAck:
            guard data == Self.ok else { throw ScaleProtocolError.framing }
            transition(loginConfirmed ? .streaming : .confirmation, at: now)
            return loginConfirmed ? [.authenticated] : []
        default: throw ScaleProtocolError.framing
        }
    }

    private func write(_ channel: ScaleChannel, _ bytes: [UInt8]) -> Effect {
        .write(ScaleWrite(channel: channel, data: Data(bytes)))
    }
}
