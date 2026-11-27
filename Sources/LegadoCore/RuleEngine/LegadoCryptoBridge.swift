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
                LegadoCryptoFailureStore.shared.set(describe(error))
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

        let cryptError: @convention(block) () -> String = { LegadoCryptoFailureStore.shared.get() }
        let randomBytes: @convention(block) (Int) -> [Int] = { count in
            (0 ..< max(0, min(count, 1_048_576))).map { _ in Int(Int8(bitPattern: UInt8.random(in: 0 ... 255))) }
        }
        let randomUUID: @convention(block) () -> String = { UUID().uuidString.lowercased() }
        let gunzipBlock: @convention(block) (Any?) -> Any? = { data in
            guard let input = bytes(from: data, encoding: "bytes"),
                  let output = gunzip(input) else { return nil }
            return output.map { Int(Int8(bitPattern: $0)) }
        }
        let charsetDecode: @convention(block) (Any?, String) -> Any? = { data, name in
            guard let input = bytes(from: data, encoding: "bytes"),
                  let encoding = stringEncoding(named: name) else { return nil }
            return String(data: Data(input), encoding: encoding)
        }
        let charsetEncode: @convention(block) (String, String) -> Any? = { text, name in
            guard let encoding = stringEncoding(named: name),
                  let data = text.data(using: encoding) else { return nil }
            return data.map { Int(Int8(bitPattern: $0)) }
        }
        java.setObject(charsetDecode, forKeyedSubscript: "__legadoCharsetDecode" as NSString)
        java.setObject(charsetEncode, forKeyedSubscript: "__legadoCharsetEncode" as NSString)
        let httpBlock: @convention(block) (String, String, Any?, Any?, Double) -> Any? = { method, urlString, headers, body, timeoutMs in
            LegadoCryptoFailureStore.shared.set("")
            guard let url = URL(string: urlString) else {
                LegadoCryptoFailureStore.shared.set("无效 URL：\(urlString)")
                return nil
            }
            var request = URLRequest(url: url)
            request.httpMethod = method.isEmpty ? "GET" : method.uppercased()
            request.timeoutInterval = min(max(timeoutMs / 1_000, 1), 180)
            if let map = headers as? [String: Any] {
                for (name, value) in map { request.setValue(String(describing: value), forHTTPHeaderField: name) }
            }
            if let payload = bytes(from: body, encoding: "bytes"), !payload.isEmpty { request.httpBody = Data(payload) }
            do {
                let response = try SynchronousJavaScriptNetworkLoader().load(request, followRedirects: true)
                return httpResult(response)
            } catch HTTPClientError.statusResponse(let response) {
                return httpResult(response)
            } catch {
                LegadoCryptoFailureStore.shared.set(error.localizedDescription)
                DiagnosticLog.shared.record(.error, category: "JS", message: "HttpURLConnection 请求失败：\(error.localizedDescription)")
                return nil
            }
        }
        let gzipBlock: @convention(block) (Any?) -> Any? = { data in
            guard let input = bytes(from: data, encoding: "bytes"), let output = gzip(input) else { return nil }
            return output.map { Int(Int8(bitPattern: $0)) }
        }
        let gcmBlock: @convention(block) (Bool, Any?, Any?, Any?, Any?, Double) -> Any? = { encrypt, key, iv, data, aad, tagBits in
            do {
                guard let keyBytes = bytes(from: key, encoding: "utf8"), [16, 24, 32].contains(keyBytes.count) else {
                    throw CryptoFailure("AES 密钥长度必须为 16/24/32 字节")
                }
                guard let ivBytes = bytes(from: iv, encoding: "bytes"), ivBytes.count == 12 else {
                    throw CryptoFailure("GCM 的 IV 目前只支持 12 字节")
                }
                guard tagBits == 128 else { throw CryptoFailure("GCM 标签长度目前只支持 128 位") }
                guard let input = bytes(from: data, encoding: "bytes") else { throw CryptoFailure("输入数据无效") }
                let additional = Data(bytes(from: aad, encoding: "bytes") ?? [])
                let symmetricKey = SymmetricKey(data: keyBytes)
                let nonce = try AES.GCM.Nonce(data: Data(ivBytes))
                if encrypt {
                    let sealed = try AES.GCM.seal(Data(input), using: symmetricKey, nonce: nonce, authenticating: additional)
                    return Array(sealed.ciphertext + sealed.tag).map { Int(Int8(bitPattern: $0)) }
                }
                guard input.count >= 16 else { throw CryptoFailure("GCM 密文太短（需包含 16 字节标签）") }
                let box = try AES.GCM.SealedBox(
                    nonce: nonce, ciphertext: Data(input.dropLast(16)), tag: Data(input.suffix(16))
                )
                let plain = try AES.GCM.open(box, using: symmetricKey, authenticating: additional)
                return Array(plain).map { Int(Int8(bitPattern: $0)) }
            } catch {
                LegadoCryptoFailureStore.shared.set(describe(error))
                DiagnosticLog.shared.record(.error, category: "JS", message: "GCM 失败：\(describe(error))")
                return nil
            }
        }
        let chineseBlock: @convention(block) (String, Bool) -> String = { text, toSimplified in
            let identifier = toSimplified ? "Hant-Hans" : "Hans-Hant"
            return text.applyingTransform(StringTransform(rawValue: identifier), reverse: false) ?? text
        }
        let downloadBlock: @convention(block) (String) -> Any? = { urlString in
            LegadoJSFileSandbox.download(urlString)
        }
        let readFileBlock: @convention(block) (String, String) -> Any? = { path, charset in
            guard let data = LegadoJSFileSandbox.read(path) else { return nil }
            if let encoding = stringEncoding(named: charset), let text = String(data: data, encoding: encoding) { return text }
            return String(decoding: data, as: UTF8.self)
        }
        let deleteFileBlock: @convention(block) (String) -> Bool = { path in LegadoJSFileSandbox.delete(path) }
        java.setObject(gcmBlock, forKeyedSubscript: "__legadoGCM" as NSString)
        java.setObject(chineseBlock, forKeyedSubscript: "__legadoChinese" as NSString)
        java.setObject(downloadBlock, forKeyedSubscript: "__legadoDownload" as NSString)
        java.setObject(readFileBlock, forKeyedSubscript: "__legadoReadFile" as NSString)
        java.setObject(deleteFileBlock, forKeyedSubscript: "__legadoDeleteFile" as NSString)
        java.setObject(httpBlock, forKeyedSubscript: "__legadoHttp" as NSString)
        java.setObject(gzipBlock, forKeyedSubscript: "__legadoGzip" as NSString)
        java.setObject(cryptError, forKeyedSubscript: "__legadoCryptError" as NSString)
        java.setObject(randomBytes, forKeyedSubscript: "__legadoRandomBytes" as NSString)
        java.setObject(randomUUID, forKeyedSubscript: "__legadoRandomUUID" as NSString)
        java.setObject(gunzipBlock, forKeyedSubscript: "__legadoGunzip" as NSString)
        java.setObject(crypt, forKeyedSubscript: "__legadoCrypt" as NSString)
        java.setObject(digestBlock, forKeyedSubscript: "__legadoDigest" as NSString)
        java.setObject(hmacBlock, forKeyedSubscript: "__legadoHmac" as NSString)
        java.setObject(encodeBlock, forKeyedSubscript: "__legadoEncodeBytes" as NSString)
        context.evaluateScript(bootstrap)

        let cacheGet: @convention(block) (String, Bool) -> Any? = { key, memoryOnly in
            LegadoJSCacheStore.shared.get(key, memoryOnly: memoryOnly)
        }
        let cachePut: @convention(block) (String, String, Double, Bool) -> Void = { key, value, seconds, memoryOnly in
            LegadoJSCacheStore.shared.put(key, value, seconds: seconds, memoryOnly: memoryOnly)
        }
        let cacheDelete: @convention(block) (String, Bool) -> Void = { key, memoryOnly in
            LegadoJSCacheStore.shared.delete(key, memoryOnly: memoryOnly)
        }
        java.setObject(cacheGet, forKeyedSubscript: "__legadoCacheGet" as NSString)
        java.setObject(cachePut, forKeyedSubscript: "__legadoCachePut" as NSString)
        java.setObject(cacheDelete, forKeyedSubscript: "__legadoCacheDelete" as NSString)
        context.evaluateScript(cacheBootstrap)
        context.evaluateScript(extraBootstrap)

        LegadoJsoupBridge.install(on: java, in: context)
        LegadoWebViewBridge.install(on: java, in: context)
    }

    /// 响应转给 JS：若声明了 gzip 但内容已被系统解压，就去掉 Content-Encoding，避免脚本再解一次而失败。
    private static func httpResult(_ response: HTTPResponse) -> [String: Any] {
        let data = response.data
        let isGzip = data.count > 2 && data[data.startIndex] == 0x1f && data[data.startIndex + 1] == 0x8b
        var headers = response.headers
        if !isGzip {
            headers = headers.filter { $0.key.caseInsensitiveCompare("Content-Encoding") != .orderedSame }
        }
        return [
            "code": response.statusCode,
            "url": response.finalURL.absoluteString,
            "headers": headers,
            "body": data.map { Int(Int8(bitPattern: $0)) }
        ]
    }

    /// 压成 gzip：头 + raw deflate（NSData .zlib）+ CRC32 + 长度。
    private static func gzip(_ input: [UInt8]) -> [UInt8]? {
        let deflated: [UInt8]
        if input.isEmpty {
            deflated = [0x03, 0x00]
        } else {
            guard let compressed = try? (Data(input) as NSData).compressed(using: .zlib) else { return nil }
            deflated = Array(compressed as Data)
        }
        var output: [UInt8] = [0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff]
        output.append(contentsOf: deflated)
        let checksum = crc32(input)
        let length = UInt32(truncatingIfNeeded: input.count)
        for shift in stride(from: 0, to: 32, by: 8) { output.append(UInt8((checksum >> UInt32(shift)) & 0xff)) }
        for shift in stride(from: 0, to: 32, by: 8) { output.append(UInt8((length >> UInt32(shift)) & 0xff)) }
        return output
    }

    private static func crc32(_ data: [UInt8]) -> UInt32 {
        var table = [UInt32](repeating: 0, count: 256)
        for index in 0 ..< 256 {
            var value = UInt32(index)
            for _ in 0 ..< 8 { value = (value & 1) != 0 ? (0xEDB88320 ^ (value >> 1)) : (value >> 1) }
            table[index] = value
        }
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data { crc = table[Int((crc ^ UInt32(byte)) & 0xff)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }

    /// IANA 字符集名（GBK、GB2312、GB18030、Big5、UTF-16 等）→ String.Encoding。
    private static func stringEncoding(named name: String) -> String.Encoding? {
        switch name.uppercased().replacingOccurrences(of: "_", with: "").replacingOccurrences(of: "-", with: "") {
        case "ISO88591", "LATIN1": return .isoLatin1
        case "UTF8": return .utf8
        case "USASCII", "ASCII": return .ascii
        default: break
        }
        let cfEncoding = CFStringConvertIANACharSetNameToEncoding(name as CFString)
        guard cfEncoding != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
    }

    /// 解 gzip：手动跳过 gzip 头/尾，交给 Foundation 解 raw deflate（NSData.CompressionAlgorithm.zlib 即 raw deflate）。
    private static func gunzip(_ input: [UInt8]) -> [UInt8]? {
        guard input.count >= 18, input[0] == 0x1f, input[1] == 0x8b, input[2] == 8 else { return nil }
        let flags = input[3]
        var offset = 10
        if flags & 0x04 != 0 {
            guard offset + 2 <= input.count else { return nil }
            offset += 2 + (Int(input[offset]) | (Int(input[offset + 1]) << 8))
        }
        if flags & 0x08 != 0 {
            while offset < input.count, input[offset] != 0 { offset += 1 }
            offset += 1
        }
        if flags & 0x10 != 0 {
            while offset < input.count, input[offset] != 0 { offset += 1 }
            offset += 1
        }
        if flags & 0x02 != 0 { offset += 2 }
        let end = input.count - 8
        guard offset < end else { return nil }
        let deflated = Data(input[offset ..< end]) as NSData
        guard let inflated = try? deflated.decompressed(using: .zlib) else { return nil }
        return Array(inflated as Data)
    }

    /// 简繁转换、沙盒文件（downloadFile / readTxtFile / cacheFile / importScript）、java.toString。
    private static let extraBootstrap = #"""
    (function () {
      function text(v) { return v === null || v === undefined ? '' : String(v); }
      java.t2s = function (v) { return java.__legadoChinese(text(v), true); };
      java.s2t = function (v) { return java.__legadoChinese(text(v), false); };
      java.toString = function (v) { return text(v); };
      java.downloadFile = function (url) { var p = java.__legadoDownload(text(url)); return p === undefined ? null : p; };
      java.readTxtFile = function (path, charset) {
        var t = java.__legadoReadFile(text(path), charset ? text(charset) : 'UTF-8');
        return t === undefined || t === null ? '' : t;
      };
      java.deleteFile = function (path) { return java.__legadoDeleteFile(text(path)); };
      java.cacheFile = function (url, saveTime) {
        var key = 'cacheFile:' + text(url);
        var hit = cache.get(key);
        if (hit !== null && hit !== undefined) return hit;
        var path = java.downloadFile(url);
        if (!path) return '';
        var body = java.readTxtFile(path, 'UTF-8');
        java.deleteFile(path);
        if (body) cache.put(key, body, Number(saveTime) || 0);
        return body;
      };
      java.importScript = function (path) {
        var p = text(path);
        var body = /^https?:/i.test(p) ? java.cacheFile(p, 86400) : java.readTxtFile(p, 'UTF-8');
        if (!body) throw new Error(p + ' 内容获取失败或者为空');
        return body;
      };
    })();
    """#

    /// Legado 的全局 `cache` 对象：get / put(key, value, saveTime 秒，0 为不过期) / delete，
    /// 以及 getFromMemory / putMemory / deleteMemory（仅内存）。
    private static let cacheBootstrap = #"""
    (function () {
      var g = java.__legadoCacheGet, p = java.__legadoCachePut, d = java.__legadoCacheDelete;
      function str(v) {
        if (v === null || v === undefined) return '';
        if (typeof v === 'string') return v;
        if (typeof v === 'object') { try { return JSON.stringify(v); } catch (e) { return String(v); } }
        return String(v);
      }
      function read(k, mem) { var v = g(String(k), mem); return v === undefined ? null : v; }
      this.cache = {
        get: function (k) { return read(k, false); },
        put: function (k, v, t) { p(String(k), str(v), Number(t) || 0, false); return v; },
        delete: function (k) { d(String(k), false); },
        getFromMemory: function (k) { return read(k, true); },
        putMemory: function (k, v) { p(String(k), str(v), 0, true); return v; },
        deleteMemory: function (k) { d(String(k), true); }
      };
    }).call(this);
    """#

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


/// `cache` 的存储：持久部分放 UserDefaults（带过期时间），内存部分放进程内字典。
private final class LegadoJSCacheStore: @unchecked Sendable {
    static let shared = LegadoJSCacheStore()

    private let lock = NSLock()
    private var memory: [String: String] = [:]
    private let defaults = UserDefaults.standard
    private let prefix = "legado.jscache."

    func get(_ key: String, memoryOnly: Bool) -> String? {
        lock.lock(); defer { lock.unlock() }
        if memoryOnly { return memory[key] }
        let storeKey = prefix + key
        guard let entry = defaults.dictionary(forKey: storeKey),
              let value = entry["v"] as? String else { return nil }
        let expires = (entry["e"] as? Double) ?? 0
        if expires > 0, Date().timeIntervalSince1970 > expires {
            defaults.removeObject(forKey: storeKey)
            return nil
        }
        return value
    }

    func put(_ key: String, _ value: String, seconds: Double, memoryOnly: Bool) {
        lock.lock(); defer { lock.unlock() }
        if memoryOnly { memory[key] = value; return }
        let expires = seconds > 0 ? Date().timeIntervalSince1970 + seconds : 0
        defaults.set(["v": value, "e": expires] as [String: Any], forKey: prefix + key)
    }

    func delete(_ key: String, memoryOnly: Bool) {
        lock.lock(); defer { lock.unlock() }
        if memoryOnly { memory.removeValue(forKey: key) } else { defaults.removeObject(forKey: prefix + key) }
    }
}


/// 记录最近一次加解密失败的原因，供 JS 的 `Cipher.doFinal` 抛错时带上。
private final class LegadoCryptoFailureStore: @unchecked Sendable {
    static let shared = LegadoCryptoFailureStore()
    private let lock = NSLock()
    private var message = ""
    func set(_ value: String) { lock.lock(); message = value; lock.unlock() }
    func get() -> String { lock.lock(); defer { lock.unlock() }; return message }
}


/// 书源 JS 只能读写这个临时目录里由 downloadFile 下载的文件，避免访问 App 其它数据。
private enum LegadoJSFileSandbox {
    private static var directory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("legado-js", isDirectory: true)
    }

    static func download(_ urlString: String) -> String? {
        guard let url = URL(string: urlString), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var request = URLRequest(url: url)
            request.timeoutInterval = 30
            let response = try SynchronousJavaScriptNetworkLoader().load(request, followRedirects: true)
            let name = SHA256.hash(data: Data(urlString.utf8)).map { String(format: "%02x", $0) }.joined()
            let target = directory.appendingPathComponent(name)
            try response.data.write(to: target, options: .atomic)
            return target.path
        } catch {
            DiagnosticLog.shared.record(.error, category: "JS", message: "downloadFile 失败：\(error.localizedDescription)")
            return nil
        }
    }

    private static func allowed(_ path: String) -> URL? {
        let candidate = URL(fileURLWithPath: path).standardizedFileURL
        let root = directory.standardizedFileURL.path + "/"
        return candidate.path.hasPrefix(root) ? candidate : nil
    }

    static func read(_ path: String) -> Data? {
        guard let url = allowed(path) else { return nil }
        return try? Data(contentsOf: url)
    }

    static func delete(_ path: String) -> Bool {
        guard let url = allowed(path) else { return false }
        return (try? FileManager.default.removeItem(at: url)) != nil
    }
}
