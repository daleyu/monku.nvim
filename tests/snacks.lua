-- Real Snacks with its global UI override disabled, in a PTY whose input stays open.
local S = vim.fn.getcwd()
local log = assert(io.open(S .. "/" .. vim.env.OUT, "w"))
local function print(msg)
        log:write(msg .. "\n")
        log:flush()
end
assert(vim.fn.stdpath("data"):find(S, 1, true))
vim.g.clipboard = {
        name = "fake",
        copy = { ["+"] = function() end, ["*"] = function() end },
        paste = {
                ["+"] = function()
                        return {}
                end,
                ["*"] = function()
                        return {}
                end,
        },
}
vim.o.swapfile = false
vim.opt.rtp:prepend(vim.env.REPO)
vim.opt.rtp:prepend(vim.env.SNACKS)
local default_select = vim.ui.select
require("snacks").setup({ picker = { enabled = true, ui_select = false } })
assert(vim.ui.select == default_select, "Monku must use Snacks without a global override")
local proj = S .. "/proj4"
vim.fn.delete(proj, "rf")
vim.fn.delete(vim.fn.stdpath("data") .. "/monku", "rf")
vim.fn.mkdir(proj .. "/.git", "p")
vim.fn.writefile({ "one", "two", "three" }, proj .. "/a.lua")
local monku = require("monku")
monku.setup({})
vim.cmd.edit(proj .. "/a.lua")
local src_win = vim.api.nvim_get_current_win()
vim.cmd("messages clear")

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
local function texts()
        local path = vim.fn.glob(vim.fn.stdpath("data") .. "/monku/*.json")
        if path == "" then
                return {}
        end
        return vim.tbl_map(function(c)
                return c.text
        end, vim.json.decode(table.concat(vim.fn.readfile(path), "\n")).comments)
end
local function input(k)
        vim.api.nvim_feedkeys(vim.keycode(k), "tx", false)
        vim.wait(400)
end -- keys, then let the UI settle
local function pickers()
        return #require("snacks").picker.get()
end
local function is_editor(win)
        return vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win)) == "monku://comment"
end
local function open(text)
        vim.api.nvim_set_current_win(src_win)
        vim.api.nvim_win_set_cursor(0, { 2, 0 })
        monku.add()
        input("i" .. text .. "<Esc>")
        assert(is_editor(0))
end

for _, exit in ipairs({ "q", "<Esc>", ":q<CR>", ":close<CR>", "<C-w>c" }) do
        open("default " .. exit:gsub("[<>]", ""))
        input(exit)
        eq(
                exit .. " | snacks picker opened, editor still there",
                { pickers(), is_editor(0), #vim.tbl_filter(is_editor, vim.api.nvim_list_wins()) },
                { 1, false, 1 }
        )
        input("<CR>") -- accept whatever is preselected, without moving
        eq(
                exit .. " | <CR> straight away saves",
                { pickers(), texts(), vim.api.nvim_get_current_win() == src_win, #vim.api.nvim_list_wins() },
                { 0, { "default " .. exit:gsub("[<>]", "") }, true, 1 }
        )
        vim.cmd("Monku delete")
end

open("kept text")
input("0")
input("q")
input("<Esc>")
if pickers() > 0 then
        input("<Esc>")
end -- first <Esc> may only leave the picker's insert mode
eq("dismissing the picker keeps editing: editor focused, text intact, normal mode, nothing stored", {
        pickers(),
        is_editor(0),
        vim.api.nvim_buf_get_lines(0, 0, -1, false),
        vim.fn.mode(),
        vim.api.nvim_win_get_cursor(0),
        texts(),
}, { 0, true, { "kept text" }, "n", { 1, 0 }, {} })
input("q")
input("<Down><CR>")
eq(
        "second item (Discard) closes without storing",
        { pickers(), texts(), vim.api.nvim_get_current_win() == src_win, #vim.api.nvim_list_wins() },
        { 0, {}, true, 1 }
)
open("kept text 2")
input(":q<CR>")
input("<Down><Down><CR>")
eq(
        "third item (Keep editing) returns to the editor",
        { pickers(), is_editor(0), vim.api.nvim_buf_get_lines(0, 0, -1, false), texts() },
        { 0, true, { "kept text 2" }, {} }
)
input(":wq<CR>")
eq(":wq afterwards saves", texts(), { "kept text 2" })
for _, cmd in ipairs({ ":w<CR>", ":wq<CR>", ":x<CR>" }) do
        vim.cmd("Monku delete")
        local text = "saved with " .. cmd:gsub("<CR>", "")
        open(text)
        input(cmd)
        eq(
                cmd .. " saves without opening a picker",
                { pickers(), texts(), #vim.api.nvim_list_wins() },
                { 0, { text }, 1 }
        )
end
eq("no E-number error in :messages", vim.fn.execute("messages"):match("E%d+:[^\n]*"), nil)
print(("\n%d passed, %d failed"):format(pass, fail))
vim.cmd(fail == 0 and "qa!" or "cquit")
