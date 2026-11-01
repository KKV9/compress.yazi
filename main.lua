--- @since 26.5.6

local is_windows = ya.target_family() == "windows"

local archive_aliases = {
	cbz = "zip",
	cb7 = "7z",
	cbr = "rar",
	tgz = "tar.gz",
	txz = "tar.xz",
	tbz = "tar.bz2",
	tbz2 = "tar.bz2",
	tzst = "tar.zst",
	tlz4 = "tar.lz4",
}

local function canonical_archive_name(name)
	return (name:gsub("%.([^%.]+)$", function(ext)
		return "." .. (archive_aliases[ext] or ext)
	end))
end

local function extension_pattern(ext)
	ext = archive_aliases[ext] or ext
	return "%." .. ext:gsub("%.", "%%.") .. "$"
end

local function is_valid_filename(name)
	name = name:match("^%s*(.-)%s*$")
	if name == "" then
		return false
	end
	if is_windows then
		if name:find('[<>:"/\\|%?%*]') then
			return false
		end
	else
		if name:find("/") or name:find("%z") then
			return false
		end
	end
	return true
end

local function notify(message, level)
	ya.notify({
		title = "Archive",
		content = message,
		level = level,
		timeout = 5,
	})
end

local command_cache = {}
local function is_command_available(cmd, bsdtar)
	local key = cmd .. (bsdtar and ":bsdtar:" .. tostring(bsdtar) or "")
	if command_cache[key] == nil then
		if bsdtar then
			local version_key = cmd .. ":version"
			if command_cache[version_key] == nil then
				local output = Command(cmd):arg("--version"):output()
				command_cache[version_key] = output and output.status.success and output.stdout or ""
			end
			local version = command_cache[version_key]
			command_cache[key] = version:find("bsdtar", 1, true) ~= nil
				and (bsdtar == true or version:find(bsdtar, 1, true) ~= nil)
		else
			local status = Command(cmd):arg("--help"):status()
			command_cache[key] = status ~= nil and status.code ~= nil
		end
	end
	return command_cache[key]
end

local function find_command_name(cmd_list, bsdtar)
	for _, cmd in ipairs(type(cmd_list) == "table" and cmd_list or { cmd_list }) do
		if is_command_available(cmd, bsdtar) then
			return cmd
		end
	end
end

local function combine_url(path, file)
	local path_url = Url(path)
	local file_url = Url(file)
	return tostring(path_url:join(file_url))
end

