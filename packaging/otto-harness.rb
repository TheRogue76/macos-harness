cask "@CASK@" do
  version "@VERSION@"
  sha256 "@SHA256@"

  url "https://github.com/TheRogue76/otto-harness/releases/download/v#{version}/Otto-#{version}.zip"
  name "Otto"
  desc "Lets coding agents see and operate Mac apps, simulators and Android devices"
  homepage "https://github.com/TheRogue76/otto-harness"

  conflicts_with cask: "@OTHER@"
  depends_on macos: :sequoia

  app "Otto.app"
  binary "#{appdir}/Otto.app/Contents/MacOS/otto"
  binary "#{appdir}/Otto.app/Contents/MacOS/otto", target: "macos-harness"

  uninstall quit: "io.github.therogue76.macos-harness"

  zap trash: [
    "~/.config/otto",
    "~/Library/Application Support/otto",
    "~/Library/Logs/otto",
    "~/.config/macos-harness",
    "~/Library/Application Support/macos-harness",
    "~/Library/Logs/macos-harness",
    "~/Library/Preferences/io.github.therogue76.macos-harness.plist",
  ]

  caveats <<~EOS
    Run `otto doctor`, grant the two permissions from the menu bar icon, then
    connect your agent with `otto setup claude` (or codex, cursor, gemini,
    opencode or pi). `macos-harness` still works as another name for `otto`.
  EOS
end
