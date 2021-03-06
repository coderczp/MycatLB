--------------------------------------
--@desc:代理实现类
--@author:coder_czp
--@date:2015/9/19
--------------------------------------


local uv           = require('uv')
local fs           = _G['fs']
local public       = {}

--轮询模式的索引
local round_index  = 1
local pool_size    = 1
local proxy_port   = nil
local all_ips      = nil
local proxy_server = nil
local log          = nil
local meta_log     = nil
local model        = "ip_hash"

--统计数据的table:请求次数,每个服务处理的次数
local _statistics   = {request_cout=0,each_ser_count={}}

--获取最小的权重
local function getMinWeight(ips_tbl)
  local tmp = nil
  local min = 1000000
  for k,v in pairs(ips_tbl) do
    tmp =  tonumber(v.weight)
    if tmp < 1 or tmp == nil then
      error(string.format("invalid weight:%s=>%s:%s",tmp,v.ip,v.port))
    end
    if tmp >1 and tmp< min then min = tmp end
  end
  return min
end

--初始化ip池
local function init_server_pool(route_cfg)

  model     = route_cfg.model
  if model ~= "round" and model ~= "ip_hash"  then
    error("[ip_hash|round] except but get:"..model)
  end

  local ips       = route_cfg.ips
  local ips_count = table.getn(ips)
  local ip_pool   = {}

  if ips_count == 1 then
    local ser_ip = ips[1]
    table.insert(ip_pool,{ip=ser_ip.ip,port=ser_ip.port})
  else
    --获取最小的权重,计算比例
    local weight_min = getMinWeight(ips)
    for k,v in pairs(ips) do
      local addr   = {ip=v.ip,port=v.port}
      local count  = math.floor(v.weight/weight_min)
      while count > 0 do
        table.insert(ip_pool,addr)
        count = count-1
      end
    end
  end
  pool_size = table.getn(ip_pool)
  all_ips   = ip_pool
end

local function ipv4_to_int(ip_str)
  local o1,o2,o3,o4 = ip_str:match("(%d+)%.(%d+)%.(%d+)%.(%d+)")
  return 2^24*o1 + 2^16*o2 + 2^8*o3 + o4
end

--根据配置选择IP
local function select_ser(client_ip)

  if model == 'ip_hash' then
    --将客户端IP转换为数字后取模
    local ipint    = ipv4_to_int(client_ip)
    local ip_index = ipint % pool_size+1
    local select   = all_ips[ip_index]
    return all_ips[ip_index]
  else
    local ip = all_ips[round_index]
    round_index    = round_index + 1
    if round_index > pool_size then round_index = 1 end
    return ip
  end

end

--添加后端服务
function public.add_backend_ser(backend_ser_tbl)
  table.insert(all_ips,backend_ser_tbl)
end

--删除后端服务
function public.del_backend_ser(backend_ser_tbl)
  local tmp = backend_ser_tbl
  for k,v in pairs(all_ips) do
    if v.ip == tmp.ip and v.port == tmp.port then
      table.remove(all_ips,i)
      return end
  end
end

function public.start(route_cfg)

  log          = fs.openSync("data/proxy.log", "a")
  local fmt    = "%s-(%s)-(%s)-(%s)\n"
  local port   = route_cfg.port

  init_server_pool(route_cfg)
  proxy_server = uv.new_tcp()
  proxy_server:bind("0.0.0.0",port)
  proxy_server:listen(128, function(error)

      local upstream = uv.new_tcp()
      local client   = uv.new_tcp()

      proxy_server:accept(client)

      local cli_add    = uv.tcp_getpeername(client)
      local ser        = select_ser(cli_add.ip)

      upstream:connect(ser.ip, ser.port, function(error)
        if error then
          print('connect to upstream err: ' ,error)
          upstream:close()
          client:close()
        else

          upstream:read_start(function(err, data)
            if data then client:write(data) return end
            if err  then p("Upstream error:",err) end
            upstream:close()
            client:close()
          end)

          client:read_start(function(err, data)
            if data then  upstream:write(data) return end
            if err  then  p("Client error:" , err) end
            upstream:close()
            client:close()
          end)

          local local_add = uv.tcp_getsockname(upstream)
          local time_str  = os.date("%Y/%m/%d %H:%M:%S", os.time())
          local ser_str   = string.format("%s:%s",ser.ip,ser.port)
          local cli_str   = string.format("%s:%s",cli_add.ip,cli_add.port)
          local log_str   = string.format(fmt,time_str,cli_str,port,ser_str)

          local statc_tbl    =  _statistics.each_ser_count
          local requst_count =  _statistics.request_cout
          local last_count   =   statc_tbl[ser_str]

          _statistics.request_cout = requst_count+1
          --如果没有就添加,有则累加
          if last_count == nil then
            statc_tbl[ser_str] = 1
            last_count = 1
          else
            statc_tbl[ser_str] = last_count+1
          end

          fs.write(log, -1, log_str, function (err, bytes_written)
            if err then print("write log error:"..err) end
          end)

        end
      end)
  end)
end

--获取统计数据
function public.statistics()
  return _statistics
end

--停止服务
function public.stop()
  if proxy_server then proxy_server:close() end
  if log then fs.close(log) end
end

--改变端口重启服务
function public.reload(reoute_cfg)
  if proxy_port ~= reoute_cfg.port then
    proxy_port   = reoute_cfg.port
    proxy_server:close()
    proxy_server = nil
    public.start(reoute_cfg)
  else
    init_server_pool(reoute_cfg)
  end
end

return public
