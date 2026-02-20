local M = {}

local highlights_defined = false

local config = {
	host = "",
	user = "",
	port = 29418,
}

local function ensure_required_config()
	if not config.host or vim.trim(config.host) == "" then
		error(
			"gerrit.nvim: config.host is required. Set it with require('gerrit').setup({ host = 'gerrit.example.com' })"
		)
	end

	if not config.user or vim.trim(config.user) == "" then
		error("gerrit.nvim: config.user is required. Set it with require('gerrit').setup({ user = 'your.user' })")
	end
end

M.setup = function(opts)
	config = vim.tbl_deep_extend("force", config, opts or {})
end

local run_cmd = function(args)
	ensure_required_config()
	local ssh_target = string.format("%s@%s", config.user, config.host)

	local cmd = {
		"ssh",
		"-q",
		"-p",
		tostring(config.port),
		ssh_target,
	}
	vim.list_extend(cmd, args)
	local result = vim.system(cmd, { text = true }):wait()

	if result.code ~= 0 then
		error(result.stderr)
	end

	return result.stdout
end

local open_changes = function()
	local output = run_cmd({
		"gerrit",
		"query",
		"is:open ((reviewer:self NOT owner:self NOT is:ignored) OR assignee:self) NOT is:wip",
		"--current-patch-set",
		"--format=JSON",
	})

	local changes = {}

	for line in output:gmatch("[^\r\n]+") do
		local ok, decoded = pcall(vim.json.decode, line)
		if ok and decoded.project then
			table.insert(changes, decoded)
		end
	end

	return changes
end

local function collect_votes(change)
	local votes = {
		["Code-Review"] = {},
		["Verified"] = {},
	}

	local approvals = change.currentPatchSet and change.currentPatchSet.approvals or {}

	for _, approval in ipairs(approvals) do
		local t = approval.type
		local v = tonumber(approval.value)

		if votes[t] then
			table.insert(votes[t], v)
		end
	end

	return votes
end

local function aggregate_code_review(values)
	if #values == 0 then
		return 0
	end

	-- If any -2 exists, return -2 immediately
	for _, v in ipairs(values) do
		if v == -2 then
			return -2
		end
	end

	-- Otherwise return highest vote
	local max = values[1]
	for _, v in ipairs(values) do
		if v > max then
			max = v
		end
	end

	return max
end

local function aggregate_verified(values)
	if #values == 0 then
		return 0
	end

	-- Verified uses worst (minimum)
	local min = values[1]
	for _, v in ipairs(values) do
		if v < min then
			min = v
		end
	end

	return min
end

local function build_labels_state(change)
	local votes = collect_votes(change)

	local cr = aggregate_code_review(votes["Code-Review"])
	local verified = aggregate_verified(votes["Verified"])

	local function score_hl(v)
		if v >= 2 then
			return "GerritScorePlus2"
		end
		if v == 1 then
			return "GerritScorePlus1"
		end
		if v == 0 then
			return "GerritScoreZero"
		end
		if v == -1 then
			return "GerritScoreMinus1"
		end
		return "GerritScoreMinus2"
	end

	local function fmt(v)
		if v == 0 then
			return "·"
		end
		if v > 0 then
			return "+" .. tostring(v)
		end
		return tostring(v)
	end

	return {
		cr_text = string.format("%2s", fmt(cr)),
		cr_hl = score_hl(cr),
		verified_text = string.format("%2s", fmt(verified)),
		verified_hl = score_hl(verified),
	}
end

local pickers = require("telescope.pickers")
local finders = require("telescope.finders")
local entry_display = require("telescope.pickers.entry_display")
local conf = require("telescope.config").values
local actions = require("telescope.actions")
local action_state = require("telescope.actions.state")

local function ensure_highlights()
	if highlights_defined then
		return
	end

	vim.api.nvim_set_hl(0, "GerritScorePlus2", { fg = "#22c55e", bold = true })
	vim.api.nvim_set_hl(0, "GerritScorePlus1", { fg = "#86efac" })
	vim.api.nvim_set_hl(0, "GerritScoreZero", { fg = "#9ca3af" })
	vim.api.nvim_set_hl(0, "GerritScoreMinus1", { fg = "#fca5a5" })
	vim.api.nvim_set_hl(0, "GerritScoreMinus2", { fg = "#ef4444", bold = true })

	highlights_defined = true
end

local pick_change = function()
	ensure_highlights()
	print("Loading changes...")
	local changes = open_changes()
	print("")
	local displayer = entry_display.create({
		separator = " ",
		items = {
			{ width = 2 },
			{ width = 2 },
			{ width = 2 },
			{ width = 1 },
			{ width = 1 },
			{ width = 7 },
			{ width = 1 },
			{ width = 28 },
			{ width = 1 },
			{ remaining = true },
		},
	})

	pickers
		.new({}, {
			prompt_title = "Gerrit Open Changes",

			finder = finders.new_table({
				results = changes,
				entry_maker = function(entry)
					local labels_state = build_labels_state(entry)
					return {
						value = entry,
						display = function()
							return displayer({
								{ labels_state.cr_text, labels_state.cr_hl },
								{ "CR", "Comment" },
								{ labels_state.verified_text, labels_state.verified_hl },
								{ "V", "Comment" },
								{ "|", "Comment" },
								tostring(entry.number),
								{ "|", "Comment" },
								entry.project,
								{ "|", "Comment" },
								entry.subject,
							})
						end,
						ordinal = entry.subject,
					}
				end,
			}),

			sorter = conf.generic_sorter({}),

			attach_mappings = function(prompt_bufnr)
				actions.select_default:replace(function()
					actions.close(prompt_bufnr)
					local selection = action_state.get_selected_entry()
					local change = selection.value
					vim.ui.open(string.format("%s/c/%s/+/%s", config.host, change.project, change.number))
				end)

				return true
			end,
		})
		:find()
end

vim.api.nvim_create_user_command("Gerrit", function()
	pick_change()
end, {})
return M
