--- @since 26.5.6

-- Check for windows
local is_windows = ya.target_family() == "windows"

-- Custom tasks, which is what makes the compression show up in the task manager, need Yazi 26.8
local has_custom_tasks = pcall(function()
	ya.task("custom", { scope = rt.scope() })
end)

-- Linux exposes how many bytes a process has read so far, which is what progress is based on
local can_track_bytes = has_custom_tasks and ya.target_os() == "linux"

-- Define default flags and strings
local is_password, is_encrypted, is_level, is_silent_success = false, false, false, false
local default_extension = "zip"

-- Allow dots when matching file extension arguments
local function extension_pattern(ext)
	return "%." .. ext:gsub("%.", "%%.") .. "$"
end

-- Function to check valid filename
local function is_valid_filename(name)
	-- Trim whitespace from both ends
	name = name:match("^%s*(.-)%s*$")
	if name == "" then
		return false
	end
	if is_windows then
		-- Windows forbidden chars and reserved names
		if name:find('[<>:"/\\|%?%*]') then
			return false
		end
	else
		-- Unix forbidden chars
		if name:find("/") or name:find("%z") then
			return false
		end
	end
	return true
end

-- Function to send notifications
local function notify(message, level)
	ya.notify({
		title = "Archive",
		content = message,
		level = level,
		timeout = 5,
	})
end

-- Function to check if command is available
local function is_command_available(cmd)
	local stat_cmd
	if is_windows then
		stat_cmd = string.format("where %s > nul 2>&1", cmd)
	else
		stat_cmd = string.format("command -v %s >/dev/null 2>&1", cmd)
	end
	return os.execute(stat_cmd)
end

-- Function to find first available command from list
local function find_command_name(cmd_list)
	for _, cmd in ipairs(cmd_list) do
		if is_command_available(cmd) then
			return cmd
		end
	end
	return cmd_list[1] -- Return first command as fallback
end

-- Function to append filename to its parent directory url
local function combine_url(path, file)
	local path_url = Url(path)
	local file_url = Url(file)
	return tostring(path_url:join(file_url))
end

