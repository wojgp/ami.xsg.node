local _json = ...
local _hjson = require"hjson"

local _ok, _systemctl = safe_load_plugin("systemctl")
ami_assert(_ok, "Failed to load systemctl plugin", EXIT_APP_START_ERROR)

local _info = {}
local _ok, _status, _started = _systemctl.safe_get_service_status(APP.id .. "-" .. APP.model.SERVICE_NAME)
ami_assert(_ok, "Failed to start " .. APP.id .. "-" .. APP.model.SERVICE_NAME .. ".service " .. (_status or ""), EXIT_APP_START_ERROR)
_info.snowgemd = _status
_info.started = _started

_info.level = "ok"
_info.synced = "not reported"
_info.status = "XSG node down"

local function _exec_xsg_cli(...)

    local arg = { "-datadir=data", ... }
    if type(APP.configuration.DAEMON_CONFIGURATION) == "table" and type(APP.configuration.DAEMON_CONFIGURATION.rpcbind) == "string" then
        table.insert(arg, 1, "-rpcconnect=" .. APP.configuration.DAEMON_CONFIGURATION.rpcbind)
    end
    local _cmd = exString.join_strings(" ", table.unpack(arg))
    local _rd, _proc_wr = eliFs.pipe()
    local _rderr, _proc_werr = eliFs.pipe()
    local _proc, _err = eliProc.spawn {"bin/snowgem-cli", args = arg, stdout = _proc_wr, stderr = _proc_werr}
    _proc_wr:close()
    _proc_werr:close()

    if not _proc then
        _rd:close()
        _rderr:close()
        ami_error("Failed to execute snowgem-cli command: " .. _cmd, EXIT_APP_INTERNAL_ERROR)
    end
    local _exitcode = _proc:wait() 
    local _stdout = _rd:read("a")
    local _stderr = _rderr:read("a")
    --ami_assert(_exitcode == 0, "Failed to execute snowgem-cli command: " .. _cmd, EXIT_APP_INTERNAL_ERROR)
    return _exitcode, _stdout, _stderr
end

local function _get_xsg_cli_result(exitcode, stdout, stderr)
    if exitcode ~= 0 then 
        local _errorInfo = stderr:match("error: (.*)")
        local _ok, _output = pcall(_hjson.parse, _errorInfo)
        if _ok then 
            return false, _output
        else 
            return false, { message = "unknown (internal error)" }
        end
    end
    
    local _ok, _output = pcall(_hjson.parse, stdout)
    if _ok then 
        return true, _output
    else 
        return false, { message = "unknown (internal error)" }
    end
end

local function _update_info(update_function)
    if _info.level ~= "ok" or type(update_function) ~= "function" then
        return
    end
    update_function()
end

if _info.snowgemd == "running" then
    local _checks = {
        function () -- blockchain info check
            local _exitcode, _stdout, _stderr = _exec_xsg_cli("getblockchaininfo")
            local _success, _output = _get_xsg_cli_result(_exitcode, _stdout, _stderr)

            if _success then
                _info.currentBlock = _output.blocks
                _info.currentBlockHash = _output.bestblockhash
            else
                _info.currentBlock = "unknown"
                _info.currentBlockHash = "unknown"
            end
        end,
        function () -- synchronization check
            local _exitcode = _exec_xsg_cli("getblocktemplate")
            _info.synced = _exitcode == 0
            if not _info.synced then
                _info.level = "warn"
                _info.status = "Syncing..."
            end
        end,
        function () -- masternode status check
            if type(APP.configuration.DAEMON_CONFIGURATION) == "table" and tonumber(APP.configuration.DAEMON_CONFIGURATION.masternode) == 1 then
                local _exitcode, _stdout, _stderr = _exec_xsg_cli("masternode", "debug")
                if type(_stdout) ~= "string" then
                    _stdout = ""
                end
                if type(_stderr) ~= "string" then
                    _stderr = ""
                end
                if _stdout:match('Masternode successfully started') then
                    _info.level = "ok"
                    _info.status = "Masternode successfully started"
                elseif _stdout:match('Hot node, waiting for remote activation') or _stderr:match('Hot node, waiting for remote activation') then
                    _info.level = "warn"
                    _info.status = 'Hot node, waiting for remote activation.'
                else
                    _info.level = "error"
                    _info.status = _stderr:match("error message:.-\n(.-)\n%s*") or _stdout:match("error message:.-\n(.-)\n%s*") or "Failed to verify masternode status!"
                end
            else
                _info.status = "XSG node up"
                _info.level = "ok"
            end
        end
    }

    for _, check in ipairs(_checks) do
        _update_info(check)
    end
else
    _info.level = "error"
    _info.status = "Node is not running!"
end

_info.version = get_app_version()
_info.type = APP.type.id

if _json then
   print(_hjson.stringify_to_json(_info, { indent = false }))
else
   print(_hjson.stringify(_info))
end