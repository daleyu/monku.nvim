-- Exercise the public flows with Snacks available, partially unavailable, and absent.
local api = vim.api
vim.opt.rtp:prepend(vim.env.REPO)
assert(vim.fn.stdpath("data"):find(vim.fn.getcwd(), 1, true))
local log = assert(io.open(vim.env.OUT, "w"))
local passed = 0
local function eq(name, actual, expected)
        assert(vim.deep_equal(actual, expected), name .. ": " .. vim.inspect(actual))
        passed = passed + 1
end
vim.o.swapfile = false
vim.fn.mkdir("project/.git", "p")
vim.fn.writefile({ "one", "two", "three" }, "project/a.lua")
vim.cmd.edit("project/a.lua")
local monku = require("monku")
monku.setup()
local source = api.nvim_get_current_buf()
local builtin_select = vim.ui.select
local choice, calls, prompts = nil, 0, {}
local function selector(items, opts, cb)
        calls = calls + 1
        prompts[#prompts + 1] = opts.prompt
        if opts.format_item then
                eq("formatted item is text", type(opts.format_item(items[1])), "string")
        end
        cb(choice and items[choice] or nil, choice)
end
local function keys(text)
        api.nvim_feedkeys(vim.keycode(text), "tx", false)
        vim.wait(30)
end
local real_system = vim.system
vim.system = function(cmd)
        eq("only list agents, never send a message", cmd[2], "agent")
        eq("only list agents, never send a message", cmd[3], "list")
        return {
                wait = function()
                        return {
                                code = 0,
                                stdout = vim.json.encode({
                                        result = {
                                                agents = {
                                                        { agent = "one", pane_id = "p1", agent_status = "idle" },
                                                        { agent = "two", pane_id = "p2", agent_status = "idle" },
                                                },
                                        },
                                }),
                                stderr = "",
                        }
                end,
        }
end

-- Missing module, missing picker, missing selector, and a picker that fails to load all fall back.
for _, kind in ipairs({ "absent", "no picker", "no selector", "load error", "snacks" }) do
        package.loaded.snacks = nil
        package.preload.snacks = function()
                if kind == "absent" then
                        error("not installed")
                end
                if kind == "no picker" then
                        return {}
                end
                if kind == "no selector" then
                        return { picker = {} }
                end
                if kind == "load error" then
                        return setmetatable({}, {
                                __index = function()
                                        error("picker unavailable")
                                end,
                        })
                end
                return { picker = { select = selector } }
        end
        vim.ui.select = kind == "snacks" and function()
                error("Snacks should be preferred")
        end or selector
        choice, calls, prompts = nil, 0, {}
        monku.menu()
        monku.create(source, 2, 2, "existing")
        monku.submit() -- dismiss the agent selector; no real Herdr command is run
        monku.list() -- dismiss the fallback comment list
        monku.clear() -- dismiss; existing comment must survive
        eq(kind .. " dismissing clear keeps comments", select(2, monku.format()), 1)
        api.nvim_win_set_cursor(0, { 3, 0 })
        monku.add()
        keys("inew text<Esc>")
        choice = 1
        keys("q")
        eq(kind .. " save closes editor", api.nvim_get_current_buf(), source)
        eq(kind .. " saves exactly one new comment", select(2, monku.format()), 2)
        eq(kind .. " all selectors used", calls, 5)
        eq(kind .. " selector prompts", prompts, {
                "Monku",
                "Send review to",
                "Review comments",
                "Delete all 1 review comment(s)?",
                "Save this comment?",
        })
        choice = 2
        monku.clear()
        eq(kind .. " explicit delete clears comments", monku.format(), nil)
end

-- Drive the real built-in vim.ui.select, replacing only inputlist's terminal input.
package.loaded.snacks = nil
package.preload.snacks = function()
        error("not installed")
end
vim.ui.select = builtin_select
local response = 1
local real_inputlist = vim.fn.inputlist
vim.fn.inputlist = function(items)
        eq("default UI presents Save first", { items[1], items[2] }, { "Save this comment?", "1: Save" })
        return response
end
monku.add()
keys("idefault UI<Esc>")
response = 0
keys("q")
eq("default UI dismissal keeps editor", api.nvim_buf_get_name(0), "monku://comment")
eq("default UI dismissal preserves text", api.nvim_get_current_line(), "default UI")
response = 1
keys(":q<CR>")
eq("default UI Save closes editor", api.nvim_get_current_buf(), source)
eq("default UI Save persists text", monku.format():find("default UI", 1, true) ~= nil, true)
vim.fn.inputlist = real_inputlist
monku.add()
keys("ireal numbered menu<Esc>")
keys("q1<CR>")
eq("real numbered menu saves and closes", api.nvim_get_current_buf(), source)
eq("real numbered menu persists text", monku.format():find("real numbered menu", 1, true) ~= nil, true)

-- Selecting a listed code comment navigates; a general comment opens its editor.
vim.ui.select = function(items, _, cb)
        cb(items[1], 1)
end
api.nvim_win_set_cursor(0, { 1, 0 })
monku.list()
vim.wait(30)
eq("fallback list jumps to comment", api.nvim_win_get_cursor(0)[1], 3)
monku.general()
keys("igeneral text<Esc>:x<CR>")
monku.list()
vim.wait(30)
eq("fallback list edits general comment", api.nvim_buf_get_name(0), "monku://comment")
eq("fallback list preserves general text", api.nvim_get_current_line(), "general text")
keys(":x<CR>")
eq("unchanged general comment :x closes", api.nvim_get_current_buf(), source)
vim.system = real_system
log:write(("%d passed, 0 failed\n"):format(passed))
log:close()
vim.cmd("qa!")
