{
  description = "ClaudeGlance — a macOS menu bar app showing Claude.ai plan usage in real time";

  # A stable darwin release branch (not nixpkgs-unstable, which dropped
  # x86_64-darwin), locked to one commit in flake.lock. The lock is refreshed by
  # scripts/update-flake.sh at each release; scripts/check-flake-lock.sh (CI and
  # `just lint`) fails if it is missing or out of step with this line, and CI
  # builds with --no-update-lock-file.
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-26.05-darwin";

  outputs = { self, nixpkgs }:
    let
      # Tracks the latest *public* release. Bump both together when a new version
      # ships — scripts/update-flake.sh does it from the released DMG. (ClaudeGlance
      # versions on `develop` between public releases; this points at the release.)
      version = "1.8.4";
      # SRI hash of that release's ClaudeGlance.dmg — the same artifact the Homebrew
      # cask pins (hex 228913f8…). Verify with: scripts/update-flake.sh <version>.
      dmgHash = "sha256-IokT+HN0pKD2iy2ZFi/mTX4CKnscLdj8tEBqb6A7F9o=";

      # macOS only — this is a native .app bundle (no Linux build).
      systems = [ "aarch64-darwin" "x86_64-darwin" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      packages = forAllSystems (pkgs:
        let
          claudeglance = pkgs.stdenvNoCC.mkDerivation {
            pname = "claudeglance";
            inherit version;

            src = pkgs.fetchurl {
              url = "https://github.com/workshop144/claudeglance/releases/download/v${version}/ClaudeGlance.dmg";
              hash = dmgHash;
            };

            nativeBuildInputs = [ pkgs.undmg pkgs.makeWrapper ];

            # undmg expands the disk image into the current directory; the app then
            # sits at ./ClaudeGlance.app.
            sourceRoot = ".";
            unpackCmd = "undmg \"$src\"";

            installPhase = ''
              runHook preInstall
              mkdir -p "$out/Applications"
              cp -R "ClaudeGlance.app" "$out/Applications/ClaudeGlance.app"
              # A `bin/claudeglance` launcher so `nix run` works and the app is on
              # PATH; Finder/Spotlight users get the bundle from $out/Applications
              # (nix-darwin / home-manager link it into ~/Applications).
              makeWrapper \
                "$out/Applications/ClaudeGlance.app/Contents/MacOS/ClaudeGlance" \
                "$out/bin/claudeglance"
              runHook postInstall
            '';

            meta = with pkgs.lib; {
              description = "macOS menu bar app showing Claude.ai plan usage in real time";
              homepage = "https://github.com/workshop144/claudeglance";
              license = licenses.mit;
              # Ad-hoc signed (not notarized) until an Apple Developer account lands.
              sourceProvenance = [ sourceTypes.binaryNativeCode ];
              platforms = systems;
              mainProgram = "claudeglance";
              maintainers = [ ];
            };
          };
        in
        {
          inherit claudeglance;
          default = claudeglance;
        });
    };
}
