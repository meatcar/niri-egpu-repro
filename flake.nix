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
    in
    {
      checks.${system}.repro = pkgs.testers.runNixOSTest {
        name = "niri-gpu-hot-remove";

        nodes.machine =
          { lib, ... }:
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
                command = lib.getExe' niri-vm "niri-session";
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
          count_outputs_cmd = (
            "NIRI_SOCKET=$(ls /run/user/1000/niri.wayland-*.sock | head -n1)"
            " niri msg outputs | grep -c '^Output'"
          )

          machine.wait_for_unit("multi-user.target")
          machine.wait_until_succeeds("ls /run/user/1000/niri.wayland-*.sock", timeout=120)

          # ensure both GPUs' outputs are present
          machine.wait_until_succeeds(f"[ $({count_outputs_cmd}) -eq 2 ]", timeout=120)
          num_outputs = int(machine.succeed(count_outputs_cmd).strip())

          # remove a GPU
          machine.succeed("echo 1 > /sys/bus/pci/devices/0000:00:${gpu2}.0/remove")

          machine.sleep(3)

          # Niri must resolve the removed device
          machine.fail("journalctl --no-pager | grep 'error creating DrmNode'")

          # The removed GPU's outputs must disappear
          machine.wait_until_succeeds(f"[ $({count_outputs_cmd}) -lt {num_outputs} ]", timeout=60)

          # Niri must still be alive on the remaining GPU
          machine.succeed(f"[ $({count_outputs_cmd}) -ge 1 ]")
        '';
      };
    };
}
