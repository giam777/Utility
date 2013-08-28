create or replace package P_SYS_UTILITY is

  -- Author  : ALEXEY
  -- Created : 23.08.2013
  -- Purpose : Get system info (*nix versions)

/*
Get on file or folder name its device or ASM group and used/free space on it 
 * raw devices not supported
*/
procedure Get_Disk_Usage ( p_file_name  in varchar2, -- file name (also accept only path)
                           o_mount_dev  out nocopy varchar2, -- device or ASM group
                           o_used_space out number, -- used space
                           o_free_space out number); -- free space 

-- Collect space USAGE in BD
-- Recomended evry day schedule run
procedure Collect_Usage;

-- Get Forecast on space usage
-- Recomended base from 10 collects
function Get_Forecast ( pDT         in date, -- date for forecast
                        pBASE       in integer default 188, -- base days in calculate forecast
                        pTYPE_F     in varchar2 default 'SLOPE', -- type forecast: SLOPE | AVG
                        pTABLESPACE in varchar2 default null, -- tablespace ( null = all )
                        pOWNER      in varchar2 default null, -- user ( null = all )
                        pTYPE       in varchar2 default null )  -- segment type ( null = all ), allow like
         return number; -- size in bytes on date pDT

-- Get score of space usage and availability
-- Can be used in external monitoring tool : Nagios, etc
function Get_Space_Status ( pFOREDAYS   in number default 60,  -- days after that
                            pFREE_PRCNT in number default 25 ) -- free cpace greater than
         return number; -- 0 - Space free enough .. 100 - not enough free space

end P_SYS_UTILITY;
/
create or replace package body P_SYS_UTILITY is

  -- directory where placed executing file 
  OS_COMMAND_DIR  constant varchar2(30)  := 'UTIL_DIR';
  -- name of executing file
  OS_COMMAND_FILE constant varchar2(255) := 'os_command.sh';

/* Executing script with lines from parameter in_script
   stdout this script returning in parameter out_lines */
procedure Execute_Command ( in_script in out nocopy dbms_debug_vc2coll,
                            out_lines in out nocopy dbms_debug_vc2coll )
-- Warning : Allow execute any script with BD starter privileges in OS
is
  f utl_file.file_type; -- file pointer
begin
  out_lines := dbms_debug_vc2coll(); -- initialize out collection
  if in_script is not empty then -- if in collection have lines
    -- open file in rewrite mode
    f := utl_file.fopen ( OS_COMMAND_DIR, OS_COMMAND_FILE, 'W', 4048 );
    -- save lines in script
    for i in in_script.first..in_script.last loop
      utl_file.put_line ( file => f, buffer => in_script(i) );
    end loop;
    utl_file.fclose (file => f); -- close file, opened file can't executed OS
    -- execute script as preprocessor for external table
    for cl in (select v_line from T_OS_COMMAND) loop
      -- collect output script
      out_lines.extend; out_lines (out_lines.last) := cl.v_line;
    end loop;
  end if;
end;

/*
Get on file or folder name its device or ASM group and used/free space on it 
*/
procedure Get_Disk_Usage ( p_file_name  in varchar2, -- file name (also accept only path)
                           o_mount_dev  out nocopy varchar2, -- device or ASM group
                           o_used_space out number, -- used space
                           o_free_space out number) -- free space 
is
  l_cmd dbms_debug_vc2coll default dbms_debug_vc2coll(); -- command for script
  l_out dbms_debug_vc2coll; -- result executing script
  l_start integer; l_token integer; -- pointers for separation result strings
