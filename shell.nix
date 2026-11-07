# Zig and the load generator used by the published comparison.
# Abla, Go, and Rust/Cargo are selected from the caller's environment;
# benchmark.py records their exact versions in every result.
let
  pkgs = import (builtins.fetchTarball {
    url = "https://github.com/NixOS/nixpkgs/archive/6510408d147d8c5e6d76043e899e9251756f6a75.tar.gz";
    sha256 = "012w2z2w4k0c3kg9hcy9cpd7qgxgrpxvf0735vy014r7x9qhmbjw";
  }) {};
in pkgs.mkShell {
  packages = [ pkgs.oha pkgs.zig ];
}
