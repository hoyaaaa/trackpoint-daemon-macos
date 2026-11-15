class Trackpointd < Formula
  desc "Menu bar companion for ThinkPad TrackPoint keyboards"
  homepage "https://github.com/hoyaaaa/trackpoint-daemon-macos"
  url "https://github.com/hoyaaaa/trackpoint-daemon-macos/releases/download/v2.5.0/trackpointd-2.5.0.tar.gz"
  sha256 "da4494667e12c38b0e97dcc187a6f20047d73b99e884006212edf22510978739"
  version "2.5.0"
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
