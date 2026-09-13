import Foundation
import CryptoKit

/// 内容哈希。
///
/// 精确查重需要比对全部字节，但直接对每个文件做完整 SHA-256 在大库上是纯粹的 I/O 浪费：
/// 绝大多数文件都是唯一的，逐个读完毫无意义。
///
/// 因此采用两级策略：
/// 1. `quickSignature` —— 首块 + 尾块 + 文件大小，只需两次随机读；
/// 2. 只有快速签名发生碰撞的候选组，才计算 `fullSHA256` 做最终确认。
///
/// 快速签名相同是“字节相同”的必要条件（同文件必然同首尾同长度），
/// 所以这个策略不会漏判，只会把少量巧合碰撞交给第二级兜住。
enum ContentHasher {

    /// 首尾各取的字节数
    static let chunkSize = 256 * 1024

    /// 两级策略的快速签名。小文件退化为“整个文件哈希”。
    static func quickSignature(url: URL, fileSize: Int64) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        var hasher = SHA256()

        // 长度本身参与计算，防止不同长度文件巧合拼出同样字节
        var sizeLE = UInt64(bitPattern: fileSize).littleEndian
        withUnsafeBytes(of: &sizeLE) { raw in
            hasher.update(data: Data(raw))
        }

        let headLength = Int(min(Int64(chunkSize), fileSize))
        if headLength > 0 {
            guard let head = try? handle.read(upToCount: headLength), !head.isEmpty else {
                return nil
            }
            hasher.update(data: head)

            // 文件比两个块还大，才需要补读尾部
            let covered = Int64(head.count)
            if fileSize > covered + Int64(chunkSize) {
                let tailOffset = UInt64(fileSize - Int64(chunkSize))
                if (try? handle.seek(toOffset: tailOffset)) != nil,
                   let tail = try? handle.read(upToCount: chunkSize), !tail.isEmpty {
                    hasher.update(data: tail)
                }
            }
        }

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// 完整 SHA-256，流式读取，内存占用恒定。
    ///
    /// 读到一半失败就返回 nil，而不是拿前半截内容当完整哈希 —— 后者会给出一个
    /// 「看着像真的」的错误身份标识，比干脆认输危险得多。返回 nil 时调用方会退回
    /// 快速签名做识别，那仍然是「字节相同」的必要条件，不会漏判。
    static func fullSHA256(url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        var hasher = SHA256()
        let step = 4 * 1024 * 1024
        while true {
            let chunk: Data
            do {
                guard let read = try handle.read(upToCount: step) else { break }   // nil = 已到文件末尾
                chunk = read
            } catch {
                return nil
            }
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
