-- :Monku submit against tests/fake-herdr: comments are cleared only once delivery is confirmed.
local api = vim.api
vim.opt.rtp:prepend(vim.env.REPO)
assert(vim.fn.stdpath("data"):find(vim.fn.getcwd(), 1, true))
local log = assert(io.open(vim.env.OUT, "w"))
local passed = 0
local function eq(name, actual, expected)
        assert(vim.deep_equal(actual, expected), name .. ": " .. vim.inspect(actual))
        passed = passed + 1
end
local dir = vim.fn.getcwd() .. "/herdr"
vim.fn.mkdir(dir, "p")
vim.env.FAKE_HERDR_DIR = dir
vim.o.swapfile = false
vim.fn.mkdir("project/.git", "p")
vim.fn.writefile({ "one", "two", "three" }, "project/a.lua")
vim.cmd.edit("project/a.lua")
local monku = require("monku")
monku.setup({ herdr_bin = vim.env.REPO .. "/tests/fake-herdr" })
local source = api.nvim_get_current_buf()
local notes = {}
vim.notify = function(msg, level)
        notes[#notes + 1] = { msg = msg, level = level }
end
local archive = vim.fn.stdpath("state") .. "/monku"

-- Submit one comment with the fake agent in `status` and the given replies (`read` is a list, one per screen
-- read); return the herdr calls made.
local function submit(name, status, replies, during)
        vim.fn.writefile({ status }, dir .. "/status")
        for _, cmd in ipairs({ "prompt", "send-keys", "wait" }) do
                vim.fn.writefile({ replies[cmd] or "ok" }, dir .. "/" .. cmd)
        end
        vim.fn.writefile(replies.read or {}, dir .. "/read")
        vim.fn.delete(dir .. "/calls")
        notes = {}
        monku.create(source, 2, 2, name)
        monku.submit()
        if during then
                during()
        end
        assert(vim.wait(5000, function()
                return #notes > 0
        end), name .. ": no result")
        return vim.fn.readfile(dir .. "/calls"), notes[#notes]
end

local WAIT = " --wait --timeout 6000 --until working --until blocked"
local READ = "pane read t:p1 --source detection"
local calls, note = submit("busy", "working", { read = { "delivered" } })
eq("working agent: plain prompt, then the input box is checked", calls, {
        "agent list",
        "agent prompt t:p1 <text>",
        READ,
})
eq("working agent: echoed above an empty box counts as delivered", monku.format(), nil)
eq("working agent: reported", note.msg:find("Sent 1 comment", 1, true) ~= nil, true)

calls = submit("busy but stuck", "working", { read = { "pasted", "delivered" } })
eq("stuck in the box: one more Enter, then check again", calls, {
        "agent list",
        "agent prompt t:p1 <text>",
        READ,
        "agent send-keys t:p1 enter",
        READ,
})
eq("stuck then delivered: cleared", monku.format(), nil)

calls = submit("idle ok", "idle", {})
eq("idle agent: waits until it starts", calls, { "agent list", "agent prompt t:p1 <text>" .. WAIT })
eq("idle agent: cleared", monku.format(), nil)

calls = submit("stalled then enter", "idle", { prompt = "agent_prompt_stalled" })
eq("stalled: one more Enter, then wait", calls, {
        "agent list",
        "agent prompt t:p1 <text>" .. WAIT,
        "agent send-keys t:p1 enter",
        "agent wait t:p1 --timeout 3000 --until working --until blocked",
})
eq("stalled then started: cleared", monku.format(), nil)

calls = submit("timeout then enter", "done", { prompt = "timeout" })
eq("caller timeout is treated as a stall", calls[3], "agent send-keys t:p1 enter")
eq("timeout then started: cleared", monku.format(), nil)

calls, note = submit("still stalled", "idle", { prompt = "agent_prompt_stalled", wait = "timeout" })
eq("still stalled: only one retry", #calls, 4)
eq("still stalled: error", note.level, vim.log.levels.ERROR)
eq("still stalled: comment kept", select(2, monku.format()), 1)

calls, note = submit("blocked", "blocked", { prompt = "agent_blocked" })
eq("blocked: no retry", #calls, 2)
eq("blocked: error", note.level, vim.log.levels.ERROR)
eq("blocked: both comments kept", select(2, monku.format()), 2)

calls, note = submit("busy and still stuck", "working", { read = { "inline", "pasted" } })
eq("still stuck: only one retry", calls, {
        "agent list",
        "agent prompt t:p1 <text>",
        READ,
        "agent send-keys t:p1 enter",
        READ,
})
eq("still stuck: error", note.level, vim.log.levels.ERROR)
eq("still stuck: error says why", note.msg:find("still in the input box", 1, true) ~= nil, true)
eq("still stuck: comments kept", select(2, monku.format()), 3)

calls, note = submit("unreadable", "working", { read = { "pane_not_found" } })
eq("read error: no retry", #calls, 3)
eq("read error: error", note.level, vim.log.levels.ERROR)
eq("read error: Herdr's message is shown", note.msg:find("fake pane_not_found", 1, true) ~= nil, true)
eq("read error: comments kept", select(2, monku.format()), 4)

-- Keep the two leftovers, submit them plus a third, and add a fourth while Herdr is still waiting.
submit("slow", "idle", { prompt = "sleep" }, function()
        monku.submit()
        eq("second submit while pending is refused", notes[1].level, vim.log.levels.WARN)
        notes = {}
        monku.create(source, 3, 3, "added while waiting")
end)
local text, count = monku.format()
eq("only the submitted comments are cleared", count, 1)
eq("the comment added while waiting is kept", text:find("added while waiting", 1, true) ~= nil, true)

local files = vim.fn.glob(archive .. "/submitted/*.md", false, true)
eq("every submission is archived", #files, 10)
local last = vim.fn.readfile(archive .. "/last-submitted.md")
eq("last-submitted.md is the latest submission", table.concat(last, "\n"):find("slow", 1, true) ~= nil, true)
eq("and is archived too", #vim.tbl_filter(function(f)
        return vim.deep_equal(vim.fn.readfile(f), last)
end, files), 1)

log:write(("%d passed, 0 failed\n"):format(passed))
log:close()
vim.cmd("qa!")
