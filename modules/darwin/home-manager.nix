{
  config,
  pkgs,
  lib,
  home-manager,
  ...
}:

let
  user = "lucg";
  sharedFiles = import ../shared/files.nix { inherit config pkgs; };
  additionalFiles = import ./files.nix { inherit user config pkgs; };
in
{
  imports = [
    ./dock
  ];

  # It me
  users.users.${user} = {
    name = "${user}";
    home = "/Users/${user}";
    isHidden = false;
    shell = pkgs.zsh;
  };

  homebrew = {
    enable = true;
    taps = [
      # alleviates 'error' / warning about attempting to untap homebrew/cask
      "homebrew/homebrew-cask"
      "homebrew/homebrew-bundle"
      # "homebrew/homebrew-core" # seemingly not necessary
    ];
    casks = pkgs.callPackage ./casks.nix { };
    brews = pkgs.callPackage ./brews.nix { };
    onActivation.cleanup = "zap";

    # These app IDs are from using the mas CLI app
    # mas = mac app store
    # https://github.com/mas-cli/mas
    #
    # $ nix shell nixpkgs#mas
    # $ mas search <app name>
    #
    # If you have previously added these apps to your Mac App Store profile (but not installed them on this system),
    # you may receive an error message "Redownload Unavailable with This Apple ID".
    # This message is safe to ignore. (https://github.com/dustinlyons/nixos-config/issues/83)
    masApps = {
      "wireguard" = 1451685025;
      "craft" = 1487937127;
      "microsoft-outlook" = 985367838;
      "xcode" = 497799835;
      "microsoft-word" = 462054704;
      "whatsapp-messenger" = 310633997;
      "copilot" = 1447330651;
      "vimlike" = 1584519802;
      "pages" = 409201541;
      "amphetamine" = 937984704;
    };
  };

  # Enable home-manager
  home-manager = {
    useGlobalPkgs = true;
    users.${user} =
      {
        pkgs,
        config,
        lib,
        ...
      }:
      {
        home = {
          enableNixpkgsReleaseCheck = false;
          packages = pkgs.callPackage ./packages.nix { };
          file = lib.mkMerge [
            sharedFiles
            additionalFiles
          ];
          stateVersion = "23.11";
        };
        programs = { } // import ../shared/home-manager.nix { inherit config pkgs lib; };

        # Marked broken Oct 20, 2022 check later to remove this
        # https://github.com/nix-community/home-manager/issues/3344
        manual.manpages.enable = false;
      };
  };

  # Fully declarative dock using the latest from Nix Store
  local.dock = {
    enable = true;
    username = user;
    entries = [
      { path = "/System/Applications/Launchpad.app/"; }
      { path = "/Applications/Slack.app/"; }
      { path = "/System/Applications/Messages.app/"; }
      { path = "/Applications/Ghostty.app/"; }
      { path = "/System/Applications/Music.app/"; }
      { path = "/System/Applications/News.app/"; }
      { path = "/System/Applications/Photos.app/"; }
      { path = "/System/Applications/System Settings.app/"; }
      {
        path = "${config.users.users.${user}.home}/Downloads";
        section = "others";
        options = "--sort name --view grid --display stack";
      }
    ];
  };

}
