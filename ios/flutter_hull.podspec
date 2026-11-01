Pod::Spec.new do |s|
  s.name = 'flutter_hull'
  s.version = '0.1.0-preview.1'
  s.summary = 'FlutterHull host container with single/group engines and Aeris integration'
  s.description = 'FlutterHull public preview host container with managed routes and resource cleanup.'
  s.homepage = 'https://github.com/zhangguozhong/flutter-hull'
  s.license = { :type => 'MIT', :file => '../LICENSE' }
  s.author = 'FlutterHull'
  s.source = { :git => 'https://github.com/zhangguozhong/flutter-hull.git', :tag => '0.1.0-preview.1' }
  s.source_files = 'Classes/**/*.swift'
  s.ios.deployment_target = '15.0'
  s.swift_version = '5.0'
  s.dependency 'Flutter'
  s.dependency 'aeris_flutter', '= 0.26.0-preview.2'
  s.dependency 'Aeris/UIKitContext', '= 0.26.0-preview.1'
  s.dependency 'Aeris/Transports', '= 0.26.0-preview.1'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
end
