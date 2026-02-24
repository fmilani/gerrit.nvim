local M = {}

local highlights_defined = false
local diff_ref_cache = {}
local comment_ns = vim.api.nvim_create_namespace("gerrit.nvim.comments")
local comment_store_by_buf = {}

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

local run_cmd = function(args, stdin)
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
	local result = vim.system(cmd, { text = true, stdin = stdin }):wait()

	if result.code ~= 0 then
		error(result.stderr)
	end

	return result.stdout
end

local function get_comment_store(buf)
	if not comment_store_by_buf[buf] then
		comment_store_by_buf[buf] = {}
	end
	return comment_store_by_buf[buf]
end

local function reset_comment_store(buf)
	comment_store_by_buf[buf] = {}
	vim.api.nvim_buf_clear_namespace(buf, comment_ns, 0, -1)
end

local function add_or_update_inline_comment(buf, line_nr, message)
	local store = get_comment_store(buf)
	local existing_marks = vim.api.nvim_buf_get_extmarks(buf, comment_ns, { line_nr - 1, 0 }, { line_nr - 1, -1 }, {})
	for _, mark in ipairs(existing_marks) do
		vim.api.nvim_buf_del_extmark(buf, comment_ns, mark[1])
		store[mark[1]] = nil
	end

	local id = vim.api.nvim_buf_set_extmark(buf, comment_ns, line_nr - 1, 0, {
		virt_lines = {
			{ { ">> " .. message, "Comment" } },
		},
		virt_lines_above = false,
	})
	store[id] = message
end

local function clear_inline_comment(buf, line_nr)
	local store = get_comment_store(buf)
	local marks = vim.api.nvim_buf_get_extmarks(buf, comment_ns, { line_nr - 1, 0 }, { line_nr - 1, -1 }, {})
	local removed = false
	for _, mark in ipairs(marks) do
		removed = true
		vim.api.nvim_buf_del_extmark(buf, comment_ns, mark[1])
		store[mark[1]] = nil
	end
	return removed
end

local function inline_comment_on_line(buf, line_nr)
	local store = get_comment_store(buf)
	local marks = vim.api.nvim_buf_get_extmarks(buf, comment_ns, { line_nr - 1, 0 }, { line_nr - 1, -1 }, {})
	if #marks == 0 then
		return nil, nil
	end

	local id = marks[1][1]
	return id, store[id]
end

local function build_diff_line_map(lines)
	local line_map = {}
	local current_file = nil
	local old_line = nil
	local new_line = nil

	for idx, line in ipairs(lines) do
		local hunk_old, hunk_new = line:match("^@@ %-(%d+),?%d* %+(%d+),?%d* @@")
		if hunk_old and hunk_new then
			old_line = tonumber(hunk_old)
			new_line = tonumber(hunk_new)
		elseif line:match("^diff %-%-git ") then
			current_file = nil
			old_line = nil
			new_line = nil
		else
			local next_file = line:match("^%+%+%+ b/(.+)$")
			if next_file then
				current_file = next_file
			elseif line == "+++ /dev/null" then
				current_file = nil
			elseif old_line and new_line then
				local prefix = line:sub(1, 1)
				if prefix == "+" and not line:match("^%+%+%+") then
					line_map[idx] = { path = current_file, line = new_line }
					new_line = new_line + 1
				elseif prefix == " " then
					line_map[idx] = { path = current_file, line = new_line }
					old_line = old_line + 1
					new_line = new_line + 1
				elseif prefix == "-" and not line:match("^%-%-%-") then
					old_line = old_line + 1
				end
			end
		end
	end

	return line_map
end

local function add_inline_comment_from_cursor(buf)
	local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	local line_map = build_diff_line_map(lines)
	local cursor = vim.api.nvim_win_get_cursor(0)
	local line_nr = cursor[1]
	local anchor = line_map[line_nr]

	if not anchor or not anchor.path or not anchor.line then
		vim.notify("gerrit.nvim: place cursor on an added/context diff line", vim.log.levels.WARN)
		return
	end

	local _, existing_message = inline_comment_on_line(buf, line_nr)
	vim.ui.input({
		prompt = existing_message and "Edit inline comment: " or "Inline comment: ",
		default = existing_message or "",
	}, function(input)
		if input == nil then
			return
		end
		local message = vim.trim(input)
		if message == "" then
			if existing_message then
				clear_inline_comment(buf, line_nr)
				vim.notify("gerrit.nvim: inline comment cleared", vim.log.levels.INFO)
			end
			return
		end
		add_or_update_inline_comment(buf, line_nr, message)
		vim.notify(existing_message and "gerrit.nvim: inline comment updated" or "gerrit.nvim: inline comment added", vim.log.levels.INFO)
	end)
end

local function clear_inline_comment_from_cursor(buf)
	local line_nr = vim.api.nvim_win_get_cursor(0)[1]
	if clear_inline_comment(buf, line_nr) then
		vim.notify("gerrit.nvim: inline comment cleared", vim.log.levels.INFO)
	else
		vim.notify("gerrit.nvim: no inline comment on this line", vim.log.levels.WARN)
	end
