import Testing
@testable import AutoReplyApp

@Test func versionBUsesDistinctDisplayNameAndBundleIdentifier() {
    #expect(AppIdentity.displayName == "千牛全自动客服-版本B")
    #expect(AppIdentity.bundleIdentifier == "com.scy.qianniu-autoreply.version-b")
}
