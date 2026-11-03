// swift-tools-version: 6.2
//
//  Package.swift
//  XmaxSDK
//  Repo: https://github.com/Xmax-AI/XmaxSDK-iOS
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/WengYuehTing
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.

import PackageDescription

let package = Package(
    name: "XmaxSDK",
    platforms: [.iOS(.v15)],
    products: [
        .library(name: "XmaxSDK", targets: ["XmaxSDK"])
    ],
    dependencies: [
        .package(url: "https://github.com/AgoraIO/AgoraRtcEngine_iOS.git", exact: "4.6.4")
    ],
    targets: [
        .target(
            name: "XmaxSDK",
            dependencies: [
                .product(name: "RtcBasic", package: "AgoraRtcEngine_iOS"),
                "QCloudCore",
                "QCloudCOSXML"
            ],
            path: "Sources/XmaxSDK"
        ),
        .binaryTarget(
            name: "QCloudCore",
            url: "https://github.com/Xmax-AI/XmaxSDK-iOS/releases/download/cos-6.5.7-spm.1/QCloudCore-6.5.7.xcframework.zip",
            checksum: "0c796e1c24b35408ea731b0889c41d481853097323af5a3e9b3c3b3af0900d95"
        ),
        .binaryTarget(
            name: "QCloudCOSXML",
            url: "https://github.com/Xmax-AI/XmaxSDK-iOS/releases/download/cos-6.5.7-spm.1/QCloudCOSXML-6.5.7.xcframework.zip",
            checksum: "027838546a66fa9ade3db2baeea71e607395607650c6d6036e5d8c99dbe6f4a7"
        )
    ]
)
