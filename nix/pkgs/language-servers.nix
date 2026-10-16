{ buildNpmPackage, runCommand, nodejs, makeWrapper }:
let
  manifests = ../../.config/dotfiles/manifests;
  source = runCommand "dotfiles-language-server-source" { } ''
    mkdir -p "$out"
    cp ${manifests}/packages-npm-language-servers.json "$out/package.json"
    cp ${manifests}/packages-npm-language-servers-lock.json "$out/package-lock.json"
  '';
in buildNpmPackage {
  pname = "dotfiles-language-servers";
  version = "1.0.0";
  src = source;
  inherit nodejs;
  npmDepsHash = "sha256-JwnDUUotoCmIHU+J//lecbxM80bP7pnXonE0Az8pWWQ=";
  dontNpmBuild = true;
  nativeBuildInputs = [ makeWrapper ];
  installPhase = ''
    runHook preInstall
    mkdir -p "$out/lib/dotfiles-language-servers" "$out/bin"
    cp -r node_modules package.json package-lock.json "$out/lib/dotfiles-language-servers/"
    for command in bash-language-server pyright pyright-langserver \
      vscode-json-language-server vscode-html-language-server \
      vscode-css-language-server vscode-eslint-language-server yaml-language-server; do
      makeWrapper ${nodejs}/bin/node "$out/bin/$command" \
        --add-flags "$out/lib/dotfiles-language-servers/node_modules/.bin/$command"
    done
    runHook postInstall
  '';
}
