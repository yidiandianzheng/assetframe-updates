import Foundation

enum SeededAssetShuffle {
    static func ordered(_ assets: [AssetItem], seed: UInt64) -> [AssetItem] {
        assets.sorted { lhs, rhs in
            let left = rank(id: lhs.id, seed: seed)
            let right = rank(id: rhs.id, seed: seed)
            return left == right ? lhs.id < rhs.id : left < right
        }
    }

    private static func rank(id: String, seed: UInt64) -> UInt64 {
        var value = seed ^ 0xcbf29ce484222325
        for byte in id.utf8 {
            value ^= UInt64(byte)
            value &*= 0x100000001b3
        }
        value &+= 0x9e3779b97f4a7c15
        value = (value ^ (value >> 30)) &* 0xbf58476d1ce4e5b9
        value = (value ^ (value >> 27)) &* 0x94d049bb133111eb
        return value ^ (value >> 31)
    }
}
