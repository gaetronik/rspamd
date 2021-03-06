--[[
Copyright (c) 2011-2015, Vsevolod Stakhov <vsevolod@highsecure.ru>

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
]]--

if confighelp then
  return
end

-- This plugin implements user dynamic settings
-- Settings documentation can be found here:
-- https://rspamd.com/doc/configuration/settings.html

local rspamd_logger = require "rspamd_logger"
local rspamd_maps = require "maps"
local redis_params

local settings = {}
local settings_ids = {}
local settings_initialized = false
local max_pri = 0
local rspamd_ip = require "rspamd_ip"
local rspamd_regexp = require "rspamd_regexp"
local ucl = require "ucl"
local fun = require "fun"

-- Checks for overridden settings within query params and returns 'true' if
-- settings are overridden
local function check_query_settings(task)
  -- Try 'settings' attribute
  local query_set = task:get_request_header('settings')
  if query_set then
    local parser = ucl.parser()
    local res,err = parser:parse_string(tostring(query_set))
    if res then
      task:set_settings(parser:get_object())

      return true
    else
      rspamd_logger.errx(task, 'Parse error: %s', err)
    end
  end

  local query_maxscore = task:get_request_header('maxscore')
  if query_maxscore then
    -- We have score limits redefined by request
    local ms = tonumber(tostring(query_maxscore))
    if ms then
      local nset = {
        default = {
          actions = {
            reject = ms
          }
        }
      }

      local query_softscore = task:get_request_header('softscore')
      if query_softscore then
        local ss = tonumber(tostring(query_softscore))
        nset['default']['actions']['add header'] = ss
      end

      task:set_settings(nset)

      return true
    end
  end

  local settings_id = task:get_request_header('settings-id')
  if settings_id and settings_initialized then
    -- settings_id is rspamd text, so need to convert it to string for lua
    local id_str = tostring(settings_id)
    local elt = settings_ids[id_str]
    if elt and elt['apply'] then
      task:set_settings(elt['apply'])

      if elt.apply['add_headers'] or elt.apply['remove_headers'] then
        local rep = {
          add_headers = elt.apply['add_headers'] or {},
          remove_headers = elt.apply['remove_headers'] or {},
        }
        task:set_rmilter_reply(rep)
      end
      rspamd_logger.infox(task, "applying settings id %s", id_str)

      return true
    end
  end

  return false
end

