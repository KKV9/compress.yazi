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

-- Archive from one shared directory so equal basenames keep distinct paths.
local selected_or_hovered = ya.sync(function()
	local tab = cx.active
	local urls = {}

	for _, u in pairs(tab.selected) do
		urls[#urls + 1] = u.url
	end

	if #urls == 0 and tab.current.hovered then
		urls[1] = tab.current.hovered.url
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

	local name = #urls == 1 and urls[1].name or tab.current.cwd.name or "archive"
	return tostring(root), filenames, name, tostring(tab.current.cwd)
end)

local function cleanup_temp_dir(temp_dir)
	local status, err = fs.remove("dir_all", Url(temp_dir))
	if not status then
		notify(
			string.format("Failed to clean up temporary directory %s, error: %s", ya.quote(temp_dir), tostring(err)),
			"error"
		)
	end
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

local function input_password()
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
	return output_password
end

-- -spd keeps literal filenames from expanding to unselected files.
local sevenzip_commands = { "7zz", "7z", "7za" }
local tar_commands = { "tar", "bsdtar" }

local archive_commands = {
	zip = {
		{ command = "zip", args = { "-r" }, level_arg = "-", level_min = 0, level_max = 9 },
		{
			command = sevenzip_commands,
			args = { "a", "-tzip", "-spd", "-mem=AES256" },
			level_arg = "-mx=",
			level_min = 0,
			level_max = 9,
			passwordable = true,
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
	["7z"] = {
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
	rar = {
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
	tar = { { command = tar_commands, args = { "-cf" } } },
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
	archive_commands["tar." .. ext] = candidates
end

local function find_archive_command(name, options)
	name = canonical_archive_name(name)
	local extension = name:match("%.([^.]+%.[^.]+)$")
	local candidates = archive_commands[extension] or archive_commands[name:match("%.([^.]+)$")]
	if not candidates then
		return false
	end
	for _, candidate in ipairs(candidates) do
		if (not options.password or candidate.passwordable) and (not options.headers or candidate.header_arg) then
			local command = find_command_name(candidate.command, candidate.bsdtar)
			local compress = candidate.compress and find_command_name(candidate.compress)
			if command and (not candidate.compress or compress) then
				local config = {}
				for key, value in pairs(candidate) do
					config[key] = value
				end
				config.cmd, config.compress = command, compress
				config.args = { table.unpack(candidate.args) }
				config.compress_args = { table.unpack(candidate.compress_args or {}) }
				return config
			end
		end
	end
end

local function input_level(config, current)
	local value, event = ya.input({
		title = string.format("Compression level (%d - %d, blank for default):", config.level_min, config.level_max),
		value = current and tostring(current) or "",
		pos = { "top-center", y = 3, w = 50 },
	})
	if event ~= 1 then
		return nil, false
	elseif value == "" then
		return nil, true
	end
	local level = tonumber(value)
	if not level or level % 1 ~= 0 or level < config.level_min or level > config.level_max then
		notify("Invalid level specified. Using defaults.", "warn")
		return nil, true
	end
	return level, true
end

local format_choices = {
	{ "z", "zip" },
	{ "7", "7z" },
	{ "r", "rar" },
	{ "t", "tar" },
	{ "g", "tar.gz" },
	{ "x", "tar.xz" },
	{ "b", "tar.bz2" },
	{ "s", "tar.zst" },
	{ "4", "tar.lz4" },
	{ "a", "tar.lha" },
}

local function configure(state)
	local function formats()
		local available = {}
		for _, choice in ipairs(format_choices) do
			local config = find_archive_command("archive." .. choice[2], state)
			if config then
				available[#available + 1] = {
					on = choice[1],
					desc = choice[2] .. " (" .. config.cmd .. ")",
					extension = choice[2],
				}
			end
		end
		return available
	end

	if not find_archive_command("archive." .. state.extension, state) then
		local available = formats()
		if #available == 0 then
			notify("No archive program supports the requested format and options", "error")
			return
		end
		state.extension = available[1].extension
	end

	while true do
		local config = find_archive_command("archive." .. state.extension, state)
		local items = { { on = "f", desc = "Format: " .. state.extension .. " (" .. config.cmd .. ")" } }
		if config.passwordable or find_archive_command("archive." .. state.extension, { password = true }) then
			items[#items + 1] = { on = "p", desc = "Password: " .. (state.password and "on" or "off") }
		end
		if config.header_arg then
			items[#items + 1] = { on = "h", desc = "Headers: " .. (state.headers and "on" or "off") }
		end
		if config.level_arg then
			items[#items + 1] = { on = "l", desc = "Level: " .. (state.level or "default") }
		end
		items[#items + 1] = { on = "c", desc = "Create" }
		local choice = ya.which({ cands = items })
		if not choice then
			return
		end
		local key = items[choice].on
		if key == "c" then
			return state
		elseif key == "f" then
			local available = formats()
			local picked = ya.which({ cands = available })
			if picked then
				state.extension = available[picked].extension
				state.level = nil
			end
		elseif key == "p" then
			state.password = not state.password
			state.headers = state.password and state.headers
		elseif key == "h" then
			state.headers = not state.headers
			state.password = state.password or state.headers
		elseif key == "l" then
			local level, accepted = input_level(config, state.level)
			if accepted then
				state.level, state.ask_level = level, false
			end
		end
	end
end

local option_flags = { p = "password", h = "headers", l = "ask_level", s = "silent", i = "interactive" }

return {
	entry = function(_, job)
		command_cache = {}
		local state = { extension = "zip" }
		for _, arg in ipairs(job.args or {}) do
			if arg:match("^%-%w+$") then
				for flag in arg:sub(2):gmatch(".") do
					local option = option_flags[flag]
					if option then
						state[option] = true
					else
						notify("Unknown flag: -" .. flag, "warn")
					end
				end
			elseif archive_commands[archive_aliases[arg] or arg] then
				state.extension = arg
			else
				notify((arg:match("^[%w%.]+$") and "Unsupported extension: " or "Unknown argument: ") .. arg, "warn")
			end
		end
		state.password = state.password or state.headers
		ya.emit("escape", { visual = true })

		local root, filenames, default_name, output_dir = selected_or_hovered()
		if not root then
			notify("Select files with a shared parent directory", "error")
			return
		elseif state.interactive and not configure(state) then
			return
		end

		local default_filename = default_name .. "." .. state.extension
		local name, event = ya.input({
			title = "Create archive:",
			value = state.interactive and default_filename or "",
			pos = { "top-center", y = 3, w = 40 },
		})
		if event ~= 1 then
			return
		elseif name == "" then
			name = default_filename
		elseif not name:match("%.%w+$") then
			name = name .. "." .. state.extension
		end
		if not is_valid_filename(name) then
			notify("Invalid archive filename", "error")
			return
		end

		local config = find_archive_command(name, state)
		if not config then
			notify(
				config == false and "Unsupported file extension"
					or "Could not find a suitable archive program for the selected format and options",
				"error"
			)
			return
		end
		if state.password then
			local password = input_password()
			if not password then
				return
			end
			config.args[#config.args + 1] = (state.headers and config.cmd == "rar" and "-hp" or "-p") .. password
		end
		if state.headers and config.cmd ~= "rar" then
			config.args[#config.args + 1] = config.header_arg
		end
		if config.level_arg then
			if state.ask_level then
				local accepted
				state.level, accepted = input_level(config, state.level)
				if not accepted then
					return
				end
			end
			if state.level then
				if state.level < config.level_min or state.level > config.level_max then
					notify("The selected compression level is unsupported by this archive format", "error")
					return
				end
				add_compression_level(
					config.compress and config.compress_args or config.args,
					config.level_arg,
					tostring(state.level)
				)
			end
		end

		-- Backends infer their format from the temporary filename, including comic archives.
		local filename = canonical_archive_name(name)
		local intermediate = config.compress and filename:match("(.*%.tar)") or filename
		local temp_dir, err = create_temp_dir(root, filenames, output_dir)
		if not temp_dir then
			notify("Failed to create a temporary directory: " .. tostring(err), "error")
			return
		end
		local temp_output = tostring(Url(temp_dir):join(intermediate))

		-- Custom tasks require Yazi 26.8. An entry already owns a plugin worker.
		local cancel_scope
		local supported, option = pcall(function()
			local scope = rt.scope():child()
			-- The task consumes the parent scope. This child observes its cancellation.
			cancel_scope = scope:child()
			return ya.task("custom", { pool = "none", progress = false, track = true, scope = scope })
		end)
		local task = supported and option:name("Compress " .. name):spawn() or nil
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
			local status, run_err = run_command(command, cancel_scope)
			if status and status.success then
				return true
			end
			fail(phase .. ": " .. tostring(run_err))
		end

		if
			not run(
				Command(config.cmd):arg(config.args):arg(temp_output):arg(filenames):cwd(root),
				"Create " .. ya.quote(name) .. " with " .. config.cmd
			)
		then
			return
		end
		if config.compress then
			local command = Command(config.compress):arg(config.compress_args)
			local target = tostring(Url(temp_dir):join(filename))
			if config.compress:match("^7z") or config.compress == "lha" then
				command:arg(target):arg(temp_output)
			elseif config.compress == "lz4" then
				command:arg(temp_output):arg(target)
			else
				command:arg(temp_output)
			end
			if not run(command, "Compress " .. ya.quote(name) .. " with " .. config.compress) then
				return
			end
		end
		if cancel_scope and cancel_scope:cancelled() then
			cleanup_temp_dir(temp_dir)
			return
		end

		local to, reserve_err = fs.unique("file", Url(output_dir):join(name))
		if not to then
			fail("Failed to choose an archive filename: " .. tostring(reserve_err))
			return
		end
		local to_name = to.name
		local from = Url(temp_dir):join(filename)
		local moved, move_err = fs.rename(from, to)
		if not moved and move_err and move_err.kind == "CrossesDevices" then
			moved, move_err = fs.copy(from, to)
		end
		if not moved or (cancel_scope and cancel_scope:cancelled()) then
			fs.remove("file", to)
			fail("Failed to save archive " .. ya.quote(tostring(to)) .. ": " .. tostring(move_err))
			return
		end
		cleanup_temp_dir(temp_dir)
		if task then
			task:succeed({ to })
		end
		if not state.silent then
			notify("Successfully created archive: " .. ya.quote(to_name), "info")
		end
	end,
}
