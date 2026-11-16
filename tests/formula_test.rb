# Evaluate the real Homebrew DSL/install method in a temporary prefix.
# Does not tap/install/register a package in the user's Homebrew installation.
ENV["TRACKPOINTD_SIGN_IDENTITY"] = "-" # Never use the user's signing key in automated tests.
require "formula"
require "formulary"
require "tmpdir"

source = Pathname(__dir__).parent
path = source/"Formula/trackpointd.rb"
klass = Formulary.load_formula_from_path("trackpointd", path, flags: [], ignore_errors: false)
formula = klass.new("trackpointd", path, :head)
Dir.mktmpdir("trackpointd-formula-test.") do |directory|
  root = Pathname(directory)
  build = root/"build"
  prefix = root/"prefix"
  (build/"Resources").mkpath
  %w[keyboard-windows.png f12-windows.png].each { |name| (build/"Resources"/name).write((source/"Resources"/name).binread) }
  (build/"scripts").mkpath
  (prefix/"bin").mkpath
  %w[trackpointd.m version.h updates.h upgrade.h icon.h windows-theme.h TrackPointD.icns].each { |file| (build/file).write((source/file).binread) }
  (build/"scripts/setup-signing.sh").write((source/"scripts/setup-signing.sh").read)
  (build/"scripts/signing-identity.sh").write((source/"scripts/signing-identity.sh").read)
  (build/"scripts/upgrade.sh").write((source/"scripts/upgrade.sh").read)
  (build/"scripts/build-app.sh").write((source/"scripts/build-app.sh").read)
  formula.define_singleton_method(:buildpath) { build }
  formula.define_singleton_method(:prefix) { prefix }
  formula.define_singleton_method(:opt_prefix) { prefix }
  formula.define_singleton_method(:libexec) { prefix/"libexec" }
  formula.define_singleton_method(:bin) { prefix/"bin" }
  formula.define_singleton_method(:system) do |*arguments|
    # Formula#system accepts command arguments, not Kernel.system's leading env Hash.
    raise "Homebrew system does not accept an environment Hash" if arguments.any? { |argument| argument.is_a?(Hash) }
    raise "command failed: #{arguments}" unless Kernel.system(*arguments.map(&:to_s))
  end
  # Before promotion, the old stable archive has no helpers: post_install is inert.
  formula.post_install
  Dir.chdir(build) { formula.install; formula.post_install }
  %w[signing-identity.sh setup-signing.sh].each do |name|
    raise "missing installed signing helper" unless (prefix/"libexec/signing"/name).file?
  end
  %w[keyboard-windows.png f12-windows.png].each do |name|
    raise "missing or changed Windows image" unless (prefix/"TrackPointD.app/Contents/Resources"/name).binread == (source/"Resources"/name).binread
  end
  executable = prefix/"bin/trackpointd"
  raise "wrapper is not executable" unless executable.executable?
  expected = (source/"version.h").read.match(/^#define TRACKPOINTD_VERSION "([^"]+)"$/)[1]
  raise "version mismatch" unless IO.popen([executable.to_s, "--version"], &:read).strip == expected && $?.success?
  raise "self-test failed" unless IO.popen([executable.to_s, "--self-test"], &:read).include?("self-test: ok") && $?.success?
  raise "signature invalid" unless Kernel.system("/usr/bin/codesign", "--verify", "--deep", "--strict", (prefix/"TrackPointD.app").to_s)
  version = IO.popen(["/usr/bin/plutil", "-extract", "CFBundleShortVersionString", "raw", "-o", "-", (prefix/"TrackPointD.app/Contents/Info.plist").to_s], &:read).strip
  raise "bundle version mismatch" unless version == expected
end
puts "Homebrew build/wrapper/bundle smoke test: ok (temporary prefix)"
