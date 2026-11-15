-- Comment editor regression suite; run with python3 tests/run.py.
local repo, S = vim.env.REPO, vim.fn.getcwd()
local log = assert(io.open(S .. "/" .. vim.env.OUT, "w"))
local function print(msg)
        log:write(msg .. "\n")
        log:flush()
end
assert(vim.fn.stdpath("data"):find(S, 1, true), "store must be redirected: " .. vim.fn.stdpath("data"))
local clip = {}
vim.g.clipboard = {
        name = "fake",
        copy = {
                ["+"] = function(l)
                        clip = l
                end,
                ["*"] = function(l)
                        clip = l
                end,
        },
        paste = {
                ["+"] = function()
                        return clip
                end,
                ["*"] = function()
                        return clip
                end,
        },
}
vim.opt.rtp:prepend(repo)
local proj = S .. "/proj2"
vim.fn.delete(proj, "rf")
vim.fn.delete(vim.fn.stdpath("data") .. "/monku", "rf")
vim.fn.mkdir(proj .. "/.git", "p")
vim.fn.writefile({ "one", "two", "three", "four" }, proj .. "/a.lua")
local monku = require("monku")
monku.setup({})
vim.cmd.edit(proj .. "/a.lua")
local buf, src_win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
print("ui attached: " .. tostring(#vim.api.nvim_list_uis() > 0))
vim.cmd("messages clear") -- a pty does not answer terminal queries, which leaves a startup E1568 behind

local pass, fail = 0, 0
local function eq(name, got, want)
        if vim.deep_equal(got, want) then
                pass = pass + 1
                print("ok    " .. name)
        else
                fail = fail + 1
                print(("FAIL  %s\n        got  %s\n        want %s"):format(name, vim.inspect(got), vim.inspect(want)))
        end
end
local function keys(k)
        vim.api.nvim_feedkeys(vim.keycode(k), "tx", false)
end
local function flush()
        vim.wait(30)
end -- let vim.schedule callbacks run

-- vim.ui.select stub: answers with ANSWER (nil = dismissed) and records every call.
local ANSWER, calls, asked = nil, 0, nil
local async = false
vim.ui.select = function(items, opts, cb)
        calls = calls + 1
        asked = { opts.prompt, items }
        local choice = ANSWER
        if choice == "DEFAULT" then
                choice = items[1]
        end -- accept the picker as it opens: <CR> on the first item
        if async then
                vim.defer_fn(function()
                        cb(choice)
                end, 5)
        else
                cb(choice)
        end
end
-- leave the editor by `exit`, answering `answer` if asked; returns how often the question was asked
local function leave(exit, answer)
        ANSWER, calls = answer, 0
        keys(exit)
        flush()
        return calls
end

local function texts()
        local path = vim.fn.glob(vim.fn.stdpath("data") .. "/monku/*.json")
        if path == "" then
                return {}
        end
        return vim.tbl_map(function(c)
                return c.text
        end, vim.json.decode(table.concat(vim.fn.readfile(path), "\n")).comments)
end
local function in_float()
        return vim.api.nvim_win_get_config(0).relative == "win"
end
local function state() -- {float open?, #windows, stored comment texts, 'confirm', current win is source}
        flush()
        return {
                in_float(),
                #vim.api.nvim_list_wins(),
                texts(),
                vim.o.confirm,
                vim.api.nvim_get_current_win() == src_win,
        }
end
local CLOSED = function(t)
        return { false, 1, t, false, true }
end
local function reset()
        if in_float() then
                vim.cmd("close!")
        end
        flush()
        local previous = ANSWER
        ANSWER = "Delete"
        vim.cmd("silent! Monku clear")
        flush()
        ANSWER = previous
        vim.api.nvim_win_set_cursor(0, { 2, 0 })
end
local function open_new(text)
        reset()
        monku.add()
        assert(in_float())
        if text then
                keys("i" .. text .. "<Esc>")
        end
end
local function open_edit(change)
        reset()
        monku.create(buf, 2, 2, "original")
        vim.cmd("Monku edit")
        assert(in_float())
        if change then
                keys("A" .. change .. "<Esc>")
        end
end

local EXITS = {
        "q",
        "<Esc>",
        ":q<CR>",
        ":quit<CR>",
        ":close<CR>",
        ":clo<CR>",
        ": q <CR>",
        "<C-w>c",
        "<C-w>q",
        "<C-w><C-q>",
}

if vim.env.QUICK then
        EXITS = { "q" }
end
eq(
        "footer",
        (function()
                open_new()
                return vim.api.nvim_win_get_config(0).footer[1][1]
        end)(),
        " <CR> or :w save · q or :q close "
)
eq("'confirm' is left alone while in the float", vim.o.confirm, false)

for pass_no, mode in ipairs({ "sync picker", "async picker" }) do
        async = pass_no == 2
        for _, exit in ipairs(EXITS) do
                local name = ("%s [%s]"):format(exit, mode)
                open_new()
                eq(name .. " | new, empty: not asked", leave(exit), 0)
                eq(name .. " | new, empty: closed, nothing stored", state(), CLOSED({}))

                open_new("abc")
                keys("0D")
                vim.cmd("doautocmd TextChanged")
                eq(name .. " | new, typed then erased: not asked", leave(exit), 0)
                eq(name .. " | new, typed then erased: closed", state(), CLOSED({}))

                open_new("hello world")
                keys("0w") -- cursor on "world"
                local cur = vim.api.nvim_win_get_cursor(0)
                local intact = function()
                        return {
                                in_float(),
                                #vim.api.nvim_list_wins(),
                                texts(),
                                vim.api.nvim_buf_get_lines(0, 0, -1, false),
                                vim.api.nvim_win_get_cursor(0),
                                vim.fn.mode(),
                                vim.bo.modified,
                        }
                end
                local INTACT = { true, 2, {}, { "hello world" }, cur, "n", true }
                eq(name .. " | new text: asked once (Keep editing)", leave(exit, "Keep editing"), 1)
                eq(name .. " | new text + Keep editing: float, text, cursor, mode intact", intact(), INTACT)
                eq(
                        name .. " | question wording",
                        asked,
                        { "Save this comment?", { "Save", "Discard", "Keep editing" } }
                )
                eq(name .. " | new text: asked once (dismissed)", leave(exit, nil), 1)
                eq(name .. " | new text + dismissed picker: float, text, cursor, mode intact", intact(), INTACT)
                eq(name .. " | new text: asked once (Save)", leave(exit, "Save"), 1)
                eq(name .. " | new text + Save: saved and closed", state(), CLOSED({ "hello world" }))
                open_new("hello world")
                eq(name .. " | new text: asked once (Discard)", leave(exit, "Discard"), 1)
                eq(name .. " | new text + Discard: closed, nothing stored", state(), CLOSED({}))

                -- the default: accepting the picker without moving the selection saves
                open_new("quick exit")
                eq(name .. " | new text: asked once (default accepted)", leave(exit, "DEFAULT"), 1)
                eq(name .. " | default choice is Save (first item)", asked[2][1], "Save")
                eq(name .. " | new text + default accepted: saved", state(), CLOSED({ "quick exit" }))
                open_edit(" quick")
                eq(name .. " | edit changed: asked once (default accepted)", leave(exit, "DEFAULT"), 1)
                eq(name .. " | edit changed + default accepted: saved", state(), CLOSED({ "original quick" }))

                open_edit()
                eq(name .. " | edit unchanged: not asked", leave(exit), 0)
                eq(name .. " | edit unchanged: closed", state(), CLOSED({ "original" }))

                open_edit(" plus")
                eq(name .. " | edit changed: asked once (Keep editing)", leave(exit, "Keep editing"), 1)
                eq(
                        name .. " | edit changed + Keep editing: stays open",
                        { in_float(), vim.api.nvim_buf_get_lines(0, 0, -1, false), texts() },
                        { true, { "original plus" }, { "original" } }
                )
                eq(name .. " | edit changed: asked once (Discard)", leave(exit, "Discard"), 1)
                eq(name .. " | edit changed + Discard: original kept", state(), CLOSED({ "original" }))
                open_edit(" plus")
                eq(name .. " | edit changed: asked once (Save)", leave(exit, "Save"), 1)
                eq(name .. " | edit changed + Save: saved", state(), CLOSED({ "original plus" }))

                open_edit("X")
                keys("$x")
                vim.cmd("doautocmd TextChanged")
                eq(name .. " | edit changed back: not asked", leave(exit), 0)
                eq(name .. " | edit changed back: closed", state(), CLOSED({ "original" }))
        end
end
async = false

-- Vim's write/quit commands: never ask -------------------------------------------------------------------
for _, cmd in ipairs({ ":w<CR>", ":wq<CR>", ":x<CR>", ":update<CR>", "ZZ", "<C-s>", "<CR>" }) do
        local label = cmd:gsub("[<>]", "")
        open_new("by " .. label)
        eq(cmd .. " | new text: not asked", leave(cmd), 0)
        eq(cmd .. " | new text: saved, float closed, source window kept", state(), CLOSED({ "by " .. label }))
        open_edit(" v2")
        eq(cmd .. " | edit: not asked", leave(cmd), 0)
        eq(cmd .. " | edit: saved", state(), CLOSED({ "original v2" }))
end
for _, cmd in ipairs({ ":w<CR>", ":wq<CR>", ":x<CR>" }) do
        open_new()
        leave(cmd)
        eq(cmd .. " | new, empty: closes, nothing stored", state(), CLOSED({}))
        open_edit()
        leave(cmd)
        eq(cmd .. " | edit unchanged: closes, text kept", state(), CLOSED({ "original" }))
end
for _, cmd in ipairs({ ":q!<CR>", ":quit!<CR>", ":close!<CR>", "ZQ" }) do
        open_new("throw away")
        eq(cmd .. " | new text: not asked", leave(cmd), 0)
        eq(cmd .. " | new text: discarded", state(), CLOSED({}))
        open_edit(" changed")
        eq(cmd .. " | edit changed: not asked", leave(cmd), 0)
        eq(cmd .. " | edit changed: discarded", state(), CLOSED({ "original" }))
end
open_new("insert mode save")
keys("A!<C-s>")
eq("<C-s> from insert mode saves", state(), CLOSED({ "insert mode save!" }))
eq("back in normal mode after insert-mode save", vim.fn.mode(), "n")

-- other command lines in the editor are not swallowed, and the guard is gone afterwards ----------
open_new("x")
keys(":let g:monku_probe = 7<CR>")
eq("an unrelated : command still runs inside the editor", vim.g.monku_probe, 7)
leave(":q!<CR>")
flush()
eq("no CmdlineLeave guard left behind", #vim.api.nvim_get_autocmds({ event = "CmdlineLeave" }), 0)
vim.cmd("new")
eq(":q in an ordinary window is untouched", { leave(":q<CR>"), #vim.api.nvim_list_wins() }, { 0, 1 })

eq("no error messages so far", vim.v.errmsg, "")
eq("no E-number error anywhere in :messages so far", vim.fn.execute("messages"):match("E%d+:[^\n]*"), nil)

-- exits where the question cannot be asked ----------------------------------------------------------------
vim.o.cmdheight = 6 -- room for Vim's two-line refusal, so a real UI does not stop at a hit-enter prompt
open_new("tab text")
vim.cmd("tabnew")
vim.cmd("tabprevious")
calls = 0
local tok, terr = pcall(vim.cmd, "tabclose")
eq(":tabclose with unsaved comment text", {
        tok,
        tostring(terr):match("E%d+"),
        calls,
        #vim.api.nvim_list_tabpages(),
        in_float(),
        vim.api.nvim_buf_get_lines(0, 0, -1, false),
}, { false, "E37", 0, 2, true, { "tab text" } })
vim.cmd("tabonly!") -- (forced: closes the other tab only)
ANSWER, calls = "Keep editing", 0
-- In a real UI Vim's refusal ends in a hit-enter prompt; the space dismisses it (headless: a harmless motion).
keys(":qa<CR> ")
flush()
vim.o.cmdheight = 1
eq("typed :qa with unsaved comment text: refused (E37/E162), not asked, editor intact", {
        calls,
        in_float(),
        vim.api.nvim_buf_get_lines(0, 0, -1, false),
        vim.fn.execute("messages"):match("E162[^\n]*"),
}, { 0, true, { "tab text" }, 'E162: No write since last change for buffer "monku://comment"' })
print("messages after :tabclose/:qa -> " .. vim.fn.execute("messages"):gsub("\n", " | "))
vim.cmd("messages clear")
vim.cmd("close!")
flush()

-- an exit that is not intercepted: a close issued without typing it (mapping / plugin / vim.cmd) --
open_new("keep me")
calls = 0
local ok, err = pcall(vim.cmd, "close")
eq(
        "programmatic :close on unsaved text: refused by Vim with E37, not asked, text kept",
        { ok, err:match("E%d+"), calls, in_float(), vim.api.nvim_buf_get_lines(0, 0, -1, false) },
        { false, "E37", 0, true, { "keep me" } }
)
vim.v.errmsg = ""
vim.cmd("messages clear")

-- focus moving to another window ---------------------------------------------------------------------
local float = vim.api.nvim_get_current_win()
calls = 0
vim.cmd("wincmd p")
eq("focus away: not asked, float stays open with its text", {
        calls,
        vim.api.nvim_get_current_win() == src_win,
        vim.api.nvim_win_is_valid(float),
        vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(float), 0, -1, false),
}, { 0, true, true, { "keep me" } })
vim.api.nvim_set_current_win(float)
leave(":wq<CR>")
eq("focus back then :wq saves", state(), CLOSED({ "keep me" }))

-- the float closed by other means while the question is still open ----------------------------------
open_new("late answer")
local late
vim.ui.select = function(_, _, cb)
        late = cb
end
keys("q")
vim.cmd("close!")
flush()
late("Save")
flush()
eq("answer arriving after the editor is gone is ignored", { vim.v.errmsg, state() }, { "", CLOSED({}) })

eq("no monku:// file on disk", { vim.fn.glob(proj .. "/monku*"), vim.fn.glob(S .. "/monku:*") }, { "", "" })
eq("'confirm' never changed", vim.o.confirm, false)
eq("no error messages", vim.v.errmsg, "")
eq("no E-number error in :messages at the end", vim.fn.execute("messages"):match("E%d+:[^\n]*"), nil)
print(("\n%d passed, %d failed"):format(pass, fail))
vim.cmd(fail == 0 and "qa!" or "cquit")
