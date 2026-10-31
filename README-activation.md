# Complete activation backup for SSHRD_Script

Fork addition to [iPh0ne4s/SSHRD_Script](https://github.com/iPh0ne4s/SSHRD_Script).
Everything here is written for **macOS 12+ (system bash 3.2) and Linux**: no bash 4
features, no GNU-only flags, no host-side plist tool.

```
./sshrd.sh --backup-activation-full     # save the whole activation state
./sshrd.sh --restore-activation-full    # put it back
./sshrd.sh --activation-info            # show what is on the device right now
./sshrd.sh --contact-info               # phone/SIM ids + account e-mails (read-only)
```

Run `./sshrd.sh` with no arguments for the full command list; the fork prints its
banner on the usage screen and on every one of its commands:

```
 _____      _      _____   _____
|  ___|    / \    |_   _| |  ___|
| |_      / _ \     | |   | |__  
|  _|    / ___ \    | |   |  __| 
|_|     /_/   \_\   |_|   |_____|
  FATE's SSHRD fork  |  complete activation backup  |  activation.sh 1.0.0
```

### Banner on the phone

The ramdisk itself is patched too, so the boot console shows the fork right after
the stock credit line:

```
SSHRD_Script by Nathan (verygenericname)
Running server

 _____      _      _____   _____
|  ___|    / \    |_   _| |  ___|
| |_      / _ \     | |   | |__  
|  _|    / ___ \    | |   |  __| 
|_|     /_/   \_\   |_|   |_____|
    fate's fork of sshrd_script
```

`restored_external` is a Mach-O binary whose strings are packed with single NUL
separators (`...verygenericname\0hopefully done...`), so it cannot be edited in
place. Instead `sshtars/ssh.tar.gz` now carries:

* `usr/local/bin/dropbear.real` - the original daemon, byte-identical
* `usr/local/bin/dropbear` - a 12-line `/bin/sh` wrapper that prints the banner and
  then `exec`s `dropbear.real "$@"`

Nothing else in the payload changed. To drop the banner again, replace the wrapper
with `dropbear.real`, or restore the stock `sshtars/ssh.tar.gz`. Note the payload is
shared by all ramdisks, so you must rebuild a ramdisk (`./sshrd.sh <version>`) to
see the change; an already-built `sshramdisk/` keeps the old payload.

---

## Why the stock `--backup-activation` is not enough

Upstream saves three files:

| file | role |
|---|---|
| `activation_record.plist` / `pod_record.plist` | the activation ticket |
| `com.apple.commcenter.device_specific_nobackup.plist` | cellular activation data |
| `IC-Info.sisv` | one file of the FairPlay identity |

That set makes SpringBoard *report* an activated state on some iOS versions, but it
is not the state the device actually trusts, and it is not what Apple's servers see
when iServices authenticate. Missing:

| missing piece | where it lives | what breaks without it |
|---|---|---|
| `data_ark.plist` | `<mobileactivationd container>/Library/internal/` | `mobileactivationd` keeps its own record: activation state, the ticket it trusts, `ProductVersion`/`BuildVersion` it was activated on, activation randomness. Without it the on-disk record is often ignored, activation boot-rejects, or iServices refuse to register. |
| whole `FairPlay/` tree | `/private/var/mobile/Library/FairPlay` | device FairPlay identity (`IC-Info.sisv` is only one file). Needed for iMessage/FaceTime/App Store device auth. |
| `Lockdown/` | `/private/var/root/Library/Lockdown` | `pair_records` + lockdown plists; on old iOS a second `data_ark.plist`. |
| `com.apple.purplebuddy.plist` | `/private/var/mobile/Library/Preferences` | Setup Assistant state, so the device boots to the home screen instead of Hello. |

The `data_ark.plist` location is version-dependent, and that is why it is easy to
miss: on iOS 7/8 it is `/private/var/root/Library/Lockdown/data_ark.plist`; from
iOS 10 it moved into the `mobileactivationd` System data container, next to
`activation_records` (same `Library` folder, `internal/` subfolder). The script
detects the container by `MCMMetadataIdentifier` instead of guessing with `*`.

---

## What a full dump contains

```
userdata/activation_records/<serial>/full/
    mad-Library/                     copy of <mobileactivationd container>/Library
        internal/data_ark.plist      <- the piece upstream never saves
        activation_records/*         activation_record.plist / pod_record.plist
        Preferences/                 mobileactivationd preferences
    FairPlay/                        whole /private/var/mobile/Library/FairPlay
    Lockdown/                        whole /private/var/root/Library/Lockdown
    com.apple.commcenter.device_specific_nobackup.plist
    com.apple.purplebuddy.plist      (optional)
    legacy/                          iOS 7-9 locations, if present
    manifest.txt                     serial / iOS / ramdisk / container UUID
    SHA256SUMS
```

Compat copies are also written one level up (`<serial>/activation_record.plist`,
`data_ark.plist`, `IC-Info.sisv`, commcenter plist) so the stock
`./sshrd.sh --restore-activation` still works from a full dump.

The dump is a plain folder: copy it off the machine, it is your only way back after
an erase. It contains device-identifying material - treat it like a key file.

## What restore does

1. Checks the dump belongs to this serial (warns and asks if not).
2. Stages everything in `/mnt2/tmp/act_restore` first, so a failed upload never
   leaves the device half-written.
3. `data_ark.plist` -> `<container>/Library/internal/` (overwrites in place, so the
   existing owner/mode are kept).
4. records -> `<container>/Library/activation_records/` (`666`, `mobile:nobody`,
   same as upstream).
5. whole `FairPlay/` -> replaced; falls back to staging through
   `/private/var/mobile/Media/Downloads` on iOS 17+ where a direct rename into
   `mobile/Library` is refused.
6. commcenter plist (`600`, `_wireless:_wireless`), `pair_records` (`700`, `root:wheel`),
   `com.apple.purplebuddy.plist` (`600`, `mobile:mobile`).
7. `sync`, then verifies every path and prints what is missing.

Reboot afterwards with `./sshrd.sh reboot`.

---

## iServices: be realistic about "everything"

Keychain items are **not files**. iMessage/IDS keys, Apple ID tokens and the
iServices account material live in the keychain, wrapped by SEP class keys, and a
ramdisk cannot read or write them. So:

* this dump preserves the **activation identity** (ticket + data ark + FairPlay),
  which is what makes iMessage/FaceTime registration *succeed*;
* if the device was **erased**, you still sign in with your Apple ID once after the
  restore, and may need to toggle iMessage/FaceTime off and on;
* you cannot clone another device's iServices registration with file copies.

If the device is only updated/restored without erasing, the keychain survives and
iServices keep working with the restored activation files.

## App signing vs. activation ("verify my app")

These are three separate gates. A file dump only closes one of them:

| gate | what it actually needs | covered by this dump? |
|---|---|---|
| device activation | activation record + `data_ark.plist` + FairPlay (`IC-Info.sisv`, `SIC-Info.sisv`) | **yes** |
| developer certificate trust | keychain (`trustd`), wiped by an erase | no - it is keychain, not a file |
| app signature check at launch | profile + cert chain + Apple OCSP reachable, cert not revoked | no - network / Apple side |

So if the device shows *"Unable to Verify App"* when you open the app (iOS 14+ only),
activation files will not fix it: that is `trustd` asking Apple about the certificate
(network, correct date, certificate not revoked). **iOS 11 has no such online check** -
trust is granted offline, so a failure there means the certificate, the provisioning
profile or the signature itself is wrong. What this dump does fix is the *device* side:
a bogus activation state makes `installd`/`amfid` and iServices misbehave even when the
app is signed correctly.

On an iPhone 6s (A9, checkm8) the practical paths by iOS version:

| iOS | how a sideloaded app gets to run |
|---|---|
| **11.x** | No TrollStore (14.0+ only) and no online verify dialog. Valid cert + profile + Settings -> General -> Profiles & Device Management -> Trust; or, on a jailbroken 11.0-11.4.1 (unc0ver/Electra), **AppSync Unified** (supports iOS 5-18) to accept ad-hoc/fakesigned IPAs. |
| **12.x** | Same as 11; checkra1n/unc0ver + AppSync, or a real certificate. |
| **13.x** | No TrollStore. Developer certificate + offline Trust; trust it again after an erase. |
| **14.0 - 15.x** | TrollStore permasigns apps through the CoreTrust bug - no 7-day re-sign, no certificate to trust. Stock feature: `./sshrd.sh --install-trollstore`. |

A free Apple ID certificate that expired or was revoked looks exactly like "doesn't
verify" and has nothing to do with activation files.

If the failure is at install time (`0xE800003A`, ApplicationVerificationFailed), the
signature/profile is the problem; if it is at launch, it is trust (OCSP only on 14+);
if the device itself is stuck on "Activation Required", that is what
`--backup-activation-full` / `--restore-activation-full` are for.

## Owner contact details (read-only)

```bash
./sshrd.sh --contact-info     # both of the below
./sshrd.sh --owner-phone      # phone / SIM identifiers
./sshrd.sh --owner-email      # account e-mail addresses
```

`--owner-phone` reimplements what upstream `--backup-activation` used to print: it
pulls `wireless/Library/Preferences/com.apple.commcenter.plist` and the activation
record, then reads `PhoneNumber`, `SIMPhoneNumber`, `NetworkPhoneNumber`,
`CDMANetworkPhoneNumber`, `ICCID`, `IMSI`, `IMEI`, `MEID`, `CarrierName` with the
same host-side parser the dump uses.

`--owner-email` is a read-only `grep -a` for `something@something.tld` across the
files a signed-in device keeps account data in:

```
mobile/Library/Accounts/Accounts3.sqlite (+ -wal)
mobile/Library/Preferences/MobileMeAccounts.plist, com.apple.accountsd.plist,
    com.apple.identityservicesd.plist, com.apple.mobilemail.plist
wireless/Library/Preferences/com.apple.commcenter.plist
<mobileactivationd container>/Library/activation_records/*_record.plist
```

It prints unique addresses only - it is not a full-disk harvest, and anything behind
Data Protection simply will not appear. Nothing is written to the device. The dump
already contains all of these files, so this is only a convenience view.

> Use these on a device you own or are authorised to service.

## Version notes

* **iOS 10+**: full commands are the intended path (`--backup-activation-full`).
* **iOS 11 specifically** (iPhone 6s and friends): APFS data volume, so
  `/usr/bin/mount_filesystems` is required; use an **11.x** ramdisk (never a 16.x
  ramdisk on 11 - that is a bootloop). The activation layout is the iOS 10+
  container layout: `<container>/Library/internal/data_ark.plist` plus
  `<container>/Library/activation_records/`. The FairPlay folder on 11 is the
  `IC-Info.sisv` / `IC-Info.sidb` / `IC-Info.sidr` / `IC-Info.sids` / `IC-Info.sidt` /
  `IC-Info.sisb` set, which is why the whole directory is dumped instead of one file.
  iOS 11's `/usr/bin/plutil` **has no `-p`** (it silently returns nothing), so the
  script copies each plist to `/mnt2/tmp` and runs `plutil -convert xml1` instead;
  container detection then falls back to a `grep -a` on the container metadata.
  On 11.2.2 the data ark also refuses `-convert` and its keys are dash-prefixed
  (`-ActivationState`, `-BuildVersion`), so the plist is parsed on the Mac with
  `plutil -p` (python `plistlib` on Linux) and the dump prints the parsed `[ark]`
  keys back as proof that what was saved is readable.
* **iOS 7-9 (HFS)**: keep using `--backup-activation-hfs` / `--restore-activation-hfs`.
  The full commands still dump the legacy locations (`/var/mobile/Library/mad/...`,
  `/var/root/Library/Lockdown/...`) and restore them best-effort, but the HFS
  commands remain the supported route for those versions.
* **iOS 16.4+ ramdisks**: same caveats as upstream (iBoot64Patcher / `hdiutil`).

## Troubleshooting

**`IC-Info.sisv` is empty / undownloadable.** Known iOS behaviour, not a bug:
delete `/mnt2/mobile/Library/FairPlay/iTunes_Control/iTunes/IC-Info.sisv`, reboot to
the lock screen (this regenerates a downloadable one), boot the ramdisk again and
re-run the backup.

**`mobileactivationd container not found`.** The data volume is not mounted, or the
device has never booted far enough for the container to be created. Run
`/usr/bin/mount_filesystems` in the ramdisk (`--activation-info` will tell you), or
boot the device once to the Hello screen and retry.

**Restore says the container is missing.** Same cause - `mobileactivationd` creates
its container on first boot. Boot the device to setup once, then restore.

**scp fails on the container copy.** The script retries item by item
(`internal`, `activation_records`, `Preferences`) and reports what it got; check the
`[MISS]` lines at the end instead of trusting the exit code alone.

**Restored but still "Activation Required".** Check `--activation-info`: if
`data_ark.plist` is present but its `ProductVersion`/`BuildVersion` do not match the
installed iOS, the record belongs to another build. Re-dump from a device that is
activated on the same build.

---

## Applying this to your fork

The repo is ~140 MB (bundled binaries), so this folder ships the changed files
rather than a full copy.

```bash
# 1. fork + clone (GitHub "Fork" button, or:)
gh repo fork iPh0ne4s/SSHRD_Script --clone
cd SSHRD_Script

# 2. put the two files in the repo root
cp /path/to/sshrd-fork/activation.sh .
cp /path/to/sshrd-fork/sshrd.sh .

#    ...or apply the patch instead of replacing sshrd.sh:
# cp /path/to/sshrd-fork/activation.sh .
# git apply /path/to/sshrd-fork/0001-activation-full-backup.patch

# 3. commit on a branch and push
git checkout -b activation-full-backup
git add sshrd.sh activation.sh README-activation.md
git commit -m "activation: complete dump/restore incl. data_ark.plist and FairPlay"
git push -u origin activation-full-backup
```

Both scripts are syntax-checked with `ash -n` (POSIX parser) and dry-run against a
fake device tree (`backup` -> wipe -> `restore` -> verify) before shipping, but they
have not been run against real hardware - test the backup first, verify the dump,
then test the restore on a device you can afford to erase.

## Files in this folder

| file | purpose |
|---|---|
| `activation.sh` | new library: `act_backup_full`, `act_restore_full`, `act_info` |
| `sshrd.sh` | upstream script + three new commands and warnings on the legacy ones |
| `0001-activation-full-backup.patch` | unified diff of the `sshrd.sh` changes only |
| `README-activation.md` | this file |
