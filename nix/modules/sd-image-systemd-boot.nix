# Flashable SD card image whose boot chain is U-Boot -> systemd-boot.
#
# The generic builder (installer/sd-card/sd-image.nix) only knows how to
# populate a FIRMWARE partition; the aarch64-specific builder additionally
# hardcodes U-Boot + extlinux. We want systemd-boot, so we assemble the FAT
# "FIRMWARE" partition ourselves:
#   * the raspberrypi firmware files, U-Boot, config.txt and the per-board
#     .dtb files (as the official sd-image-aarch64.nix does), plus
#   * a systemd-boot ESP on the same partition:
#       EFI/BOOT/BOOTAA64.EFI               <- the systemd-boot binary U-Boot chainloads
#       EFI/nixos/{kernel,initrd,*.dtb}     <- the single NixOS entry
#       loader/{loader.conf, entries/nixos.conf}
#
# On first boot there is exactly one systemd-boot menu entry. After the
# machine runs `nixos-rebuild switch`, installBootLoader takes over and
# manages generations on this ESP like on any other systemd-boot NixOS.
{
  config,
  lib,
  pkgs,
  ...
}:
{
  boot.loader.grub.enable = lib.mkDefault false;
  boot.loader.generic-extlinux-compatible.enable = lib.mkDefault false;
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = lib.mkDefault false; # no EFI NVRAM on RPi U-Boot
  boot.loader.efi.efiSysMountPoint = "/boot/firmware";

  boot.consoleLogLevel = lib.mkDefault 7;

  # Serial consoles: ttyS0 (Tegra), ttyAMA0 (Raspberry Pi UART / QEMU virt).
  # Plain (not mkDefault): base.nix already sets kernelParams, and the two get
  # merged, exactly like the official sd-image-aarch64.nix does it.
  boot.kernelParams = [
    "console=ttyS0,115200n8"
    "console=ttyAMA0,115200n8"
    "console=tty0"
  ];

  # Kernel + initrd end up on the ESP, give the FAT plenty of room.
  sdImage.firmwareSize = 128;

  # No extlinux: keep the root /boot mount-point (firmware is on the ESP at
  # /boot/firmware) and pass the kernel command line through systemd-boot.
  sdImage.populateRootCommands = ''
    mkdir -p ./files/boot
  '';

  sdImage.populateFirmwareCommands =
    let
      # Mirrors the official aarch64 sd-image config.txt (see
      # installer/sd-card/sd-image-aarch64.nix in the pinned nixpkgs).
      configTxt = pkgs.writeText "config.txt" ''
        kernel=u-boot.bin

        # Boot in 64-bit mode.
        arm_64bit=1

        # U-Boot needs this to work, regardless of whether UART is actually used or not.
        enable_uart=1

        # Prevent the firmware from smashing the framebuffer setup done by the mainline kernel
        # when attempting to show low-voltage or overtemperature warnings.
        avoid_warnings=1

        [pi3]
        # Otherwise the serial output will be garbled.
        core_freq=250

        [pi4]
        enable_gic=1
        armstub=armstub8-gic.bin

        # Otherwise the resolution will be weird in most cases, compared to
        # what the pi3 firmware does by default.
        disable_overscan=1

        # Supported in newer board revisions
        arm_boost=1

        [cm4]
        # Enable host mode on the 2711 built-in XHCI USB controller.
        otg_mode=1

        [cm5]
        dtoverlay=dwc2,dr_mode=host

        [pi5]
        # On some revisions of the RPi5, U-Boot picks up ghost inputs from the
        # uart, interrupting the boot process.
        enable_uart=0
      '';
      # hardware/deviceTree.nix in nixpkgs - kernel dtb derivation.
      dtbDir = config.hardware.deviceTree.package;
      dtbName = builtins.baseNameOf config.hardware.deviceTree.name;
    in
    ''
      # --- raspberrypi firmware + U-Boot + per-board dtbs (official set) ---
      (cd ${pkgs.raspberrypifw}/share/raspberrypi/boot && cp bootcode.bin fixup*.dat start*.elf $NIX_BUILD_TOP/firmware/)
      cp ${pkgs.ubootRaspberryPiAarch64}/u-boot.bin firmware/u-boot.bin
      cp ${configTxt} firmware/config.txt

      cp ${pkgs.raspberrypifw}/share/raspberrypi/boot/bcm2710-rpi-2-b.dtb firmware/
      cp ${pkgs.raspberrypifw}/share/raspberrypi/boot/bcm2710-rpi-3-b.dtb firmware/
      cp ${pkgs.raspberrypifw}/share/raspberrypi/boot/bcm2710-rpi-3-b-plus.dtb firmware/
      cp ${pkgs.raspberrypifw}/share/raspberrypi/boot/bcm2710-rpi-cm3.dtb firmware/
      cp ${pkgs.raspberrypifw}/share/raspberrypi/boot/bcm2710-rpi-zero-2.dtb firmware/
      cp ${pkgs.raspberrypifw}/share/raspberrypi/boot/bcm2710-rpi-zero-2-w.dtb firmware/
      cp ${pkgs.raspberrypi-armstubs}/armstub8-gic.bin firmware/armstub8-gic.bin
      cp ${pkgs.raspberrypifw}/share/raspberrypi/boot/bcm2711-rpi-4-b.dtb firmware/
      cp ${pkgs.raspberrypifw}/share/raspberrypi/boot/bcm2711-rpi-400.dtb firmware/
      cp ${pkgs.raspberrypifw}/share/raspberrypi/boot/bcm2711-rpi-cm4.dtb firmware/
      cp ${pkgs.raspberrypifw}/share/raspberrypi/boot/bcm2711-rpi-cm4s.dtb firmware/
      cp ${pkgs.raspberrypifw}/share/raspberrypi/boot/bcm2712-d-rpi-5-b.dtb firmware/
      cp ${pkgs.raspberrypifw}/share/raspberrypi/boot/bcm2712-rpi-5-b.dtb firmware/
      cp ${pkgs.raspberrypifw}/share/raspberrypi/boot/bcm2712-rpi-500.dtb firmware/
      cp ${pkgs.raspberrypifw}/share/raspberrypi/boot/bcm2712-rpi-cm5-cm4io.dtb firmware/
      cp ${pkgs.raspberrypifw}/share/raspberrypi/boot/bcm2712-rpi-cm5-cm5io.dtb firmware/
      cp ${pkgs.raspberrypifw}/share/raspberrypi/boot/bcm2712-rpi-cm5l-cm4io.dtb firmware/
      cp ${pkgs.raspberrypifw}/share/raspberrypi/boot/bcm2712-rpi-cm5l-cm5io.dtb firmware/

      # --- systemd-boot ESP on the same FAT partition ----------------------
      mkdir -p firmware/EFI/BOOT firmware/EFI/nixos firmware/loader/entries
      cp ${pkgs.systemd}/lib/systemd/boot/efi/systemd-bootaa64.efi firmware/EFI/BOOT/BOOTAA64.EFI
      cp ${config.system.build.toplevel}/kernel firmware/EFI/nixos/kernel
      cp ${config.system.build.toplevel}/initrd firmware/EFI/nixos/initrd
      cp ${dtbDir}/${config.hardware.deviceTree.name} firmware/EFI/nixos/${dtbName}

      cat > firmware/loader/loader.conf <<EOF
      default nixos
      timeout 3
      console-mode max
      EOF
      cat > firmware/loader/entries/nixos.conf <<EOF
      title NixOS
      sort-key nixos
      linux /EFI/nixos/kernel
      initrd /EFI/nixos/initrd
      devicetree /EFI/nixos/${dtbName}
      options ${lib.concatStringsSep " " config.boot.kernelParams} init=${config.system.build.toplevel}/init
      EOF
    '';
}