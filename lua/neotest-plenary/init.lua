local logger = require("neotest.logging")
local Path = require("plenary.path")
local lib = require("neotest.lib")
local base = require("neotest-plenary.base")

local function script_path()
  local str = debug.getinfo(2, "S").source:sub(2)
  return str:match("(.*/)")
end

local function join_results(base, update)
  if not base then
    return update
  end
  local status = (base.status == "failed" or update == "failed") and "failed" or "passed"
  local errors = (base.errors or update.errors)
      and (vim.list_extend(base.errors or {}, update.errors or {}))
    or nil
  return {
    status = status,
    errors = errors,
  }
end

local test_script = (Path.new(script_path()):parent():parent() / "run_tests.sh").filename

---@type NeotestAdapter
local PlenaryNeotestAdapter = { name = "neotest-plenary" }

function PlenaryNeotestAdapter.is_test_file(file_path)
  return base.is_test_file(file_path)
end

---@async
---@return Tree | nil
function PlenaryNeotestAdapter.discover_positions(path)
  if path and not lib.files.is_dir(path) then
    local query = [[
      ((function_call
        (identifier) @func_name
        (arguments (_) @namespace.name (function_definition))
      ) (#match? @func_name "describe")) @namespace.definition

      ((function_call
        (identifier) @func_name
        (arguments (_) @test.name (function_definition))
      ) (#match? @func_name "it")) @test.definition
    ]]
    return lib.treesitter.parse_positions(path, query, { nested_namespaces = true })
  end
  local files = lib.func_util.filter_list(base.is_test_file, lib.files.find({ path }))
  return lib.files.parse_dir_from_files(path, files)
end

---@param args NeotestRunArgs
---@return NeotestRunSpec | nil
function PlenaryNeotestAdapter.build_spec(args)
  local results_path = vim.fn.tempname()
  local tree = args.tree
  if not tree then
    return
  end
  local pos = args.tree:data()
  if pos.type == "dir" then
    return
  end
  local filters = {}
  if pos.type == "namespace" or pos.type == "test" then
    table.insert(filters, 1, { pos.range[1], pos.range[3] })
    for parent in tree:iter_parents() do
      local parent_pos = parent:data()
      if parent_pos.type ~= "namespace" then
        break
      end
      table.insert(filters, 1, { parent_pos.range[1], parent_pos.range[3] })
    end
  end
  local script_args = vim.tbl_flatten({
    results_path,
    pos.path,
    vim.inspect(filters),
  })
  local command = vim.tbl_flatten({
    test_script,
    script_args,
  })
  return {
    command = command,
    context = {
      results_path = results_path,
      file = pos.path,
    },
  }
end

---@param result PlenaryTestResult
local function convert_plenary_result(result, status, file)
  return table.concat(vim.tbl_flatten({ file, result.descriptions }), "::"),
    {
      status = status,
      short = result.msg,
      errors = result.msg and { { message = result.msg } },
    }
end

---@param lists string[][]
local function permutations(lists, cur_i)
  cur_i = cur_i or 1
  if cur_i > #lists then
    return { {} }
  end
  local sub_results = permutations(lists, cur_i + 1)
  local result = {}
  for _, elem in pairs(lists[cur_i]) do
    for _, sub_result in pairs(sub_results) do
      local l = vim.list_extend({ elem }, sub_result)
      table.insert(result, l)
    end
  end
  return result
end

---@class PlenaryTestResult
---@field descriptions string[]
---@field msg? string

---@class PlenaryTestResults
---@field pass PlenaryTestResult[]
---@field fail PlenaryTestResult[]
---@field errs PlenaryTestResult[]
---@field fatal PlenaryTestResult[]

---@class PlenaryOutput
---@field results PlenaryTestResults
---@field locations table<string, integer>

---@async
---@param spec NeotestRunSpec
---@param _ NeotestStrategyResult
---@param tree Tree
---@return NeotestResult[]
function PlenaryNeotestAdapter.results(spec, _, tree)
  -- TODO: Find out if this JSON option is supported in future
  local success, data = pcall(lib.files.read, spec.context.results_path)
  if not success then
    data = vim.json.encode({ pass = {}, fail = {}, errs = {}, fatal = {} })
  end
  ---@type PlenaryOutput
  local plenary_output = vim.json.decode(data, { luanil = { object = true } })
  if not plenary_output.results then
    return {}
  end

  local plenary_results = plenary_output.results
  local locations = plenary_output.locations
  local results = {}
  for _, plen_result in pairs(plenary_results.pass) do
    local pos_id, pos_result = convert_plenary_result(plen_result, "passed", spec.context.file)
    results[pos_id] = pos_result
  end
  local file_result = { status = "passed", errors = {} }
  local failed = vim.list_extend({}, plenary_results.errs)
  vim.list_extend(failed, plenary_results.fail)
  vim.list_extend(failed, plenary_results.fatal) -- TODO: Verify shape

  for _, plen_result in pairs(failed) do
    local pos_id, pos_result = convert_plenary_result(plen_result, "failed", spec.context.file)
    results[pos_id] = pos_result
    file_result.status = "failed"
    vim.list_extend(file_result.errors, pos_result.errors)
  end

  results[spec.context.file] = file_result

  --- We now have all results mapped by their alias names
  --- Need to combine using alias map

  local aliases = {}
  for alias, line in pairs(locations) do
    local node = tree:sorted_search(line, function(pos)
      return pos.range[1]
    end, false)
    if not node then
      error("Node not found for line " .. line)
    end
    local pos = node:data()
    aliases[pos.id] = aliases[pos.id] or {}
    table.insert(aliases[pos.id], alias)
  end

  for _, node in tree:iter_nodes() do
    local pos = node:data()
    if pos.type == "test" and not results[pos.id] then
      local namespace_aliases = {}
      for parent in node:iter_parents() do
        if parent:data().type ~= "namespace" then
          break
        end
        table.insert(namespace_aliases, 1, aliases[parent:data().id])
      end
      local namespace_permutations = permutations(namespace_aliases)
      for _, perm in ipairs(namespace_permutations) do
        for _, alias in ipairs(aliases[pos.id]) do
          local alias_id = table.concat(vim.tbl_flatten({ pos.path, perm, alias }), "::")
          results[pos.id] = join_results(results[pos.id], results[alias_id])
          results[alias_id] = nil
        end
      end
    end
  end

  return results
end

setmetatable(PlenaryNeotestAdapter, {
  __call = function(_, opts)
    return PlenaryNeotestAdapter
  end,
})

return PlenaryNeotestAdapter
