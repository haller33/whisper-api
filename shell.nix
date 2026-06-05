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
    export LD_LIBRARY_PATH="${pkgs.lib.makeLibraryPath [ 
      pkgs.stdenv.cc.cc.lib 
      pkgs.zlib 
      pkgs.libgcc
      pkgs.ffmpeg
      pkgs.pkg-config
      pkgs.portaudio
    ]}:$LD_LIBRARY_PATH"

    # Create virtual environment if it doesn't exist
    if [ ! -d .venv ]; then
      echo "Creating virtual environment with uv..."
      uv venv .venv
    fi

    # Activate the virtual environment
    source .venv/bin/activate

    # Install build essentials
    uv pip install setuptools wheel

    # Install ALL dependencies from requirements.txt without build isolation
    # This fixes the openai-whisper ModuleNotFoundError for pkg_resources
    echo "Installing all Python dependencies (this may take a moment)..."
    uv pip install -r requirements.txt --no-build-isolation

    echo "--- NixOS Dev Environment Active ---"
    echo "Python: $(python --version)"
    echo "Virtual env: $VIRTUAL_ENV"
    echo "Libraries: zlib, libstdc++, libgcc, ffmpeg, portaudio"
    echo "All dependencies installed. Ready to run: uv run python whisper_api.py"
    # uv run python whisper_api.py
  '';
}