-- Check limit for a task
local function check_settings(task)
  local function check_addr_setting(rule, addr)
    local function check_specific_addr(elt)
      if rule['name'] then
        if rspamd_maps.rspamd_maybe_check_map(rule['name'], elt['addr']) then
          return true
        end
      end
      if rule['user'] then
        if rspamd_maps.rspamd_maybe_check_map(rule['user'], elt['user']) then
          return true
        end
      end
      if rule['domain'] and elt['domain'] then
        if rspamd_maps.rspamd_maybe_check_map(rule['domain'], elt['domain']) then
          return true
        end
      end
      if rule['regexp'] then
        if rule['regexp']:match(elt['addr']) then
          return true
        end
      end
      return false
    end

    for _, e in ipairs(addr) do
      if check_specific_addr(e) then
        return true
      end
    end

    return false
  end

  local function check_ip_setting(rule, ip)
    if not rule[2] then
      if rspamd_maps.rspamd_maybe_check_map(rule[1], ip:to_string()) then
        return true
      end
    else
      if rule[2] ~= 0 then
        local nip = ip:apply_mask(rule[2])
        if nip and nip:to_string() == rule[1]:to_string() then
          return true
        end
      elseif ip:to_string() == rule[1]:to_string() then
        return true
      end
    end

    return false
  end

  local function check_specific_setting(_, rule, ip, client_ip, from, rcpt,
      user, auth_user)
    local res = false

    if rule['authenticated'] then
      if auth_user then
        res = true
      end
      if not res then
        return nil
      end
    end

    if rule['ip'] then
      if not ip then
        return nil
      end
      for _, i in ipairs(rule['ip']) do
        res = check_ip_setting(i, ip)
        if res then
          break
        end
      end
      if not res then
        return nil
      end
    end

    if rule['client_ip'] then
      if not client_ip or not client_ip:is_valid() then
        return nil
      end
      for _, i in ipairs(rule['client_ip']) do
        res = check_ip_setting(i, client_ip)
        if res then
          break
        end
      end
      if not res then
        return nil
      end
    end

    if rule['from'] then
      if not from then
        return nil
      end
      for _, i in ipairs(rule['from']) do
        res = check_addr_setting(i, from)
        if res then
          break
        end
      end
      if not res then
        return nil
      end
    end

    if rule['rcpt'] then
      if not rcpt then
        return nil
      end
      for _, i in ipairs(rule['rcpt']) do
        res = check_addr_setting(i, rcpt)
        if res then
          break
        end
      end
      if not res then
        return nil
      end
    end

    if rule['user'] then
      if not user then
        return nil
      end
      for _, i in ipairs(rule['user']) do
        res = check_addr_setting(i, user)
        if res then
          break
        end
      end
      if not res then
        return nil
      end
    end

    if rule['request_header'] then
      for k, v in pairs(rule['request_header']) do
        local h = task:get_request_header(k)
        res = (h and v:match(h))
        if res then
          break
        end
      end
      if not res then
        return nil
      end
    end

    if rule['header'] then
      for k, v in pairs(rule['header']) do
        local h = task:get_header(k)
        res = (h and v:match(h))
        if res then
          break
        end
      end
      if not res then
        return nil
      end
    end

    if res then
      if rule['whitelist'] then
        rule['apply'] = {whitelist = true}
      end

      return rule
    end

    return nil
  end

  -- Check if we have override as query argument
  if check_query_settings(task) then
    return
  end

  -- Do not waste resources
  if not settings_initialized then
    return
  end

  rspamd_logger.infox(task, "check for settings")
  local ip = task:get_from_ip()
  local client_ip = task:get_client_ip()
  local from = task:get_from()
  local rcpt = task:get_recipients()
  local uname = task:get_user()
  local user = {}
  if uname then
    user[1] = {}
    local localpart, domainpart = string.gmatch(uname, "(.+)@(.+)")()
    if localpart then
      user[1]["user"] = localpart
      user[1]["domain"] = domainpart
      user[1]["addr"] = uname
    else
      user[1]["user"] = uname
      user[1]["addr"] = uname
    end
  end
  -- Match rules according their order
  local applied = false

  for pri = max_pri,1,-1 do
    if not applied and settings[pri] then
      for _,s in ipairs(settings[pri]) do
        local rule = check_specific_setting(s.name, s.rule, ip, client_ip, from, rcpt, user, uname)
        if rule then
          rspamd_logger.infox(task, "<%1> apply settings according to rule %2",
            task:get_message_id(), s.name)
          if rule['apply'] then
            task:set_settings(rule['apply'])
            applied = true
          end
          if rule['symbols'] then
            -- Add symbols, specified in the settings
            fun.each(function(val)
              task:insert_result(val, 1.0)
            end, rule['symbols'])
          end
        end
      end
    end
  end

end

