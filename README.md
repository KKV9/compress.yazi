# archive.yazi

A Yazi plugin that compresses selected files to an archive.

## Supported file types

| Extention     | Command       |
| ------------- | ------------- |
| .zip          | zip -r        |
| .7z           | 7z a          |
| .rar          | rar a         |
| .tar          | tar rpf       |
| .tar.gz       | gzip          |
| .tar.bz2      | bzip2         |
| .tar.xz       | xz            |

## Install

```bash
# With git
git clone https://github.com/KKV9/archive.yazi.git ~/.config/yazi/plugins/archive.yazi
# Or with yazi plugin manager
ya pack -a KKV9/archive
```

## Usage

- Add this to your `keymap.toml`:

```toml
[[manager.prepend_keymap]]
on   = [ "c", "a" ]
run  = "plugin archive"
desc = "Archive selected files"
```

 - Select files or folders to add, then press `c` `a` to create a new archive.
 - Type a name for the new file. 
 - The file extention must match one of the supported filetype extentions.
 - The desired archive/compression command must be installed on your system.
