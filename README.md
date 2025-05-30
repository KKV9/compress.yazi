# ~~archive.yazi~~ compress.yazi

A Yazi plugin that compresses selected files to an archive. Supporting yazi v25.5.28.

## Supported file types

| Extension     | Unix Command  | Windows Command |
| ------------- | ------------- | --------------- |
| .zip          | zip -r        | 7z a -tzip      |
| .7z           | 7z a          | 7z a            |
| .tar          | tar rpf       | tar rpf         |
| .tar.gz       | gzip          | 7z a -tgzip     |
| .tar.xz       | xz            | 7z a -txz       |
| .tar.bz2      | bzip2         | 7z a -tbzip2    |
| .tar.zst      | zstd          | zstd            |


**NOTE:** Windows users are required to install 7-Zip and add 7z.exe to the `path` environment variable, only tar archives will be available otherwise. Alternatively, install nanazip.


## Install

```bash
# For Unix platforms
git clone https://github.com/KKV9/compress.yazi.git ~/.config/yazi/plugins/compress.yazi

## For Windows cmd - Don't use powershell!
git clone https://github.com/KKV9/compress.yazi.git %AppData%\yazi\config\plugins\compress.yazi

# Or with yazi plugin manager
ya pkg add KKV9/compress
```

- Add this to your `keymap.toml`:

```toml
[[mgr.prepend_keymap]]
on   = [ "c", "a", "a" ]
run  = "plugin compress"
desc = "Archive selected files"
[[mgr.prepend_keymap]]
on   = [ "c", "a", "p" ]
run  = "plugin compress -p"
desc = "Archive selected files (password)"
[[mgr.prepend_keymap]]
on   = [ "c", "a", "h" ]
run  = "plugin compress -ph"
desc = "Archive selected files (password+header)"
[[mgr.prepend_keymap]]
on   = [ "c", "a", "l" ]
run  = "plugin compress -l"
desc = "Archive selected files (compression level)"
[[mgr.prepend_keymap]]
on   = [ "c", "a", "u" ]
run  = "plugin compress -phl"
desc = "Archive selected files (password+header+level)"
```

## Usage

 - Select files or folders to add, then press `c` `a` to create a new archive.
 - Press `a` again for a standard archive. 
 -  OR Press `p` for a password protected archive (7z and zip only). 
 -  OR Press `h` to also encrypt the header (7zip only)
 -  OR Press `l` to select level of compression (all algorithims except zstd).
 -  OR Press `u` to get everything.
 - Type a name for the new file. 
 - Enter the password if selected.
 - Enter the compression level (0-9) if selected. 0 works for zip and 7z only.
 - Overwrite prompt will appear if filename matches another file. Type y to overwrite or type n or press enter to cancel.
 - The file extension must match one of the supported filetype extensions.
 - The desired archive/compression command must be installed on your system.

## Flags

 - Combine flags for more functionality.
 - -p allows you to set a password (7z and zip only)
 - -h allows you to encrypt header (7z only)
 - -l allows you to set a compression level (0 - 9) -- 0 = Store, 9 = Best compression

**NOTE:** Compression level currently works for all compression algorithims except zstd.
