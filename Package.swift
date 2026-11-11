// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WeChatAutoReply",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "WeChatAutoReplyCore", targets: ["WeChatAutoReplyCore"]),
        .executable(name: "wechat-autoreply", targets: ["WeChatAutoReply"]),
        .executable(name: "self-test", targets: ["WeChatAutoReplySelfTest"]),
    ],
    targets: [
        .target(name: "WeChatAutoReplyCore"),
        .executableTarget(
            name: "WeChatAutoReply",
            dependencies: ["WeChatAutoReplyCore"]
        ),
        .executableTarget(
            name: "WeChatAutoReplySelfTest",
            dependencies: ["WeChatAutoReplyCore"],
            path: "Tests/WeChatAutoReplySelfTest"
        ),
    ]
)
