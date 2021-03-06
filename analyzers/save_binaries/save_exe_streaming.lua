-- save_exe_prod.lua
--
-- *production version of save_exe.lua, streaming performance*
--
-- 1. Saves all Executable files using the magic number method
-- 2. Generates various metrics to self-monitor the performance 
-- 
-- Config params            Defaults
-- ---------------          --------
-- OutputDirectory          /tmp/savedfiles
-- Regex                    (shockwave|msdownload|dosexec|pdf|macro) to save common malware files
--                          SWF,PDF,MSI,EXE etc
--
local ffi=require('ffi')
local C = ffi.load('libmagic.so.1')
--  local dbg=require'debugger'

ffi.cdef[[
  static const int MAGIC_NONE=0x000000;
  static const int MAGIC_DEBUG=0x000001;
  typedef void * magic_t;
  magic_t magic_open(int k);
  const char *magic_error(magic_t);
  const char *magic_file(magic_t, const char *);
  const char *magic_buffer(magic_t, const char *, size_t );
  int magic_load(magic_t, const char *);
]]


function file_exists(name)
   local f=io.open(name,"r")
   if f~=nil then io.close(f) return true else return false end
end


-- --------------------------------------------
-- override by trisul_apps_save_exe.config.lua 
-- in probe config directory /usr/local/var/lib/trisul-probe/dX/pX/contextX/config 
--
DEFAULT_CONFIG = {
  -- where do you want the extracted files to go
  OutputDirectory="/tmp/savedfiles",

  -- the strings returned by libmagic you want to save
  Regex="(?i)(msdos|pe32|ms-dos|microsoft|windows|elf|executable|pdf|flash|macro|composite|x86 boot|iso\\s+9660)",

  -- filter out these which make it past Regex (to overcome a limitation of RE2) 
  Regex_Inv="(?i)(ico|jpeg)",
}
-- --------------------------------------------


-- plugin starts 
-- 
TrisulPlugin = {

  id = {
    name = "Save EXE,PDF,etc",
    description = "Extract MSI,EXE, using magic numbers",
    author = "Unleash",
    version_major = 1,
    version_minor = 0,
  },


  -- make sure the output directory is present 
  onload = function()

      local enabled = T.env.get_config("Reassembly>FileExtraction>Enabled")
      if  enabled:lower() ~= "true" then
          T.logwarning("Save Binaries : needs the Reassembly>FileExtraction>Enabled config setting to be TRUE. Cant proceed. ");
          return false
      end

      -- load custom config if present 
      T.active_config = DEFAULT_CONFIG
      local custom_config_file = T.env.get_config("App>DBRoot").."/config/trisulnsm_save_exe.config.lua"
      if file_exists(custom_config_file) then 
        local newsettings = dofile(custom_config_file) 
        T.log("Loading custom settings from ".. custom_config_file)
        for k,v in pairs(newsettings) do 
          T.active_config[k]=v
          T.log("Loaded new setting "..k.."="..v)
        end
      else 
        T.log("Loaded default settings")
      end


      -- initialize libmagic via FFI
      T.magic_handle=C.magic_open(C.MAGIC_NONE);
      if T.magic_handle == nil then
        T.logerror("Error opening magic handle")
        return false
      end
      if C.magic_load(T.magic_handle,nil) == nil then
        T.logerror("magic_load(..) error="..ffi.string(C.magic_error(T.magic_handle)) )
        return false
      end

      -- ensure output Dir exists and pre-Compile the Google RE2 regexes 
      os.execute("mkdir -p "..T.active_config.OutputDirectory)
      T.trigger_patterns = T.re2(T.active_config.Regex)
      T.trigger_patterns_inv = T.re2(T.active_config.Regex_Inv)
      T.savechunks={}
  end,

  filex_monitor  = {


    --
    -- stage 1 filter: skip the html/css/js content types to save decompressor CPU cycles 
    --
    filter = function( engine, timestamp, flowkey, header)

      -- meter : how many times the decompressor was started vs skipped
      -- a useful measure of CPU cycles neede
      local decompressor_needed =  header:is_response() and header:match_value("Content-Encoding","gzip") 

      if header:is_request() then
        return true
      elseif header:match_value("Content-Type", "(javascript|html|css)")  then
        engine:update_counter_raw("{282E13BE-9691-4B61-F0A3-21CB90792478}","ContentTypeSkip",0,1)
        if decompressor_needed then 
            engine:update_counter_raw("{282E13BE-9691-4B61-F0A3-21CB90792478}","DecompressorSkip",0,1)
        end
        return false
      else
        if decompressor_needed then 
            engine:update_counter_raw("{282E13BE-9691-4B61-F0A3-21CB90792478}","DecompressorStart",0,1)
        end
        return true
      end

    end,


    -- streaming interface Trisul supplies stream of payloads 
    -- Stage 2: in initial payload (seekpos=0) check the magic number regex
    onpayload_http   = function ( engine, timestamp, flow, path, req_header, resp_header, dir , seekpos , buffer )

      -- you can get 0 length for HTTP 304, etc - skip it (or log it in other ways etc)
      if buffer:size()  == 0 then return; end 

      -- seekpos ==0 is the first chunk of a http file 
      if  seekpos == 0  then 

        -- get magic number 
        local val_c = C.magic_buffer( T.magic_handle, buffer:tostring(), buffer:length())
        if val_c== nil then
          T.logerror("magic_file(..) error="..ffi.string(C.magic_error(T.magic_handle)) )
          engine:update_counter_raw("{282E13BE-9691-4B61-F0A3-21CB90792478}","LibmagicError",0,1)
          return
        end 

        local magic_filetype=ffi.string(val_c)
        -- print("type = ".. magic_filetype)
        local ctrkey=magic_filetype:match("(%w+%s+%w+)")

        -- saving if this trigger our RE2 pattern 
        if T.trigger_patterns:partial_match(magic_filetype) and 
           not T.trigger_patterns_inv:partial_match(magic_filetype) then 
          T.savechunks[flow:id()]=true 
          engine:update_counter_raw("{282E13BE-9691-4B61-F0A3-21CB90792478}","Extracted",0,1)
          engine:update_counter_raw("{282E13BE-9691-4B61-F0A3-21CB90792478}",ctrkey,2,1)
        else
          T.savechunks[flow:id()]=false 
          engine:update_counter_raw("{282E13BE-9691-4B61-F0A3-21CB90792478}","Skipped",0,1)
          return false
        end 

      end


      -- if previously flagged , add 
      -- async = moves the actual I/O out of the *fast path* to prevent pkt drops 
      -- 
      if T.savechunks[flow:id()]  then 
        local fn = path:match("^.+/(.+)$")
        T.async:copybuffer( buffer, T.active_config.OutputDirectory.."/"..fn, seekpos )
        engine:update_counter_raw("{282E13BE-9691-4B61-F0A3-21CB90792478}","ExtractedBW",1,buffer:size())
      end 

  end,

  -- flow terminated ; clean up 
  onterminateflow = function(engine, ts, flow)
    T.savechunks[flow:id()]=nil 
  end,

 }
}

