package Proxmox::Install::SurfaceEFI;

use strict;
use warnings;

use Proxmox::Sys::Command qw(syscmd);
use Proxmox::Sys::File qw(file_read_all);

my $no_nvram = 0;
my $mounted = 0;

sub no_nvram { return $no_nvram; }

sub mount_efivars {
    my ($targetdir, $run_env) = @_;
    $no_nvram = 0;
    $mounted = 0;
    return if $run_env->{boot_type} ne 'efi';

    my $mountpoint = "$targetdir/sys/firmware/efi/efivars";
    if (syscmd(['mount', '-n', '-t', 'efivarfs', 'efivarfs', $mountpoint]) == 0) {
        $mounted = 1;
        return;
    }

    # This Surface boots via UEFI, but its current kernel does not register
    # the Qualcomm variable backend. Keep UEFI/ESP installation enabled and
    # use the standard fallback loader without writing Boot#### variables.
    # A failed efivarfs mount on other machines remains an installation error.
    my $compatible = eval { file_read_all('/sys/firmware/devicetree/base/compatible') } // '';
    if ($run_env->{arch} eq 'arm64'
        && grep { $_ eq 'microsoft,surface-laptop-13-2095' } split(/\0/, $compatible)) {
        $no_nvram = 1;
        warn "Surface: EFI variables unavailable; installing the EFI fallback loader without NVRAM updates\n";
        return;
    }

    die "unable to mount efivarfs on $mountpoint (see mount error above)\n";
}

sub grub_options {
    return $no_nvram ? '--no-nvram --force-extra-removable' : '';
}

sub grub_debconfig {
    my ($package) = @_;
    return $no_nvram ? "$package grub2/update_nvram boolean false\n" : '';
}

sub unmount_efivars {
    my ($targetdir) = @_;
    syscmd(['umount', "$targetdir/sys/firmware/efi/efivars"]) if $mounted;
    $mounted = 0;
}

1;
