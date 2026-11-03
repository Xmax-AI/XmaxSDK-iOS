# Installation guide

For CocoaPods, follow the [README installation steps](../README.md#cocoapods).
This guide covers the Agora-based implementation.
Use the installation guide from the Git tag matching your SDK release;
older XmaxSDK binaries require their original RTC dependencies.

## Swift Package Manager

Follow the [SwiftPM instructions in the README](../README.md#swift-package-manager)
and add only the **XmaxSDK** product to your application target.

- XmaxSDK requires Xcode 26 or later (Swift 6.2+ compiler, Swift 6 language mode)
  and supports iOS 15.0 or later.
- Agora RTC `4.6.4` is resolved from the
  [official Swift package](https://github.com/AgoraIO/AgoraRtcEngine_iOS).
- COS `6.5.7` uses Xmax-built dynamic XCFrameworks for `QCloudCOSXML/Transfer`
  and `QCloudCore/WithoutMTA`, without the optional Tencent analytics components.
  This is an Xmax packaging of Tencent's source, not an official Tencent Swift package.
  The archives and notices are published in the
  [COS dependency release](https://github.com/Xmax-AI/XmaxSDK-iOS/releases/tag/cos-6.5.7-spm.1).
- COS archives contain the upstream copyright and license notices; the COS XML
  framework also includes the upstream privacy manifest. Keep these files when
  redistributing the frameworks.
- The COS binaries support iOS devices (`arm64`) and simulators (`arm64`, `x86_64`).
  Xcode handles linking, embedding, and signing the dynamic dependencies.

The manual integration instructions below use Tencent's **official static** COS
frameworks. Their embed settings do not apply to the **dynamic** COS frameworks
downloaded by SwiftPM. Do not mix the two distributions in the same app target.

## Manual integration

### Download the frameworks

Download and extract `XmaxSDK.xcframework` from the
[release archive linked in the README](../README.md#manual). Do not combine an
older VolcEngine-based XmaxSDK binary with the Agora dependencies below.
Use these exact versions:

- [Agora RTC `4.6.4`](https://download.agora.io/sdk/release/AgoraRtcEngine_iOS-4.6.4.zip):
  use `AgoraRtcKit.xcframework`, `Agorafdkaac.xcframework`,
  `Agoraffmpeg.xcframework`, `AgoraSoundTouch.xcframework`, and `video_dec.xcframework`.
- [Agora Infrastructure `1.3.5`](https://download.agora.io/sdk/release/AgoraInfra_iOS-1.3.5.zip):
  use `aosl.xcframework`.
- [Tencent Cloud COS iOS SDK `6.5.7`](https://github.com/tencentyun/qcloud-sdk-ios/releases/download/6.5.7/QCloudCOSXML-6.5.7.zip):
  use `QCloudCOSXML.xcframework` and `QCloudCore.xcframework` from the official
  release archive.

### Configure embedding

Add the frameworks to the application target under **Frameworks, Libraries, and
Embedded Content**:

| Framework | Embed setting |
| --- | --- |
| `XmaxSDK.xcframework` | Do Not Embed |
| `QCloudCOSXML.xcframework` | Do Not Embed |
| `QCloudCore.xcframework` | Do Not Embed |
| `AgoraRtcKit.xcframework` | Embed & Sign |
| `Agorafdkaac.xcframework` | Embed & Sign |
| `Agoraffmpeg.xcframework` | Embed & Sign |
| `AgoraSoundTouch.xcframework` | Embed & Sign |
| `video_dec.xcframework` | Embed & Sign |
| `aosl.xcframework` | Embed & Sign |

The XmaxSDK and COS binaries are static. The six Agora binaries are dynamic
and must be embedded and signed by the application target.

### Configure the target

1. Set the deployment target to **iOS 15.0** or later and **Swift Language Version**
   to **Swift 6**.
2. Add `-ObjC` to **Other Linker Flags**.
3. Link `Accelerate.framework`, `CoreMedia.framework`,
   `CoreTelephony.framework`, `SystemConfiguration.framework`, `libz.tbd`,
   and `libc++.tbd`.
4. Add the COS
   [`PrivacyInfo.xcprivacy`](https://github.com/tencentyun/qcloud-sdk-ios/blob/6.5.7/QCloudCOSXML/PrivacyInfo.xcprivacy)
   file to the application target.
5. Confirm that every XCFramework contains a slice for the target platform and
   architecture. Apple silicon simulator builds require an `arm64` simulator slice.

Only `QCloudCOSXML.xcframework` and `QCloudCore.xcframework` are required for COS.
Do not add `QCloudTrack.xcframework`, `COSBeaconAPI_Base.xcframework`, or QimeiSDK.
The third-party frameworks must be present when importing XmaxSDK because its stable
Swift module interface imports `QCloudCOSXML` and `AgoraRtcKit`.

Continue with the [Quick Start](../README.md#quick-start) to configure permissions
and start generation.
