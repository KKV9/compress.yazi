-- Check for windows
local is_windows = ya.target_family() == "windows"
-- Define flags and strings
local is_password, is_encrypted, is_level, cmd_password, cmd_level = false, false, false, "", ""

-- Function to check valid filename
local function is_valid_filename(name)
    -- Trim whitespace from both ends
    name = name:match("^%s*(.-)%s*$")
    if name == "" then return false end
    if is_windows then
        -- Windows forbidden chars and reserved names
        if name:find('[<>:"/\\|%?%*]') then return false end
        local reserved = {
            "CON", "PRN", "AUX", "NUL",
            "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
            "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9"
        }
        for _, r in ipairs(reserved) do
            if name:upper() == r or name:upper():match("^" .. r .. "%.") then return false end
        end
    else
        -- Unix forbidden chars
        if name:find("/") or name:find("%z") then return false end
    end
    return true
end

-- Function to send notifications
local function notify_error(message, urgency)
	ya.notify({
		title = "Archive",
		content = message,
		level = urgency,
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
	local cmd_exists = os.execute(stat_cmd)
	if cmd_exists then
		return true
	else
		return false
	end
end

-- Function to change command arrays --> string -- Use first command available or first command
local function find_binary(cmd_list)
	for _, cmd in ipairs(cmd_list) do
		if is_command_available(cmd) then
			return cmd
		end
	end
	return cmd_list[1] -- Return first command as fallback
end

-- Function to check if a file exists
local function file_exists(name)
	local f = io.open(name, "r")
	if f ~= nil then
		io.close(f)
		return true
	else
		return false
	end
end

-- Function to append filename to it's parent directory url
local function combine_url(path, file)
	path, file = Url(path), Url(file)
	return tostring(path:join(file))
end

-- Function to display errors if a command goes wrong
local function command_warning(command, status, error)
		if not status or not status.success then
			notify_error(
			string.format(
				"%s with selected files failed, exit code %s",
				command,
				status and status.code or error
			),
			"error"
		)
	end
end

-- Function to make a table of selected or hovered files: path = filenames
local selected_or_hovered = ya.sync(function()
	local tab, paths, names, path_fnames = cx.active, {}, {}, {}
	for _, u in pairs(tab.selected) do
		paths[#paths + 1] = tostring(u.parent)
		names[#names + 1] = tostring(u.name)
	end
	if #paths == 0 and tab.current.hovered then
		paths[1] = tostring(tab.current.hovered.url.parent)
		names[1] = tostring(tab.current.hovered.name)
	end
	for idx, name in ipairs(names) do
		if not path_fnames[paths[idx]] then
			path_fnames[paths[idx]] = {}
		end
		table.insert(path_fnames[paths[idx]], name)
	end
	return path_fnames, tostring(tab.current.cwd)
end)

-- Table of archive commands
local archive_commands = {
	["%.zip$"] = {
		{ command = "zip", args = { "-r" }, level_arg = "-", level_min = 0, level_max = 9, passwordable = true },
		{ command = { "7z", "7zz" }, args = { "a", "-tzip" }, level_arg = "-mx=", level_min = 0, level_max = 9, passwordable = true },
		{ command = { "tar", "bsdtar" }, args = { "-caf" }, level_arg = { "--option", "compression-level=" }, level_min = 1, level_max = 9 },
	},
	["%.7z$"] = {
		{ command = { "7z", "7zz" }, args = { "a" }, level_arg = "-mx=", level_min = 0, level_max = 9, header_arg = "-mhe=on", passwordable = true },
	},
	["%.rar$"] = {
		{ command = "rar", args = { "a" }, level_arg = "-m", level_min = 0, level_max = 5, header_arg = "-hp",  passwordable = true },
	},
	["%.tar.gz$"] = {
		{ command = { "tar", "bsdtar" }, args = { "rpf" }, level_arg = "-", level_min = 1, level_max = 9, compress = "gzip" },
		{
			command = { "tar", "bsdtar" },
			args = { "rpf" },
			level_arg = "-mx=",
			level_min = 1,
			level_max = 9,
			compress = "7z",
			compress_args = { "a", "-tgzip", "-sdel" },
		},
		{ command = { "tar", "bsdtar" }, args = { "-czf" }, level_arg = { "--option", "gzip:compression-level=" }, level_min = 1, level_max = 9 },
	},
	["%.tar.xz$"] = {
		{ command = { "tar", "bsdtar" }, args = { "rpf" }, level_arg = "-", level_min = 1, level_max = 9, compress = "xz" },
		{
			command = { "tar", "bsdtar" },
			args = { "rpf" },
			level_arg = "-mx=",
			level_min = 1,
			level_max = 9,
			compress = "7z",
			compress_args = { "a", "-txz", "-sdel" },
		},
		{ command = { "tar", "bsdtar" }, args = { "-cJf" }, level_arg = { "--option", "xz:compression-level=" }, level_min = 1, level_max = 9 },
	},
	["%.tar.bz2$"] = {
		{ command = { "tar", "bsdtar" }, args = { "rpf" }, level_arg = "-", level_min = 1, level_max = 9, compress = "bzip2" },
		{
			command = { "tar", "bsdtar" },
			args = { "rpf" },
			level_arg = "-mx=",
			level_min = 1,
			level_max = 9,
			compress = "7z",
			compress_args = { "a", "-tbzip2", "-sdel" },
		},
		{ command = { "tar", "bsdtar" }, args = { "-cjf" }, level_arg = { "--option", "bzip2:compression-level=" }, level_min = 1, level_max = 9 },
	},
	["%.tar.zst$"] = {
		{ command = { "tar", "bsdtar" }, args = { "rpf" }, level_arg = "-", level_min = 1, level_max = 19, compress = "zstd", compress_args = { "--rm" } },
	},
	["%.tar.lz4$"] = {
		{ command = { "tar", "bsdtar" }, args = { "rpf" }, level_arg = "-", level_min = 1, level_max = 12, compress = "lz4", compress_args = { "--rm" } },
	},
	["%.tar.lha$"] = {
		{ command = { "tar", "bsdtar" }, args = { "rpf" }, level_arg = "-o", level_min = 5, level_max = 7, compress = "lha", compress_args = { "-ad" } },
	},
	["%.tar$"] = {
		{ command = { "tar", "bsdtar" }, args = { "rpf" } },
	},
}

return {
	entry = function(_, job)
		-- Check if password is needed. Search for char in the entire arguments array as a single string
		if job.args ~= nil then
			local args_string = table.concat(job.args, "")
			is_password = string.find(args_string, "p") ~= nil
			is_encrypted = string.find(args_string, "h") ~= nil
			is_level = string.find(args_string, "l") ~= nil
		end
		-- Exit visual mode
		ya.emit("escape", { visual = true })
		-- Define file table and output_dir (pwd) 
		local path_fnames, output_dir = selected_or_hovered()
		-- Get archive filename
		local output_name, event = ya.input({
			title = "Create archive:",
			position = { "top-center", y = 3, w = 40 },
		})
		if event ~= 1 then
			return
		end
		if not is_valid_filename(output_name) then
			notify_error("Invalid archive filename", "error")
			return
		end	

		-- Match user input to archive command
		local archive_cmd, archive_args, archive_compress, archive_level_arg, archive_level_min, archive_level_max, archive_header_arg, archive_passwordable, archive_compress_args
		local matched_pattern = false
		for pattern, cmd_list in pairs(archive_commands) do
			if output_name:match(pattern) then
				matched_pattern = true -- Mark that file extention is correct
				for _, cmd in ipairs(cmd_list) do
					-- Check if archive_cmd is available
					local find_command = type(cmd.command) == "table" and find_binary(cmd.command) or cmd.command
					if is_command_available(find_command) then
						-- Check if compress_cmd (if listed) is available
						if cmd.compress == nil or is_command_available(cmd.compress) then
							archive_cmd = find_command
							archive_args = cmd.args
							archive_compress = cmd.compress or ""
							archive_level_arg = is_level and cmd.level_arg or ""
							archive_level_min = cmd.level_min
							archive_level_max = cmd.level_max
							archive_header_arg = is_encrypted and cmd.header_arg or ""
							archive_passwordable = cmd.passwordable or false
							archive_compress_args = cmd.compress_args or {}
							break
						end
					end
				end
				if archive_cmd then break end
			end
		end

		-- Check if no archive command is available for the extension
		if not matched_pattern then
			notify_error("Unsupported file extension", "error")
			return
		end

		-- Check if no suitable archive program was found
		if not archive_cmd then
			notify_error("Could not find a suitable archive program for the selected file extension", "error")
			return
		end

		-- Tar archive to delete after compression for 7z and lha
		if archive_compress_args[3] == "-sdel" or archive_compress_args[1] == "-ad" then
			table.insert(archive_compress_args, output_name)
		end

		-- Check if archive command has multiple names
		if type(archive_cmd) == "table" then
			archive_cmd = find_binary(archive_cmd)
		end

		-- Exit if archive command is not available
		if not is_command_available(archive_cmd) then
			notify_error(string.format("%s not available", archive_cmd), "error")
			return
		end

		-- Exit if compress command is not available
		if archive_compress ~= "" and not is_command_available(archive_compress) then
			notify_error(string.format("%s compression not available", archive_compress), "error")
			return
		end

		-- Add password arg if selected
		if archive_passwordable and is_password then
			local output_password, event = ya.input({
				title = "Enter password:",
				obscure = true,
				position = { "top-center", y = 3, w = 40 },
			})
			if event ~= 1 then
				return
			end
			if output_password ~= "" then
				cmd_password = "-P" .. output_password
				if archive_cmd == "rar" and is_encrypted then
					cmd_password = archive_header_arg .. output_password
				end
				table.insert(archive_args, cmd_password)
			end
		end

		-- Add header arg if selected
		if is_encrypted and archive_header_arg ~= "" and archive_cmd ~= "rar" then
			table.insert(archive_args, archive_header_arg)
		end

		-- Add level arg if selected
		if archive_level_arg ~= "" and is_level then
			local output_level, event = ya.input({
				title = string.format("Enter compression level (%s - %s)", archive_level_min, archive_level_max),
				position = { "top-center", y = 3, w = 40 },
			})
			if event ~= 1 then
				return
			end
			-- Validate user input for compression level
			if output_level ~= "" and tonumber(output_level) ~= nil and tonumber(output_level) >= archive_level_min and tonumber(output_level) <= archive_level_max then
				cmd_level = type(archive_level_arg) == "table" and archive_level_arg[#archive_level_arg] .. output_level or archive_level_arg .. output_level
				local target_args = archive_compress == "" and archive_args or archive_compress_args
				if type(archive_level_arg) == "table" then
					 -- Insert each element of archive_level_arg (except last) into target_args at the correct position
					for i = 1, #archive_level_arg - 1 do
						table.insert(target_args, i, archive_level_arg[i])
					end
					table.insert(target_args, #archive_level_arg, cmd_level) -- Add level at the end
				else
					-- Insert the compression level argument at the start if not a table
					table.insert(target_args, 1, cmd_level)
				end
			else
				notify_error("Invalid level specified. Using defaults.", "warn")
			end
		end

		-- If file exists show overwrite prompt
		local output_url = combine_url(output_dir, output_name)
		while true do
			if file_exists(output_url) then
				local overwrite_answer = ya.input({
					title = "Overwrite " .. output_name .. "? y/N:",
					position = { "top-center", y = 3, w = 40 },
				})
				if overwrite_answer:lower() ~= "y" then
					notify_error("Operation canceled", "warn")
					return -- If no overwrite selected, exit
				else
					local rm_status, rm_err = os.remove(output_url)
					if not rm_status then
						notify_error(string.format("Failed to remove %s, exit code %s", output_name, rm_err), "error")
						return
					end -- If overwrite fails, exit
				end
			end
			if archive_compress ~= "" and not output_name:match("%.tar$") then
				output_name = output_name:match("(.*%.tar)") -- Test for .tar and .tar.*
				output_url = combine_url(output_dir, output_name) -- Update output_url
			else
				break
			end
		end

		-- Add to output archive in each path, their respective files
		for filepath, filenames in pairs(path_fnames) do
			local archive_status, archive_err = 
			Command(archive_cmd):arg(archive_args):arg(output_url):arg(filenames):cwd(filepath):spawn():wait()
			command_warning(archive_cmd, archive_status, archive_err)
		end

		-- Use compress command if needed
		if archive_compress ~= "" then
			local compress_status, compress_err =
			Command(archive_compress):arg(archive_compress_args):arg(output_name):cwd(output_dir):spawn():wait()
			command_warning(archive_compress, compress_status, compress_err)
		end
	end,
}
