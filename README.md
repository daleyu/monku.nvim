# 💬 `monku.nvim`

Leave review comments on code as you read it, then send them all to a coding agent.

- comments are anchored to lines and follow your edits
- shown inline under the code, on hover or all at once
- sent to an agent in your [Herdr](https://herdr.dev) workspace, or copied to the clipboard

## ⚡️ Requirements

- **Neovim** >= 0.11
- [herdr](https://herdr.dev) for `submit` _(optional)_
- [snacks.nvim](https://github.com/folke/snacks.nvim) for the list picker _(optional)_

## 📦 Installation

Install with [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "daleyu/monku.nvim",
  lazy = false,
  ---@type table
  opts = {
    -- your configuration comes here
    -- or leave it empty to use the default settings
  },
  keys = {
    { "<leader>ma", function() require("monku").add() end, mode = { "n", "x" }, desc = "Add comment" },
    { "<leader>mg", "<cmd>Monku general<cr>", desc = "Add general comment" },
    { "<leader>mm", "<cmd>Monku<cr>", mode = { "n", "x" }, desc = "Pick an action" },
    { "<leader>ml", "<cmd>Monku list<cr>", desc = "List comments" },
    { "<leader>ms", "<cmd>Monku submit<cr>", desc = "Send to agent" },
    { "]r", "<cmd>Monku next<cr>", desc = "Next comment" },
    { "[r", "<cmd>Monku prev<cr>", desc = "Previous comment" },
  },
}
```

## ⚙️ Configuration

```lua
{
  herdr_bin = vim.env.HERDR_BIN_PATH or "herdr",
  auto_expand = true, -- show a comment inline while the cursor is on its line
  clear_on_submit = true, -- drop the comments once the agent has accepted them
  sign = "▍",
  colors = { sign = "#7287b8", border = "#7287b8", text = "#8c9bc4" },
  max_snippet_lines = 30,
}
```

## 🚀 Usage

`:Monku` opens a picker with every action. Each one is also a subcommand:

| Command | Description |
| --- | --- |
| `:Monku add` | Comment on the current line or visual selection |
| `:Monku general` | Add a comment not tied to a line |
| `:Monku edit` / `delete` | Edit or delete the comment under the cursor |
| `:Monku next` / `prev` | Jump between comments in the file |
| `:Monku list` | List all comments; `<CR>` jumps, `<C-x>` deletes |
| `:Monku toggle` | Show or hide all comments inline |
| `:Monku copy` | Copy all comments to the clipboard |
| `:Monku submit` | Send all comments to the agent |
| `:Monku clear` | Delete all comments |
| `:Monku delmarks` | Delete all Vim marks |
