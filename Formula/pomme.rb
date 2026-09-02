class Pomme < Formula
  desc "Headless macOS VM CLI built with Virtualization.framework"
  homepage "https://github.com/weswhet/pomme"
  license "NOASSERTION"
  head "https://github.com/weswhet/pomme.git", branch: "main"

  depends_on xcode: ["16.0", :build]
  depends_on arch: :arm64

  def install
    build_dir = buildpath/"build"
    product_dir = build_dir/"Release"

    xcodebuild \
      "-project", "pomme.xcodeproj",
      "-scheme", "pomme",
      "-configuration", "Release",
      "-arch", "arm64",
      "SYMROOT=#{build_dir}",
      "build"

    bin.install product_dir/"pomme"
  end

  test do
    assert_match "pomme CLI", shell_output("#{bin}/pomme --help")
  end
end
