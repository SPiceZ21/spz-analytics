-- server/db.lua — batched writes.
--
-- Rows are queued in memory and written every Config.FlushSec in multi-row
-- INSERTs, so gameplay never waits on the database. Counters (daily stats,
-- feature usage) are summed in memory and upserted with "x = x + VALUES(x)".

DB = {}

local queues = {}     -- [table] = { cols = {...}, rows = { {...}, ... }, ignore = bool }
local counters = {}   -- [table] = { key = {...}, cols = {...}, data = { [k] = { keyvals..., sums... } } }

function DB.Now() return os.date("%Y-%m-%d %H:%M:%S") end
function DB.Day() return os.date("%Y-%m-%d") end

--- Queue one row. `cols` fixes the column order the first time a table is used.
function DB.Insert(tbl, cols, row, ignore)
    local q = queues[tbl]
    if not q then q = { cols = cols, rows = {}, ignore = ignore }; queues[tbl] = q end
    q.rows[#q.rows + 1] = row
end

--- Add to a counter row identified by its key columns.
function DB.Add(tbl, keyCols, keyVals, sums)
    local c = counters[tbl]
    if not c then c = { keyCols = keyCols, data = {} }; counters[tbl] = c end
    local k = table.concat(keyVals, "|")
    local e = c.data[k]
    if not e then e = { keys = keyVals, sums = {} }; c.data[k] = e end
    for col, v in pairs(sums) do e.sums[col] = (e.sums[col] or 0) + v end
end

local CHUNK = 200

local function flushQueue(tbl, q)
    local rows = q.rows
    if #rows == 0 then return end
    q.rows = {}
    for i = 1, #rows, CHUNK do
        local vals, params = {}, {}
        for j = i, math.min(i + CHUNK - 1, #rows) do
            -- A nil value is written as a literal NULL: a nil in the params
            -- list would leave a hole and shift every later value one column.
            local ph = {}
            for c = 1, #q.cols do
                local v = rows[j][c]
                if v == nil then ph[c] = "NULL" else ph[c] = "?"; params[#params + 1] = v end
            end
            vals[#vals + 1] = "(" .. table.concat(ph, ",") .. ")"
        end
        local sql = ("INSERT %sINTO `%s` (`%s`) VALUES %s"):format(
            q.ignore and "IGNORE " or "", tbl, table.concat(q.cols, "`,`"), table.concat(vals, ","))
        local ok, err = pcall(function() MySQL.query.await(sql, params) end)
        if not ok then print(("^1[spz-analytics] write to %s failed: %s^7"):format(tbl, tostring(err))) end
    end
end

local function flushCounter(tbl, c)
    local data = c.data
    if not next(data) then return end
    c.data = {}
    for _, e in pairs(data) do
        local cols, params, upd = {}, {}, {}
        for i, kc in ipairs(c.keyCols) do cols[#cols + 1] = kc; params[#params + 1] = e.keys[i] end
        for col, v in pairs(e.sums) do
            cols[#cols + 1] = col
            params[#params + 1] = v
            upd[#upd + 1] = ("`%s` = `%s` + VALUES(`%s`)"):format(col, col, col)
        end
        local sql = ("INSERT INTO `%s` (`%s`) VALUES (%s) ON DUPLICATE KEY UPDATE %s"):format(
            tbl, table.concat(cols, "`,`"), string.rep("?,", #cols):sub(1, -2), table.concat(upd, ", "))
        local ok, err = pcall(function() MySQL.query.await(sql, params) end)
        if not ok then print(("^1[spz-analytics] upsert to %s failed: %s^7"):format(tbl, tostring(err))) end
    end
end

function DB.Flush()
    for tbl, q in pairs(queues) do flushQueue(tbl, q) end
    for tbl, c in pairs(counters) do flushCounter(tbl, c) end
end
