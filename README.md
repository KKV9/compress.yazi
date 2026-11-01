# compress.yazi

Create archives from selected or hovered files in [Yazi](https://github.com/sxyazi/yazi).

## Installation

Requires Yazi 26.5.6 or newer and archive tools in your `PATH`.

```sh
ya pkg add greyxp1/compress
```

Or clone into your plugin directory:

```sh
git clone https://github.com/greyxp1/compress.yazi.git ~/.config/yazi/plugins/compress.yazi
```

On Windows, using CMD:

```cmd
git clone https://github.com/greyxp1/compress.yazi.git "%AppData%\yazi\config\plugins\compress.yazi"
```

On Windows, add the installed archive tools to your `PATH`, such as `C:\Program Files\7-Zip` and `C:\Program Files\WinRAR`.

## Supported formats

| Formats | Tools |
| --- | --- |
| `.zip`, `.cbz` | `zip`, 7-Zip or BSD tar |
| `.7z`, `.cb7` | 7-Zip |
| `.rar`, `.cbr` | `rar` |
| `.tar` | TAR |
| `.tar.gz`, `.tgz` | TAR with `gzip` or 7-Zip, or BSD tar |
| `.tar.xz`, `.txz` | TAR with `xz` or 7-Zip, or BSD tar |
| `.tar.bz2`, `.tbz`, `.tbz2` | TAR with `bzip2` or 7-Zip, or BSD tar |
| `.tar.zst`, `.tzst` | TAR with `zstd`, or BSD tar |
| `.tar.lz4`, `.tlz4` | TAR with `lz4`, or BSD tar |
| `.tar.lha` | TAR with `lha` |

7-Zip is detected as `7zz`, `7z` or `7za`, in that order. BSD tar compression depends on its built-in codecs.

Password-protected ZIP/CBZ archives use AES-256 and require 7-Zip and an AES-compatible reader.

## Usage

Add bindings to `keymap.toml`:

```toml
[[mgr.prepend_keymap]]
on = [ "c", "a" ]
run = "plugin compress"
desc = "Create archive"

[[mgr.prepend_keymap]]
on = [ "c", "i" ]
run = "plugin compress -i"
desc = "Configure archive options"
```

Select files, or leave the selection empty to use the hovered file. Run the plugin and enter an archive name. Leave the name blank to use the selected filename or current directory name. Existing archives are preserved by choosing a unique filename.

On Yazi 26.8+, press `w`, select `Compress …` and press `x` to cancel.

## Flags

| Argument | Effect |
| --- | --- |
| `-i` | Choose a format and options from a menu |
| `-p` | Require a password for ZIP, 7z or RAR |
| `-h` | Encrypt headers and require a password for 7z or RAR |
| `-l` | Choose a compression level |
| `-s` | Hide the success notification |
| `<extension>` | Set the default format, such as `7z` or `tar.gz` |

The default format is ZIP. Names without an extension use the default format. Passwords must be entered twice.

Combine flags and quote arguments containing spaces:

```toml
run = "plugin compress '-phl 7z'"
```

## Credits

Based on [KKV9/compress.yazi](https://github.com/KKV9/compress.yazi). See the [commit history](https://github.com/greyxp1/compress.yazi/commits/main) for contributors.
