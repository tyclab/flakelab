# One source for local Starlark rules and administrator-enforced TOML rules.
[
  {
    pattern = [
      "git"
      [
        "commit"
        "push"
        "reset"
        "clean"
        "rebase"
        "merge"
        "-C"
        "-c"
      ]
    ];
    decision = "prompt";
  }
  {
    pattern = [
      "git"
      "branch"
      [
        "-d"
        "-D"
      ]
    ];
    decision = "prompt";
  }
  {
    pattern = [
      "git"
      "worktree"
      [
        "remove"
        "prune"
      ]
    ];
    decision = "prompt";
  }
  {
    pattern = [
      "git"
      "push"
      "--mirror"
    ];
    decision = "forbidden";
    justification = "Mirror pushes can delete unrelated remote refs; push the intended branch explicitly.";
    match = [ "git push --mirror origin" ];
    not_match = [ "git push origin main" ];
  }
  {
    pattern = [
      "git"
      "push"
      "origin"
      "--mirror"
    ];
    decision = "forbidden";
    justification = "Mirror pushes can delete unrelated remote refs; push the intended branch explicitly.";
  }
  {
    pattern = [
      [
        "glab"
        "gh"
      ]
      "api"
    ];
    decision = "prompt";
  }
  {
    pattern = [
      [
        "glab"
        "gh"
      ]
      [
        "mr"
        "pr"
      ]
      [
        "merge"
        "close"
      ]
    ];
    decision = "prompt";
  }
  {
    pattern = [
      "glab"
      "ci"
      [
        "run"
        "trigger"
      ]
    ];
    decision = "prompt";
  }
  {
    pattern = [
      "gh"
      "workflow"
      "run"
    ];
    decision = "prompt";
  }
  {
    pattern = [
      "flakelab"
      [
        "update"
        "update-all"
        "provision"
      ]
    ];
    decision = "prompt";
  }
  {
    pattern = [
      [
        "gitcleaner"
        "sudo"
        "ssh"
        "scp"
        "rsync"
        "rm"
        "sops"
        "bao"
        "bw"
      ]
    ];
    decision = "prompt";
  }
  {
    pattern = [
      [
        "tofu"
        "terraform"
      ]
      [
        "apply"
        "destroy"
        "import"
        "state"
      ]
    ];
    decision = "prompt";
  }
  {
    pattern = [
      "kubectl"
      [
        "apply"
        "delete"
        "exec"
        "patch"
        "replace"
        "scale"
      ]
    ];
    decision = "prompt";
  }
  {
    pattern = [
      "docker"
      [
        "exec"
        "run"
        "start"
        "stop"
        "restart"
        "kill"
        "rm"
        "prune"
        "system"
        "compose"
      ]
    ];
    decision = "prompt";
  }
  {
    pattern = [ "ansible-playbook" ];
    decision = "prompt";
  }
  {
    pattern = [
      "make"
      [
        "deploy"
        "tofu-apply"
        "bao-login"
        "edge-tunnel"
      ]
    ];
    decision = "prompt";
  }
  {
    pattern = [
      "systemctl"
      [
        "start"
        "stop"
        "restart"
        "reload"
        "enable"
        "disable"
        "mask"
      ]
    ];
    decision = "prompt";
  }
]
