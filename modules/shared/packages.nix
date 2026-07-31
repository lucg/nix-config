{ pkgs }:

with pkgs;
[
  # General packages for development and system management
  alacritty
  bash-completion
  bat
  btop
  coreutils
  killall
  openssh
  sqlite
  wget
  zip
  nixfmt
  yubikey-manager
  tailscale
  mosh

  # Encryption and security tools
  age
  gnupg

  # Cloud-related tools and SDKs
  docker
  docker-compose
  sbxa

  # Media-related packages
  dejavu_fonts
  fd
  font-awesome
  hack-font
  noto-fonts
  noto-fonts-color-emoji
  meslo-lgs-nf
  pandoc
  poppler-utils

  # Node.js development tools
  # nodePackages.npm # globally install npm
  # nodePackages.prettier
  # nodejs_24
  # yarn

  # Text and terminal utilities
  htop
  jetbrains-mono
  jq
  ripgrep
  tree
  tmux
  unzip

  # Development tools
  curl
  terraform
  kubectl
  awscli2
  lazygit
  fzf
  # direnv
  qemu
  cmake
  compiledb

  # Programming languages and runtimes
  go
  rustc
  cargo
  openjdk

  # Python packages
  python3
  uv

  # Compilers
  gfortran14

  # Embedded dev
  platformio
  gcc-arm-embedded

  # Hardware dev
  iverilog
  verilator
  surfer
  openfpgaloader
  pulseview
  yosys

  # LaTeX
  texlive.combined.scheme-full
]
++ (with pkgs.unstable; [
  # Fast-moving media-related packages
  spotify

  # Fast-moving development tools
  vscode
  docker-sbx
  gemini-cli
  claude-code
  cursor-cli
])
