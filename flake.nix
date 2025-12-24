{
  description = "Zig 0.14 SDL3 OpenGL Triangle";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # Zig 0.14 is currently development/master.
    # We use an overlay to get the latest compiler.
    zig-overlay.url = "github:mitchellh/zig-overlay";
    zig-overlay.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, zig-overlay }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        overlays = [ zig-overlay.overlays.default ];
      };

      # Select Zig 0.14 (master/nightly)
      zig = pkgs.zigpkgs.master;
    in
    {
      packages.${system}.default = pkgs.stdenv.mkDerivation {
        pname = "zig-triangle";
        version = "0.1.0";
        src = ./.;

        nativeBuildInputs = [
          zig
          pkgs.pkg-config
          pkgs.patchelf
          pkgs.makeWrapper
        ];

        buildInputs = [
          pkgs.sdl3
          pkgs.glew
          pkgs.libGL
          pkgs.vulkan-loader
          pkgs.vulkan-headers
          pkgs.vulkan-validation-layers
        ];

        # Disable hardening to fix "__builtin_va_arg_pack" error during C import
        hardeningDisable = [ "all" ];

        dontConfigure = true;
        dontBuild = true;

        installPhase = ''
          export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache
          zig build -Doptimize=Debug -Dtarget=x86_64-linux-gnu --prefix $out
        '';

        postFixup = ''
          patchelf --add-rpath ${pkgs.lib.makeLibraryPath [ pkgs.glew pkgs.libGL pkgs.sdl3 pkgs.vulkan-loader pkgs.stdenv.cc.cc.lib ]} $out/bin/zig-triangle
          wrapProgram $out/bin/zig-triangle \
            --prefix LD_LIBRARY_PATH : ${pkgs.lib.makeLibraryPath [ pkgs.stdenv.cc.cc.lib pkgs.vulkan-loader ]}
        '';
      };

      devShells.${system}.default = pkgs.mkShell {
        nativeBuildInputs = [
          zig
          pkgs.zls
          pkgs.pkg-config
          pkgs.glslang
        ];

        buildInputs = [
          pkgs.sdl3
          pkgs.glew    # For GL extension loading
          pkgs.libGL   # Base OpenGL driver support
          pkgs.vulkan-loader
          pkgs.vulkan-headers
          pkgs.vulkan-validation-layers
        ];

        shellHook = ''
          echo "Zig 0.14 + SDL3 Dev Environment"
          echo "Compiler: $(zig version)"
        '';
      };
    };
}
