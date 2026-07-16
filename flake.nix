{
  description = "niri eGPU hot-remove repro";

  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";
  inputs.niri = {
    url = "github:niri-wm/niri";
    inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    { nixpkgs, niri, ... }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};

      # PCI slots for the two GPUs
      gpu1 = "1e";
      gpu2 = "1f";

      niri-vm = niri.packages.${system}.default.overrideAttrs (old: {
        patches = (old.patches or [ ]) ++ [
          ./allow-software-egl.patch # allows Niri to render in VM
          # ./fix.patch
        ];
        # speed up build
        doCheck = false;
        cargoBuildType = "debug";
      });

      niri-session-traced = pkgs.writeShellScript "niri-session-traced" ''
        export RUST_LOG=niri=trace
        exec ${pkgs.lib.getExe' niri-vm "niri-session"}
      '';
    in
    {
      checks.${system}.repro = pkgs.testers.runNixOSTest {
        name = "niri-gpu-hot-remove";

        nodes.machine =
          { ... }:
          {
            programs.niri.enable = true;
            programs.niri.package = niri-vm;

            users.users.alice = {
              isNormalUser = true;
              uid = 1000; # testScript hardcodes /run/user/1000
            };

            # auto-start a session to get Niri to process the hot-remove event.
            services.greetd = {
              enable = true;
              settings.default_session = {
                command = niri-session-traced;
                user = "alice";
              };
            };

            # Two virtio GPUs, the second one gets hot-removed mid-test.
            virtualisation.qemu.options = [
              "-vga none"
              "-device virtio-gpu-pci,addr=0x${gpu1}"
              "-device virtio-gpu-pci,addr=0x${gpu2}"
            ];
          };

        testScript = ''
          def dump(title, cmd):
              status, out = machine.execute(cmd)
              print(f"=== {title} (exit {status}) ===\n{out}")

          def cmd(socket, cmd):
              return f"NIRI_SOCKET={socket} {cmd}"

          count_outputs_cmd = "niri msg outputs | grep -c '^Output'"

          socket = None
          try:
              machine.wait_for_unit("multi-user.target")

              # resolve niri's IPC socket
              machine.wait_until_succeeds("ls /run/user/1000/niri.wayland-*.sock")
              socket = machine.succeed("ls /run/user/1000/niri.wayland-*.sock").strip()

              # wait until both GPUs' outputs are present
              machine.wait_until_succeeds(cmd(socket, f"[ $({count_outputs_cmd}) -eq 2 ]"))

              # capture drm hotplug events around the removal
              machine.succeed(
                  "udevadm monitor --kernel --udev --property --subsystem-match=drm"
                  " > /tmp/udev.log 2>&1 &"
              )

              # remove a GPU
              machine.succeed("echo 1 > /sys/bus/pci/devices/0000:00:${gpu2}.0/remove")

              machine.sleep(3)

              # Niri must resolve the removed device
              machine.fail("journalctl --no-pager | grep 'error creating DrmNode'")

              # The removed GPU's outputs must disappear
              machine.wait_until_succeeds(cmd(socket, f"[ $({count_outputs_cmd}) -eq 1 ]"), timeout=60)
          finally:
              # dumps go to stdout
              dump("outputs after removal", cmd(socket, "niri msg outputs"))
              dump("drm udev events", "pkill udevadm; cat /tmp/udev.log")
              dump("niri log (RUST_LOG=niri=trace)", "journalctl --no-pager -t niri")
        '';
      };
    };
}
