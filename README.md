Utility
=======

Some utility for Oracle DB
<pre>
/*
For work P_SYS_UTILITY need: 
  directory UTIL_DIR with grants on read, write and execute on it
  file os_command.sh in this directory with RWX permission for user/group running RDBMS
  External organization table T_OS_COMMAND in directory UTIL_DIR with preprocessor os_command

    Sample: UTIL_DIR is '/u01'
      touch /u01/os_command.sh
      chmod ug+x /u01/os_command.sh

Gor work 

*/


create or replace directory UTIL_DIR as '/u01';

CREATE TABLE T_OS_COMMAND  (
 v_line varchar2(4000)  )
 ORGANIZATION external
 ( TYPE oracle_loader
 DEFAULT DIRECTORY UTIL_DIR
 ACCESS PARAMETERS
 ( RECORDS DELIMITED BY NEWLINE
 preprocessor UTIL_DIR:'os_command.sh'
 FIELDS TERMINATED BY "\n" LDRTRIM
 )
 location ( 'os_command.sh')
 )
/
/*
comment on table T_OS_COMMAND is 'Execute external script as preprocessor and return it stdout to rows';
comment on column T_OS_COMMAND.V_LINE is 'line from stdout execute script';
*/

create table T_SPACE_USAGE (
  dt$ date,
  owner$ varchar2(30),
  tablespace$ varchar2(30),
  type$ varchar2(18),
  bytes$ number,
  blocks$ number);
create index INDX_T_SPACE_USAGE_DT on T_SPACE_USAGE (dt$);
comment on table T_SPACE_USAGE is 'Store archive data of usage space in RDBMS';
comment on column T_SPACE_USAGE.DT$ is 'Date collect space usage';
comment on column T_SPACE_USAGE.OWNER$ is 'Segment owner - user in BD';
comment on column T_SPACE_USAGE.TABLESPACE$ is 'Name of tablespace in BD';
comment on column T_SPACE_USAGE.TYPE$ is 'Segment type';
comment on column T_SPACE_USAGE.BYTES$ is 'Size in bytes';
comment on column T_SPACE_USAGE.BLOCKS$ is 'Size in blocks';
</pre>
