class Trackpointd < Formula
  desc "Menu bar companion for ThinkPad TrackPoint keyboards"
  homepage "https://github.com/hoyaaaa/trackpoint-daemon-macos"
  url "https://github.com/hoyaaaa/trackpoint-daemon-macos/releases/download/v2.6.0/trackpointd-2.6.0.tar.gz"
  sha256 "02db6edd824a9161acf90b370285b3fbed94821f0f85f6bf00f24fa4ac265277"
  version "2.6.0"
  head "https://github.com/hoyaaaa/trackpoint-daemon-macos.git", branch: "main"
  license "MIT"
  depends_on macos: :monterey
  skip_clean "TrackPointD.app"

  def install
    # Homebrew also isolates post-install. Sign from the launcher/updater instead.
    system "env", "TRACKPOINTD_SIGN_IDENTITY=-", "bash", "scripts/build-app.sh", buildpath/"TrackPointD.app"
    # The previous stable source archive has no local-signing helpers yet.
    if (buildpath/"scripts/signing-identity.sh").file?
      (libexec/"signing").install "scripts/signing-identity.sh", "scripts/setup-signing.sh"
      (libexec/"signing").install "scripts/sign-app.sh" if (buildpath/"scripts/sign-app.sh").file?
    end
    prefix.install "TrackPointD.app"
    (bin/"trackpointd").write <<~SH
      #!/bin/bash
      set -euo pipefail
      if [ "$#" -eq 0 ]; then
        if [ -f "#{opt_prefix}/libexec/signing/sign-app.sh" ]; then
          /bin/bash "#{opt_prefix}/libexec/signing/sign-app.sh" "#{opt_prefix}/TrackPointD.app"
        fi
        exec /usr/bin/open -g "#{opt_prefix}/TrackPointD.app"
      fi
      exec "#{opt_prefix}/TrackPointD.app/Contents/MacOS/trackpointd" "$@"
    SH
    (bin/"trackpointd").chmod 0755
  end

  def caveats
    <<~EOS
      Start TrackPointD with: trackpointd
      Grant Accessibility and Input Monitoring permission to TrackPointD.
      Quit TrackPointD before upgrading, then run trackpointd to reopen it.
      Run trackpointd once after installing/upgrading to create or reuse local signing.
      macOS may ask you to unlock the keychain or approve codesign on first use.
      Add #{opt_prefix}/TrackPointD.app to Login Items if desired.
      Do not also run a separately installed copy from ~/Applications.
    EOS
  end

  test do
    system "/usr/bin/codesign", "--verify", "--deep", "--strict", prefix/"TrackPointD.app"
    assert_match version.to_s, shell_output("#{bin}/trackpointd --version") unless build.head?
    assert_match "self-test: ok", shell_output("#{bin}/trackpointd --self-test")
  end
end
