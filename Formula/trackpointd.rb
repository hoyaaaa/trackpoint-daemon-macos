class Trackpointd < Formula
  desc "Menu bar companion for ThinkPad TrackPoint keyboards"
  homepage "https://github.com/hoyaaaa/trackpoint-daemon-macos"
  url "https://github.com/hoyaaaa/trackpoint-daemon-macos/releases/download/v2.3.2/trackpointd-2.3.2.tar.gz"
  sha256 "686002891c6a09a3c2b18ec27583e754ea395051b44a8e322b76947916df5c20"
  version "2.3.2"
  head "https://github.com/hoyaaaa/trackpoint-daemon-macos.git", branch: "main"
  license "MIT"
  depends_on macos: :monterey
  skip_clean "TrackPointD.app"

  def install
    system "bash", "scripts/build-app.sh", buildpath/"TrackPointD.app"
    prefix.install "TrackPointD.app"
    (bin/"trackpointd").write <<~SH
      #!/bin/bash
      if [ "$#" -eq 0 ]; then
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
      This source-built app uses ad-hoc signing; privacy approval may be needed again.
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
