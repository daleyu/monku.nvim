-- monku.nvim: leave review comments on code, then hand them to a coding agent.
--
-- Comments are anchored with extmarks (so they follow edits), persisted per project as JSON, shown inline
-- below the commented lines, and delivered either to an agent pane in the current Herdr workspace or to the
-- clipboard.

local api = vim.api

local M = {}

local config = {
        herdr_bin = vim.env.HERDR_BIN_PATH or "herdr",
        -- Expand a comment inline while the cursor is on one of its lines.
        auto_expand = true,
        -- Drop the comments once the agent has accepted them.
        clear_on_submit = true,
        sign = "▍",
        -- Foreground colors: the gutter sign, the bar beside an inline comment, and the comment text.
        colors = {
                sign = "#7287b8",
                border = "#7287b8",
                text = "#8c9bc4",
        },
        max_snippet_lines = 30,
        intro = "Please address the following %d code review comment(s). Paths are relative to %s. "
                .. "The quoted code is what each comment is anchored to.",
}

local ns = api.nvim_create_namespace("monku/anchors")
local ns_view = api.nvim_create_namespace("monku/view")
local ns_picker = api.nvim_create_namespace("monku/picker")
local ns_input = api.nvim_create_namespace("monku/input")

---@class MonkuComment
---@field id integer
---@field file string path relative to the project root; "" for a general comment
---@field lnum integer
---@field end_lnum integer
---@field text string
---@field snippet string[]

---@type table<string, { comments: MonkuComment[], next_id: integer }>
local stores = {}
---@type table<integer, { root: string, file: string, marks: table<integer, integer>, hover: integer? }>
local bufs = {}
local expand_all = false

local function notify(msg, level)
        vim.notify(msg, level or vim.log.levels.INFO, { title = "monku" })
end

-- Storage -------------------------------------------------------------------------------------------------

local function realpath(path)
        return vim.fs.normalize(vim.uv.fs_realpath(path) or path)
end

local function root_for(path)
        return realpath(vim.fs.root(path, ".git") or vim.fn.getcwd())
end

local function store_path(root)
        return ("%s/monku/%s.json"):format(vim.fn.stdpath("data"), vim.fn.sha256(root):sub(1, 16))
end

