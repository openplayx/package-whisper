# In-process speech recognition: compiles the opx_asr C ABI and links the
# pinned whisper.cpp / ggml static libraries (CPU backend) into this plugin's
# framework. Only opx_asr_* symbols are exported.
Pod::Spec.new do |s|
  s.name = 'openplayx_whisper'
  s.version = '0.1.0'
  s.summary = 'OpenPlayX in-process whisper.cpp speech recognition'
  s.homepage = 'https://github.com/openplayx/openplayx'
  s.license = { :type => 'MIT' }
  s.author = 'OpenPlayX'
  s.source = { :path => '.' }
  s.source_files = 'Classes/**/*'
  s.tvos.deployment_target = '15.0'
  s.frameworks = 'Accelerate', 'Foundation'
  s.libraries = 'c++'
  s.script_phase = {
    :name => 'Build pinned whisper.cpp',
    :script => 'bash "${PODS_TARGET_SRCROOT}/../tool/ensure_whisper_apple.sh"',
    :execution_position => :before_compile,
    :always_out_of_date => '1',
  }
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'FRAMEWORK_SEARCH_PATHS' => '$(inherited) "${PODS_ROOT}/../Flutter"',
    'LIBRARY_SEARCH_PATHS[sdk=appletvos*]' => '"${PODS_TARGET_SRCROOT}/../third_party/whisper/tvos-arm64/lib"',
    'LIBRARY_SEARCH_PATHS[sdk=appletvsimulator*][arch=arm64]' => '"${PODS_TARGET_SRCROOT}/../third_party/whisper/tvos-sim-arm64/lib"',
    'LIBRARY_SEARCH_PATHS[sdk=appletvsimulator*][arch=x86_64]' => '"${PODS_TARGET_SRCROOT}/../third_party/whisper/tvos-sim-x86_64/lib"',
    'HEADER_SEARCH_PATHS[sdk=appletvos*]' => '"${PODS_TARGET_SRCROOT}/../third_party/whisper/tvos-arm64/include"',
    'HEADER_SEARCH_PATHS[sdk=appletvsimulator*][arch=arm64]' => '"${PODS_TARGET_SRCROOT}/../third_party/whisper/tvos-sim-arm64/include"',
    'HEADER_SEARCH_PATHS[sdk=appletvsimulator*][arch=x86_64]' => '"${PODS_TARGET_SRCROOT}/../third_party/whisper/tvos-sim-x86_64/include"',
    'OTHER_LDFLAGS' => '-lwhisper -lggml -lggml-cpu -lggml-base -Wl,-exported_symbols_list,"${PODS_TARGET_SRCROOT}/../src/exports.txt"',
    'GCC_SYMBOLS_PRIVATE_EXTERN' => 'YES',
    'WARNING_CFLAGS' => '-Wno-documentation',
  }
end
