_self: super:
let
  inherit (super) lib runCommand writeShellApplication;
  nixKit = runCommand "sbxa-nix-kit" { } ''
    mkdir -p $out
    cp -r ${../sandboxes/kits/nix}/. $out/
  '';
in
{
  sbxa = writeShellApplication {
    name = "sbxa";
    runtimeInputs = with super; [
      coreutils
      gnugrep
      gnused
      jq
    ];
    text = lib.replaceStrings [ "@storeKit@" ] [ (toString nixKit) ] (
      builtins.readFile ../sandboxes/sbxa.sh
    );
  };
}