-- Function to make a table of selected or hovered files: path = filenames
local selected_or_hovered = ya.sync(function()
	local tab = cx.active
	local paths = {}
	local names = {}
	local path_fnames = {}

	for _, u in pairs(tab.selected) do
		paths[#paths + 1] = tostring(u.url.parent)
		names[#names + 1] = tostring(u.name)
	end

	if #paths == 0 and tab.current.hovered then
		paths[1] = tostring(tab.current.hovered.url.parent)
		names[1] = tostring(tab.current.hovered.name)
	end

	for idx, name in ipairs(names) do
		local path = paths[idx]
		if not path_fnames[path] then
			path_fnames[path] = {}
		end
		table.insert(path_fnames[path], name)
	end

	return path_fnames, names, tostring(tab.current.cwd)
end)

-- Function to cleanup temporary directory
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

-- How often to sample the archiver's progress, in seconds
local POLL_INTERVAL = 0.25

-- Number of consecutive failed samples after which sampling is given up on
local POLL_FAILURES = 5

-- Function to read how many bytes the process `pid` has read so far
local function read_rchar(pid)
	local output = Command("cat"):arg(string.format("/proc/%d/io", pid)):output()
	if not output or not output.status.success then
		return nil
	end
	return tonumber(output.stdout:match("rchar:%s*(%d+)"))
end

-- Function to run `command` to completion, reporting its progress to `task` while it runs,
-- where `budget` is how many bytes the command is expected to read.
-- Returns (status, err), just like `Child:wait()`
local function run_tracked(command, task, budget)
	local child, err = command:spawn()
	if not child then
		return nil, err
	end

	local pid = child:id()
	if not task or not can_track_bytes or not pid or budget <= 0 then
		-- Nothing to report against, so simply wait for the command to finish
		return child:wait()
	end

	local done, failures = 0, 0
	while true do
		local rchar = failures < POLL_FAILURES and read_rchar(pid)
		if rchar then
			failures, rchar = 0, math.min(rchar, budget)
			if rchar > done then
				-- Every reported value adds up within the task, so send the difference only
				task:progress { processed = rchar - done }
				done = rchar
			end
		else
			failures = failures + 1
		end

		local status, wait_err = child:try_wait()
		if status then
			-- Charge the rest of the budget once the command succeeds, so that the
			-- reported percentage stays exact and only ever moves forward
			if status.success and budget > done then
				task:progress { processed = budget - done }
			end
			return status, wait_err
		end

		ya.sleep(POLL_INTERVAL)
	end
end

-- Function for compression level
local function add_compression_level(target_args, level_arg, level_value)
	if type(level_arg) == "table" then
		-- Insert each element except last
		for i = 1, #level_arg - 1 do
			table.insert(target_args, i, level_arg[i])
		end
		-- Add the level value with the last element
		table.insert(target_args, #level_arg, level_arg[#level_arg] .. level_value)
	else
		-- Single string argument
		table.insert(target_args, 1, level_arg .. level_value)
	end
end

-- Function for password handling
local function get_password_args(archive_cmd, encrypted, header_arg)
	local output_password, event = ya.input({
		title = "Enter password:",
		obscure = true,
		pos = { "top-center", y = 3, w = 40 },
	})
	if event ~= 1 or output_password == "" then
		return nil
	end
	-- Handling for RAR with encryption
	if archive_cmd == "rar" and encrypted then
		return { header_arg .. output_password }
	end
	return { "-P" .. output_password }
end

-- Table of archive commands
local archive_commands = {
	["%.zip$"] = {
		{ command = "zip", args = { "-r" }, level_arg = "-", level_min = 0, level_max = 9, passwordable = true },
		{
			command = { "7z", "7zz", "7za" },
			args = { "a", "-tzip" },
			level_arg = "-mx=",
			level_min = 0,
			level_max = 9,
			passwordable = true,
		},
		{
			command = { "tar", "bsdtar" },
			args = { "-caf" },
			level_arg = { "--option", "compression-level=" },
			level_min = 1,
			level_max = 9,
		},
	},
	["%.7z$"] = {
		{
			command = { "7z", "7zz", "7za" },
			args = { "a" },
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
	["%.tar%.gz$"] = {
		{
			command = { "tar", "bsdtar" },
			args = { "rpf" },
			level_arg = "-",
			level_min = 1,
			level_max = 9,
			compress = "gzip",
		},
		{
			command = { "tar", "bsdtar" },
			args = { "rpf" },
			level_arg = "-mx=",
			level_min = 1,
			level_max = 9,
			compress = "7z",
			compress_args = { "a", "-tgzip" },
		},
		{
			command = { "tar", "bsdtar" },
			args = { "-czf" },
			level_arg = { "--option", "gzip:compression-level=" },
			level_min = 1,
			level_max = 9,
		},
	},
	["%.tar%.xz$"] = {
		{
			command = { "tar", "bsdtar" },
			args = { "rpf" },
			level_arg = "-",
			level_min = 1,
			level_max = 9,
			compress = "xz",
		},
		{
			command = { "tar", "bsdtar" },
			args = { "rpf" },
			level_arg = "-mx=",
			level_min = 1,
			level_max = 9,
			compress = "7z",
			compress_args = { "a", "-txz" },
		},
		{
			command = { "tar", "bsdtar" },
			args = { "-cJf" },
			level_arg = { "--option", "xz:compression-level=" },
			level_min = 1,
			level_max = 9,
		},
	},
	["%.tar%.bz2$"] = {
		{
			command = { "tar", "bsdtar" },
			args = { "rpf" },
			level_arg = "-",
			level_min = 1,
			level_max = 9,
			compress = "bzip2",
		},
		{
			command = { "tar", "bsdtar" },
			args = { "rpf" },
			level_arg = "-mx=",
			level_min = 1,
			level_max = 9,
			compress = "7z",
			compress_args = { "a", "-tbzip2" },
		},
		{
			command = { "tar", "bsdtar" },
			args = { "-cjf" },
			level_arg = { "--option", "bzip2:compression-level=" },
			level_min = 1,
			level_max = 9,
		},
	},
	["%.tar%.zst$"] = {
		{
			command = { "tar", "bsdtar" },
			args = { "rpf" },
			level_arg = "-",
			level_min = 1,
			level_max = 22,
			compress = "zstd",
			compress_args = { "--ultra" },
		},
	},
	["%.tar%.lz4$"] = {
		{
			command = { "tar", "bsdtar" },
			args = { "rpf" },
			level_arg = "-",
			level_min = 1,
			level_max = 12,
			compress = "lz4",
		},
	},
	["%.tar%.lha$"] = {
		{
			command = { "tar", "bsdtar" },
			args = { "rpf" },
			level_arg = "-o",
			level_min = 5,
			level_max = 7,
			compress = "lha",
			compress_args = { "-a" },
		},
	},
	["%.tar$"] = {
		{ command = { "tar", "bsdtar" }, args = { "rpf" } },
	},
}

-- Function for command matching
local function find_archive_command(output_name)
	for pattern, cmd_list in pairs(archive_commands) do
		if output_name:match(pattern) then
			for _, cmd in ipairs(cmd_list) do
				-- Check if archive command is available
				local cmd_name = type(cmd.command) == "table" and find_command_name(cmd.command) or cmd.command
				if is_command_available(cmd_name) then
					-- Check if compress command (if listed) is available
					if not cmd.compress or is_command_available(cmd.compress) then
						return {
							cmd = cmd_name,
							args = cmd.args,
							compress = cmd.compress or "",
							level_arg = cmd.level_arg or "",
							level_min = cmd.level_min,
							level_max = cmd.level_max,
							header_arg = cmd.header_arg or "",
							passwordable = cmd.passwordable or false,
							compress_args = cmd.compress_args or {},
						}
					end
				end
			end
			-- Pattern matched but no suitable command found
			return nil
		end
	end
	-- No pattern matched - unsupported extension
	return false
end

return {
	entry = function(_, job)
		-- Parse flags and default extension
		if job.args then
			for _, arg in ipairs(job.args) do
				if arg:match("^%-(%w+)$") then
					-- Handle combined flags (e.g., -phl)
					for flag in arg:sub(2):gmatch(".") do
						if flag == "p" then
							is_password = true
						elseif flag == "h" then
							is_encrypted = true
						elseif flag == "l" then
							is_level = true
						elseif flag == "s" then
							is_silent_success = true
						end
					end
				elseif arg:match("^[%w%.]+$") then
					-- Handle default extension (e.g., 7z, zip)
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

		-- Exit visual mode
		ya.emit("escape", { visual = true })

		-- Define file table and output_dir (pwd)
		local path_fnames, fnames, output_dir = selected_or_hovered()

		-- Get archive filename
		local output_name, event = ya.input({
			title = "Create archive:",
			pos = { "top-center", y = 3, w = 40 },
		})
		if event ~= 1 then
			return
		end

		-- Determine the default name for the archive
		local default_name = #fnames == 1 and fnames[1] or Url(output_dir).name
		output_name = output_name == "" and string.format("%s.%s", default_name, default_extension) or output_name

		-- Add default extension if none is specified
		if not output_name:match("%.%w+$") then
			output_name = string.format("%s.%s", output_name, default_extension)
		end

		-- Validate the final archive filename
		if not is_valid_filename(output_name) then
			notify("Invalid archive filename", "error")
			return
		end

		-- Command matching
		local archive_config = find_archive_command(output_name)
		if archive_config == false then
			notify("Unsupported file extension", "error")
			return
		elseif not archive_config then
			notify("Could not find a suitable archive program for the selected file extension", "error")
			return
		end

		-- Extract configuration
		local archive_cmd = archive_config.cmd
		local archive_args = archive_config.args
		local archive_compress = archive_config.compress
		local archive_level_arg = is_level and archive_config.level_arg or ""
		local archive_level_min = archive_config.level_min
		local archive_level_max = archive_config.level_max
		local archive_header_arg = is_encrypted and archive_config.header_arg or ""
		local archive_passwordable = archive_config.passwordable
		local archive_compress_args = archive_config.compress_args

		-- Password handling
		if archive_passwordable and is_password then
			local password_args = get_password_args(archive_cmd, is_encrypted, archive_header_arg)
			if password_args then
				for _, arg in ipairs(password_args) do
					table.insert(archive_args, arg)
				end
			end
		end

		-- Add header arg if selected for 7z
		if is_encrypted and archive_header_arg ~= "" and archive_cmd ~= "rar" then
			table.insert(archive_args, archive_header_arg)
		end

		-- Use extracted compression level
		if archive_level_arg ~= "" and is_level then
			local output_level, level_event = ya.input({
				title = string.format("Enter compression level (%s - %s)", archive_level_min, archive_level_max),
				pos = { "top-center", y = 3, w = 40 },
			})
			if level_event ~= 1 then
				return
			end
			-- Validate user input for compression level
			local level_num = tonumber(output_level)
			if level_num and level_num >= archive_level_min and level_num <= archive_level_max then
				local target_args = archive_compress == "" and archive_args or archive_compress_args
				add_compression_level(target_args, archive_level_arg, output_level)
			else
				notify("Invalid level specified. Using defaults.", "warn")
			end
		end

		-- Store the original output name for later use
		local original_name = output_name

		-- If compression is needed, adjust the output name to exclude extensions like ".tar"
		if archive_compress ~= "" then
			output_name = output_name:match("(.*%.tar)") or output_name
		end

		-- Create a temporary directory for intermediate files
		local temp_dir_name = ".tmp_compress"
		local temp_dir = combine_url(output_dir, temp_dir_name)
		temp_dir = tostring(fs.unique("dir", Url(temp_dir)))

		-- Attempt to create the temporary directory
		local temp_dir_status, temp_dir_err = fs.create("dir_all", Url(temp_dir))
		if not temp_dir_status then
			-- Notify the user if the temporary directory creation fails
			notify(string.format("Failed to create temp directory, error code: %s", tostring(temp_dir_err)), "error")
			return
		end

		-- Define the temporary output file path within the temporary directory
		local temp_output_url = combine_url(temp_dir, output_name)

		-- Report a failure to the task, to the user, and clean up the temporary directory
		local task
		local function fail(reason)
			if task then
				task:fail(reason)
			end
			notify(reason, "error")
			cleanup_temp_dir(temp_dir)
		end

		-- Work out how many bytes the archiver is going to read, to report progress against
		local budgets, total_size = {}, 0
		for filepath, filenames in pairs(path_fnames) do
			local budget = 0
			for _, filename in ipairs(filenames) do
				local calculator = fs.calc_size(Url(combine_url(filepath, filename)))
				while true do
					local chunk = calculator and calculator:recv()
					if not chunk then
						break
					end
					budget = budget + chunk
				end
			end
			budgets[filepath] = budget
			total_size = total_size + budget
		end

		-- The compressor reads the archive produced by the archiver, which is roughly as
		-- large as the files that went into it, so it accounts for about half of the work
		local workload = archive_compress ~= "" and total_size * 2 or total_size

		-- Register the compression as a Yazi task, so that it shows up in the task manager
		-- (`w`) and in the status bar, with a progress bar while it runs
		if has_custom_tasks then
			task = ya.task("custom", {
				-- No pool: the task needs no worker of its own, so Yazi starts it right away
				pool = "none",
				-- Trace the created archive in the manager, like Yazi's own file tasks do
				track = true,
				-- Without a size to work against, the task shows up without a percentage
				progress = can_track_bytes and workload > 0,
				scope = rt.scope(),
			}):name("Compress " .. original_name):spawn()

			if not task:acquire() then
				cleanup_temp_dir(temp_dir)
				return
			end

			task:progress { total = #fnames, workload = workload }
		end

		-- Add files to the output archive
		for filepath, filenames in pairs(path_fnames) do
			-- Execute the archive command for each path and its respective files
			local command = Command(archive_cmd):arg(archive_args):arg(temp_output_url):arg(filenames):cwd(filepath)
			local archive_status, archive_err = run_tracked(command, task, budgets[filepath])
			if not archive_status or not archive_status.success then
				-- Report the failure if the archiving process fails
				fail(
					string.format(
						"Failed to create archive %s with '%s', error: %s",
						ya.quote(output_name),
						archive_cmd,
						tostring(archive_err)
					)
				)
				return
			end

			if task then
				task:progress { success = #filenames }
			end
		end

		-- If compression is required, execute the compression command
		if archive_compress ~= "" then
			-- The compressor reads the uncompressed archive created above
			local tar_cha = fs.cha(Url(temp_output_url))
			local tar_size = tar_cha and tar_cha.len or 0

			local command
			-- Check if using 7z for compression (requires output file argument)
			if archive_compress:match("^7z") then
				local compressed_output = combine_url(temp_dir, original_name)
				command = Command(archive_compress)
					:arg(archive_compress_args)
					:arg(compressed_output)
					:arg(temp_output_url)
			else
				-- Native compression tools (gzip, xz, bzip2, etc.) compress in-place
				command = Command(archive_compress):arg(archive_compress_args):arg(temp_output_url)
			end

			local compress_status, compress_err = run_tracked(command, task, tar_size)
			if not compress_status or not compress_status.success then
				-- Report the failure if the compression process fails
				fail(
					string.format(
						"Failed to compress archive %s with '%s', error: %s",
						ya.quote(output_name),
						archive_compress,
						tostring(compress_err)
					)
				)
				return
			end
		end

		-- Move the final file from the temporary directory to the output directory
		local final_output_url = combine_url(output_dir, original_name)
		local temp_url_processed = combine_url(temp_dir, original_name)
		final_output_url = tostring(fs.unique("file", Url(final_output_url)))
		local from, to = Url(temp_url_processed), Url(final_output_url)
		-- `to` is consumed by `task:succeed` below, so keep its name around
		local to_name = to.name
		local move_status, move_err = fs.rename(from, to)
		if not move_status then
			if move_err and move_err.kind == "CrossesDevices" then
				local copy_status, copy_err = fs.copy(from, to)
				if not copy_status then
					fail(
						string.format(
							"Failed to copy across devices %s to %s, error: %s",
							ya.quote(from.name),
							ya.quote(to.name),
							copy_err and tostring(copy_err.kind) or "unknown"
						)
					)
					return
				end
			else
				fail(
					string.format(
						"Failed to move %s to %s, error: %s",
						ya.quote(from.name),
						ya.quote(to.name),
						move_err and tostring(move_err.kind) or "unknown"
					)
				)
				return
			end
		end

		-- Cleanup the temporary directory after successful operation
		cleanup_temp_dir(temp_dir)

		-- Finish the task, which also traces the created archive in the manager
		if task then
			task:succeed { to }
		end

		-- Notify user of success
		if not is_silent_success then
			notify(string.format("Successfully created archive: %s", ya.quote(to_name)), "info")
		end
	end,
}
