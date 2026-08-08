{
  description = "Shi-tate reproducible macOS development tools";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { nixpkgs, ... }:
    let
      system = "aarch64-darwin";
      pkgs = import nixpkgs { inherit system; };
    in
    {
      devShells.${system}.default = pkgs.mkShellNoCC {
        packages = with pkgs; [
          actionlint
          cmake
          coreutils
          git
          gnugrep
          gnutar
          imagemagick
          jq
          ninja
          nixfmt
          pkg-config
          ripgrep
          shellcheck
          yq-go
          zstd
        ];

        shellHook = ''
          if [[ -z "''${DEVELOPER_DIR:-}" ]]; then
            for candidate in \
              /Applications/Xcode.app/Contents/Developer \
              /Applications/Xcode_26.6.app/Contents/Developer; do
              if [[ -d "$candidate" ]]; then
                export DEVELOPER_DIR="$candidate"
                break
              fi
            done
          fi

          if [[ ! -d "''${DEVELOPER_DIR:-}" ]]; then
            printf 'Shi-tate requires Xcode 26.6 under /Applications.\n' >&2
          fi
        '';
      };

      formatter.${system} = pkgs.nixfmt;
    };
}
