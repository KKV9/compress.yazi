-- Check for windows
local is_windows = ya.target_family() == "windows"
-- Define flags
local is_password, is_encrypted, is_level = false, false, false

-- Send error notification
local function notify_error(message, urgency)
	ya.notify({
		title = "Archive",
		content = message,
		level = urgency,
		timeout = 5,
	})
end

-- Make table of selected or hovered: path = filenames
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

-- Check if archive command is available
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

-- Archive command list --> string
local function find_binary(cmd_list)
	for _, cmd in ipairs(cmd_list) do
		if is_command_available(cmd) then
			return cmd
		end
	end
	return cmd_list[1] -- Return first command as fallback
end

-- Check if file exists
local function file_exists(name)
	local f = io.open(name, "r")
	if f ~= nil then
		io.close(f)
		return true
	else
		return false
	end
end

-- Append filename to it's parent directory
local function combine_url(path, file)
	path, file = Url(path), Url(file)
	return tostring(path:join(file))
end

return {
	entry = function(_, job)
		-- Check if password is needed. Search for char in arguments string
		if job.args[1] ~= nil then
			is_password = string.find(tostring(job.args[1]), "p") ~= nil
			is_encrypted = string.find(tostring(job.args[1]), "h") ~= nil
			is_level = string.find(tostring(job.args[1]), "l") ~= nil
		end

		-- Exit visual mode
		ya.manager_emit("escape", { visual = true })

		-- Define file table and output_dir (pwd)
		local path_fnames, output_dir = selected_or_hovered()

		-- Get input
		local output_name, event = ya.input({
			title = "Create archive:",
			position = { "top-center", y = 3, w = 40 },
		})
		if event ~= 1 then
			return
		end

		-- Use appropriate archive command
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
					compress = "7z",
					compress_args = { "a", "-tgzip", "-sdel", output_name },
				},
			},
			["%.tar.xz$"] = {
				unix = { command = "tar", args = { "rpf" }, level_arg = "-", compress = "xz" },
				windows = {
					command = "tar",
					args = { "rpf" },
					compress = "7z",
					compress_args = { "a", "-txz", "-sdel", output_name },
				},
			},
			["%.tar.bz2$"] = {
				unix = { command = "tar", args = { "rpf" }, level_arg = "-", compress = "bzip2" },
				windows = {
					command = "tar",
					args = { "rpf" },
					compress = "7z",
					compress_args = { "a", "-tbzip2", "-sdel", output_name },
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

		-- Match user input to archive command
		local archive_cmd, archive_args, archive_compress, archive_level_arg, archive_header_arg, archive_passwordable, archive_compress_args
		for pattern, cmd_pair in pairs(archive_commands) do
			if output_name:match(pattern) then
				if is_windows then
					archive_cmd = cmd_pair.windows.command
					archive_args = cmd_pair.windows.args
					archive_compress = cmd_pair.windows.compress or ""
					archive_level_arg = is_level and cmd_pair.windows.level_arg or ""
					archive_header_arg = is_encrypted and cmd_pair.windows.header_arg or ""
					archive_passwordable = cmd_pair.windows.passwordable or false
					archive_compress_args = cmd_pair.windows.compress_args or {}
				else
					archive_cmd = cmd_pair.unix.command
					archive_args = cmd_pair.unix.args
					archive_compress = cmd_pair.unix.compress or ""
					archive_level_arg = is_level and cmd_pair.unix.level_arg or ""
					archive_header_arg = is_encrypted and cmd_pair.unix.header_arg or ""
					archive_passwordable = cmd_pair.unix.passwordable or false
					archive_compress_args = cmd_pair.unix.compress_args or {}
				end
			end
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

		local archive_additional_args = {}
		local compress_additional_args = {}

		-- Get password if selected
		local cmd_password = ""
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
				table.insert(archive_additional_args, cmd_password)
			end
		end

		if is_encrypted and archive_header_arg ~= "" then
			table.insert(archive_additional_args, archive_header_arg)
		end

		-- Get level if selected
		local cmd_level = ""
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
				table.insert(archive_additional_args, cmd_level)
			end
			-- Decide if level will be used for comrpession command or archive command
			if cmd_level ~= "" and archive_level_arg ~= "" and archive_compress ~= "" then
				compress_additional_args = { cmd_level }
			end
		end

		-- Add to output archive in each path, their respective files
		for path, names in pairs(path_fnames) do
			local archive_status, archive_err = 
			Command(archive_cmd):arg(archive_args):arg(archive_additional_args):arg(output_url):arg(names):cwd(path):spawn():wait()
			if not archive_status or not archive_status.success then
				notify_error(
					string.format(
						"%s with selected files failed, exit code %s",
						archive_cmd,
						archive_status and archive_status.code or archive_err
					),
					"error"
				)
			end
		end

		-- Use compress command if needed
		if archive_compress ~= "" then
			local compress_status, compress_err =
				Command(archive_compress):arg(archive_compress_args):arg(compress_additional_args):arg(output_name):cwd(output_dir):spawn():wait()
					if not compress_status or not compress_status.success then
						notify_error(
						string.format(
							"%s with %s failed, exit code %s",
							archive_compress,
							output_name,
							compress_status and compress_status.code or compress_err
						),
						"error"
					)
			end
		end
	end,
}
