-- Check for windows
local is_windows = ya.target_family() == "windows"
-- Define flags and strings
local is_password, is_encrypted, is_level, cmd_password, cmd_level = false, false, false, "", ""

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
		unix = { command = "zip", args = { "-r" }, level_arg = "-", passwordable = true },
		windows = { command = "7z", args = { "a", "-tzip" }, level_arg = "-mx=", passwordable = true },
	},
	["%.7z$"] = {
		unix = { command = { "7z", "7zz" }, args = { "a" }, level_arg = "-mx=", header_arg = "-mhe=on", passwordable = true },
		windows = { command = "7z", args = { "a" }, level_arg = "-mx=", header_arg = "-mhe=on", passwordable = true },
	},
	["%.tar.gz$"] = {
		unix = { command = "tar", args = { "rpf" }, level_arg = "-", compress = "gzip" },
		windows = {
			command = "tar",
			args = { "rpf" },
			level_arg = "-mx=",
			compress = "7z",
			compress_args = { "a", "-tgzip", "-sdel" },
		},
	},
	["%.tar.xz$"] = {
		unix = { command = "tar", args = { "rpf" }, level_arg = "-", compress = "xz" },
		windows = {
			command = "tar",
			args = { "rpf" },
			level_arg = "-mx=",
			compress = "7z",
			compress_args = { "a", "-txz", "-sdel" },
		},
	},
	["%.tar.bz2$"] = {
		unix = { command = "tar", args = { "rpf" }, level_arg = "-", compress = "bzip2" },
		windows = {
			command = "tar",
			args = { "rpf" },
			level_arg = "-mx=",
			compress = "7z",
			compress_args = { "a", "-tbzip2", "-sdel" },
		},
	},
	["%.tar.zst$"] = {
		unix = { command = "tar", args = { "rpf" }, compress = "zstd", compress_args = { "--rm" } },
		windows = { command = "tar", args = { "rpf" }, compress = "zstd", compress_args = { "--rm" } },
	},
	["%.tar$"] = {
		unix = { command = "tar", args = { "rpf" } },
		windows = { command = "tar", args = { "rpf" } },
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
		ya.manager_emit("escape", { visual = true })
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

		-- Match user input to archive command
		local archive_cmd, archive_args, archive_compress, archive_level_arg, archive_header_arg, archive_passwordable, archive_compress_args
		for pattern, cmd_pair in pairs(archive_commands) do
			if output_name:match(pattern) then
				local os_cmd = is_windows and cmd_pair.windows or cmd_pair.unix
				archive_cmd = os_cmd.command
				archive_args = os_cmd.args
				archive_compress = os_cmd.compress or ""
				archive_level_arg = is_level and os_cmd.level_arg or ""
				archive_header_arg = is_encrypted and os_cmd.header_arg or ""
				archive_passwordable = os_cmd.passwordable or false
				archive_compress_args = os_cmd.compress_args or {}
			end
		end

		-- 7z needs to know tar archive to delete after compression
		if archive_compress_args[3] == "-sdel" then
			table.insert(archive_compress_args, output_name)
		end

		-- Check if archive command has multiple names
		if type(archive_cmd) == "table" then
			archive_cmd = find_binary(archive_cmd)
		end

		-- Check if no archive command is available for the extension
		if not archive_cmd then
			notify_error("Unsupported file extension", "error")
			return
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
				table.insert(archive_args, cmd_password)
			end
		end

		-- Add header arg if selected
		if is_encrypted and archive_header_arg ~= "" then
			table.insert(archive_args, archive_header_arg)
		end

		-- Add level arg if selected
		if archive_level_arg ~= "" and is_level then
			local output_level, event = ya.input({
				title = "Enter compression level (0 - 9):",
				position = { "top-center", y = 3, w = 40 },
			})
			if event ~= 1 then
				return
			end
			-- Make sure this string is a single digit. False if using tar & compression level is 0 (defeats the purpose of using compression).
			if output_level ~= "" and tonumber(output_level) ~= nil and string.len(output_level) == 1 and not ( archive_cmd == "tar" and output_level == "0" ) then
				cmd_level = archive_level_arg .. output_level
			end
			-- Decide if level will be used for compression command or archive command
			if archive_compress == "" then
				table.insert(archive_args, cmd_level)
			else
				table.insert(archive_compress_args, cmd_level)
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
