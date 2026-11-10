# NixOS guest for the disposable microvm.nix verification lane.
#
# One boot = one full xsprof verification run: the guest installs the
# Nix-packaged xsprof binary, runs nix/microvm/guest-verify.sh as a root
# oneshot, prints strict markers on the qemu serial console, and reboots the
# disposable VM. The guest has no networking, no display server, and never
# writes scheduler/memory policy; the only writes are temporary files under the
# verify script's $TMPDIR (host_mutation stays false in every wire record).
#
# `variant` selects the qemu CPU policy used by the generated runner:
#   kvm - microvm.cpu = null: the runner passes -enable-kvm, so the lane needs
#         a readable/writable /dev/kvm (microvm machine type, KVM-tuned).
#   tcg - microvm.cpu = "max": the runner omits -enable-kvm and the machine's
#         accel="kvm:tcg" makes qemu fall back to TCG on hosts without
#         /dev/kvm (containers, CI). The standard q35 machine is used because
#         the microvm machine type wedges this kernel in early KASLR under TCG;
#         q35 boots the same guest under TCG (verified in this lane).
{ variant
, version
, xsprof
, scenario
}:
{ lib, pkgs, ... }:
let
  isTcg = variant == "tcg";
in
{
  system.stateVersion = lib.trivial.release;
  networking.hostName = "xsprof-verify";
  networking.useDHCP = false;

  # Headless CPU-only smoke: keep the guest closure small and quiet. The lane
  # is driven entirely by the serial console, so systemd colors and the serial
  # getty (a human login is never needed) are disabled for clean evidence.
  documentation.enable = false;
  documentation.nixos.enable = false;
  boot.kernelParams = [ "systemd.log_color=0" ];
  systemd.services."serial-getty@ttyS0".enable = false;
  systemd.services."serial-getty@ttyAMA0".enable = false;

  microvm = {
    hypervisor = "qemu";
    vcpu = 2;
    # microvm.nix warns that qemu hangs with exactly 2048 MiB (issue #171).
    mem = 1024;
    graphics.enable = false;
    # serialConsole is the default; the markers below are read from it.
    qemu.serialConsole = true;
    # KVM variant keeps cpu = null so the runner adds -enable-kvm. The TCG
    # variant sets an explicit emulated CPU so the runner does not, and qemu's
    # accel="kvm:tcg" falls back to TCG when /dev/kvm is unavailable.
    cpu = if isTcg then "max" else null;
  } // lib.optionalAttrs isTcg {
    # q35 exposes a conventional ISA/PCIe machine to the guest. The microvm
    # machine type works on KVM hosts, but under qemu TCG it wedges this kernel
    # after "Poking KASLR" before the real console comes up; q35 boots the same
    # NixOS closure under TCG in well under a minute.
    qemu.machine = "q35";
  };

  systemd.services.xsprof-vm-verify = {
    description = "xsprof disposable microVM verification (read-only)";
    wantedBy = [ "multi-user.target" ];
    after = [ "multi-user.target" ];
    # Tools for the script; the script does not use `set -e`, so it reports
    # every failure itself instead of aborting silently.
    path = [
      xsprof
      pkgs.python3
      pkgs.coreutils
      pkgs.gnugrep
      pkgs.systemd
    ];
    script = builtins.readFile ./guest-verify.sh;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      # The markers must reach the qemu serial console: the host-side harness
      # parses that console log, not the guest journal.
      StandardOutput = "journal+console";
      StandardError = "journal+console";
      Environment = [
        "XSPROF_EXPECTED_VERSION=${version}"
        "XSPROF_FIXTURES_DIR=${xsprof}/share/xsprof/fixtures"
        "XSPROF_SCENARIO=${scenario}"
        "XSPROF_VARIANT=${variant}"
      ];
    };
  };
}
