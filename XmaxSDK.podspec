Pod::Spec.new do |spec|
  spec.name = 'XmaxSDK'
  spec.version = '1.0.13'
  spec.summary = 'Xmax realtime generation SDK for iOS.'
  spec.description = <<-DESC
    XmaxSDK provides the native iOS APIs for Xmax realtime generation.
    Supports Swift Package Manager, CocoaPods, and manual integration.
  DESC

  spec.homepage = 'https://xmax.ai'
  spec.license = { type: 'MIT', file: 'LICENSE' }
  spec.author = { 'XMAX.AI PTE. LTD.' => 'sdk@xmax.ai' }
  spec.source = {
    git: 'https://github.com/Xmax-AI/XmaxSDK-iOS.git',
    tag: spec.version.to_s
  }

  spec.platform = :ios, '15.0'
  spec.swift_version = '6.0'
  spec.module_name = 'XmaxSDK'
  spec.static_framework = true
  spec.source_files = 'Sources/XmaxSDK/**/*.swift'

  # QCloudCOSXML 6.5.7 excludes arm64 for every consumer simulator target.
  # Its sources build on arm64, so undo that legacy setting for Apple silicon.
  spec.user_target_xcconfig = {
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => ''
  }

  spec.dependency 'AgoraRtcEngine_iOS/RtcBasic', '4.6.4'
  spec.dependency 'QCloudCOSXML/Transfer', '6.5.7'

  spec.test_spec 'Tests' do |tests|
    tests.source_files = 'Tests/XmaxSDKTests/**/*.swift'
  end
end