-- Process settings based on their priority
local function process_settings_table(tbl)
  local get_priority = function(elt)
    local pri_tonum = function(p)
      if p then
        if type(p) == "number" then
          return tonumber(p)
        elseif type(p) == "string" then
          if p == "high" then
            return 3
          elseif p == "medium" then
            return 2
          end

        end

      end

      return 1
    end

    return pri_tonum(elt['priority'])
  end

  -- Check the setting element internal data
  local process_setting_elt = function(name, elt)

    -- Process IP address
    local function process_ip(ip)
      local out = {}

      if type(ip) == "table" then
        for _,v in ipairs(ip) do
          table.insert(out, process_ip(v))
        end
      elseif type(ip) == "string" then
        local slash = string.find(ip, '/')

        if not slash then
          -- Just a plain IP address
          local res = rspamd_ip.from_string(ip)

          if res:is_valid() then
            out[1] = res
            out[2] = 0
          else
            -- It can still be a map
            out[1] = res
          end
        else
          local res = rspamd_ip.from_string(string.sub(ip, 1, slash - 1))
          local mask = tonumber(string.sub(ip, slash + 1))

          if res:is_valid() then
            out[1] = res
            out[2] = mask
          else
            rspamd_logger.errx(rspamd_config, "bad IP address: " .. ip)
            return nil
          end
        end
      else
        return nil
      end

      return out
    end

    local function process_addr(addr)
      local out = {}
      if type(addr) == "table" then
        for _,v in ipairs(addr) do
          table.insert(out, process_addr(v))
        end
      elseif type(addr) == "string" then
        if string.sub(addr, 1, 4) == "map:" then
          -- It is map, don't apply any extra logic
          out['name'] = addr
        else
          local start = string.sub(addr, 1, 1)
          if start == '/' then
            -- It is a regexp
            local re = rspamd_regexp.create(addr)
            if re then
              out['regexp'] = re
            else
              rspamd_logger.errx(rspamd_config, "bad regexp: " .. addr)
              return nil
            end

          elseif start == '@' then
            -- It is a domain if form @domain
            out['domain'] = string.sub(addr, 2)
          else
            -- Check user@domain parts
            local at = string.find(addr, '@')
            if at then
              -- It is full address
              out['name'] = addr
            else
              -- It is a user
              out['user'] = addr
            end
          end
        end
      else
        return nil
      end

      return out
    end

    local check_table = function(chk_elt, out)
      if type(chk_elt) == 'string' then
        return {out}
      end

      return out
    end

    local out = {}

    if elt['ip'] then
      local ip = process_ip(elt['ip'])

      if ip then
        out['ip'] = check_table(elt['ip'], ip)
      end
    end
    if elt['client_ip'] then
      local ip = process_ip(elt['client_ip'])

      if ip then
        out['client_ip'] = check_table(elt['client_ip'], ip)
      end
    end
    if elt['from'] then
      local from = process_addr(elt['from'])

      if from then
        out['from'] = check_table(elt['from'], from)
      end
    end
    if elt['rcpt'] then
      local rcpt = process_addr(elt['rcpt'])
      if rcpt then
        out['rcpt'] = check_table(elt['rcpt'], rcpt)
      end
    end
    if elt['user'] then
      local user = process_addr(elt['user'])
      if user then
        out['user'] = check_table(elt['user'], user)
      end
    end
    if elt['authenticated'] then
      out['authenticated'] = true
    end
    if elt['request_header'] then
      local rho = {}
      for k, v in pairs(elt['request_header']) do
        local re = rspamd_regexp.get_cached(v)
        if not re then
          re = rspamd_regexp.create_cached(v)
        end
        if re then
          rho[k] = re
        end
      end
      out['request_header'] = rho
    end
    if elt['header'] then
      local rho = {}
      for k, v in pairs(elt['header']) do
        local re = rspamd_regexp.get_cached(v)
        if not re then
          re = rspamd_regexp.create_cached(v)
        end
        if re then
          rho[k] = re
        end
      end
      out['header'] = rho
    end

    -- Now we must process actions
    if elt['symbols'] then out['symbols'] = elt['symbols'] end
    if elt['id'] then
      out['id'] = elt['id']
      settings_ids[elt['id']] = out
    end

    if elt['apply'] then
      -- Just insert all metric results to the action key
      out['apply'] = elt['apply']
    elseif elt['whitelist'] or elt['want_spam'] then
      out['whitelist'] = true
    else
      rspamd_logger.errx(rspamd_config, "no actions in settings: " .. name)
      return nil
    end

    return out
  end

  settings_initialized = false
  -- filter trash in the input
  local ft = fun.filter(
    function(_, elt)
      if type(elt) == "table" then
        return true
      end
      return false
    end, tbl)

  -- clear all settings
  max_pri = 0
  local nrules = 0
  settings_ids = {}
  for k in pairs(settings) do settings[k]={} end
  -- fill new settings by priority
  fun.for_each(function(k, v)
    local pri = get_priority(v)
    if pri > max_pri then max_pri = pri end
    if not settings[pri] then
      settings[pri] = {}
    end
    local s = process_setting_elt(k, v)
    if s then
      table.insert(settings[pri], {name = k, rule = s})
      nrules = nrules + 1
    end
  end, ft)
  -- sort settings with equal priopities in alphabetical order
  for pri,_ in pairs(settings) do
    table.sort(settings[pri], function(a,b) return a.name < b.name end)
  end

  settings_initialized = true
  rspamd_logger.infox(rspamd_config, 'loaded %1 elements of settings', nrules)

  return true
