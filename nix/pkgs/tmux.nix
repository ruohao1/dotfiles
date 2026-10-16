{ tmux, fetchFromGitHub, lib, stdenv, jemalloc }:
# Source hash and Darwin jemalloc setup from the official nixpkgs expression at
# c9fe7d12cd78d1adcd12dd15e24432dde5b155a0. Retain the locked baseline recipe.
tmux.overrideAttrs (previous: {
  version = "3.7c";
  src = fetchFromGitHub {
    owner = "tmux";
    repo = "tmux";
    tag = "3.7c";
    hash = "sha256-TpZXTeXKQv6MV1vAPu5MIT52d3Pl6dYcOReZa7QANZY=";
  };
  # The baseline's control-notify patch is already included in 3.7c.
  patches = [ ];
  buildInputs = previous.buildInputs ++ lib.optionals stdenv.hostPlatform.isDarwin [ jemalloc ];
  configureFlags = previous.configureFlags ++ lib.optionals stdenv.hostPlatform.isDarwin [ "--enable-jemalloc" ];
})