begin
  o_mount_dev := null; o_used_space := 0; o_free_space := 0;
  if p_file_name like '+%' then -- this ASM
    -- get ASM disk group
    o_mount_dev := substr( p_file_name, 2, instr(p_file_name, '/') - 2 );
    -- and her space info
    select ( total_mb - free_mb ) * 1024 * 1024,
           usable_file_mb  * 1024 * 1024
      into o_used_space, o_free_space
      from v$asm_diskgroup where name = o_mount_dev;
  else
    -- create script
    l_cmd.extend(3);
    l_cmd(1) := '#!/bin/sh';
    l_cmd(2) := 'export lang=en_US.UTF-8';
    l_cmd(3) := '/bin/df -k '||p_file_name||' | /bin/grep /';
    -- and execute it
    Execute_Command ( in_script => l_cmd, out_lines => l_out );
    if l_out is not empty then
      --sample recive line, we work only with first line 
      --/dev/sdb2            961432104 606012700 306581404  67% /u02
      l_start := 1; l_token := 1;
      -- separate line for tokens
      for i in 1..length(l_out(1)) loop
        if substr(l_out(1), i, 1) = ' ' and i > 1 and
           substr(l_out(1), i-1, 1) != ' ' 
        then -- end current token
          if l_token = 1 then -- /dev/sdb2 = o_mount_dev
            o_mount_dev := substr(l_out(1), l_start, i-l_start);
          elsif l_token = 2 then -- 961432104 = total
            null;
          elsif l_token = 3 then -- 606012700 = o_used_space
            o_used_space := to_number ( substr(l_out(1), l_start, i-l_start) ) * 1024;
          elsif l_token = 4 then -- 306581404 = o_free_space
            o_free_space := to_number ( substr(l_out(1), l_start, i-l_start) ) * 1024;
          elsif l_token = 5 then -- 67% = %used
            null;
          end if;
        elsif substr(l_out(1), i, 1) != ' ' and i > 1 and
              substr(l_out(1), i-1, 1) = ' '
        then -- start new token
          l_token := l_token + 1; l_start := i;
        end if;
      end loop;
    end if;
  end if;
end;

-- Collect space USAGE in BD
-- Recomended evry day schedule run
procedure Collect_Usage
is
  lDT date default trunc(sysdate);
begin
  merge into T_SPACE_USAGE t
  using (select owner, tablespace_name, segment_type, sum(bytes) as bytes, sum(blocks) blocks, lDT as dt$ 
           from dba_segments 
          where segment_type like 'TABLE%' or  -- exclude temporary and undo segments
                segment_type like 'CLUSTER%' or 
                segment_type like 'INDEX%' or 
                segment_type like 'LOB%'
          group by owner, tablespace_name, segment_type) s
  on (t.dt$ = s.dt$ and t.owner$ = s.owner and t.tablespace$ = s.tablespace_name and t.type$=s.segment_type)
  when matched then update
    set t.bytes$ = s.bytes, t.blocks$ = s.blocks
  when not matched then insert (dt$, owner$, tablespace$, type$, bytes$, blocks$)
    values (s.dt$, s.owner, s.tablespace_name, s.segment_type, s.bytes, s.blocks);
  commit;
end;

-- Get Forecast on space usage
function Get_Forecast ( pDT         in date, -- date for forecast
                        pBASE       in integer default 188, -- base days in calculate forecast
                        pTYPE_F     in varchar2 default 'SLOPE', -- type forecast: SLOPE | AVG
                        pTABLESPACE in varchar2 default null, -- tablespace ( null = all )
                        pOWNER      in varchar2 default null, -- user ( null = all )
                        pTYPE       in varchar2 default null )  -- segment type ( null = all ), allow like
         return number -- size in bytes on date pDT
is
  l_res number;
begin
  select nvl ( ( pDT - min(dt$) + avg (d_dt) ) * 
               ( case when pTYPE_F = 'SLOPE' then REGR_SLOPE(bytes, n_dt) 
                      else avg(d_bytes/d_dt) end ) + max(start_bytes),
               max(bytes) )
    into l_res
    from (select d.dt$, nvl(s.bytes, 0) bytes, nvl(s.blocks, 0) blocks,
                 bytes - lag(bytes ignore nulls) over (order by d.dt$ asc) d_bytes,
                 s.dt$ - lag(s.dt$ ignore nulls) over (order by d.dt$ asc) d_dt,
                 d.dt$ - min(s.dt$) over () n_dt,
                 max(bytes) keep (dense_rank first order by s.dt$ asc) over () start_bytes
            from (select distinct dt$ from T_SPACE_USAGE where dt$ >= trunc(sysdate) - pBASE) d
            left join (select sum(bytes$) bytes, sum(blocks$) blocks, dt$
                         from T_SPACE_USAGE
                        where dt$ >= trunc(sysdate) - pBASE
                          and (tablespace$ = pTABLESPACE or pTABLESPACE is null)
                          and (owner$ = pOWNER or pOWNER is null)
                          and (type$ like pTYPE or pTYPE is null )
                        group by dt$ ) s
            on s.dt$ = d.dt$) a;
  return l_res;
