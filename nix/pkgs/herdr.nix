{ lib, stdenv, stdenvNoCC, fetchurl, autoPatchelfHook }:
let
  # Digests published by the official v0.8.0 GitHub release API. Linux values
  # additionally match the repository's existing direct-download manifest.
  assets = {
    x86_64-linux = { name = "herdr-linux-x86_64"; sha256 = "b872ea7e40fa2cb17e857ac9b62b1bf26db7b403c622f5d2f3f5b35f6e9acd28"; };
    aarch64-linux = { name = "herdr-linux-aarch64"; sha256 = "f647ac66468d9efbc642fe534fb284468f0aea60641606fc008dfc0d82a3ca87"; };
    x86_64-darwin = { name = "herdr-macos-x86_64"; sha256 = "77cb5afd6c8fcaaaf3bc28e474ec01c209331ad08094e20d7f8aa9b0bb78d649"; };
    aarch64-darwin = { name = "herdr-macos-aarch64"; sha256 = "d53a9f93fccfdfcc55632927bf51002f5add0aa7990bcdf508ffbd84ac658178"; };
  };
  asset = assets.${stdenvNoCC.hostPlatform.system};
in stdenvNoCC.mkDerivation {
  pname = "herdr";
  version = "0.8.0";
  src = fetchurl {
    url = "https://github.com/herdrdev/herdr/releases/download/v0.8.0/${asset.name}";
    inherit (asset) sha256;
  };
  dontUnpack = true;
  dontStrip = true;
  nativeBuildInputs = lib.optionals stdenvNoCC.hostPlatform.isLinux [ autoPatchelfHook ];
  buildInputs = lib.optionals stdenvNoCC.hostPlatform.isLinux [ stdenv.cc.cc.lib ];
  installPhase = ''
    runHook preInstall
    mkdir -p "$out/bin"
    install -m755 "$src" "$out/bin/herdr"
    runHook postInstall
  '';
  meta = {
    description = "Terminal agent multiplexer, pinned compatible upstream release";
    homepage = "https://herdr.dev";
    license = lib.licenses.asl20;
    mainProgram = "herdr";
    platforms = builtins.attrNames assets;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
}
