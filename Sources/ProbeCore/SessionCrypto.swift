import Foundation
import CryptoKit
import CryptoSwift

enum ScaleProtocolError: String, Error {
    case tokenFormat, randomLength, authentication, rejected, framing, timeout, replay, ciphertext, schema
    var message: String {
        switch self {
        case .tokenFormat: return "Token 必须是 24 位十六进制（12 字节）"
        case .randomLength: return "安全随机数生成失败"
        case .authentication: return "认证校验失败，请核对或重新获取 token"
        case .rejected: return "体脂秤拒绝登录，请核对 token 并关闭其他连接端"
        case .framing: return "收到不完整、乱序或超长的数据帧"
        case .timeout: return "登录或收帧超时，请重试"
        case .replay: return "收到重复或倒退的加密计数器，已停止本次会话"
        case .ciphertext: return "加密数据校验失败，未保存测量"
        case .schema: return "测量格式尚未支持，未保存为完整测量"
        }
    }
}

enum TokenFormat {
    static func parse(_ text: String) throws -> Data {
        let bytes = Array(text.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        guard bytes.count == 24, bytes.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else {
            throw ScaleProtocolError.tokenFormat
        }
        return Data(stride(from: 0, to: 24, by: 2).map { UInt8(String(decoding: bytes[$0..<$0+2], as: UTF8.self), radix: 16)! })
    }
}

struct SessionKeys {
    let deviceKey: Data
    let appKey: Data
    let deviceIV: Data
    let appIV: Data

    static func derive(token: Data, appRandom: Data, deviceRandom: Data) throws -> SessionKeys {
        guard token.count == 12 else { throw ScaleProtocolError.tokenFormat }
        guard appRandom.count == 16, deviceRandom.count == 16 else { throw ScaleProtocolError.randomLength }
        let key = CryptoKit.HKDF<CryptoKit.SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: token),
            salt: appRandom + deviceRandom, info: Data("mible-login-info".utf8), outputByteCount: 64)
        let bytes = key.withUnsafeBytes { Data($0) }
        return SessionKeys(deviceKey: bytes.subdata(in: 0..<16), appKey: bytes.subdata(in: 16..<32),
                           deviceIV: bytes.subdata(in: 32..<36), appIV: bytes.subdata(in: 36..<40))
    }

    static func hmac(key: Data, message: Data) -> Data {
        Data(CryptoKit.HMAC<CryptoKit.SHA256>.authenticationCode(for: message, using: SymmetricKey(data: key)))
    }

    func verifiesRemote(_ hmac: Data, appRandom: Data, deviceRandom: Data) -> Bool {
        CryptoKit.HMAC<CryptoKit.SHA256>.isValidAuthenticationCode(hmac, authenticating: deviceRandom + appRandom,
                                                                  using: SymmetricKey(data: deviceKey))
    }

    func decrypt(_ packet: Data, fromApp: Bool = false) throws -> Data {
        let key = fromApp ? appKey : deviceKey
        let iv = fromApp ? appIV : deviceIV
        guard (7...4096).contains(packet.count), key.count == 16, iv.count == 4 else {
            throw ScaleProtocolError.ciphertext
        }
        let nonce = iv + Data(repeating: 0, count: 4) + packet.prefix(2) + Data(repeating: 0, count: 2)
        let encrypted = Array(packet.dropFirst(2))
        let mode = CCM(iv: Array(nonce), tagLength: 4, messageLength: encrypted.count - 4)
        do {
            // Whole-message API: never release incremental plaintext before tag validation.
            return Data(try CryptoSwift.AES(key: Array(key), blockMode: mode, padding: .noPadding).decrypt(encrypted))
        } catch { throw ScaleProtocolError.ciphertext }
    }

    func encryptForDevice(_ plain: Data, counter: UInt16) throws -> Data {
        guard (1...4090).contains(plain.count) else { throw ScaleProtocolError.ciphertext }
        let prefix = Data([UInt8(counter & 255), UInt8(counter >> 8)])
        let nonce = appIV + Data(repeating: 0, count: 4) + prefix + Data(repeating: 0, count: 2)
        do {
            let mode = CCM(iv: Array(nonce), tagLength: 4, messageLength: plain.count)
            return prefix + Data(try CryptoSwift.AES(key: Array(appKey), blockMode: mode, padding: .noPadding).encrypt(Array(plain)))
        } catch { throw ScaleProtocolError.ciphertext }
    }
}
