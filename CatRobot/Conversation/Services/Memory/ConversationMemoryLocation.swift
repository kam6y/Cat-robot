import Foundation

enum ConversationMemoryLocation {
    static func directory(applicationSupport: URL, environment: [String: String]) throws -> URL {
#if DEBUG
        if let value = environment["CATROBOT_MEMORY_TEST_ID"] {
            guard let id = UUID(uuidString: value) else { throw ConversationMemoryError.invalidData }
            return applicationSupport.appendingPathComponent("CatRobot/DeviceMemoryTests/\(id.uuidString)", isDirectory: true)
        }
#endif
        return applicationSupport.appendingPathComponent("CatRobot/ConversationMemory", isDirectory: true)
    }
}