-- Archive from one shared directory so equal basenames keep distinct paths.
local selected_or_hovered = ya.sync(function()
	local tab = cx.active
	local urls = {}
	local names = {}

	for _, u in pairs(tab.selected) do
		urls[#urls + 1] = u.url
		names[#names + 1] = tostring(u.name)
	end

	if #urls == 0 and tab.current.hovered then
		urls[1] = tab.current.hovered.url
		names[1] = tostring(tab.current.hovered.name)
	end

	local root = tab.current.cwd
	for _, url in ipairs(urls) do
		while root and not url.parent:starts_with(root) do
			root = root.parent
		end
	end

	if not root or #urls == 0 then
		return nil
	end

	local filenames = {}
	for _, url in ipairs(urls) do
		filenames[#filenames + 1] = "." .. (is_windows and "\\" or "/") .. tostring(url:strip_prefix(root))
	end

	return tostring(root), filenames, names, tostring(tab.current.cwd)
end)

local function cleanup_temp_dir(temp_dir)
	local status, err = fs.remove("dir_all", Url(temp_dir))
	if not status then
		notify(
			string.format("Failed to clean up temporary directory %s, error: %s", ya.quote(temp_dir), tostring(err)),
			"error"
		)
		return false
	end
	return true
end

local function create_temp_dir(root, filenames, output_dir)
	local source, last_err = Url(root)
	-- Staging inside a selected ancestor would add our own files to the archive.
	for _, parent in ipairs({ output_dir, root, tostring(rt.preview.cache_dir) }) do
		local base, inside = Url(parent), false
		for _, filename in ipairs(filenames) do
			if base:starts_with(source:join(filename)) then
				inside = true
				break
			end
		end
		if not inside then
			local dir, err = fs.unique("dir", base:join(".tmp_compress"))
			if dir then
				return tostring(dir)
			elseif parent == output_dir then
				return nil, err
			end
			last_err = err
		end
	end
	return nil, last_err or "Temporary storage must be outside the selected files"
end

local function run_command(command, scope)
	if scope and scope:cancelled() then
		return nil, "Cancelled"
	end
	local child, err = command:stdout(Command.PIPED):stderr(Command.PIPED):spawn()
	if not child then
		return nil, tostring(err)
	end
	local diagnostic, closed = "", false
	while true do
		if scope and scope:cancelled() then
			child:start_kill()
			child:wait()
			return nil, "Cancelled"
		end
		if not closed then
			local line, event = child:read_line_with({ timeout = 100 })
			if event == 0 or event == 1 then
				diagnostic = (diagnostic .. line):sub(-8192)
			elseif event == 2 then
				closed = true
			end
		else
			local status, wait_err = child:try_wait()
			if status then
				local reason = status.code and "exit code " .. status.code or "Process terminated without an exit code"
				return status, diagnostic ~= "" and diagnostic or reason
			elseif wait_err then
				return nil, tostring(wait_err)
			end
			ya.sleep(0.1)
		end
	end
end

local function add_compression_level(target_args, level_arg, level_value)
	if type(level_arg) == "table" then
		for i = 1, #level_arg - 1 do
			table.insert(target_args, i, level_arg[i])
		end
		table.insert(target_args, #level_arg, level_arg[#level_arg] .. level_value)
	else
		-- LHA requires its command before compression switches.
		table.insert(target_args, level_arg == "-o" and 2 or 1, level_arg .. level_value)
	end
end

local function get_password_args(archive_cmd, encrypted, header_arg)
	local output_password, event = ya.input({
		title = "Enter password:",
		obscure = true,
		pos = { "top-center", y = 3, w = 40 },
	})
	if event ~= 1 or output_password == "" then
		notify("Password required, operation aborted", "error")
		return nil
	end
	local output_confirm_password, event = ya.input({
		title = "Confirm password:",
		obscure = true,
		pos = { "top-center", y = 3, w = 40 },
	})
	if event ~= 1 or output_confirm_password == "" then
		notify("Password confirmation required, operation aborted", "error")
		return nil
	end
	if output_password ~= output_confirm_password then
		notify("Passwords do not match", "error")
		return nil
	end
	if archive_cmd == "rar" and encrypted then
		return { header_arg .. output_password }
	end
	return { "-p" .. output_password }
end

-- -spd keeps literal filenames from expanding to unselected files.
local sevenzip_commands = { "7zz", "7z", "7za" }
local tar_commands = { "tar", "bsdtar" }

local archive_commands = {
	["%.zip$"] = {
		{ command = "zip", args = { "-r" }, level_arg = "-", level_min = 0, level_max = 9 },
		{
			command = sevenzip_commands,
			args = { "a", "-tzip", "-spd" },
			level_arg = "-mx=",
			level_min = 0,
			level_max = 9,
			passwordable = true,
			password_args = { "-mem=AES256" },
		},
		{
			command = { "bsdtar", "tar" },
			bsdtar = true,
			args = { "--format=zip", "-cf" },
			level_arg = { "--options", "zip:compression-level=" },
			level_min = 0,
			level_max = 9,
		},
	},
	["%.7z$"] = {
		{
			command = sevenzip_commands,
			args = { "a", "-t7z", "-spd" },
			level_arg = "-mx=",
			level_min = 0,
			level_max = 9,
			header_arg = "-mhe=on",
			passwordable = true,
		},
	},
	["%.rar$"] = {
		{
			command = "rar",
			args = { "a" },
			level_arg = "-m",
			level_min = 0,
			level_max = 5,
			header_arg = "-hp",
			passwordable = true,
		},
	},
	["%.tar$"] = { { command = tar_commands, args = { "-cf" } } },
}

local compressors = {
	gz = { command = "gzip", level_max = 9, sevenzip = "gzip", bsdtar = "-z", option = "gzip", library = "zlib" },
	xz = { command = "xz", level_max = 9, sevenzip = "xz", bsdtar = "-J", option = "xz", library = "liblzma" },
	bz2 = { command = "bzip2", level_max = 9, sevenzip = "bzip2", bsdtar = "-j", option = "bzip2", library = "bz2lib" },
	zst = {
		command = "zstd",
		args = { "--ultra" },
		level_max = 22,
		bsdtar = "--zstd",
		option = "zstd",
		library = "libzstd",
	},
	lz4 = {
		command = "lz4",
		level_max = 12,
		bsdtar = "--lz4",
		option = "lz4",
		library = "liblz4",
		bsdtar_level_max = 9,
	},
	lha = { command = "lha", args = { "a" }, level_arg = "-o", level_min = 5, level_max = 7 },
}

for ext, compressor in pairs(compressors) do
	local candidates = {
		{
			command = tar_commands,
			args = { "-cf" },
			compress = compressor.command,
			compress_args = compressor.args,
			level_arg = compressor.level_arg or "-",
			level_min = compressor.level_min or 1,
			level_max = compressor.level_max,
		},
	}
	if compressor.sevenzip then
		candidates[#candidates + 1] = {
			command = tar_commands,
			args = { "-cf" },
			compress = sevenzip_commands,
			compress_args = { "a", "-t" .. compressor.sevenzip, "-spd" },
			level_arg = "-mx=",
			level_min = 1,
			level_max = 9,
		}
	end
	if compressor.bsdtar then
		candidates[#candidates + 1] = {
			command = { "bsdtar", "tar" },
			bsdtar = compressor.library,
			args = { compressor.bsdtar, "-cf" },
			level_arg = { "--options", compressor.option .. ":compression-level=" },
			level_min = 1,
			level_max = compressor.bsdtar_level_max or compressor.level_max,
		}
	end
	archive_commands[extension_pattern("tar." .. ext)] = candidates
end

local function find_archive_command(output_name, password_required, headers_required)
	output_name = canonical_archive_name(output_name)
	for pattern, cmd_list in pairs(archive_commands) do
		if output_name:match(pattern) then
			for _, cmd in ipairs(cmd_list) do
				local cmd_name = find_command_name(cmd.command, cmd.bsdtar)
				if
					cmd_name
					and (not password_required or cmd.passwordable)
					and (not headers_required or cmd.header_arg)
				then
					local compress = cmd.compress and find_command_name(cmd.compress)
					if not cmd.compress or compress then
						return {
							cmd = cmd_name,
							args = { table.unpack(cmd.args) },
							compress = compress or "",
							level_arg = cmd.level_arg or "",
							level_min = cmd.level_min,
							level_max = cmd.level_max,
							header_arg = cmd.header_arg or "",
							passwordable = cmd.passwordable or false,
							password_args = cmd.password_args or {},
							compress_args = { table.unpack(cmd.compress_args or {}) },
						}
					end
				end
			end
			return nil
		end
	end
	return false
end

return {
	entry = function(_, job)
		command_cache = {}
		local is_password, is_encrypted, is_level, is_silent_success = false, false, false, false
		local default_extension = "zip"
		if job.args then
			for _, arg in ipairs(job.args) do
				if arg:match("^%-(%w+)$") then
					for flag in arg:sub(2):gmatch(".") do
						if flag == "p" then
							is_password = true
						elseif flag == "h" then
							is_encrypted = true
						elseif flag == "l" then
							is_level = true
						elseif flag == "s" then
							is_silent_success = true
						else
							notify("Unknown flag: -" .. flag, "warn")
						end
					end
				elseif arg:match("^[%w%.]+$") then
					if archive_commands[extension_pattern(arg)] then
						default_extension = arg
					else
						notify(string.format("Unsupported extension: %s", arg), "warn")
					end
				else
					notify(string.format("Unknown argument: %s", arg), "warn")
				end
			end
		end
		is_password = is_password or is_encrypted

		ya.emit("escape", { visual = true })

		local archive_dir, filenames, fnames, output_dir = selected_or_hovered()
		if not archive_dir then
			notify("Select files with a shared parent directory", "error")
			return
		end

		local output_name, event = ya.input({
			title = "Create archive:",
			pos = { "top-center", y = 3, w = 40 },
		})
		if event ~= 1 then
			return
		end

		local default_name = #fnames == 1 and fnames[1] or Url(output_dir).name
		output_name = output_name == "" and string.format("%s.%s", default_name, default_extension) or output_name

		if not output_name:match("%.%w+$") then
			output_name = string.format("%s.%s", output_name, default_extension)
		end

		if not is_valid_filename(output_name) then
			notify("Invalid archive filename", "error")
			return
		end

		local archive_config = find_archive_command(output_name, is_password, is_encrypted)
		if archive_config == false then
			notify("Unsupported file extension", "error")
			return
		elseif not archive_config then
			notify("Could not find a suitable archive program for the selected format and options", "error")
			return
		end

		local archive_cmd = archive_config.cmd
		local archive_args = archive_config.args
		local archive_compress = archive_config.compress
		local archive_level_arg = is_level and archive_config.level_arg or ""
		local archive_level_min = archive_config.level_min
		local archive_level_max = archive_config.level_max
		local archive_header_arg = is_encrypted and archive_config.header_arg or ""
		local archive_passwordable = archive_config.passwordable
		local archive_compress_args = archive_config.compress_args

		if archive_passwordable and is_password then
			local password_args = get_password_args(archive_cmd, is_encrypted, archive_header_arg)
			if not password_args then
				return
			end
			for _, arg in ipairs(password_args) do
				table.insert(archive_args, arg)
			end
			for _, arg in ipairs(archive_config.password_args) do
				table.insert(archive_args, arg)
			end
		end

		if is_encrypted and archive_header_arg ~= "" and archive_cmd ~= "rar" then
			table.insert(archive_args, archive_header_arg)
		end

		if archive_level_arg ~= "" and is_level then
			local output_level, level_event = ya.input({
				title = string.format("Enter compression level (%s - %s)", archive_level_min, archive_level_max),
				pos = { "top-center", y = 3, w = 40 },
			})
			if level_event ~= 1 then
				return
			end
			local level_num = tonumber(output_level)
			if
				level_num
				and level_num % 1 == 0
				and level_num >= archive_level_min
				and level_num <= archive_level_max
			then
				local target_args = archive_compress == "" and archive_args or archive_compress_args
				add_compression_level(target_args, archive_level_arg, output_level)
			else
				notify("Invalid level specified. Using defaults.", "warn")
			end
		end

		local original_name = output_name
		-- Backends infer their format from the temporary filename, including comic archives.
		local processed_name = canonical_archive_name(output_name)
		output_name = processed_name

		if archive_compress ~= "" then
			output_name = output_name:match("(.*%.tar)") or output_name
		end

		local temp_dir, temp_err = create_temp_dir(archive_dir, filenames, output_dir)
		if not temp_dir then
			notify("Failed to create a temporary directory: " .. tostring(temp_err), "error")
			return
		end

		local temp_output_url = combine_url(temp_dir, output_name)

		-- Custom tasks require Yazi 26.8. An entry already owns a plugin worker.
		local cancel_scope
		local supported, option = pcall(function()
			local scope = rt.scope():child()
			-- The task consumes the parent scope. This child observes its cancellation.
			cancel_scope = scope:child()
			return ya.task("custom", { pool = "none", progress = false, track = true, scope = scope })
		end)
		local task = supported and option:name("Compress " .. original_name):spawn() or nil
		cancel_scope = task and cancel_scope or nil
		if task and not task:acquire() then
			cleanup_temp_dir(temp_dir)
			return
		end

		local function fail(reason)
			if not cancel_scope or not cancel_scope:cancelled() then
				if task then
					task:fail(reason)
				end
				notify(reason, "error")
			end
			cleanup_temp_dir(temp_dir)
		end

		local function run(command, phase)
			if task then
				task:log(phase)
			end
			local status, err = run_command(command, cancel_scope)
			if status and status.success then
				return true
			end
			fail(phase .. ": " .. tostring(err))
			return false
		end

		if
			not run(
				Command(archive_cmd):arg(archive_args):arg(temp_output_url):arg(filenames):cwd(archive_dir),
				"Create " .. ya.quote(output_name) .. " with " .. archive_cmd
			)
		then
			return
		end
		if archive_compress ~= "" then
			local command = Command(archive_compress):arg(archive_compress_args)
			local compressed_output = combine_url(temp_dir, processed_name)
			if archive_compress:match("^7z") or archive_compress == "lha" then
				command:arg(compressed_output):arg(temp_output_url)
			elseif archive_compress == "lz4" then
				command:arg(temp_output_url):arg(compressed_output)
			else
				command:arg(temp_output_url)
			end
			if not run(command, "Compress " .. ya.quote(output_name) .. " with " .. archive_compress) then
				return
			end
		end

		if cancel_scope and cancel_scope:cancelled() then
			cleanup_temp_dir(temp_dir)
			return
		end
		local final_output_url = combine_url(output_dir, original_name)
		local temp_url_processed = combine_url(temp_dir, processed_name)
		local unique_file, unique_file_err = fs.unique("file", Url(final_output_url))
		if not unique_file then
			fail("Failed to choose an archive filename: " .. tostring(unique_file_err))
			return
		end
		final_output_url = tostring(unique_file)
		local from, to = Url(temp_url_processed), Url(final_output_url)
		local to_name = to.name
		local moved, err = fs.rename(from, to)
		if not moved and err and err.kind == "CrossesDevices" then
			moved, err = fs.copy(from, to)
		end
		if not moved or (cancel_scope and cancel_scope:cancelled()) then
			fs.remove("file", to)
			fail("Failed to save archive " .. ya.quote(final_output_url) .. ": " .. tostring(err))
			return
		end

		cleanup_temp_dir(temp_dir)
		if task then
			task:succeed({ to })
		end

		if not is_silent_success then
			notify(string.format("Successfully created archive: %s", ya.quote(to_name)), "info")
		end
	end,
}
