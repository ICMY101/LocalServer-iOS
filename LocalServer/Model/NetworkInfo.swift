import Foundation

struct InterfaceAddress: Hashable, Identifiable {
    let interface: String
    let ip: String

    var id: String { interface + ip }

    var label: String {
        if interface == "en0" { return "Wi-Fi" }
        if interface.hasPrefix("bridge") { return "个人热点" }
        return "局域网（\(interface)）"
    }
}

enum NetworkInfo {
    /// 当前设备可供局域网访问的 IPv4 地址（Wi-Fi、个人热点、有线网卡）
    static func lanAddresses() -> [InterfaceAddress] {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return [] }
        defer { freeifaddrs(pointer) }

        var result: [InterfaceAddress] = []
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(bitPattern: entry.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0 else { continue }
            guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }

            let name = String(cString: entry.pointee.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("bridge") else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let status = getnameinfo(
                address, socklen_t(address.pointee.sa_len),
                &host, socklen_t(host.count),
                nil, 0, NI_NUMERICHOST
            )
            guard status == 0 else { continue }
            let ip = String(cString: host)
            // 169.254.x.x 是链路本地地址，通常不可用
            guard !ip.hasPrefix("169.254.") else { continue }
            result.append(InterfaceAddress(interface: name, ip: ip))
        }
        return result.sorted { $0.interface < $1.interface }
    }
}
