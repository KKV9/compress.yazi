<h1 align="center">🗜️ compress.yazi</h1>
<p align="center">
  <b>A blazing fast, flexible archive plugin for <a href="https://github.com/sxyazi/yazi">Yazi</a></b><br>
  <i>Effortlessly compress your files and folders with style!</i>
</p>

---

## 🚀 Features

- **Multi-format support:** zip, 7z, rar, tar, tar.gz, tar.xz, tar.bz2, tar.zst, tar.lz4, tar.lha
- **Cross-platform:** Works on Unix & Windows (with 7-Zip)
- **Maximum Compatibility:** Uses native Unix & Windows tools (tar, zip, gz, xz)
- **Password protection:** Secure your archives (zip/7z/rar)
- **Header encryption:** Hide file lists (7z/rar)
- **Compression level:** Choose your balance of speed vs. size
- **Overwrite safety:** Never lose files by accident
- **Seamless Yazi integration:** Fast, native-like UX

---

## 📦 Supported File Types

| Extension     | Default Command | 7z Command     | Bsdtar Command (Win10+ & Unix) |
| ------------- | --------------- | -------------- | ------------------------------ |
| `.zip`        | `zip -r`        | `7z a -tzip`   | `tar -caf`(No password)        |
| `.7z`         | `7z a`          |                |                                |
| `.rar`        | `rar a`         |                |                                |
| `.tar`        | `tar rpf`       |                |                                |
| `.tar.gz`     | `gzip`          | `7z a -tgzip`  | `tar -czf`                     |
| `.tar.xz`     | `xz`            | `7z a -txz`    | `tar -cJf`                     |
| `.tar.bz2`    | `bzip2`         | `7z a -tbzip2` | `tar -cjf`                     |
| `.tar.zst`    | `zstd`          |                | `tar --zstd -cf`               |
| `.tar.lz4`    | `lz4`           |                |                                |
| `.tar.lha`    | `lha`           |                |                                |

---

## ⚡️ Installation

```bash
# Unix
git clone https://github.com/KKV9/compress.yazi.git ~/.config/yazi/plugins/compress.yazi

# Windows (CMD, not PowerShell!)
git clone https://github.com/KKV9/compress.yazi.git %AppData%\yazi\config\plugins\compress.yazi

# Or with yazi plugin manager
ya pkg add KKV9/compress
```

> **Extras:**  
> On Windows, install [7-Zip](https://www.7-zip.org/) and add `C:\Program Files\7-Zip` to your `PATH`.  
> Or install [Nanazip](https://github.com/M2Team/NanaZip).
> This will allow you to compress 7z and create password protected zip archives.  
> install [WinRAR](https://www.win-rar.com/download.html) and add `C:\Program Files\WinRAR` to your `PATH`
> This will allow you to compress rar.
> lha, lz4, gzip etc. can also be installed and used on windows.

---

## 🎹 Keymap Example

Add this to your `keymap.toml`:

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

---

## 🛠️ Usage

1. **Select files/folders** in Yazi.
2. Press <kbd>c</kbd> <kbd>a</kbd> to open the archive dialog.
3. Choose:
   - <kbd>a</kbd> for a standard archive
   - <kbd>p</kbd> for password protection (zip/7z/rar)
   - <kbd>h</kbd> to encrypt header (7z/rar)
   - <kbd>l</kbd> to set compression level (all compression algorithims)
   - <kbd>u</kbd> for all options
4. **Type a name** for your archive (must match a supported extension).
5. **Enter password** and/or **compression level** if prompted.
6. **Confirm overwrite** if a file already exists.
7. Enjoy your shiny new archive!

---

## 🏳️‍🌈 Flags

- Combine flags for more power!
- `-p` Password protect (zip/7z/rar)
- `-h` Encrypt header (7z/rar)
- `-l` Set compression level (all compression algorithims)

---

## 💡 Tips

- The file extension **must** match a supported type.
- The required compression tool **must** be installed and in your `PATH` (7zip/rar etc.).
- Overwrite prompt: Type `y` to overwrite, `n` or <kbd>Enter</kbd> to cancel.

---

## 📣 Credits

Made with ❤️ for [Yazi](https://github.com/sxyazi/yazi) by [KKV9](https://github.com/KKV9).

---
