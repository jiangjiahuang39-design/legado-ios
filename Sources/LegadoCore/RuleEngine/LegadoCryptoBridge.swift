import CommonCrypto
import CryptoKit
import Foundation
import JavaScriptCore

/// 补齐 Legado 书源 JS 里常用的 `java.*` 加解密/摘要函数（对照 Android 版 JsExtensions / JsEncodeUtils）。
///
/// 已提供：
/// - `java.createSymmetricCrypto(transformation, key, iv)` → decrypt / decryptStr / encrypt / encryptBase64 / encryptHex / setIv
/// - `java.aes*` / `java.des*`：DecodeToString、DecodeToByteArray、Base64DecodeToString、Base64DecodeToByteArray、
///   EncodeToString、EncodeToByteArray、EncodeToBase64String、EncodeToBase64ByteArray
/// - `java.tripleDESDecodeStr` / `tripleDESDecodeArgsBase64Str` / `tripleDESEncodeBase64Str` / `tripleDESEncodeArgsBase64Str`
/// - `java.md5Encode16` / `digestHex` / `digestBase64Str` / `HMacHex` / `HMacBase64`
///
/// 支持算法 AES(16/24/32 字节密钥)、DES、DESede；模式 ECB/CBC/CFB/CFB8/CTR/OFB；
/// 填充 PKCS5Padding/PKCS7Padding/NoPadding/ZeroPadding。暂不支持 GCM、ISO10126、RSA。
/// 失败时与 Legado 一致返回 null，并把原因写入诊断日志（分类 JS）。
enum LegadoCryptoBridge {
    /// 必须在 `context.setObject(java, forKeyedSubscript: "java")` 之后调用。
    static func install(on java: JSValue?, in context: JSContext) {
        guard let java else { return }

        let crypt: @convention(block) (Bool, String, Any?, Any?, Any?, String) -> Any? = {
            encrypt, transformation, key, iv, data, inputEncoding in
            do {
                guard let input = bytes(from: data, encoding: inputEncoding) else {
                    throw CryptoFailure("输入数据无法解析（\(inputEncoding)）")
                }
                guard let keyBytes = bytes(from: key, encoding: "utf8") else {
                    throw CryptoFailure("密钥无效")
                }
                let ivBytes = bytes(from: iv, encoding: "utf8") ?? []
                let output = try SymmetricCipher.run(
                    encrypt: encrypt,
                    transformation: transformation,
                    key: keyBytes,
                    iv: ivBytes,
                    input: input
                )
                return output.map { Int(Int8(bitPattern: $0)) }
            } catch {
                DiagnosticLog.shared.record(
                    .error,
                    category: "JS",
                    message: "\(encrypt ? "加密" : "解密")失败 [\(transformation)]：\(describe(error))"
                )
                return nil
            }
        }

        let digestBlock: @convention(block) (String, Any?) -> Any? = { algorithm, data in
            guard let input = bytes(from: data, encoding: "utf8"),
                  let output = digest(algorithm, input) else {
                DiagnosticLog.shared.record(.error, category: "JS", message: "摘要算法不支持或输入无效：\(algorithm)")
                return nil
            }
            return output.map { Int(Int8(bitPattern: $0)) }
        }

        let hmacBlock: @convention(block) (String, Any?, Any?) -> Any? = { algorithm, key, data in
            guard let keyBytes = bytes(from: key, encoding: "utf8"),
                  let input = bytes(from: data, encoding: "utf8"),
                  let output = hmac(algorithm, key: keyBytes, data: input) else {
                DiagnosticLog.shared.record(.error, category: "JS", message: "HMAC 算法不支持或输入无效：\(algorithm)")
                return nil
            }
            return output.map { Int(Int8(bitPattern: $0)) }
        }

        let encodeBlock: @convention(block) (Any?, String) -> Any? = { value, kind in
            guard let raw = bytes(from: value, encoding: "utf8") else { return nil }
            switch kind {
            case "base64": return Data(raw).base64EncodedString()
            case "hex": return raw.map { String(format: "%02x", $0) }.joined()
            default: return String(decoding: raw, as: UTF8.self)
            }
        }

        java.setObject(crypt, forKeyedSubscript: "__legadoCrypt" as NSString)
        java.setObject(digestBlock, forKeyedSubscript: "__legadoDigest" as NSString)
        java.setObject(hmacBlock, forKeyedSubscript: "__legadoHmac" as NSString)
        java.setObject(encodeBlock, forKeyedSubscript: "__legadoEncodeBytes" as NSString)
        context.evaluateScript(bootstrap)
    }

