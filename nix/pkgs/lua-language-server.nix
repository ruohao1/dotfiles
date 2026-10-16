{ lua-language-server, fetchFromGitHub }:
# Preserve the bootstrap's >=3.19.1 requirement. Official source/submodule hash
# from nixpkgs c9fe7d12cd78d1adcd12dd15e24432dde5b155a0; build recipe is unchanged.
lua-language-server.overrideAttrs (_: {
  version = "3.19.1";
  src = fetchFromGitHub {
    owner = "luals";
    repo = "lua-language-server";
    tag = "3.19.1";
    hash = "sha256-3Sm958Fr5wn54B+aJMaK+cR/F10dPIcGvBrhjHTy2us=";
    fetchSubmodules = true;
  };
})
