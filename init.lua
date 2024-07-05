-- Send error notification
local function notify_error(message, urgency)
	ya.notify({
		title = "Archive",
		content = message,
		level = urgency,
		timeout = 5,
	})
end

-- Make list of selected or hovered urls
local selected_or_hovered = ya.sync(function()
	local first_dir
	local tab, paths, names, is_same_dir = cx.active, {}, {}, true
	for _, u in pairs(tab.selected) do
		if not first_dir then
			first_dir = u:parent()
		elseif first_dir ~= u:parent() then
			is_same_dir = false
		end -- Check if all selected files share the same parent directory
		paths[#paths + 1] = tostring(u)
		names[#names + 1] = tostring(u:name()) -- Create a list of file urls and names
	end
	if #paths == 0 and tab.current.hovered then
		paths[1] = tostring(tab.current.hovered.name)
		names[1] = tostring(tab.current.hovered.name)
    first_dir = tostring(tab.current.hovered.url:parent())
	end
	if is_same_dir then
		return names, is_same_dir, tostring(first_dir)
	end
  if tab.current.hovered then
    first_dir = tostring(tab.current.hovered.url:parent())
  end
	return paths, is_same_dir, tostring(first_dir) -- Return full paths if parent directories do not match
end)

-- Check if archive command is available
local function is_command_available(cmd)
	local stat_cmd = string.format("command -v %s >/dev/null 2>&1", cmd)
	local cmd_exists = os.execute(stat_cmd)
	if cmd_exists then
		return true
	else
		notify_error(string.format("%s not available", cmd), "error")
		return false
	end
end

return {
	entry = function()
		-- Exit visual mode
		ya.manager_emit("escape", { visual = true })

		-- Get selected files
		local urls, is_same_dir, working_dir = selected_or_hovered()
		if #urls == 0 then
			notify_error("No file selected", "error")
			return
		end

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
			["%.zip$"] = { command = "zip", arg = "-r" },
			["%.7z$"] = { command = "7z", arg = "a" },
			["%.rar$"] = { command = "rar", arg = "a" },
			["%.tar.gz$"] = { command = "tar", arg = "czf" },
			["%.tar.bz2$"] = { command = "tar", arg = "cjf" },
			["%.tar.xz$"] = { command = "tar", arg = "cJf" },
			["%.tar$"] = { command = "tar", arg = "cpf" },
		}

		-- Match user input to archive command
		local archive_cmd, archive_arg
		for pattern, cmd_pair in pairs(archive_commands) do
			if output_name:match(pattern) then
				if is_command_available(cmd_pair.command) then
					archive_cmd = cmd_pair.command
					archive_arg = cmd_pair.arg
				end
			end
		end

		-- Check if no archive command is available for the extention
		if not archive_cmd or not archive_arg then
			notify_error("Unsupported file type", "error")
			return
		end

		-- Tar will overwrite archive, other commands will add files
		local title
		if archive_cmd == "tar" then
			title = "Overwrite an existing file y/N:"
		else
			title = "Add to an existing archive y/N:"
		end

		-- If file exists show overwrite prompt
		local test_status = Command("test"):arg("!"):arg("-f"):arg(output_name):cwd(working_dir):spawn():wait()
		if not test_status or not test_status.success then
			local overwrite_answer = ya.input({
				title = title,
				position = { "top-center", y = 3, w = 40 },
			})
			if overwrite_answer:lower() ~= "y" then
				notify_error("Operation canceled", "warn")
				return
			end
		end

		-- If all files share the same directory, no copying is required
		if is_same_dir then
			-- Archive files
			local archive_status, archive_err =
				Command(archive_cmd):arg(archive_arg):arg(output_name):args(urls):cwd(working_dir):spawn():wait()
			if not archive_status or not archive_status.success then
				notify_error(
					string.format(
						"%s with selected files failed, exit code %s",
						archive_arg,
						archive_status and archive_status.code or archive_err
					),
					"error"
				)
			end
			return
		end

		-- Create directory
		local mkdir_status, mkdir_err = Command("mkdir"):arg("-p"):cwd(working_dir):arg(".tempzip/"):spawn():wait()
		if not mkdir_status or not mkdir_status.success then
			notify_error(
				string.format("Mkdir failed, exit code %s", mkdir_status and mkdir_status.code or mkdir_err),
				"error"
			)
			return
		end

		-- Copy files
		local copy_status, copy_err = Command("cp"):arg("-rt"):arg(".tempzip/"):args(urls):cwd(working_dir):spawn():wait()
		if not copy_status or not copy_status.success then
			notify_error(
				string.format("Copy with %s failed, exit code %s", urls, copy_status and copy_status.code or copy_err),
				"error"
			)
			return
		end

		-- Archive files
		local archive_status, archive_err = Command(archive_cmd)
			:arg(archive_arg)
			:arg(string.format("../%s", output_name))
			:arg(".")
			:cwd(working_dir .. "/.tempzip/")
			:spawn()
			:wait()
		if not archive_status or not archive_status.success then
			notify_error(
				string.format(
					"%s with selected files failed, exit code %s",
					archive_arg,
					archive_status and archive_status.code or archive_err
				),
				"error"
			)
		end

		-- Remove temporary files
		local rm_status, rm_err = Command("rm"):arg("-rf"):arg(".tempzip/"):cwd(working_dir):spawn():wait()
		if not rm_status or not rm_status.success then
			notify_error(
				string.format("Remove .tempzip/ directory failed, exit code %s", rm_status and rm_status.code or rm_err),
				"error"
			)
		end
	end,
}