end

-- Parse settings map from the ucl line
local function process_settings_map(string)
  local parser = ucl.parser()
  local res,err = parser:parse_string(string)
  if not res then
    rspamd_logger.warnx(rspamd_config, 'cannot parse settings map: ' .. err)
  else
    local obj = parser:get_object()
    if obj['settings'] then
      process_settings_table(obj['settings'])
    else
      process_settings_table(obj)
    end
  end

  return res
end

local function gen_redis_callback(handler, id)
  return function(task)
    local key = handler(task)

    local function redis_settings_cb(err, data)
      if not err and type(data) == 'table' then
        for _, d in ipairs(data) do
          if type(d) == 'string' then
            local parser = ucl.parser()
            local res,ucl_err = parser:parse_string(d)
            if not res then
              rspamd_logger.warnx(rspamd_config, 'cannot parse settings from redis: %s',
                ucl_err)
            else
              local obj = parser:get_object()
              rspamd_logger.infox(task, "<%1> apply settings according to redis rule %2",
                task:get_message_id(), id)
              task:set_settings(obj)
              break
            end
          end
        end
      elseif err then
        rspamd_logger.errx(task, 'Redis error: %1', err)
      end
    end

    if not key then
      rspamd_logger.errx(rspamd_config, 'Cannot execute handler number %s', id)
      return
    end

    local keys
    if type(key) == 'table' then
      keys = key
    else
      keys = {key}
    end
    key = keys[1]

    local ret,_,_ = rspamd_redis_make_request(task,
      redis_params, -- connect params
      key, -- hash key
      false, -- is write
      redis_settings_cb, --callback
      'MGET', -- command
      keys -- arguments
    )
    if not ret then
      rspamd_logger.errx(task, 'Redis MGET failed: %s', ret)
    end
  end
end

local redis_section = rspamd_config:get_all_opt("settings_redis")
local redis_key_handlers = {}

if redis_section then
  redis_params = rspamd_parse_redis_server('settings_redis')
  if redis_params then
    local handlers = redis_section.handlers

    for id,h in pairs(handlers) do
      local chunk,err = load(h)

      if not chunk then
        rspamd_logger.errx(rspamd_config, 'Cannot load handler from string: %s',
            tostring(err))
      else
        local res,func = pcall(chunk)
        if not res then
          rspamd_logger.errx(rspamd_config, 'Cannot add handler from string: %s',
            tostring(func))
        else
          redis_key_handlers[id] = func
        end
      end
    end
  end

  fun.each(function(id, h)
    rspamd_config:register_symbol({
      name = 'REDIS_SETTINGS' .. tostring(id),
      type = 'prefilter,nostat',
      callback = gen_redis_callback(h, id),
      priority = 10
    })
  end, redis_key_handlers)
end

local set_section = rspamd_config:get_all_opt("settings")

if set_section and set_section[1] and type(set_section[1]) == "string" then
  -- Just a map of ucl
  if not rspamd_config:add_map(set_section[1], "settings map", process_settings_map) then
    rspamd_logger.errx(rspamd_config, 'cannot load settings from %1', set_section)
  end
elseif set_section and type(set_section) == "table" then
  process_settings_table(set_section)
end

rspamd_config:register_symbol({
  name = 'SETTINGS_CHECK',
  type = 'prefilter,nostat',
  callback = check_settings,
  priority = 10
})