    // MARK: - JS 侧包装

    private static let bootstrap = #"""
    (function () {
      var crypt = java.__legadoCrypt, digest = java.__legadoDigest,
          hmac = java.__legadoHmac, encode = java.__legadoEncodeBytes;
      function text(b) { return b == null ? null : encode(b, 'utf8'); }
      function b64(b) { return b == null ? null : encode(b, 'base64'); }
      function hex(b) { return b == null ? null : encode(b, 'hex'); }
      function toBytes(s) { return s == null ? null : java.strToBytes(String(s)); }
      function run(enc, t, key, iv, data, inEnc) {
        return crypt(enc, String(t), key, iv == null ? '' : iv, data, inEnc);
      }

      java.createSymmetricCrypto = function (t, key, iv) {
        var o = {
          decrypt: function (d) { return run(false, t, key, iv, d, 'auto'); },
          decryptStr: function (d) { return text(o.decrypt(d)); },
          encrypt: function (d) { return run(true, t, key, iv, d, 'utf8'); },
          encryptBase64: function (d) { return b64(o.encrypt(d)); },
          encryptHex: function (d) { return hex(o.encrypt(d)); },
          setIv: function (v) { iv = v; return o; }
        };
        return o;
      };

      ['aes', 'des'].forEach(function (p) {
        java[p + 'DecodeToByteArray'] = function (s, k, t, iv) { return run(false, t, k, iv, s, 'auto'); };
        java[p + 'DecodeToString'] = function (s, k, t, iv) { return text(run(false, t, k, iv, s, 'auto')); };
        java[p + 'Base64DecodeToByteArray'] = function (s, k, t, iv) { return run(false, t, k, iv, s, 'base64'); };
        java[p + 'Base64DecodeToString'] = function (s, k, t, iv) { return text(run(false, t, k, iv, s, 'base64')); };
        java[p + 'EncodeToByteArray'] = function (d, k, t, iv) { return run(true, t, k, iv, d, 'utf8'); };
        java[p + 'EncodeToString'] = function (d, k, t, iv) { return text(run(true, t, k, iv, d, 'utf8')); };
        java[p + 'EncodeToBase64ByteArray'] = function (d, k, t, iv) { return toBytes(b64(run(true, t, k, iv, d, 'utf8'))); };
        java[p + 'EncodeToBase64String'] = function (d, k, t, iv) { return b64(run(true, t, k, iv, d, 'utf8')); };
      });

      function tri(m, p) { return 'DESede/' + m + '/' + p; }
      java.tripleDESDecodeStr = function (d, k, m, p, iv) { return text(run(false, tri(m, p), k, iv, d, 'auto')); };
      java.tripleDESDecodeArgsBase64Str = function (d, k, m, p, iv) { return text(run(false, tri(m, p), k, iv, d, 'base64')); };
      java.tripleDESEncodeBase64Str = function (d, k, m, p, iv) { return b64(run(true, tri(m, p), k, iv, d, 'utf8')); };
      java.tripleDESEncodeArgsBase64Str = java.tripleDESEncodeBase64Str;

      java.md5Encode16 = function (s) { var h = hex(digest('MD5', s)); return h == null ? null : h.substring(8, 24); };
      java.digestHex = function (d, alg) { return hex(digest(String(alg), d)); };
      java.digestBase64Str = function (d, alg) { return b64(digest(String(alg), d)); };
      java.HMacHex = function (d, alg, key) { return hex(hmac(String(alg), key, d)); };
      java.HMacBase64 = function (d, alg, key) { return b64(hmac(String(alg), key, d)); };
    })();
    """#

    // MARK: - 数据转换

    private struct CryptoFailure: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    private static func describe(_ error: Error) -> String {
        (error as? CryptoFailure)?.message ?? error.localizedDescription
    }

    /// encoding: "utf8"（字符串按文本）、"base64"、"hex"、"auto"（先判十六进制，否则 Base64，与 hutool 一致）。
    /// 数组（JS 字节数组，有符号/无符号均可）直接当字节。
    private static func bytes(from value: Any?, encoding: String) -> [UInt8]? {
        guard let value, !(value is NSNull) else { return nil }
        if let text = value as? String {
            switch encoding {
            case "base64": return decodeBase64(text)
            case "hex": return decodeHex(text)
            case "auto":
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty, trimmed.count.isMultiple(of: 2), trimmed.allSatisfy({ $0.isHexDigit }) {
                    return decodeHex(trimmed)
                }
                return decodeBase64(trimmed)
            default: return Array(text.utf8)
            }
        }
        let items: [Any]
        if let array = value as? [Any] {
            items = array
        } else if let array = value as? NSArray {
            items = array.map { $0 }
        } else {
            return nil
        }
        var result: [UInt8] = []
        result.reserveCapacity(items.count)
        for item in items {
            guard let number = item as? NSNumber else { return nil }
            result.append(UInt8(truncatingIfNeeded: number.intValue))
        }
        return result
    }

    private static func decodeHex(_ text: String) -> [UInt8]? {
        let characters = Array(text.trimmingCharacters(in: .whitespacesAndNewlines))
        guard characters.count.isMultiple(of: 2) else { return nil }
        var result: [UInt8] = []
        result.reserveCapacity(characters.count / 2)
        var index = 0
        while index < characters.count {
            guard let byte = UInt8(String(characters[index ... index + 1]), radix: 16) else { return nil }
            result.append(byte)
            index += 2
        }
        return result
    }

    /// 兼容换行、URL-safe 字符和缺失的 `=` 填充。
    private static func decodeBase64(_ text: String) -> [UInt8]? {
        var cleaned = text.filter { !$0.isWhitespace }
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = cleaned.count % 4
        if remainder == 1 { return nil }
        if remainder != 0 { cleaned += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: cleaned).map { Array($0) }
    }

    // MARK: - 摘要 / HMAC

    private static func normalizedHashName(_ name: String) -> String {
        var value = name.uppercased()
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: " ", with: "")
        if value.hasPrefix("HMAC") { value.removeFirst(4) }
        return value == "SHA" ? "SHA1" : value
    }

    private static func digest(_ algorithm: String, _ data: [UInt8]) -> [UInt8]? {
        switch normalizedHashName(algorithm) {
        case "MD5": return Array(Insecure.MD5.hash(data: data))
        case "SHA1": return Array(Insecure.SHA1.hash(data: data))
        case "SHA224":
            var out = [UInt8](repeating: 0, count: Int(CC_SHA224_DIGEST_LENGTH))
            _ = CC_SHA224(data, CC_LONG(data.count), &out)
            return out
        case "SHA256": return Array(SHA256.hash(data: data))
        case "SHA384": return Array(SHA384.hash(data: data))
        case "SHA512": return Array(SHA512.hash(data: data))
        default: return nil
        }
    }

    private static func hmac(_ algorithm: String, key: [UInt8], data: [UInt8]) -> [UInt8]? {
        let symmetricKey = SymmetricKey(data: key)
        switch normalizedHashName(algorithm) {
        case "MD5": return Array(HMAC<Insecure.MD5>.authenticationCode(for: data, using: symmetricKey))
        case "SHA1": return Array(HMAC<Insecure.SHA1>.authenticationCode(for: data, using: symmetricKey))
        case "SHA224":
            var out = [UInt8](repeating: 0, count: Int(CC_SHA224_DIGEST_LENGTH))
            CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA224), key, key.count, data, data.count, &out)
            return out
        case "SHA256": return Array(HMAC<SHA256>.authenticationCode(for: data, using: symmetricKey))
        case "SHA384": return Array(HMAC<SHA384>.authenticationCode(for: data, using: symmetricKey))
        case "SHA512": return Array(HMAC<SHA512>.authenticationCode(for: data, using: symmetricKey))
        default: return nil
        }
    }

    // MARK: - 对称加解密

    private enum SymmetricCipher {
        enum Padding { case pkcs7, noPadding, zero }

        static func run(
            encrypt: Bool,
            transformation: String,
            key rawKey: [UInt8],
            iv rawIV: [UInt8],
            input: [UInt8]
        ) throws -> [UInt8] {
            let parts = transformation
                .split(separator: "/", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces).uppercased() }
            guard let algorithmName = parts.first, !algorithmName.isEmpty else {
                throw CryptoFailure("缺少算法名")
            }
            let modeName = parts.count > 1 ? parts[1] : "ECB"
            let paddingName = parts.count > 2 ? parts[2] : "PKCS5PADDING"

            // 算法与密钥
            let algorithm: CCAlgorithm
            let blockSize: Int
            var key = rawKey
            switch algorithmName {
            case "AES":
                guard [16, 24, 32].contains(key.count) else {
                    throw CryptoFailure("AES 密钥长度必须为 16/24/32 字节，实际 \(key.count)")
                }
                algorithm = CCAlgorithm(kCCAlgorithmAES)
                blockSize = 16
            case "DES":
                guard key.count >= 8 else { throw CryptoFailure("DES 密钥至少 8 字节，实际 \(key.count)") }
                key = Array(key.prefix(8))
                algorithm = CCAlgorithm(kCCAlgorithmDES)
                blockSize = 8
            case "DESEDE", "TRIPLEDES", "3DES":
                if key.count == 16 { key += key.prefix(8) }
                guard key.count >= 24 else { throw CryptoFailure("DESede 密钥至少 24 字节，实际 \(rawKey.count)") }
                key = Array(key.prefix(24))
                algorithm = CCAlgorithm(kCCAlgorithm3DES)
                blockSize = 8
            default:
                throw CryptoFailure("不支持的算法 \(algorithmName)")
            }

            // 模式
            let mode: CCMode
            var options: CCModeOptions = 0
            var isBlockMode = false
            switch modeName {
            case "ECB": mode = CCMode(kCCModeECB); isBlockMode = true
            case "CBC": mode = CCMode(kCCModeCBC); isBlockMode = true
            case "CFB": mode = CCMode(kCCModeCFB)
            case "CFB8": mode = CCMode(kCCModeCFB8)
            case "OFB": mode = CCMode(kCCModeOFB)
            case "CTR":
                mode = CCMode(kCCModeCTR)
                options = CCModeOptions(kCCModeOptionCTR_BE)
            default:
                throw CryptoFailure("不支持的模式 \(modeName)")
            }

            // 填充（统一手动处理，CommonCrypto 一律按 NoPadding 调用）
            let padding: Padding
            switch paddingName {
            case "PKCS5PADDING", "PKCS7PADDING": padding = .pkcs7
            case "NOPADDING": padding = .noPadding
            case "ZEROPADDING": padding = .zero
            default: throw CryptoFailure("不支持的填充 \(paddingName)")
            }

            // IV
            var iv: [UInt8] = []
            if modeName != "ECB" {
                iv = rawIV.isEmpty ? [UInt8](repeating: 0, count: blockSize) : rawIV
                guard iv.count == blockSize else {
                    throw CryptoFailure("IV 长度必须为 \(blockSize) 字节，实际 \(iv.count)")
                }
            }

            var data = input
            if encrypt {
                switch padding {
                case .pkcs7:
                    let pad = blockSize - data.count % blockSize
                    data += [UInt8](repeating: UInt8(pad), count: pad)
                case .zero:
                    let remainder = data.count % blockSize
                    if remainder != 0 { data += [UInt8](repeating: 0, count: blockSize - remainder) }
                case .noPadding:
                    if isBlockMode, !data.count.isMultiple(of: blockSize) {
                        throw CryptoFailure("NoPadding 要求数据长度为 \(blockSize) 的整数倍")
                    }
                }
            } else if isBlockMode {
                guard !data.isEmpty, data.count.isMultiple(of: blockSize) else {
                    throw CryptoFailure("密文长度不是 \(blockSize) 的整数倍（\(data.count)），可能不是 base64/hex 或参数不对")
                }
            }

            var output = try transform(
                encrypt: encrypt, algorithm: algorithm, mode: mode, options: options,
                key: key, iv: iv, data: data, blockSize: blockSize
            )

            if !encrypt {
                switch padding {
                case .pkcs7:
                    guard let last = output.last, last >= 1, Int(last) <= blockSize,
                          Int(last) <= output.count,
                          output.suffix(Int(last)).allSatisfy({ $0 == last }) else {
                        throw CryptoFailure("PKCS 填充校验失败（密钥/IV/模式不匹配）")
                    }
                    output.removeLast(Int(last))
                case .zero:
                    while output.last == 0 { output.removeLast() }
                case .noPadding:
                    break
                }
            }
            return output
        }

        private static func transform(
            encrypt: Bool,
            algorithm: CCAlgorithm,
            mode: CCMode,
            options: CCModeOptions,
            key: [UInt8],
            iv: [UInt8],
            data: [UInt8],
            blockSize: Int
        ) throws -> [UInt8] {
            var cryptor: CCCryptorRef?
            let operation = CCOperation(encrypt ? kCCEncrypt : kCCDecrypt)
            let createStatus = key.withUnsafeBytes { keyPointer in
                iv.withUnsafeBytes { ivPointer in
                    CCCryptorCreateWithMode(
                        operation, mode, algorithm, CCPadding(ccNoPadding),
                        iv.isEmpty ? nil : ivPointer.baseAddress,
                        keyPointer.baseAddress, key.count,
                        nil, 0, 0, options, &cryptor
                    )
                }
            }
            guard createStatus == kCCSuccess, let cryptor else {
                throw CryptoFailure("CommonCrypto 创建失败（状态 \(createStatus)，该算法/模式组合可能不受支持）")
            }
            defer { CCCryptorRelease(cryptor) }

            var output = [UInt8](repeating: 0, count: data.count + blockSize)
            let capacity = output.count
            var moved = 0
            let updateStatus = data.withUnsafeBytes { inputPointer in
                output.withUnsafeMutableBytes { outputPointer in
                    CCCryptorUpdate(
                        cryptor, inputPointer.baseAddress, data.count,
                        outputPointer.baseAddress, capacity, &moved
                    )
                }
            }
            guard updateStatus == kCCSuccess else {
                throw CryptoFailure("CommonCrypto 处理失败（状态 \(updateStatus)）")
            }
            var finalMoved = 0
            let finalOffset = moved
            let finalStatus = output.withUnsafeMutableBytes { outputPointer in
                CCCryptorFinal(
                    cryptor, outputPointer.baseAddress.map { $0 + finalOffset },
                    capacity - finalOffset, &finalMoved
                )
            }
            guard finalStatus == kCCSuccess else {
                throw CryptoFailure("CommonCrypto 收尾失败（状态 \(finalStatus)）")
            }
            return Array(output.prefix(moved + finalMoved))
        }
    }
}