end;

-- Get limits for growth BD/TS/File
procedure Get_Limits ( pTABLESPACE in varchar2 default null, -- tablespace ( null = all )
                       pFILE_ID    in number default null, -- id_file ( null = all )
                       pFILE_NAME  in varchar2 default null, -- file name ( null = all )
                       oUSED       out number, -- used space in BD/TS/File
                       oCURRENT    out number, -- current size in BD/TS/File
                       oBD_LIMIT   out number, -- BD limits for BD/TS/File (based on autoextend info)
                       oDISK_FREE  out number ) -- DISK limits for BD/TS/File (based on devices info)
is
  type t_df is table of number index by varchar2(255);
  l_df t_df; -- collect already get devices ASM groups
  function Get_Disk_Free ( p_file_name in varchar2 )
           return number
  is
    ll_mnt varchar2(255);
    ll_used number;
    ll_free number;
  begin
    Get_Disk_Usage ( p_file_name => p_file_name,
                     o_mount_dev => ll_mnt,
                     o_used_space => ll_used,
                     o_free_space => ll_free );
    if l_df.exists(ll_mnt) then
      return 0; -- Already calculated
    else
      l_df(ll_mnt) := ll_free; -- Remember
      return ll_free; 
    end if;
  end;
begin
  oCURRENT   := 0;
  oUSED      := 0;
  oBD_LIMIT  := 0;
  oDISK_FREE := 0;
  for c_files in (select f.file_name, f.file_id, f.tablespace_name, f.bytes, f.maxbytes, f.user_bytes 
                    from dba_data_files f, dba_tablespaces t
                   where (f.tablespace_name = pTABLESPACE or pTABLESPACE is null )
                     and (f.file_id = pFILE_ID or pFILE_ID is null )
                     and (f.file_name like pFILE_NAME or pFILE_NAME is null)
                     and f.tablespace_name = t.tablespace_name 
                     and t.contents = 'PERMANENT')
  loop
    oCURRENT    := oCURRENT    + c_files.bytes;
    oUSED       := oUSED       + c_files.user_bytes;
    oBD_LIMIT   := oBD_LIMIT   + c_files.maxbytes;
    oDISK_FREE  := oDISK_FREE  + Get_Disk_Free ( c_files.file_name );
  end loop;
end;

-- Get score of space usage and availability
-- Can be used in external monitoring tool : Nagios, etc
function Get_Space_Status ( pFOREDAYS   in number default 60,  -- days after that
                            pFREE_PRCNT in number default 25 ) -- free cpace greater than
         return number -- 0 - Space free enough .. 100 - not enough free space
is
  l_used number;
  l_size number;
  l_bd   number;
  l_disk number;
  l_fore number;
  l_res  number;
begin
  Get_Limits (oUSED => l_used, oCURRENT => l_size, oBD_LIMIT => l_bd, oDISK_FREE => l_disk);
  l_fore := Get_Forecast ( pDT => sysdate + pFOREDAYS );
  -- calculate ratio
  l_res := least ( l_size + l_disk, l_bd) / greatest (l_fore, l_used) / ( 1 + pFREE_PRCNT / 100 );
  dbms_output.put_line ( 'Used: '||l_used||',   Size: '||l_size||',   BD: '||l_bd||', DISK: '||l_disk);
  dbms_output.put_line ( 'Forecast: '||l_fore||',    ratio: '||l_res);
  if l_res >= 1 then
    return 0;
  else
    return ( 1 - l_res ) * 100;
  end if;
end;

end P_SYS_UTILITY;
/