local function load_store(root)
        if stores[root] then
                return stores[root]
        end
        local store = { comments = {}, next_id = 1 }
        local fd = io.open(store_path(root), "r")
        if fd then
                local ok, data = pcall(vim.json.decode, fd:read("*a"))
                fd:close()
                if ok and type(data) == "table" and type(data.comments) == "table" then
                        store.comments = data.comments
                        store.next_id = data.next_id or (#data.comments + 1)
                end
        end
        stores[root] = store
        return store
end

local function save_store(root)
        local store = stores[root]
        if not store then
                return
        end
        local path = store_path(root)
        if #store.comments == 0 then
                os.remove(path)
                return
        end
        vim.fn.mkdir(vim.fs.dirname(path), "p")
        local fd = assert(io.open(path, "w"))
        fd:write(vim.json.encode({ root = root, comments = store.comments, next_id = store.next_id }))
        fd:close()
end

local function sorted_comments(root)
        local comments = vim.list_extend({}, load_store(root).comments)
        table.sort(comments, function(a, b)
                if a.file ~= b.file then
                        return a.file < b.file
                end
                if a.lnum ~= b.lnum then
                        return a.lnum < b.lnum
                end
                return a.id < b.id
        end)
        return comments
end

-- Anchors -------------------------------------------------------------------------------------------------

local function mark_range(buf, mark)
        local pos = api.nvim_buf_get_extmark_by_id(buf, ns, mark, { details = true })
        if #pos == 0 then
                return nil
        end
        local s = pos[1] + 1
        return s, math.max(s, (pos[3].end_row or pos[1]) + 1)
end

local function place(buf, comment)
        local count = api.nvim_buf_line_count(buf)
        local s = math.min(math.max(comment.lnum, 1), count)
        local e = math.min(math.max(comment.end_lnum, s), count)
        bufs[buf].marks[comment.id] = api.nvim_buf_set_extmark(buf, ns, s - 1, 0, {
                end_row = e - 1,
                end_col = 0,
                sign_text = config.sign,
                sign_hl_group = "MonkuSign",
        })
end

-- Copy the live extmark positions (and the code under them) back into the stored comments.
local function sync(buf)
        local info = bufs[buf]
        if not info or not api.nvim_buf_is_loaded(buf) then
                return
        end
        for _, comment in ipairs(load_store(info.root).comments) do
                local mark = info.marks[comment.id]
                local s, e = nil, nil
                if mark then
                        s, e = mark_range(buf, mark)
                end
                if s then
                        comment.lnum, comment.end_lnum = s, e
                        comment.snippet = api.nvim_buf_get_lines(buf, s - 1, e, false)
                end
        end
end

local function sync_all()
        local roots = {}
        for buf, info in pairs(bufs) do
                if api.nvim_buf_is_valid(buf) then
                        sync(buf)
                        roots[info.root] = true
                end
        end
        for root in pairs(roots) do
                save_store(root)
        end
end

-- Rendering -----------------------------------------------------------------------------------------------

local function wrap(text, width)
        local out = {}
        for _, line in ipairs(vim.split(text, "\n", { plain = true })) do
                local cur = ""
                for word in line:gmatch("%S+") do
                        if cur == "" then
                                cur = word
                        elseif vim.fn.strdisplaywidth(cur .. " " .. word) <= width then
                                cur = cur .. " " .. word
                        else
                                out[#out + 1] = cur
                                cur = word
                        end
                end
                out[#out + 1] = cur
        end
        return out
end

-- The comment as virtual lines, indented to sit under the code it refers to.
local function comment_virt_lines(text, width, indent)
        indent = math.min(indent, math.floor(width / 3))
        local pad = (" "):rep(indent)
        local virt_lines = {}
        for _, line in ipairs(wrap(text, math.max(20, width - indent - 4))) do
                virt_lines[#virt_lines + 1] = {
                        { pad .. "┃ ", "MonkuBorder" },
                        { line, "MonkuText" },
                }
        end
        return virt_lines
end

local function render(buf)
        local info = bufs[buf]
        if not info or not api.nvim_buf_is_valid(buf) then
                return
        end
        api.nvim_buf_clear_namespace(buf, ns_view, 0, -1)

        local win = vim.fn.bufwinid(buf)
        local width = 80
        if win ~= -1 then
                width = api.nvim_win_get_width(win) - vim.fn.getwininfo(win)[1].textoff
        end

        for _, comment in ipairs(load_store(info.root).comments) do
                local mark = info.marks[comment.id]
                local s, e = nil, nil
                if mark then
                        s, e = mark_range(buf, mark)
                end
                if s and e ~= info.input_line then
                        if expand_all or (config.auto_expand and info.hover == comment.id) then
                                api.nvim_buf_set_extmark(buf, ns_view, e - 1, 0, {
                                        virt_lines = comment_virt_lines(comment.text, width, vim.fn.indent(s)),
                                })
                        end
                end
        end
end

local function buf_identity(buf)
        if not api.nvim_buf_is_valid(buf) or vim.bo[buf].buftype ~= "" then
                return nil
        end
        local name = api.nvim_buf_get_name(buf)
        if name == "" then
                return nil
        end
        local path = realpath(name)
        local root = root_for(path)
        local file = vim.fs.relpath(root, path)
        if not file then
                return nil
        end
        return root, file
end

-- (Re)create the anchors for a buffer from the stored comments.
local function attach(buf)
        local root, file = buf_identity(buf)
        if not root then
                return nil
        end
        api.nvim_buf_clear_namespace(buf, ns, 0, -1)
        bufs[buf] = { root = root, file = file, marks = {} }
        for _, comment in ipairs(load_store(root).comments) do
                if comment.file == file then
                        place(buf, comment)
                end
        end
        render(buf)
        return bufs[buf]
end

local function comment_at(buf, lnum)
        local info = bufs[buf]
        if not info then
                return nil
        end
        for _, comment in ipairs(load_store(info.root).comments) do
                local mark = info.marks[comment.id]
                if mark then
                        local s, e = mark_range(buf, mark)
                        if s and lnum >= s and lnum <= e then
                                return comment
                        end
                end
        end
end

local function update_hover(buf)
        local info = bufs[buf]
        if not info then
                return
        end
        local comment = comment_at(buf, api.nvim_win_get_cursor(0)[1])
        local id = comment and comment.id or nil
        if info.hover ~= id then
                info.hover = id
                render(buf)
        end
end

local function current_root()
        local info = bufs[api.nvim_get_current_buf()]
        return info and info.root or root_for(vim.fn.getcwd())
end

local function remove(root, id)
        local store = load_store(root)
        for i, comment in ipairs(store.comments) do
                if comment.id == id then
                        table.remove(store.comments, i)
                        break
                end
        end
        for buf, info in pairs(bufs) do
                if info.root == root and info.marks[id] and api.nvim_buf_is_valid(buf) then
                        api.nvim_buf_del_extmark(buf, ns, info.marks[id])
                        info.marks[id] = nil
                        if info.hover == id then
                                info.hover = nil
                        end
                        render(buf)
                end
        end
        save_store(root)
end

local function remove_all(root)
        load_store(root).comments = {}
        for buf, info in pairs(bufs) do
                if info.root == root and api.nvim_buf_is_valid(buf) then
                        api.nvim_buf_clear_namespace(buf, ns, 0, -1)
                        info.marks, info.hover = {}, nil
                        render(buf)
                end
        end
        save_store(root)
end

-- Input ---------------------------------------------------------------------------------------------------

local MIN_INPUT_HEIGHT, MAX_INPUT_HEIGHT = 2, 15

-- Open the comment editor. With `opts.line` it opens directly below that line of the current window, and the
-- code underneath is pushed down to make room rather than covered. Without it (a general comment) it sits
-- along the bottom edge of the window. Either way it starts small and grows with the text.
local function open_input(opts)
        local src_win = api.nvim_get_current_win()
        local src_buf = api.nvim_get_current_buf()
        local line = opts.line
        local src_view = vim.fn.winsaveview()
        local width = api.nvim_win_get_width(src_win) - vim.fn.getwininfo(src_win)[1].textoff - 2
        width = math.max(20, math.min(100, width))

        local buf = api.nvim_create_buf(false, true)
        vim.bo[buf].bufhidden = "wipe"
        vim.b[buf].completion = false
        if opts.initial then
                api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(opts.initial, "\n", { plain = true }))
        end

        local win_config = {
                relative = "win",
                win = src_win,
                width = width,
                height = MIN_INPUT_HEIGHT,
                style = "minimal",
                border = "rounded",
                title = " " .. opts.title .. " ",
                footer = " <C-s> or <CR> save · q cancel ",
        }
        local line_height, spacer = 1, nil
        if line then
                -- Hide inline comments under this line so the editor is the only thing below it.
                bufs[src_buf].input_line = line
                render(src_buf)
                line_height = api.nvim_win_text_height(src_win, { start_row = line - 1, end_row = line - 1 }).all
                win_config.bufpos = { line - 1, 0 }
                win_config.row = line_height
                win_config.col = 0
        else
                win_config.anchor = "SW"
                win_config.row = api.nvim_win_get_height(src_win)
                win_config.col = 0
        end

        -- Reserve blank rows under the line for the editor (plus its border), scrolling if they would fall
        -- below the bottom of the window.
        local function make_room(height)
                if not line then
                        return
                end
                spacer = api.nvim_buf_set_extmark(src_buf, ns_input, line - 1, 0, {
                        id = spacer,
                        virt_lines = vim.fn["repeat"]({ { { "", "Normal" } } }, height + 2),
                })
                local pos = vim.fn.screenpos(src_win, line, 1)
                if pos.row == 0 then
                        return
                end
                local bottom = pos.row - vim.fn.win_screenpos(src_win)[1] + line_height + height + 2
                local overflow = bottom - api.nvim_win_get_height(src_win)
                if overflow > 0 then
                        api.nvim_win_call(src_win, function()
                                vim.cmd("normal! " .. overflow .. vim.keycode("<C-e>"))
                        end)
                end
        end

        make_room(MIN_INPUT_HEIGHT)
        local win = api.nvim_open_win(buf, true, win_config)
        vim.wo[win].wrap = true
        vim.wo[win].linebreak = true
        -- Floats normally get their own (often opaque) background; use the editor's so it blends in.
        vim.wo[win].winhighlight =
                "NormalFloat:Normal,FloatBorder:MonkuBorder,FloatTitle:MonkuText,FloatFooter:MonkuBorder"

        local function fit()
                if not api.nvim_win_is_valid(win) then
                        return
                end
                local height = api.nvim_win_text_height(win, {}).all
                height = math.max(MIN_INPUT_HEIGHT, math.min(MAX_INPUT_HEIGHT, height))
                if height ~= api.nvim_win_get_height(win) then
                        make_room(height)
                        api.nvim_win_set_height(win, height)
                end
        end
        api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, { buffer = buf, callback = fit })
        fit()

        local closed = false
        local function close()
                if closed then
                        return
                end
                closed = true
                vim.cmd.stopinsert()
                if api.nvim_win_is_valid(win) then
                        api.nvim_win_close(win, true)
                end
                if line and api.nvim_buf_is_valid(src_buf) then
                        api.nvim_buf_clear_namespace(src_buf, ns_input, 0, -1)
                        if bufs[src_buf] then
                                bufs[src_buf].input_line = nil
                                render(src_buf)
                        end
                        if api.nvim_win_is_valid(src_win) and api.nvim_win_get_buf(src_win) == src_buf then
                                api.nvim_win_call(src_win, function()
                                        vim.fn.winrestview(src_view)
                                end)
                        end
                end
        end
        local function save()
                local text = vim.trim(table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), "\n"))
                close()
                if text ~= "" then
                        opts.on_submit(text)
                end
        end
        -- Clean up even if the window is closed some other way (:q, <C-w>c, ...).
        api.nvim_create_autocmd("WinClosed", { pattern = tostring(win), once = true, callback = close })

        vim.keymap.set({ "n", "i" }, "<C-s>", save, { buffer = buf })
        vim.keymap.set("n", "<CR>", save, { buffer = buf })
        vim.keymap.set("n", "q", close, { buffer = buf })
        vim.keymap.set("n", "<Esc>", close, { buffer = buf })
        if opts.initial then
                vim.cmd.startinsert({ bang = true })
        else
                vim.cmd.startinsert()
        end