end

local function submit_comments_from_buffer(buf, code_review_vote)
	local revision = vim.b[buf].gerrit_revision
	if not revision or revision == "" then
		vim.notify("gerrit.nvim: current buffer has no Gerrit revision metadata", vim.log.levels.ERROR)
		return
	end

	local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	local line_map = build_diff_line_map(lines)
	local store = get_comment_store(buf)
	local extmarks = vim.api.nvim_buf_get_extmarks(buf, comment_ns, 0, -1, {})
	local comments = {}
	local unresolved = 0
	local resolved_mark_ids = {}
	local total = 0

	for _, mark in ipairs(extmarks) do
		local id = mark[1]
		local row = mark[2]
		local message = store[id]
		if message and message ~= "" then
			local anchor = line_map[row + 1]
			if anchor and anchor.path and anchor.line then
				comments[anchor.path] = comments[anchor.path] or {}
				table.insert(comments[anchor.path], {
					line = anchor.line,
					message = message,
				})
				table.insert(resolved_mark_ids, id)
				total = total + 1
			else
				unresolved = unresolved + 1
			end
		end
	end

	if unresolved > 0 then
		vim.notify(
			string.format("gerrit.nvim: %d comment(s) could not be mapped to a diff line", unresolved),
			vim.log.levels.WARN
		)
	end

	local payload_table = {}
	if total > 0 then
		payload_table.comments = comments
	end
	if code_review_vote ~= nil then
		payload_table.labels = {
			["Code-Review"] = code_review_vote,
		}
	end

	if payload_table.comments == nil and payload_table.labels == nil then
		vim.notify("gerrit.nvim: nothing to submit", vim.log.levels.WARN)
		return
	end

	local payload = vim.json.encode(payload_table)
	run_cmd({ "gerrit", "review", "--json", revision }, payload)

	for _, id in ipairs(resolved_mark_ids) do
		vim.api.nvim_buf_del_extmark(buf, comment_ns, id)
		store[id] = nil
	end

	local vote_msg = code_review_vote ~= nil and string.format("CR %s", code_review_vote > 0 and ("+" .. code_review_vote) or tostring(code_review_vote))
		or "no vote"
	vim.notify(string.format("gerrit.nvim: submitted %d comment(s), %s", total, vote_msg), vim.log.levels.INFO)
end

local function submit_with_vote_prompt(buf)
	local options = {
		{ label = "0", vote = 0 },
		{ label = "-2", vote = -2 },
		{ label = "-1", vote = -1 },
		{ label = "+1", vote = 1 },
		{ label = "+2", vote = 2 },
	}

	vim.ui.select(options, {
		prompt = "Code-Review vote:",
		format_item = function(item)
			return item.label
		end,
	}, function(choice)
		if not choice then
			return
		end
		submit_comments_from_buffer(buf, choice.vote)
	end)
end

local function submit_change_from_buffer(buf)
	local revision = vim.b[buf].gerrit_revision
	if not revision or revision == "" then
		vim.notify("gerrit.nvim: current buffer has no Gerrit revision metadata", vim.log.levels.ERROR)
		return
	end

	run_cmd({ "gerrit", "review", "--submit", revision })
	vim.notify("gerrit.nvim: change submitted", vim.log.levels.INFO)

	if vim.b[buf].gerrit_review_view then
		local wins = vim.fn.win_findbuf(buf)
		if #wins > 0 and vim.api.nvim_win_is_valid(wins[1]) then
			vim.api.nvim_win_close(wins[1], false)
		end
	end
end

local function parse_code_review_vote(token)
	if token == nil or token == "" then
		return true, nil
	end

	local map = {
		["0"] = 0,
		["-2"] = -2,
		["-1"] = -1,
		["+1"] = 1,
		["1"] = 1,
		["+2"] = 2,
		["2"] = 2,
	}

	local vote = map[token]
	if vote == nil then
		return false, nil
	end

	return true, vote
end

local function change_ref(change)
	local patchset = change.currentPatchSet
	if not patchset then
		return nil
	end

	if patchset.ref and patchset.ref ~= "" then
		return patchset.ref
	end

	if not patchset.number then
		return nil
	end

	local two_digits = string.format("%02d", tonumber(change.number) % 100)
	return string.format("refs/changes/%s/%s/%s", two_digits, change.number, patchset.number)
end

local function cache_key(change)
	local patchset = change.currentPatchSet or {}
	local revision = patchset.revision or ""
	return table.concat({ change.project or "", tostring(change.number or ""), tostring(patchset.number or ""), revision }, "|")
end

local function sanitize_ref_component(value)
	return tostring(value):gsub("[^%w%._%-%/]", "-")
end

local function local_diff_ref(change)
	local patchset = change.currentPatchSet or {}
	return string.format(
		"refs/gerrit-nvim/%s/%s/%s",
		sanitize_ref_component(change.project or "unknown"),
		sanitize_ref_component(change.number or "unknown"),
		sanitize_ref_component(patchset.number or "latest")
	)
