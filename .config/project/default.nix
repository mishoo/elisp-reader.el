{
  config,
  flaky,
  lib,
  supportedSystems,
  ...
}: {
  project = {
    name = "elisp-reader";
    summary = "A custom Lisp reader written in Elisp";
  };

  ## dependency management
  services.renovate.enable = true;

  ## development
  programs = {
    direnv.enable = true;
    git.enable = true;
  };

  ## formatting
  editorconfig.enable = true;
  project.file.".dir-locals.el".source = lib.mkForce ../emacs/.dir-locals.el;
  programs = {
    treefmt.enable = true;
    vale.enable = true;
  };

  ## CI
  services.garnix.enable = true;

  ## publishing
  services.flakehub.enable = true;
  services.github.enable = true;
}
