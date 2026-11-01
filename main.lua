--- @since 26.9.1
--- @sync entry

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
		-- 7-Zip parallelizes bzip2 at a higher memory cost.
		table.insert(candidates, ext == "bz2" and 1 or #candidates + 1, {
			command = tar_commands,
			args = { "-cf" },
			compress = sevenzip_commands,
			compress_args = { "a", "-t" .. compressor.sevenzip, "-spd" },
			level_arg = "-mx=",
			level_min = 1,
			level_max = 9,
		})
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
		ya.async(function()
			command_cache = {}
			local args = job.args or {}
			local state = { extension = "zip", interactive = #args == 0 }
			for _, arg in ipairs(args) do
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
					notify(
						(arg:match("^[%w%.]+$") and "Unsupported extension: " or "Unknown argument: ") .. arg,
						"warn"
					)
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
			local progress = (config.cmd:match("^7z") or (config.compress or ""):match("^7z")) ~= nil
			local scope = rt.scope():child()
			local cancel_scope = scope:child()
			local task = ya.task("custom", {
				pool = "plugin",
				progress = progress,
				track = true,
				scope = scope,
			})
				:name("Compress " .. name)
				:spawn()
			task:progress({ total = 1, workload = progress and 100 or 0 })
			local native = task.cancel ~= nil
			local function select(work)
				if native then
					return ya.select(task, work)
				elseif cancel_scope:cancelled() then
					return 1
				end

				-- Stable 26.9.1 has a placeholder ya.select and no callable tasks.
				local tx, rx = ya.chan("mpsc", 1)
				local ok, result
				local worker = ya.async(function()
					ok, result = pcall(work)
					tx:send(2)
				end)
				local watcher = ya.async(function()
					while not cancel_scope:cancelled() do
						ya.sleep(0.1)
					end
					tx:send(1)
				end)
				local branch = rx:recv()
				if branch == 1 then
					worker:abort()
					-- Abort completes on the next poll, releasing the child's I/O borrow.
					ya.sleep(0)
				end
				watcher:abort()
				if branch == 2 and not ok then
					error(result, 0)
				end
				return branch
			end

			local child, temp_dir, destination
			local function run(command, phase, sevenzip)
				task:log(phase)
				if sevenzip then
					command:arg({ "-bso0", "-bsp1", "-sccUTF-8" })
				end
				local err
				child, err = command:stdout(Command.PIPED):stderr(Command.PIPED):spawn()
				if not child then
					error(phase .. ": " .. tostring(err), 0)
				end

				local diagnostic, tail, last = "", "", 0
				while true do
					local chunk, event, read_err = child:read(4096)
					if not chunk then
						error(phase .. ": " .. tostring(read_err), 0)
					elseif event == 2 then
						break
					end
					if type(chunk) == "table" then
						chunk = string.char(table.unpack(chunk))
					end
					diagnostic = (diagnostic .. chunk):sub(-8192)
					if sevenzip and event == 0 then
						local text, percent = tail .. chunk, last
						for line in text:gmatch("[^\r\n\b]+") do
							percent = tonumber(line:match("^%s*(%d+)%%")) or percent
						end
						percent = math.min(100, percent)
						tail = text:match("[^\r\n\b]*$"):sub(-4096)
						if percent > last then
							task:progress({ processed = percent - last })
							last = percent
						end
					end
				end

				local status, wait_err = child:wait()
				if not status or not status.success then
					local reason = status and (status.code and "exit code " .. status.code or "Process terminated")
						or tostring(wait_err)
					error(phase .. ": " .. (diagnostic ~= "" and diagnostic or reason), 0)
				end
				child = nil
				if sevenzip then
					task:progress({ processed = 100 - last })
				end
			end

			local ok, result = pcall(function()
				if not task:acquire() then
					return
				end

				-- Reserve paths outside cancellable branches so cleanup always owns them.
				local err
				temp_dir, err = create_temp_dir(root, filenames, output_dir)
				if not temp_dir then
					error("Failed to create a temporary directory: " .. tostring(err), 0)
				end
				local temp_output = tostring(Url(temp_dir):join(intermediate))
				local branch = select(function()
					run(
						Command(config.cmd):arg(config.args):arg(temp_output):arg(filenames):cwd(root),
						"Create " .. ya.quote(name) .. " with " .. config.cmd,
						config.cmd:match("^7z")
					)
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
						run(
							command,
							"Compress " .. ya.quote(name) .. " with " .. config.compress,
							config.compress:match("^7z")
						)
					end
				end)
				if branch == 1 then
					return
				end

				destination, err = fs.unique("file", Url(output_dir):join(name))
				if not destination then
					error("Failed to choose an archive filename: " .. tostring(err), 0)
				end
				-- Filesystem operations can outlive a cancelled Lua future.
				local from = Url(temp_dir):join(filename)
				local moved, move_err = fs.rename(from, destination)
				if not moved and move_err and move_err.kind == "CrossesDevices" then
					moved, move_err = fs.copy(from, destination)
				end
				if not moved then
					error("Failed to save archive " .. ya.quote(tostring(destination)) .. ": " .. tostring(move_err), 0)
				elseif cancel_scope:cancelled() then
					return
				end
				local saved = destination
				destination = nil
				return saved
			end)

			if child then
				child:start_kill()
				local stopped, err = child:wait()
				if not stopped then
					ok, result = false, "Failed to stop archive program: " .. tostring(err)
				end
			end
			if destination then
				local removed, err = fs.remove("file", destination)
				if not removed then
					ok, result = false, "Failed to remove incomplete archive: " .. tostring(err)
				end
			end
			if temp_dir then
				local removed, err = fs.remove("dir_all", Url(temp_dir))
				if not removed then
					ok, result = false, "Failed to clean up temporary directory: " .. tostring(err)
				end
			end

			if not ok then
				task:progress({ failed = 1 })
				task:fail(tostring(result))
				notify(tostring(result), "error")
			elseif result then
				local to_name = result.name
				task:progress(native and { succeeded = 1 } or { success = 1 })
				task:succeed({ result })
				if not state.silent then
					notify("Successfully created archive: " .. ya.quote(to_name), "info")
				end
			elseif native then
				task:cancel()
			end
		end)
	end,
}
