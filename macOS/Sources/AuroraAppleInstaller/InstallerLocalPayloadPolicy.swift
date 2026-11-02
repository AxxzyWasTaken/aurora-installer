import Foundation

/// This source is absent from every release-configuration build, including
/// release builds made with the test build environment variable set.
enum InstallerLocalPayloadPolicy {
  static func directory(requested: URL? = nil) -> URL? {
    #if DEBUG && AURORA_LOCAL_PAYLOAD_TEST_BUILD
      return requested ?? URL(fileURLWithPath: "/Users/Shared/AuroraInstallerTestPayloads")
    #else
      return nil
    #endif
  }
}
