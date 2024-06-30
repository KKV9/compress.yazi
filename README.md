# archive.yazi

A Yazi plugin that compresses selected files to an archive.
This plugin is only available on Unix platforms at the moment since it relies on sh.

## Supported file types

| Extention     | Command       |
| ------------- | ------------- |
| .zip          | zip -r        |
| .7z           | 7z a          |
| .rar          | rar a         |
| .tar.gz       | tar czf       |
| .tar.bz2      | tar cjf       |
| .tar.xz       | tar cJf       |
| .tar          | tar cpf       |

## Install

```bash
git clone https://github.com/KKV9/archive.yazi.git ~/.config/yazi/plugins/archive.yazi
```

## Usage

- Add this to your `keymap.toml`:

```toml
[manager]
prepend_keymap = [
  { on = [
    "c",
    "a",
  ], run = "plugin archive", desc = "Create archive with selected files" },
]
```

 - Select files or folders to add, then press `c` `a` to display the prompt.
 - Type a name for a new or existing archive. 
 - The file extention must match one of the supported filetype extentions.
 - Tar overwrites an existing archive with newly selected files when overwriting.
 - Other archive formats add newly selected files to an existing archive when overwriting.