end

-- Public API ----------------------------------------------------------------------------------------------

---Create a comment without prompting.
---@return MonkuComment?
function M.create(buf, lnum, end_lnum, text)
        local info = bufs[buf] or attach(buf)
        if not info then
                notify("This buffer is not a file, so it cannot be commented on", vim.log.levels.WARN)
                return nil
        end
        local store = load_store(info.root)
        local comment = {
                id = store.next_id,
                file = info.file,
                lnum = lnum,
                end_lnum = end_lnum,
                text = text,
                snippet = api.nvim_buf_get_lines(buf, lnum - 1, end_lnum, false),
        }
        store.next_id = store.next_id + 1
        store.comments[#store.comments + 1] = comment
        place(buf, comment)
        save_store(info.root)
        if buf == api.nvim_get_current_buf() then
                info.hover = nil
                update_hover(buf)
        end
        render(buf)
        return comment
end

---Comment on the current line, the visual selection, or an explicit line range.
function M.add(line1, line2)
        local buf = api.nvim_get_current_buf()
        if not line1 then
                line1, line2 = vim.fn.line("."), vim.fn.line(".")
                if vim.fn.mode():match("^[vV\22]") then
                        line1, line2 = vim.fn.line("v"), vim.fn.line(".")
                        api.nvim_feedkeys(vim.keycode("<Esc>"), "nx", false)
                end
        end
        if line1 > line2 then
                line1, line2 = line2, line1
        end
        if not (bufs[buf] or attach(buf)) then
                notify("This buffer is not a file, so it cannot be commented on", vim.log.levels.WARN)
                return
        end
        local range = line1 == line2 and ("L" .. line1) or ("L%d-%d"):format(line1, line2)
        open_input({
                title = "Review comment · " .. range,
                line = line2,
                on_submit = function(text)
                        M.create(buf, line1, line2, text)
                end,
        })
end

---Add a comment about the project as a whole, not tied to any file or line.
function M.general()
        local root = current_root()
        open_input({
                title = "General review comment",
                on_submit = function(text)
                        local store = load_store(root)
                        store.comments[#store.comments + 1] =
                                { id = store.next_id, file = "", lnum = 0, end_lnum = 0, text = text, snippet = {} }
                        store.next_id = store.next_id + 1
                        save_store(root)
                        notify("Added general comment")
                end,
        })
end

local function edit_comment(root, comment, line)
        open_input({
                line = line,
                title = comment.file == "" and "Edit general comment" or "Edit review comment",
                initial = comment.text,
                on_submit = function(text)
                        comment.text = text
                        save_store(root)
                        for buf in pairs(bufs) do
                                render(buf)
                        end
                end,
        })
end

function M.edit()
        local buf = api.nvim_get_current_buf()
        local comment = comment_at(buf, vim.fn.line("."))
        if not comment then
                notify("No comment on this line", vim.log.levels.WARN)
                return
        end
        local _, last = mark_range(buf, bufs[buf].marks[comment.id])
        edit_comment(bufs[buf].root, comment, last)
end

function M.delete()
        local buf = api.nvim_get_current_buf()
        local comment = comment_at(buf, vim.fn.line("."))
        if not comment then
                notify("No comment on this line", vim.log.levels.WARN)
                return
        end
        remove(bufs[buf].root, comment.id)
end

function M.clear()
        local root = current_root()
        local count = #load_store(root).comments
        if count == 0 then
                notify("No comments to clear")
                return
        end
        if vim.fn.confirm(("Delete all %d review comment(s)?"):format(count), "&Yes\n&No", 2) == 1 then
                remove_all(root)
        end
end

---Toggle showing every comment in full, instead of only the one under the cursor.
function M.toggle()
        expand_all = not expand_all
        for buf in pairs(bufs) do
                render(buf)
        end
        notify(expand_all and "Showing all comments" or "Comments hidden")
end

---Delete this buffer's lowercase marks and all global uppercase marks. These are Vim marks, not comments:
---a slow press of a `<leader>m…` mapping falls through to the built-in `m{letter}` and sets one.
function M.delmarks()
        vim.cmd("delmarks!")
        vim.cmd("delmarks A-Z")
        vim.cmd("redraw!")
        notify("Deleted all marks")
end

local function jump(direction)
        local buf = api.nvim_get_current_buf()
        local info = bufs[buf]
        local lines = {}
        for _, mark in pairs(info and info.marks or {}) do
                lines[#lines + 1] = mark_range(buf, mark)
        end
        if #lines == 0 then
                notify("No comments in this file", vim.log.levels.WARN)
                return
        end
        table.sort(lines)
        local cur = vim.fn.line(".")
        -- Wrap around to the other end of the file when nothing lies in that direction.
        local target = direction > 0 and lines[1] or lines[#lines]
        for i = direction > 0 and 1 or #lines, direction > 0 and #lines or 1, direction do
                if (direction > 0 and lines[i] > cur) or (direction < 0 and lines[i] < cur) then
                        target = lines[i]
                        break
                end
        end
        vim.cmd("normal! m'")
        api.nvim_win_set_cursor(0, { target, 0 })
        vim.cmd("normal! ^zv")
end

---Jump to the next comment in this file.
function M.next()
        jump(1)
end

---Jump to the previous comment in this file.
function M.prev()
        jump(-1)
end

---The whole review as markdown, or nil when there are no comments.
function M.format(root)
        sync_all()
        root = root or current_root()
        local comments = sorted_comments(root)
        if #comments == 0 then
                return nil
        end
        local out = { config.intro:format(#comments, root), "" }
        for i, comment in ipairs(comments) do
                if comment.file == "" then
                        out[#out + 1] = ("## %d. General"):format(i)
                else
                        local range = comment.lnum == comment.end_lnum and tostring(comment.lnum)
                                or ("%d-%d"):format(comment.lnum, comment.end_lnum)
                        out[#out + 1] = ("## %d. %s:%s"):format(i, comment.file, range)
                end
                local snippet = vim.list_slice(comment.snippet or {}, 1, config.max_snippet_lines)
                if #snippet > 0 then
                        local fence = table.concat(snippet, "\n"):find("```", 1, true) and "````" or "```"
                        out[#out + 1] = fence .. (vim.filetype.match({ filename = comment.file }) or "")
                        vim.list_extend(out, snippet)
                        if #comment.snippet > #snippet then
                                out[#out + 1] = ("… (%d more lines)"):format(#comment.snippet - #snippet)
                        end
                        out[#out + 1] = fence
                end
                out[#out + 1] = comment.text
                out[#out + 1] = ""
        end
        return table.concat(out, "\n"), #comments
end

function M.copy()
        local text, count = M.format()
        if not text then
                notify("No comments to copy", vim.log.levels.WARN)
                return
        end
        vim.fn.setreg('"', text)
        if not pcall(vim.fn.setreg, "+", text) then
                notify("No clipboard provider; copied to the unnamed register only", vim.log.levels.WARN)
                return
        end
        notify(("Copied %d comment(s) to the clipboard"):format(count))
end

local function pick_agent(on_choice)
        local ok, res = pcall(function()
                return vim.system({ config.herdr_bin, "agent", "list" }, { text = true }):wait()
        end)
        if not ok or res.code ~= 0 then
                notify(
                        "Could not list Herdr agents: " .. vim.trim(ok and (res.stdout .. res.stderr) or res),
                        vim.log.levels.ERROR
                )
                return
        end
        local decoded, data = pcall(vim.json.decode, res.stdout)
        local agents = decoded and vim.tbl_get(data, "result", "agents") or {}
        local here = vim.tbl_filter(function(agent)
                return agent.workspace_id == vim.env.HERDR_WORKSPACE_ID
        end, agents)
        if #here > 0 then
                agents = here
        end
        if #agents == 0 then
                notify("No agents are running in Herdr", vim.log.levels.ERROR)
        elseif #agents == 1 then
                on_choice(agents[1])
        else
                vim.ui.select(agents, {
                        prompt = "Send review to",
                        format_item = function(agent)
                                return ("%s %s [%s] %s"):format(
                                        agent.agent,
                                        agent.pane_id,
                                        agent.agent_status,
                                        agent.terminal_title_stripped or ""
                                )
                        end,
                }, function(agent)
                        if agent then
                                on_choice(agent)
                        end
                end)
        end
end

---Send every comment to an agent in the current Herdr workspace.
function M.submit()
        local root = current_root()
        local text, count = M.format(root)
        if not text then
                notify("No comments to submit", vim.log.levels.WARN)
                return
        end
        pick_agent(function(agent)
                local res = vim.system({ config.herdr_bin, "agent", "prompt", agent.pane_id, text }, { text = true })
                        :wait()
                if res.code ~= 0 then
                        local decoded, data = pcall(vim.json.decode, res.stdout)
                        local reason = decoded and vim.tbl_get(data, "error", "message")
                                or vim.trim(res.stdout .. res.stderr)
                        notify(
                                ("Herdr did not deliver the review (%s). Comments kept."):format(reason),
                                vim.log.levels.ERROR
                        )
                        return
                end

                -- Keep the last submission around in case the agent never picks it up.
                local archive = vim.fn.stdpath("state") .. "/monku/last-submitted.md"
                vim.fn.mkdir(vim.fs.dirname(archive), "p")
                vim.fn.writefile(vim.split(text, "\n", { plain = true }), archive)

                if config.clear_on_submit then
                        remove_all(root)
                end
                notify(("Sent %d comment(s) to %s (%s)"):format(count, agent.agent, agent.pane_id))
        end)
end

local function list_items(root)
        sync_all()
        local items = {}
        for _, comment in ipairs(sorted_comments(root)) do
                local first = comment.text:gsub("%s*\n%s*", " ")
                local general = comment.file == ""
                items[#items + 1] = {
                        text = comment.file .. " " .. first,
                        file = not general and (root .. "/" .. comment.file) or nil,
                        pos = not general and { comment.lnum, 0 } or nil,
                        label = general and "General" or ("%s:%d"):format(comment.file, comment.lnum),
                        comment = first,
                        comment_text = comment.text,
                        end_lnum = comment.end_lnum,
                        comment_id = comment.id,
                        root = root,
                }
        end
        return items
end

---List every comment; <CR> jumps to it, <C-x> deletes it.
function M.list()
        -- Resolve the project now: once the picker is focused, the current buffer is no longer a file.
        local root = current_root()
        local items = list_items(root)
        if #items == 0 then
                notify("No review comments yet")
                return
        end
        local ok, snacks = pcall(require, "snacks")
        if not ok or not snacks.picker then
                local qf = {}
                for _, item in ipairs(items) do
                        qf[#qf + 1] = { filename = item.file, lnum = item.pos and item.pos[1], text = item.comment }
                end
                vim.fn.setqflist({}, " ", { title = "Review comments", items = qf })
                vim.cmd.copen()
                return
        end
        snacks.picker.pick({
                title = "Review comments",
                finder = function()
                        return list_items(root)
                end,
                format = function(item)
                        return {
                                { item.label, "SnacksPickerFile" },
                                { "  " },
                                { item.comment, "SnacksPickerComment" },
                        }
                end,
                -- The file preview, with the full comment shown under the lines it refers to.
                preview = function(ctx)
                        if not ctx.item.file then
                                -- A general comment has no code to show, so the preview is the comment itself.
                                ctx.preview:reset()
                                ctx.preview:set_title("General comment")
                                local width = api.nvim_win_get_width(ctx.preview.win.win) - 4
                                ctx.preview:set_lines(wrap(ctx.item.comment_text, math.max(20, width)))
                                return
                        end
                        local ret = snacks.picker.preview.file(ctx)
                        local pbuf, pwin = ctx.preview.win.buf, ctx.preview.win.win
                        if not (pbuf and pwin and api.nvim_buf_is_valid(pbuf) and api.nvim_win_is_valid(pwin)) then
                                return ret
                        end
                        api.nvim_buf_clear_namespace(pbuf, ns_picker, 0, -1)
                        local last = math.min(ctx.item.end_lnum, api.nvim_buf_line_count(pbuf))
                        local width = api.nvim_win_get_width(pwin) - vim.fn.getwininfo(pwin)[1].textoff
                        local indent = api.nvim_buf_call(pbuf, function()
                                return vim.fn.indent(math.min(ctx.item.pos[1], last))
                        end)
                        api.nvim_buf_set_extmark(pbuf, ns_picker, last - 1, 0, {
                                virt_lines = comment_virt_lines(ctx.item.comment_text, width, indent),
                        })
                        return ret
                end,
                -- A general comment has nowhere to jump to, so <CR> edits it instead.
                confirm = function(picker, item)
                        if not item or item.file then
                                return picker:action("jump")
                        end
                        picker:close()
                        vim.schedule(function()
                                for _, comment in ipairs(load_store(item.root).comments) do
                                        if comment.id == item.comment_id then
                                                edit_comment(item.root, comment)
                                        end
                                end
                        end)
                end,
                actions = {
                        review_delete = function(picker, item)
                                if item then
                                        remove(item.root, item.comment_id)
                                        picker:find()
                                end
                        end,
                },
                win = {
                        input = { keys = { ["<c-x>"] = { "review_delete", mode = { "n", "i" } } } },
                        list = { keys = { ["<c-x>"] = "review_delete", ["dd"] = "review_delete" } },
                },
        })
end

local actions = {
        { "add", "Add a comment on the current line" },
        { "general", "Add a general comment, not tied to a line" },
        { "edit", "Edit the comment under the cursor" },
        { "delete", "Delete the comment under the cursor" },
        { "next", "Jump to the next comment in this file" },
        { "prev", "Jump to the previous comment in this file" },
        { "list", "List all comments and jump to one" },
        { "toggle", "Show or hide all comments inline" },
        { "copy", "Copy all comments to the clipboard" },
        { "submit", "Send all comments to the agent" },
        { "clear", "Delete all comments" },
        { "delmarks", "Delete all Vim marks (this buffer's a-z, and global A-Z)" },
}
local subcommands = vim.tbl_map(function(action)
        return action[1]
end, actions)

---Pick one of the plugin's actions from a menu.
function M.menu()
        -- Opening the menu ends visual mode, so remember the selection for "add".
        local line1, line2
        if vim.fn.mode():match("^[vV\22]") then
                line1, line2 = vim.fn.line("v"), vim.fn.line(".")
                api.nvim_feedkeys(vim.keycode("<Esc>"), "nx", false)
        end
        vim.ui.select(actions, {
                prompt = "Monku",
                format_item = function(action)
                        return ("%-8s %s"):format(action[1], action[2])
                end,
        }, function(action)
                if not action then
                        return
                end
                -- The picker hands control back before its window is fully closed.
                vim.schedule(function()
                        if action[1] == "add" and line1 then
                                M.add(line1, line2)
                        else
                                M[action[1]]()
                        end
                end)
        end)
end

local function set_highlights()
        api.nvim_set_hl(0, "MonkuSign", { fg = config.colors.sign })
        api.nvim_set_hl(0, "MonkuBorder", { fg = config.colors.border })
        api.nvim_set_hl(0, "MonkuText", { fg = config.colors.text })
end

function M.setup(opts)
        config = vim.tbl_deep_extend("force", config, opts or {})

        set_highlights()

        local group = api.nvim_create_augroup("monku", { clear = true })
        api.nvim_create_autocmd("ColorScheme", { group = group, callback = set_highlights })
        api.nvim_create_autocmd({ "BufReadPost", "BufNewFile" }, {
                group = group,
                callback = function(ev)
                        attach(ev.buf)
                end,
        })
        api.nvim_create_autocmd("BufWritePost", {
                group = group,
                callback = function(ev)
                        local info = bufs[ev.buf]
                        if info and next(info.marks) then
                                sync(ev.buf)
                                save_store(info.root)
                        end
                end,
        })
        api.nvim_create_autocmd("BufUnload", {
                group = group,
                callback = function(ev)
                        local info = bufs[ev.buf]
                        if info and next(info.marks) then
                                sync(ev.buf)
                                save_store(info.root)
                        end
                        bufs[ev.buf] = nil
                end,
        })
        api.nvim_create_autocmd({ "CursorMoved", "BufEnter" }, {
                group = group,
                callback = function(ev)
                        update_hover(ev.buf)
                end,
        })
        api.nvim_create_autocmd("BufLeave", {
                group = group,
                callback = function(ev)
                        local info = bufs[ev.buf]
                        if info and info.hover then
                                info.hover = nil
                                render(ev.buf)
                        end
                end,
        })

        api.nvim_create_user_command("Monku", function(cmd)
                local sub = cmd.fargs[1]
                if not sub then
                        M.menu()
                elseif not vim.list_contains(subcommands, sub) then
                        notify("Usage: Monku " .. table.concat(subcommands, "|"), vim.log.levels.ERROR)
                elseif sub == "add" and cmd.range > 0 then
                        M.add(cmd.line1, cmd.line2)
                else
                        M[sub]()
                end
        end, {
                nargs = "?",
                range = true,
                complete = function(lead)
                        return vim.tbl_filter(function(sub)
                                return vim.startswith(sub, lead)
                        end, subcommands)
                end,
        })

        for _, buf in ipairs(api.nvim_list_bufs()) do
                if api.nvim_buf_is_loaded(buf) then
                        attach(buf)
                end
        end
end

return M