end

local function has_local_ref(ref)
	local check = vim.system({ "git", "rev-parse", "--verify", "--quiet", ref .. "^{commit}" }, { text = true }):wait()
	return check.code == 0
end

local function open_change_diff(change)
	ensure_required_config()

	local ref = change_ref(change)
	if not ref then
		vim.notify("gerrit.nvim: missing patchset ref", vim.log.levels.ERROR)
		return
	end

	local key = cache_key(change)
	local target_ref = diff_ref_cache[key]
	if not target_ref or not has_local_ref(target_ref) then
		target_ref = local_diff_ref(change)
		local remote = string.format("ssh://%s@%s:%s/%s", config.user, config.host, config.port, change.project)
		local refspec = string.format("+%s:%s", ref, target_ref)
		local fetch = vim.system({ "git", "fetch", "--quiet", remote, refspec }, { text = true }):wait()
		if fetch.code ~= 0 then
			vim.notify(fetch.stderr or "gerrit.nvim: git fetch failed", vim.log.levels.ERROR)
			return
		end
		diff_ref_cache[key] = target_ref
	end

	local show = vim.system({ "git", "show", "--no-color", target_ref }, { text = true }):wait()
	if show.code ~= 0 then
		vim.notify(show.stderr or "gerrit.nvim: git show failed", vim.log.levels.ERROR)
		return
	end

	vim.cmd("tabnew")
	local buf = vim.api.nvim_create_buf(true, true)
	vim.api.nvim_set_current_buf(buf)
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].swapfile = false
	vim.bo[buf].filetype = "diff"

	local lines = vim.split(show.stdout, "\n", { plain = true })
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modifiable = false
	vim.bo[buf].readonly = true
	reset_comment_store(buf)
	local patchset_number = change.currentPatchSet and change.currentPatchSet.number or "latest"
	vim.api.nvim_buf_set_name(buf, string.format("gerrit://%s/%s.diff", tostring(change.number), tostring(patchset_number)))
	vim.b[buf].gerrit_revision = change.currentPatchSet and change.currentPatchSet.revision or ""
	vim.b[buf].gerrit_review_view = true
	vim.keymap.set("n", "gc", function()
		add_inline_comment_from_cursor(buf)
	end, { buffer = buf, silent = true, desc = "Add Gerrit inline comment" })
	vim.keymap.set("n", "gC", function()
		clear_inline_comment_from_cursor(buf)
	end, { buffer = buf, silent = true, desc = "Clear Gerrit inline comment" })
	vim.keymap.set("n", "gr", function()
		submit_with_vote_prompt(buf)
	end, { buffer = buf, silent = true, desc = "Send Gerrit review" })
	vim.keymap.set("n", "gs", function()
		submit_change_from_buffer(buf)
	end, { buffer = buf, silent = true, desc = "Submit Gerrit change" })
	vim.notify("gerrit.nvim: gc add/edit comment, gC clear, gr review, gs submit", vim.log.levels.INFO)
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
			{ width = 48 },
			{ width = 1 },
			{ width = 24 },
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
								entry.subject,
								{ "|", "Comment" },
								entry.project,
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
					open_change_diff(change)
				end)

				vim.keymap.set({ "i", "n" }, "<C-o>", function()
					local selection = action_state.get_selected_entry()
					if not selection or not selection.value then
						return
					end
					vim.ui.open(string.format("%s/c/%s/+/%s", config.host, selection.value.project, selection.value.number))
				end, { buffer = prompt_bufnr })

				return true
			end,
		})
		:find()
end

vim.api.nvim_create_user_command("Gerrit", function(opts)
	local fargs = opts.fargs or {}
	local subcommand = fargs[1] and vim.trim(fargs[1]) or ""
	if subcommand == "" then
		pick_change()
		return
	end

	if subcommand == "review" then
		local vote_token = fargs[2] and vim.trim(fargs[2]) or nil
		if vote_token ~= nil and vote_token ~= "" then
			local ok, vote = parse_code_review_vote(vote_token)
			if not ok then
				vim.notify("gerrit.nvim: invalid vote. Use 0, -2, -1, +1, +2", vim.log.levels.ERROR)
				return
			end
			submit_comments_from_buffer(vim.api.nvim_get_current_buf(), vote)
			return
		end
		submit_with_vote_prompt(vim.api.nvim_get_current_buf())
		return
	end

	if subcommand == "submit" then
		submit_change_from_buffer(vim.api.nvim_get_current_buf())
		return
	end

	vim.notify("gerrit.nvim: unknown subcommand '" .. subcommand .. "'", vim.log.levels.ERROR)
end, {
	nargs = "*",
	complete = function(_, cmdline)
		if cmdline:match("^%s*Gerrit%s+review%s+") then
			return { "0", "-2", "-1", "+1", "+2" }
		end
		return { "review", "submit" }
	end,
})

return M
