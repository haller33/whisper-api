{ pkgs ? import <nixpkgs> {} }:

pkgs.mkShell {
  buildInputs = [
    pkgs.uv
    pkgs.python312
    pkgs.stdenv.cc.cc.lib
    pkgs.zlib
    pkgs.libgcc
    pkgs.ffmpeg
    pkgs.pkg-config
    pkgs.portaudio
  ];

  shellHook = ''
    # Manually build the library path string for the environment
    export LD_LIBRARY_PATH="${pkgs.lib.makeLibraryPath [ 
      pkgs.stdenv.cc.cc.lib 
      pkgs.zlib 
      pkgs.libgcc
      pkgs.ffmpeg
      pkgs.pkg-config
      pkgs.portaudio
      pkgs.uv
    ]}:$LD_LIBRARY_PATH"

    # Activate your virtual environment automatically
    if [ -d .venv ]; then
      source .venv/bin/activate
    fi
    
    echo "--- NixOS Dev Environment Active ---"
    echo "Libraries loaded: zlib, libstdc++, libgcc"
  '';
}
